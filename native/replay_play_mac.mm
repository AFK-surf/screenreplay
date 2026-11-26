#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

#include "replay_mac_common.h"

__asm__(".linker_option \"-framework\", \"AudioToolbox\"");

namespace {

struct RpKept {
  std::string path;
  int fd = -1;
  uint64_t used = 0;
};

static RpKept rp_kept[6];
static std::mutex rp_kept_mu;
static uint64_t rp_kept_clock = 0;

static int rp_play_open_fd(const char *utf8) {
  if (!utf8 || !utf8[0]) return -1;
  int fd = open(utf8, O_RDONLY);
  if (fd >= 0) {
    struct stat st;
    if (fstat(fd, &st) != 0 || S_ISDIR(st.st_mode)) {
      close(fd);
      return -1;
    }
  }
  return fd;
}

// Caller must hold rp_kept_mu.
static bool rp_kept_put(const std::string &path, int fd) {
  int slot = 0;
  for (int i = 0; i < 6; i++) {
    if (rp_kept[i].fd >= 0 && rp_kept[i].path == path) return false;
    if (rp_kept[i].fd < 0) {
      slot = i;
      break;
    }
    if (rp_kept[i].used < rp_kept[slot].used) slot = i;
  }
  if (rp_kept[slot].fd >= 0) close(rp_kept[slot].fd);
  rp_kept[slot].path = path;
  rp_kept[slot].fd = fd;
  rp_kept[slot].used = ++rp_kept_clock;
  return true;
}

static std::vector<std::string> rp_warmed;
static std::vector<std::string> rp_warm_todo;
static std::condition_variable rp_warm_wake;
static bool rp_warm_started = false;
static std::atomic<int64_t> rp_warm_gen{0};

static void rp_warm_loop() {
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
  std::vector<uint8_t> buf(1 << 20);
  for (;;) {
    std::string p;
    int64_t gen = 0;
    {
      std::unique_lock<std::mutex> lock(rp_kept_mu);
      rp_warm_wake.wait(lock, [] { return !rp_warm_todo.empty(); });
      p = rp_warm_todo.back();
      rp_warm_todo.pop_back();
      gen = rp_warm_gen.load();
    }
    int fd = rp_play_open_fd(p.c_str());
    if (fd < 0) continue;
    off_t off = 0;
    while (rp_warm_gen.load() == gen) {
      ssize_t got = pread(fd, buf.data(), buf.size(), off);
      if (got < 0) {
        if (errno == EINTR) continue;
        break;
      }
      if (got == 0) break;
      off += got;
    }
    bool kept = false;
    {
      std::lock_guard<std::mutex> lock(rp_kept_mu);
      kept = rp_kept_put(p, fd);
    }
    if (!kept) close(fd);
  }
}

}

extern "C" moonbit_bytes_t rp_play_read(moonbit_bytes_t path, double offset, int32_t length) {
  if (length <= 0) return moonbit_make_bytes(0, 0);
  std::string p = rp_str(path);
  if (p.empty()) return moonbit_make_bytes(0, 0);

  moonbit_bytes_t out = moonbit_make_bytes(length, 0);
  int32_t total = 0;
  {
    std::lock_guard<std::mutex> lock(rp_kept_mu);
    int fd = -1;
    for (int i = 0; i < 6; i++) {
      if (rp_kept[i].fd >= 0 && rp_kept[i].path == p) {
        fd = rp_kept[i].fd;
        rp_kept[i].used = ++rp_kept_clock;
        break;
      }
    }
    if (fd < 0) {
      int o = rp_play_open_fd(p.c_str());
      if (o >= 0) {
        rp_kept_put(p, o);
        fd = o;
      }
    }
    if (fd >= 0) {
      off_t off = offset > 0.0 ? (off_t)offset : 0;
      while (total < length) {
        ssize_t got = pread(fd, out + total, (size_t)(length - total), off + total);
        if (got < 0) {
          if (errno == EINTR) continue;
          total = 0;
          break;
        }
        if (got == 0) break;
        total += (int32_t)got;
      }
    }
  }
  if (total == length) return out;
  return rp_bytes_from(out, (size_t)total);
}

extern "C" void rp_play_warm(moonbit_bytes_t path) {
  std::string p = rp_str(path);
  if (p.empty()) return;
  std::lock_guard<std::mutex> lock(rp_kept_mu);
  for (const auto &w : rp_warmed) {
    if (w == p) return;
  }
  rp_warmed.push_back(p);
  if (rp_warmed.size() > 64) rp_warmed.erase(rp_warmed.begin());
  rp_warm_todo.push_back(p);
  if (rp_warm_todo.size() > 3) rp_warm_todo.erase(rp_warm_todo.begin());
  rp_warm_gen.fetch_add(1);
  if (!rp_warm_started) {
    rp_warm_started = true;
    try {
      std::thread(rp_warm_loop).detach();
    } catch (...) {
      rp_warm_started = false;
      rp_warm_todo.clear();
    }
  }
  rp_warm_wake.notify_one();
}

extern "C" void rp_play_release(void) {
  std::lock_guard<std::mutex> lock(rp_kept_mu);
  for (auto &k : rp_kept) {
    if (k.fd >= 0) close(k.fd);
    k.fd = -1;
    k.path.clear();
    k.used = 0;
  }
  rp_warmed.clear();
  rp_warm_todo.clear();
  rp_warm_gen.fetch_add(1);
}

namespace {

static const OSStatus kRpNeedMoreInput = 0x52504D49;  // 'RPMI'

static void rp_push_descr_len(std::vector<uint8_t> &b, uint32_t len) {
  b.push_back((uint8_t)(0x80 | ((len >> 21) & 0x7F)));
  b.push_back((uint8_t)(0x80 | ((len >> 14) & 0x7F)));
  b.push_back((uint8_t)(0x80 | ((len >> 7) & 0x7F)));
  b.push_back((uint8_t)(len & 0x7F));
}

// Build ISO/IEC 14496-1 ES_Descr payload from raw AudioSpecificConfig bytes for kAudioConverterDecompressionMagicCookie.
static std::vector<uint8_t> rp_make_esds_cookie(const uint8_t *asc, size_t asc_len) {
  std::vector<uint8_t> dec_spec;
  dec_spec.push_back(0x05);  // DecSpecificInfoTag
  rp_push_descr_len(dec_spec, (uint32_t)asc_len);
  dec_spec.insert(dec_spec.end(), asc, asc + asc_len);

  std::vector<uint8_t> dec_cfg;
  dec_cfg.push_back(0x04);  // DecoderConfigDescrTag
  rp_push_descr_len(dec_cfg, (uint32_t)(13 + dec_spec.size()));
  dec_cfg.push_back(0x40);  // Audio ISO/IEC 14496-3
  dec_cfg.push_back(0x15);  // AudioStream (0x05 << 2 | 0x01)
  dec_cfg.push_back(0x00);
  dec_cfg.push_back(0x00);
  dec_cfg.push_back(0x00);  // bufferSizeDB
  for (int i = 0; i < 8; i++) dec_cfg.push_back(0x00);  // maxBitrate + avgBitrate
  dec_cfg.insert(dec_cfg.end(), dec_spec.begin(), dec_spec.end());

  std::vector<uint8_t> sl_cfg;
  sl_cfg.push_back(0x06);  // SLConfigDescrTag
  rp_push_descr_len(sl_cfg, 1);
  sl_cfg.push_back(0x02);  // predefined = 2

  std::vector<uint8_t> esds;
  esds.push_back(0x03);  // ES_DescrTag
  rp_push_descr_len(esds, (uint32_t)(3 + dec_cfg.size() + sl_cfg.size()));
  esds.push_back(0x00);
  esds.push_back(0x00);  // ES_ID = 0
  esds.push_back(0x00);  // flags = 0
  esds.insert(esds.end(), dec_cfg.begin(), dec_cfg.end());
  esds.insert(esds.end(), sl_cfg.begin(), sl_cfg.end());
  return esds;
}

struct RpAac {
  AudioConverterRef conv = nullptr;
  int rate = 48000;
  int channels = 2;
  uint32_t frames_per_packet = 1024;
  double phase = 0.0;
  int16_t last_l = 0, last_r = 0;
  bool have_last = false;
  std::vector<int16_t> decode_buf;
};

struct RpAacFeedCtx {
  const uint8_t *data;
  UInt32 len;
  UInt32 channels;
  bool fed;
  AudioStreamPacketDescription desc;
};

static OSStatus rp_aac_input_proc(AudioConverterRef,
                                  UInt32 *ioNumberDataPackets,
                                  AudioBufferList *ioData,
                                  AudioStreamPacketDescription **outDataPacketDescription,
                                  void *inUserData) {
  RpAacFeedCtx *ctx = (RpAacFeedCtx *)inUserData;
  if (ctx->fed || ctx->len == 0) {
    *ioNumberDataPackets = 0;
    return kRpNeedMoreInput;
  }
  ctx->fed = true;
  *ioNumberDataPackets = 1;
  ioData->mBuffers[0].mNumberChannels = ctx->channels;
  ioData->mBuffers[0].mDataByteSize = ctx->len;
  ioData->mBuffers[0].mData = (void *)ctx->data;
  if (outDataPacketDescription) {
    ctx->desc.mStartOffset = 0;
    ctx->desc.mVariableFramesInPacket = 0;
    ctx->desc.mDataByteSize = ctx->len;
    *outDataPacketDescription = &ctx->desc;
  }
  return noErr;
}

static std::vector<RpAac *> rp_aacs;

static RpAac *rp_aac_of(int32_t h) {
  return h >= 1 && h <= (int32_t)rp_aacs.size() ? rp_aacs[(size_t)(h - 1)] : nullptr;
}

static void rp_aac_to48(RpAac *a, const int16_t *s, size_t frames, std::vector<int16_t> &to) {
  int ch = a->channels;
  if (a->rate == 48000) {
    for (size_t i = 0; i < frames; i++) {
      to.push_back(s[i * ch]);
      to.push_back(ch > 1 ? s[i * ch + 1] : s[i * ch]);
    }
    return;
  }
  double step = (double)a->rate / 48000.0;
  for (size_t i = 0; i < frames; i++) {
    int16_t l = s[i * ch], r = ch > 1 ? s[i * ch + 1] : s[i * ch];
    if (!a->have_last) {
      a->last_l = l;
      a->last_r = r;
      a->have_last = true;
      continue;
    }
    while (a->phase < 1.0) {
      double f = a->phase;
      to.push_back((int16_t)(a->last_l + (l - a->last_l) * f));
      to.push_back((int16_t)(a->last_r + (r - a->last_r) * f));
      a->phase += step;
    }
    a->phase -= 1.0;
    a->last_l = l;
    a->last_r = r;
  }
}

}

extern "C" int32_t rp_aac_open(moonbit_bytes_t asc, int32_t rate, int32_t channels) {
  int32_t n = asc ? Moonbit_array_length(asc) : 0;
  if (n <= 0 || rate <= 0 || channels <= 0) return 0;

  std::vector<uint8_t> cookie = rp_make_esds_cookie((const uint8_t *)asc, (size_t)n);

  AudioStreamBasicDescription in_asbd = {};
  in_asbd.mFormatID = kAudioFormatMPEG4AAC;
  UInt32 info_size = sizeof(in_asbd);
  OSStatus info_st = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                            (UInt32)cookie.size(), cookie.data(),
                                            &info_size, &in_asbd);
  if (info_st != noErr || in_asbd.mSampleRate <= 0 || in_asbd.mChannelsPerFrame == 0) {
    memset(&in_asbd, 0, sizeof(in_asbd));
    in_asbd.mSampleRate = (Float64)rate;
    in_asbd.mFormatID = kAudioFormatMPEG4AAC;
    in_asbd.mChannelsPerFrame = (UInt32)channels;
    in_asbd.mFramesPerPacket = 1024;
  }

  int actual_rate = in_asbd.mSampleRate > 0 ? (int)(in_asbd.mSampleRate + 0.5) : rate;
  int actual_ch = in_asbd.mChannelsPerFrame > 0 ? (int)in_asbd.mChannelsPerFrame : channels;
  uint32_t fpp = in_asbd.mFramesPerPacket > 0 ? in_asbd.mFramesPerPacket : 1024;

  AudioStreamBasicDescription out_asbd = {};
  out_asbd.mSampleRate = (Float64)actual_rate;
  out_asbd.mFormatID = kAudioFormatLinearPCM;
  out_asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  out_asbd.mBytesPerPacket = (UInt32)(actual_ch * 2);
  out_asbd.mFramesPerPacket = 1;
  out_asbd.mBytesPerFrame = (UInt32)(actual_ch * 2);
  out_asbd.mChannelsPerFrame = (UInt32)actual_ch;
  out_asbd.mBitsPerChannel = 16;

  AudioConverterRef conv = nullptr;
  if (AudioConverterNew(&in_asbd, &out_asbd, &conv) != noErr || !conv) return 0;

  OSStatus cookie_st = AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                                 (UInt32)cookie.size(), cookie.data());
  if (cookie_st != noErr) {
    // Fallback: some AudioConverter configurations accept raw AudioSpecificConfig directly
    cookie_st = AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                          (UInt32)n, (const void *)asc);
    if (cookie_st != noErr) {
      AudioConverterDispose(conv);
      return 0;
    }
  }

  RpAac *a = new RpAac();
  a->conv = conv;
  a->rate = actual_rate;
  a->channels = actual_ch;
  a->frames_per_packet = fpp;
  a->decode_buf.resize((size_t)fpp * 4 * (size_t)actual_ch);

  for (size_t i = 0; i < rp_aacs.size(); i++) {
    if (!rp_aacs[i]) {
      rp_aacs[i] = a;
      return (int32_t)i + 1;
    }
  }
  rp_aacs.push_back(a);
  return (int32_t)rp_aacs.size();
}

extern "C" moonbit_bytes_t rp_aac_decode(int32_t h, moonbit_bytes_t data) {
  RpAac *a = rp_aac_of(h);
  std::vector<int16_t> pcm;
  int32_t n = data ? Moonbit_array_length(data) : 0;
  if (a && a->conv && n > 0) {
    RpAacFeedCtx ctx = {(const uint8_t *)data, (UInt32)n, (UInt32)a->channels, false, {}};
    for (int guard = 0; guard < 4; guard++) {
      UInt32 want_frames = a->frames_per_packet;
      AudioBufferList abl = {};
      abl.mNumberBuffers = 1;
      abl.mBuffers[0].mNumberChannels = (UInt32)a->channels;
      abl.mBuffers[0].mDataByteSize = want_frames * (UInt32)(a->channels * 2);
      abl.mBuffers[0].mData = a->decode_buf.data();

      OSStatus st = AudioConverterFillComplexBuffer(a->conv, rp_aac_input_proc, &ctx, &want_frames, &abl, nullptr);
      if (want_frames > 0) {
        rp_aac_to48(a, a->decode_buf.data(), (size_t)want_frames, pcm);
      }
      if (st != noErr || ctx.fed) break;
    }
  }
  return rp_bytes_from(pcm.data(), pcm.size() * sizeof(int16_t));
}

extern "C" void rp_aac_reset(int32_t h) {
  RpAac *a = rp_aac_of(h);
  if (!a) return;
  if (a->conv) AudioConverterReset(a->conv);
  a->phase = 0.0;
  a->have_last = false;
}

extern "C" void rp_aac_release_all(void) {
  for (auto &a : rp_aacs) {
    if (!a) continue;
    if (a->conv) AudioConverterDispose(a->conv);
    delete a;
    a = nullptr;
  }
}

extern "C" void rp_aac_close(int32_t h) {
  RpAac *a = rp_aac_of(h);
  if (!a) return;
  if (a->conv) AudioConverterDispose(a->conv);
  delete a;
  rp_aacs[(size_t)(h - 1)] = nullptr;
}

namespace {

struct RpTs {
  double rate;
  std::vector<float> l, r;
  double pos;
  long nat;
  std::vector<float> acc_l, acc_r, win;
};

static const int RP_TS_W = 1536, RP_TS_HS = 768, RP_TS_DL = 480;
static std::vector<RpTs *> rp_tss;

static RpTs *rp_ts_of(int32_t h) {
  return h >= 1 && h <= (int32_t)rp_tss.size() ? rp_tss[(size_t)(h - 1)] : nullptr;
}

static float rp_ts_fit(const RpTs *t, long a, long b) {
  const float *xl = t->l.data() + a, *yl = t->l.data() + b;
  const float *xr = t->r.data() + a, *yr = t->r.data() + b;
  float xy = 0, xx = 1e-3f;
  for (int j = 0; j < RP_TS_W; j += 2) {
    xy += xl[j] * yl[j] + xr[j] * yr[j];
    xx += xl[j] * xl[j] + xr[j] * xr[j];
  }
  return xy / sqrtf(xx);
}

}

extern "C" int32_t rp_ts_open(double rate) {
  RpTs *t = new RpTs();
  t->rate = rate < 0.25 ? 0.25 : (rate > 8.0 ? 8.0 : rate);
  t->pos = 0;
  t->nat = -1;
  t->acc_l.assign(RP_TS_W, 0.f);
  t->acc_r.assign(RP_TS_W, 0.f);
  t->win.resize(RP_TS_W);
  for (int i = 0; i < RP_TS_W; i++) t->win[(size_t)i] = (float)(0.5 - 0.5 * cos(6.283185307179586 * i / RP_TS_W));
  for (size_t i = 0; i < rp_tss.size(); i++) {
    if (!rp_tss[i]) {
      rp_tss[i] = t;
      return (int32_t)i + 1;
    }
  }
  rp_tss.push_back(t);
  return (int32_t)rp_tss.size();
}

extern "C" void rp_ts_close(int32_t h) {
  RpTs *t = rp_ts_of(h);
  if (!t) return;
  delete t;
  rp_tss[(size_t)(h - 1)] = nullptr;
}

extern "C" moonbit_bytes_t rp_ts_feed(int32_t h, moonbit_bytes_t data, int32_t from, int32_t flush) {
  RpTs *t = rp_ts_of(h);
  std::vector<int16_t> out;
  if (t) {
    int32_t n = data ? Moonbit_array_length(data) : 0;
    if (from < 0) from = 0;
    const int16_t *p = (const int16_t *)(data + from);
    long frames = from < n ? (n - from) / 4 : 0;
    for (long i = 0; i < frames; i++) {
      float l = p[2 * i] / 32768.f, r = p[2 * i + 1] / 32768.f;
      t->l.push_back(l);
      t->r.push_back(r);
    }
    if (flush) {
      for (int i = 0; i < RP_TS_W + RP_TS_HS + 2 * RP_TS_DL; i++) {
        t->l.push_back(0);
        t->r.push_back(0);
      }
    }
    for (;;) {
      long at = (long)t->pos;
      long len = (long)t->l.size();
      if (at + RP_TS_DL + RP_TS_HS + RP_TS_W > len) break;
      long seg = at;
      if (t->nat >= 0) {
        long lo = at - RP_TS_DL < 0 ? 0 : at - RP_TS_DL, hi = at + RP_TS_DL;
        float best = rp_ts_fit(t, at, t->nat);
        for (long k = lo; k <= hi; k += 4) {
          float f = rp_ts_fit(t, k, t->nat);
          if (f > best) best = f, seg = k;
        }
        long c = seg;
        for (long k = c - 3; k <= c + 3; k++) {
          if (k < lo || k > hi || k == c) continue;
          float f = rp_ts_fit(t, k, t->nat);
          if (f > best) best = f, seg = k;
        }
      }
      for (int j = 0; j < RP_TS_W; j++) {
        t->acc_l[(size_t)j] += t->win[(size_t)j] * t->l[(size_t)(seg + j)];
        t->acc_r[(size_t)j] += t->win[(size_t)j] * t->r[(size_t)(seg + j)];
      }
      for (int j = 0; j < RP_TS_HS; j++) {
        float l = t->acc_l[(size_t)j] * 32767.f, r = t->acc_r[(size_t)j] * 32767.f;
        out.push_back((int16_t)(l > 32767.f ? 32767 : (l < -32768.f ? -32768 : l)));
        out.push_back((int16_t)(r > 32767.f ? 32767 : (r < -32768.f ? -32768 : r)));
      }
      memmove(t->acc_l.data(), t->acc_l.data() + RP_TS_HS, (RP_TS_W - RP_TS_HS) * sizeof(float));
      memmove(t->acc_r.data(), t->acc_r.data() + RP_TS_HS, (RP_TS_W - RP_TS_HS) * sizeof(float));
      for (int j = RP_TS_W - RP_TS_HS; j < RP_TS_W; j++) t->acc_l[(size_t)j] = t->acc_r[(size_t)j] = 0.f;
      t->nat = seg + RP_TS_HS;
      t->pos += RP_TS_HS * t->rate;
      long drop = (long)t->pos - RP_TS_DL;
      if (t->nat < drop) drop = t->nat;
      if (drop > 8192) {
        t->l.erase(t->l.begin(), t->l.begin() + drop);
        t->r.erase(t->r.begin(), t->r.begin() + drop);
        t->pos -= drop;
        t->nat -= drop;
      }
    }
  }
  return rp_bytes_from(out.data(), out.size() * sizeof(int16_t));
}

extern "C" double rp_ts_lag(int32_t h) {
  RpTs *t = rp_ts_of(h);
  if (!t) return 0;
  return (double)t->l.size() - t->pos - RP_TS_HS * (1.0 - t->rate);
}
