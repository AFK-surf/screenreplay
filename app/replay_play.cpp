// The player's reads of its files, and its sound (native_player.mbt).
//
// Its reads (rp_play_read): each file kept open for the next read of it, the last few of them, so a frame's bytes
// cost the read alone; opening the file for every frame took 8 to 18 ms a 4K frame here (the system's scan of a file
// as it opens), more than a frame's time. Opened shared (the recorder may let a segment go meanwhile: it goes once
// the handle closes). A file about to be read (the next segment) opened ahead on a thread of its own (rp_play_warm).
//
// Its sound: a segment's AAC frames, as its MP4 holds them (mp4.mbt's `soun` track,
// its AudioSpecificConfig), decoded one at a time by Media Foundation's AAC decoder (an MFT driven here, on the
// window's thread: a frame of 1024 samples decodes in well under a millisecond) into what an mbui stream plays,
// 48 kHz stereo PCM16 (@ui.Stream::audio). Mono is played on both sides, more than two channels as their first two,
// another rate brought to 48 kHz by straight lines between samples.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <string>
#include <thread>
#include "moonbit.h"

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "wmcodecdspuuid.lib")
#pragma comment(lib, "ole32.lib")

// ---- reads ----

struct RpKept {
  std::string path;
  HANDLE h;
  ULONGLONG used;
};

static RpKept rp_kept[6];
static SRWLOCK rp_kept_lock = SRWLOCK_INIT;
static ULONGLONG rp_kept_clock;

static HANDLE rp_play_open(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  if (n <= 0) return INVALID_HANDLE_VALUE;
  std::wstring w(n, L' ');
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
  return CreateFileW(w.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}

// (under the lock) `h` kept for `path`, in the place of the one used longest ago; false where one is kept already
static bool rp_kept_put(const std::string &path, HANDLE h) {
  int slot = 0;
  for (int i = 0; i < 6; i++) {
    if (rp_kept[i].h && rp_kept[i].path == path) return false;
    if (!rp_kept[i].h) {
      slot = i;
      break;
    }
    if (rp_kept[i].used < rp_kept[slot].used) slot = i;
  }
  if (rp_kept[slot].h) CloseHandle(rp_kept[slot].h);
  rp_kept[slot].path = path;
  rp_kept[slot].h = h;
  rp_kept[slot].used = ++rp_kept_clock;
  return true;
}

// `length` bytes of the file at `path` from `offset` (fewer at its end; none where it cannot be read).
extern "C" moonbit_bytes_t rp_play_read(moonbit_bytes_t path, double offset, int32_t length) {
  if (length <= 0) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = moonbit_make_bytes(length, 0);
  std::string p((const char *)path);
  HANDLE h = nullptr;
  AcquireSRWLockExclusive(&rp_kept_lock);
  for (int i = 0; i < 6; i++) {
    if (rp_kept[i].h && rp_kept[i].path == p) {
      h = rp_kept[i].h;
      rp_kept[i].used = ++rp_kept_clock;
      break;
    }
  }
  if (!h) {
    HANDLE o = rp_play_open(p.c_str());
    if (o != INVALID_HANDLE_VALUE) {
      rp_kept_put(p, o);
      h = o;
    }
  }
  DWORD got = 0;
  if (h) {
    OVERLAPPED at = {};
    ULONGLONG off = (ULONGLONG)offset;
    at.Offset = (DWORD)off;
    at.OffsetHigh = (DWORD)(off >> 32);
    if (!ReadFile(h, out, (DWORD)length, &got, &at)) got = 0;
  }
  ReleaseSRWLockExclusive(&rp_kept_lock);
  if ((int32_t)got == length) return out;
  moonbit_bytes_t trimmed = moonbit_make_bytes((int32_t)got, 0);
  if (got) memcpy(trimmed, out, got);
  return trimmed;
}

// The files warmed in this run (each once till the window is put away: rp_play_release).
static std::vector<std::string> rp_warmed;

// The files asked to be warmed and not begun yet, newest last; the one thread that warms them (started at the first
// ask, kept for the process's life: a window may be put away while it reads). Before, each ask started a thread of its
// own, and a fast run across many segments started dozens at once, each reading its whole file: the disk was busy
// with all of them while the frames asked for waited behind.
static std::vector<std::string> rp_warm_todo;
static CONDITION_VARIABLE rp_warm_wake = CONDITION_VARIABLE_INIT;
static bool rp_warm_started;
// (raised by each ask and by rp_play_release: a read-through under way gives way to what is asked for now)
static volatile LONG rp_warm_gen;

static void rp_warm_loop() {
  std::vector<uint8_t> buf(1 << 20);
  for (;;) {
    AcquireSRWLockExclusive(&rp_kept_lock);
    while (rp_warm_todo.empty()) SleepConditionVariableSRW(&rp_warm_wake, &rp_kept_lock, INFINITE, 0);
    // (the newest asked first: the oldest asks are for segments played past already)
    std::string p = rp_warm_todo.back();
    rp_warm_todo.pop_back();
    LONG gen = rp_warm_gen;
    ReleaseSRWLockExclusive(&rp_kept_lock);
    HANDLE h = rp_play_open(p.c_str());
    if (h == INVALID_HANDLE_VALUE) continue;
    // (read through once, so its bytes are in the system's cache when its frames are read; given up where another file
    // is asked for meanwhile)
    DWORD got = 0;
    while (rp_warm_gen == gen && ReadFile(h, buf.data(), (DWORD)buf.size(), &got, nullptr) && got > 0) {
    }
    // (the same handle then kept for the reads to come: the file opened once; its position is no matter, every read
    // says where)
    AcquireSRWLockExclusive(&rp_kept_lock);
    bool kept = rp_kept_put(p, h);
    ReleaseSRWLockExclusive(&rp_kept_lock);
    if (!kept) CloseHandle(h);
  }
}

// The file at `path` opened off the window's thread, kept for the reads to come, and read through once there so its
// bytes are in the system's cache when its frames are read (a frame read cold from the disk took 12 to 24 ms here).
extern "C" void rp_play_warm(moonbit_bytes_t path) {
  std::string p((const char *)path);
  AcquireSRWLockExclusive(&rp_kept_lock);
  bool there = false;
  for (auto &w : rp_warmed) there = there || w == p;
  if (!there) {
    rp_warmed.push_back(p);
    if (rp_warmed.size() > 64) rp_warmed.erase(rp_warmed.begin());
    rp_warm_todo.push_back(p);
    // (at most a few waiting: the oldest let go)
    if (rp_warm_todo.size() > 3) rp_warm_todo.erase(rp_warm_todo.begin());
    InterlockedIncrement(&rp_warm_gen);
    if (!rp_warm_started) {
      rp_warm_started = true;
      try {
        std::thread(rp_warm_loop).detach();
      } catch (...) {
        rp_warm_started = false;
        rp_warm_todo.clear();
      }
    }
    WakeConditionVariable(&rp_warm_wake);
  }
  ReleaseSRWLockExclusive(&rp_kept_lock);
}

// Every file kept open let go of (the window put away, rp_play_release): a segment the recorder has let go of since
// is gone from the disk only once nothing holds it; what is warmed is warmed again when asked.
extern "C" void rp_play_release(void) {
  AcquireSRWLockExclusive(&rp_kept_lock);
  for (auto &k : rp_kept) {
    if (k.h) CloseHandle(k.h);
    k.h = nullptr;
    k.path.clear();
    k.used = 0;
  }
  rp_warmed.clear();
  rp_warm_todo.clear();
  InterlockedIncrement(&rp_warm_gen);
  ReleaseSRWLockExclusive(&rp_kept_lock);
}

// ---- sound ----

struct RpAac {
  IMFTransform *mft;
  int rate, channels;
  bool own_samples;  // the decoder hands out its own output samples
  DWORD out_size;
  // (another rate than 48 kHz: where between the last input sample and the next the next output one falls, and that
  // last sample's two sides)
  double phase;
  int16_t last_l, last_r;
  bool have_last;
};

static std::vector<RpAac *> rp_aacs;

static RpAac *rp_aac_of(int32_t h) {
  return h >= 1 && h <= (int32_t)rp_aacs.size() ? rp_aacs[h - 1] : nullptr;
}

extern "C" int32_t rp_aac_open(moonbit_bytes_t asc, int32_t rate, int32_t channels) {
  int32_t n = (int32_t)Moonbit_array_length(asc);
  if (n <= 0 || rate <= 0 || channels <= 0) return 0;
  // (COM and Media Foundation started once on the window's thread, kept for its life: started again at each decoder
  // made, their counts only grew)
  static int started = 0;
  if (started == 0) {
    HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    (void)co;
    started = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE)) ? 1 : -1;
  }
  if (started < 0) return 0;
  IMFTransform *mft = nullptr;
  if (FAILED(CoCreateInstance(CLSID_CMSAACDecMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&mft)))) return 0;
  IMFMediaType *in = nullptr, *out = nullptr;
  bool ok = SUCCEEDED(MFCreateMediaType(&in));
  if (ok) {
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)rate);
    in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    in->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
    in->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
    // (HEAACWAVEINFO's fields after its WAVEFORMATEX: raw payload, profile unknown; then the AudioSpecificConfig)
    std::vector<uint8_t> ud(12 + n, 0);
    ud[2] = 0xFE;
    memcpy(ud.data() + 12, asc, n);
    in->SetBlob(MF_MT_USER_DATA, ud.data(), (UINT32)ud.size());
    ok = SUCCEEDED(mft->SetInputType(0, in, 0));
  }
  if (ok) ok = SUCCEEDED(MFCreateMediaType(&out));
  if (ok) {
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)rate);
    out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    out->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, (UINT32)(channels * 2));
    out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, (UINT32)(rate * channels * 2));
    ok = SUCCEEDED(mft->SetOutputType(0, out, 0));
  }
  MFT_OUTPUT_STREAM_INFO info = {};
  if (ok) ok = SUCCEEDED(mft->GetOutputStreamInfo(0, &info));
  if (in) in->Release();
  if (out) out->Release();
  if (!ok) {
    mft->Release();
    return 0;
  }
  mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  RpAac *a = new RpAac();
  a->mft = mft;
  a->rate = rate;
  a->channels = channels;
  a->own_samples = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
  a->out_size = info.cbSize > 0 ? info.cbSize : 1024 * 8 * 2;
  // (a place one closed left taken again: the table no longer grows by one each decoder made)
  for (size_t i = 0; i < rp_aacs.size(); i++) {
    if (!rp_aacs[i]) {
      rp_aacs[i] = a;
      return (int32_t)i + 1;
    }
  }
  rp_aacs.push_back(a);
  return (int32_t)rp_aacs.size();
}

// PCM16 of the decoder's channels and rate, made 48 kHz stereo onto `to`.
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
    // (the output samples between the last input sample and this one)
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

// What the decoder has ready, onto `to`; false where it broke.
static bool rp_aac_drain(RpAac *a, std::vector<int16_t> &to) {
  for (int guard = 0; guard < 64; guard++) {
    MFT_OUTPUT_DATA_BUFFER ob = {};
    IMFSample *mine = nullptr;
    if (!a->own_samples) {
      IMFMediaBuffer *buf = nullptr;
      if (FAILED(MFCreateSample(&mine)) || FAILED(MFCreateMemoryBuffer(a->out_size, &buf))) {
        if (mine) mine->Release();
        return false;
      }
      mine->AddBuffer(buf);
      buf->Release();
      ob.pSample = mine;
    }
    DWORD status = 0;
    HRESULT hr = a->mft->ProcessOutput(0, 1, &ob, &status);
    if (ob.pEvents) ob.pEvents->Release();
    IMFSample *got = ob.pSample;
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
      if (got) got->Release();
      return true;
    }
    if (FAILED(hr)) {
      if (got) got->Release();
      return false;
    }
    if (got) {
      IMFMediaBuffer *buf = nullptr;
      if (SUCCEEDED(got->ConvertToContiguousBuffer(&buf))) {
        BYTE *p = nullptr;
        DWORD len = 0;
        if (SUCCEEDED(buf->Lock(&p, nullptr, &len))) {
          rp_aac_to48(a, (const int16_t *)p, len / (2 * a->channels), to);
          buf->Unlock();
        }
        buf->Release();
      }
      got->Release();
    }
  }
  return true;
}

// One AAC frame decoded: 48 kHz stereo PCM16 (empty while the decoder holds it back, or where it broke).
extern "C" moonbit_bytes_t rp_aac_decode(int32_t h, moonbit_bytes_t data) {
  RpAac *a = rp_aac_of(h);
  std::vector<int16_t> pcm;
  int32_t n = (int32_t)Moonbit_array_length(data);
  if (a && n > 0) {
    IMFSample *s = nullptr;
    IMFMediaBuffer *buf = nullptr;
    if (SUCCEEDED(MFCreateSample(&s)) && SUCCEEDED(MFCreateMemoryBuffer((DWORD)n, &buf))) {
      BYTE *p = nullptr;
      if (SUCCEEDED(buf->Lock(&p, nullptr, nullptr))) {
        memcpy(p, data, n);
        buf->Unlock();
        buf->SetCurrentLength((DWORD)n);
        s->AddBuffer(buf);
        HRESULT hr = a->mft->ProcessInput(0, s, 0);
        if (hr == MF_E_NOTACCEPTING) {
          rp_aac_drain(a, pcm);
          hr = a->mft->ProcessInput(0, s, 0);
        }
        if (SUCCEEDED(hr)) rp_aac_drain(a, pcm);
      }
    }
    if (buf) buf->Release();
    if (s) s->Release();
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(pcm.size() * 2), 0);
  if (!pcm.empty()) memcpy(out, pcm.data(), pcm.size() * 2);
  return out;
}

// What the decoder holds let go (a seek): the next frame decodes on its own.
extern "C" void rp_aac_reset(int32_t h) {
  RpAac *a = rp_aac_of(h);
  if (!a) return;
  a->mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  a->phase = 0;
  a->have_last = false;
}

// Every sound decoder let go of (the window hidden: rp_resident_proc). Each handle the app holds is then of none (its
// decodes give nothing and its close does nothing); the app makes a new one as it next sounds (Deck::rest, as it shows).
extern "C" void rp_aac_release_all(void) {
  for (auto &a : rp_aacs) {
    if (!a) continue;
    a->mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    a->mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    a->mft->Release();
    delete a;
    a = nullptr;
  }
}

extern "C" void rp_aac_close(int32_t h) {
  RpAac *a = rp_aac_of(h);
  if (!a) return;
  a->mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  a->mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  a->mft->Release();
  delete a;
  rp_aacs[h - 1] = nullptr;
}
