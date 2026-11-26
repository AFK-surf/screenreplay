#import "replay_mac_common.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <sstream>
#include <thread>

namespace {

static bool has_gif_ext(const std::string &path) {
  if (path.size() < 4) return false;
  std::string ext = path.substr(path.size() - 4);
  for (char &c : ext) {
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
  }
  return ext == ".gif";
}

static double gif_duration_ms(const std::string &path) {
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    if (!url) return -1.0;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!src) return -1.0;
    size_t count = CGImageSourceGetCount(src);
    if (count == 0) {
      CFRelease(src);
      return -1.0;
    }
    double total = 0.0;
    for (size_t i = 0; i < count; i++) {
      double delay_s = 0.1;
      CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, i, nullptr);
      if (props) {
        CFDictionaryRef gif = (CFDictionaryRef)CFDictionaryGetValue(props, kCGImagePropertyGIFDictionary);
        if (gif) {
          CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(gif, kCGImagePropertyGIFUnclampedDelayTime);
          if (!n) n = (CFNumberRef)CFDictionaryGetValue(gif, kCGImagePropertyGIFDelayTime);
          if (n) {
            double v = 0.0;
            if (CFNumberGetValue(n, kCFNumberDoubleType, &v) && v >= 0.02) delay_s = v;
          }
        }
        CFRelease(props);
      }
      total += delay_s * 1000.0;
    }
    CFRelease(src);
    return total > 0.0 ? total : -1.0;
  }
}

static std::vector<uint8_t> gif_first_frame_bmp(const std::string &path, int max_w, int max_h,
                                                int cx, int cy, int cw, int ch) {
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    if (!url) return {};
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!src) return {};
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
    CFRelease(src);
    if (!img) return {};
    std::vector<uint8_t> bgra;
    int w = 0, h = 0;
    bool ok = rp_cgimage_to_bgra(img, max_w, max_h, cx, cy, cw, ch, bgra, w, h);
    CGImageRelease(img);
    if (!ok) return {};
    return rp_bmp_from_bgra(bgra.data(), w, h, w * 4);
  }
}

struct CachedDecodedFrame {
  std::mutex mu;
  std::string file;
  double ms = -1e9;
  CGImageRef img = nullptr;

  ~CachedDecodedFrame() { clear(); }

  void clear() {
    if (img) {
      CGImageRelease(img);
      img = nullptr;
    }
    file.clear();
    ms = -1e9;
  }
};

static CachedDecodedFrame *g_decoded_cache = new CachedDecodedFrame();

static CGImageRef decode_video_cgimage(const std::string &path, double ms, bool allow_cache) {
  if (allow_cache) {
    std::lock_guard<std::mutex> lock(g_decoded_cache->mu);
    if (g_decoded_cache->img && g_decoded_cache->file == path && std::abs(g_decoded_cache->ms - ms) < 0.5) {
      return CGImageRetain(g_decoded_cache->img);
    }
  }
  @autoreleasepool {
    NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
    if (!nsPath) return nullptr;
    NSURL *url = [NSURL fileURLWithPath:nsPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    if (!asset) return nullptr;
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;
    CMTime req = CMTimeMakeWithSeconds(std::max(0.0, ms) / 1000.0, 60000);
    NSError *err = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGImageRef img = [gen copyCGImageAtTime:req actualTime:nullptr error:&err];
    if (!img) {
      // Fallback with relaxed tolerance if exact timestamp lies slightly past last frame
      gen.requestedTimeToleranceBefore = CMTimeMake(2, 1);
      gen.requestedTimeToleranceAfter = CMTimeMake(2, 1);
      img = [gen copyCGImageAtTime:req actualTime:nullptr error:&err];
    }
#pragma clang diagnostic pop
    if (img && allow_cache) {
      std::lock_guard<std::mutex> lock(g_decoded_cache->mu);
      if (g_decoded_cache->img) CGImageRelease(g_decoded_cache->img);
      g_decoded_cache->img = CGImageRetain(img);
      g_decoded_cache->file = path;
      g_decoded_cache->ms = ms;
    }
    return img;
  }
}

static std::vector<uint8_t> thumb_bmp_sync(const std::string &path, double ms, int max_w, int max_h,
                                           int cx, int cy, int cw, int ch) {
  if (path.empty()) return {};
  if (has_gif_ext(path)) return gif_first_frame_bmp(path, max_w, max_h, cx, cy, cw, ch);
  CGImageRef img = decode_video_cgimage(path, ms, true);
  if (!img) return {};
  std::vector<uint8_t> bgra;
  int w = 0, h = 0;
  bool ok = rp_cgimage_to_bgra(img, max_w, max_h, cx, cy, cw, ch, bgra, w, h);
  CGImageRelease(img);
  if (!ok) return {};
  return rp_bmp_from_bgra(bgra.data(), w, h, w * 4);
}

struct RpThumbJob {
  std::mutex mutex;
  std::condition_variable changed;
  std::string key;
  std::string file;
  double ms = 0.0;
  int32_t max_w = 320, max_h = 180, cx = 0, cy = 0, cw = 0, ch = 0;
  std::deque<std::pair<std::string, std::vector<uint8_t>>> cache;
  bool busy = false;
  bool started = false;
  bool release = false;
};

static RpThumbJob *g_thumb_jobs = new RpThumbJob();

static void thumb_worker_loop() {
  RpThumbJob *job = g_thumb_jobs;
  for (;;) {
    std::unique_lock<std::mutex> lock(job->mutex);
    while (!job->busy) {
      if (job->release) {
        job->release = false;
        lock.unlock();
        {
          std::lock_guard<std::mutex> dl(g_decoded_cache->mu);
          g_decoded_cache->clear();
        }
        lock.lock();
        continue;
      }
      if (!job->changed.wait_for(lock, std::chrono::seconds(5), [job] { return job->busy || job->release; })) {
        lock.unlock();
        {
          std::lock_guard<std::mutex> dl(g_decoded_cache->mu);
          g_decoded_cache->clear();
        }
        lock.lock();
      }
    }
    std::string file = job->file, key = job->key;
    double ms = job->ms;
    int32_t mw = job->max_w, mh = job->max_h, x = job->cx, y = job->cy, w = job->cw, h = job->ch;
    lock.unlock();

    double t0 = rp_mono_ms();
    std::vector<uint8_t> bmp = thumb_bmp_sync(file, ms, mw, mh, x, y, w, h);
    if (rp_env_set("REPLAY_TRACE")) {
      printf("REPLAY_DECODE %.1f ms offset=%.0f bytes=%zu\n", rp_mono_ms() - t0, ms, bmp.size());
      fflush(stdout);
    }

    lock.lock();
    job->cache.emplace_back(key, std::move(bmp));
    if (job->cache.size() > 32) job->cache.pop_front();
    job->busy = false;
  }
}

static moonbit_bytes_t rp_thumb_job(const std::string &path, const std::string &identity, double ms,
                                    int32_t max_w, int32_t max_h, int32_t cx, int32_t cy, int32_t cw, int32_t ch) {
  RpThumbJob *job = g_thumb_jobs;
  std::lock_guard<std::mutex> guard(job->mutex);
  for (auto &entry : job->cache) {
    if (entry.first == identity) {
      return entry.second.empty() ? moonbit_make_bytes(1, 1) : rp_bytes_from(entry.second.data(), entry.second.size());
    }
  }
  if (!job->started) {
    try {
      std::thread(thumb_worker_loop).detach();
      job->started = true;
    } catch (...) {
      return moonbit_make_bytes(1, 1);
    }
  }
  if (!job->busy) {
    job->key = identity;
    job->file = path;
    job->ms = ms;
    job->max_w = max_w;
    job->max_h = max_h;
    job->cx = cx;
    job->cy = cy;
    job->cw = cw;
    job->ch = ch;
    job->busy = true;
    job->changed.notify_one();
  }
  return moonbit_make_bytes(1, 0);
}

struct ConcatPart {
  std::string path;
  double offset_ms = 0.0;
  double trim_ms = 0.0;
  double end_ms = 0.0;
};

static std::vector<ConcatPart> parse_concat_plan(const std::string &plan) {
  std::vector<ConcatPart> out;
  std::istringstream ss(plan);
  std::string line;
  while (std::getline(ss, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    size_t t1 = line.find('\t');
    if (t1 == std::string::npos) continue;
    size_t t2 = line.find('\t', t1 + 1);
    if (t2 == std::string::npos) continue;
    size_t t3 = line.find('\t', t2 + 1);
    if (t3 == std::string::npos) continue;
    ConcatPart p;
    p.path = line.substr(0, t1);
    try {
      p.offset_ms = std::stod(line.substr(t1 + 1, t2 - t1 - 1));
      p.trim_ms = std::stod(line.substr(t2 + 1, t3 - t2 - 1));
      p.end_ms = std::stod(line.substr(t3 + 1));
    } catch (...) {
      continue;
    }
    if (!p.path.empty() && p.end_ms > p.trim_ms) out.push_back(std::move(p));
  }
  return out;
}

static std::atomic<int> g_concat_phase{0};     // 0 none, 1 joining, 2 done
static std::atomic<int> g_concat_code{0};      // 0 ok, -2147467260 cancelled (E_ABORT), <0 err
static std::atomic<int> g_join_permille{0};
static std::atomic<bool> g_join_stop{false};

static constexpr int32_t kConcatCancelled = (int32_t)0x80004004u;  // E_ABORT (-2147467260)

static int32_t run_passthrough_concat(const std::string &plan_str, const std::string &out_str) {
  std::vector<ConcatPart> parts = parse_concat_plan(plan_str);
  if (parts.empty() || out_str.empty()) return -1001;

  @autoreleasepool {
    unlink(out_str.c_str());
    AVMutableComposition *comp = [AVMutableComposition composition];
    AVMutableCompositionTrack *compVideo = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                             preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *compAudio = nil;
    bool anyVideo = false;
    CMTime cursor = kCMTimeZero;

    for (const auto &part : parts) {
      if (g_join_stop.load()) return kConcatCancelled;
      NSString *nsPath = [NSString stringWithUTF8String:part.path.c_str()];
      if (!nsPath) continue;
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:nsPath]
                                              options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
      NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if (vTracks.count == 0) continue;
      AVAssetTrack *vTrack = vTracks.firstObject;
      if (!anyVideo) {
        compVideo.preferredTransform = vTrack.preferredTransform;
      }

      CMTime assetDur = asset.duration;
      double assetMs = CMTIME_IS_NUMERIC(assetDur) ? CMTimeGetSeconds(assetDur) * 1000.0 : part.end_ms;
      double startMs = std::max(0.0, part.trim_ms);
      double stopMs = std::min(assetMs, part.end_ms);
      if (stopMs <= startMs) continue;

      CMTime rangeStart = CMTimeMakeWithSeconds(startMs / 1000.0, 60000);
      CMTime rangeDur = CMTimeMakeWithSeconds((stopMs - startMs) / 1000.0, 60000);
      CMTimeRange srcRange = CMTimeRangeMake(rangeStart, rangeDur);
      CMTime dstAt = part.offset_ms >= 0.0 ? CMTimeMakeWithSeconds(part.offset_ms / 1000.0, 60000) : cursor;
      if (CMTimeCompare(dstAt, cursor) < 0) dstAt = cursor;

      NSError *insErr = nil;
      if (![compVideo insertTimeRange:srcRange ofTrack:vTrack atTime:dstAt error:&insErr]) {
        return insErr ? (int32_t)insErr.code : -1002;
      }
      anyVideo = true;

      NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
      if (aTracks.count > 0) {
        if (!compAudio) {
          compAudio = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                        preferredTrackID:kCMPersistentTrackID_Invalid];
        }
        AVAssetTrack *aTrack = aTracks.firstObject;
        CMTime aDur = aTrack.timeRange.duration;
        CMTime aEnd = CMTimeMinimum(CMTimeAdd(rangeStart, rangeDur), aDur);
        if (CMTimeCompare(aEnd, rangeStart) > 0) {
          [compAudio insertTimeRange:CMTimeRangeMake(rangeStart, CMTimeSubtract(aEnd, rangeStart))
                             ofTrack:aTrack
                              atTime:dstAt
                               error:nil];
        }
      }
      cursor = CMTimeAdd(dstAt, rangeDur);
    }

    if (!anyVideo) return -1001;

    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:comp
                                                                     presetName:AVAssetExportPresetPassthrough];
    if (!session) return -1003;
    session.outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:out_str.c_str()]];
    session.outputFileType = AVFileTypeMPEG4;
    session.shouldOptimizeForNetworkUse = NO;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{
      dispatch_semaphore_signal(sem);
    }];

    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC)) != 0) {
      if (g_join_stop.load()) {
        [session cancelExport];
      }
      int perm = (int)(session.progress * 1000.0f);
      g_join_permille.store(std::max(0, std::min(999, perm)));
    }

    if (g_join_stop.load() || session.status == AVAssetExportSessionStatusCancelled) {
      unlink(out_str.c_str());
      return kConcatCancelled;
    }
    if (session.status != AVAssetExportSessionStatusCompleted) {
      unlink(out_str.c_str());
      NSError *e = session.error;
      return e ? (e.code != 0 ? (int32_t)-std::abs((int)e.code) : -1004) : -1004;
    }
    g_join_permille.store(1000);
    return 0;
  }
}

static std::atomic<int> g_frame_copying{0};  // 0 idle, 1 busy, 2 copied, 3 failed

static bool put_png_frame(const uint8_t *bgra, int w, int h, int stride) {
  std::vector<uint8_t> png = rp_png_from_bgra(bgra, w, h, stride);
  if (png.empty()) return false;
  const char *test_out = getenv("REPLAY_TEST_COPY_FRAME");
  if (test_out && test_out[0] != '\0') {
    return rp_write_file_raw(test_out, png.data(), png.size());
  }
  if (rp_env_set("REPLAY_NO_CLIPBOARD")) return false;
  NSData *nsData = [NSData dataWithBytes:png.data() length:png.size()];
  __block BOOL ok = NO;
  void (^putBlock)(void) = ^{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    ok = [pb setData:nsData forType:NSPasteboardTypePNG];
  };
  if ([NSThread isMainThread]) putBlock();
  else dispatch_sync(dispatch_get_main_queue(), putBlock);
  return ok == YES;
}

}

extern "C" {
typedef void (*mb_stream_grabbed_fn)(void *arg, const unsigned char *rows, int w, int h, int pitch, double ts);
int mb_stream_grab(int id, mb_stream_grabbed_fn done, void *arg);
}

static double g_grab_began = 0.0;

static void on_stream_grabbed(void *, const unsigned char *rows, int w, int h, int pitch, double) {
  double read_at = rp_mono_ms();
  if (!rows || w <= 0 || h <= 0 || pitch < w * 4) {
    g_frame_copying.store(3);
    return;
  }
  auto bgra = std::make_shared<std::vector<uint8_t>>((size_t)w * (size_t)h * 4);
  for (int y = 0; y < h; y++) {
    uint8_t *dst = &(*bgra)[(size_t)y * (size_t)w * 4];
    memcpy(dst, rows + (size_t)y * (size_t)pitch, (size_t)w * 4);
    for (int x = 0; x < w; x++) dst[x * 4 + 3] = 255;
  }
  try {
    std::thread([bgra, w, h, read_at]() {
      bool ok = put_png_frame(bgra->data(), w, h, w * 4);
      if (rp_env_set("REPLAY_TRACE")) {
        printf("REPLAY_COPY_SHOWN read %.1f ms, put %.1f ms %dx%d ok=%d\n",
               read_at - g_grab_began, rp_mono_ms() - read_at, w, h, (int)ok);
        fflush(stdout);
      }
      g_frame_copying.store(ok ? 2 : 3);
    }).detach();
  } catch (...) {
    g_frame_copying.store(3);
  }
}

extern "C" moonbit_bytes_t rp_thumb(moonbit_bytes_t path, double ms, int32_t max_w, int32_t max_h) {
  std::vector<uint8_t> bmp = thumb_bmp_sync(rp_str(path), ms, max_w, max_h, 0, 0, 0, 0);
  return rp_bytes_from(bmp.data(), bmp.size());
}

extern "C" void rp_thumb_release(void) {
  {
    std::lock_guard<std::mutex> dl(g_decoded_cache->mu);
    g_decoded_cache->clear();
  }
  RpThumbJob *job = g_thumb_jobs;
  std::lock_guard<std::mutex> guard(job->mutex);
  job->cache.clear();
  job->cache.shrink_to_fit();
  if (job->started) {
    job->release = true;
    job->changed.notify_one();
  }
}

extern "C" moonbit_bytes_t rp_clip_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms) {
  return rp_thumb_job(rp_str(path), rp_str(identity), ms, 640, 360, 0, 0, 0, 0);
}

extern "C" moonbit_bytes_t rp_crop_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms,
                                         int32_t cx, int32_t cy, int32_t cw, int32_t ch) {
  return rp_thumb_job(rp_str(path), rp_str(identity), ms, 480, 270, cx, cy, cw, ch);
}

extern "C" int32_t rp_concat(moonbit_bytes_t plan, moonbit_bytes_t output) {
  g_join_permille.store(0);
  g_join_stop.store(false);
  return run_passthrough_concat(rp_str(plan), rp_str(output));
}

extern "C" int32_t rp_concat_start(moonbit_bytes_t plan, moonbit_bytes_t output) {
  int idle = 0;
  if (!g_concat_phase.compare_exchange_strong(idle, 1)) return 0;
  g_join_permille.store(0);
  g_join_stop.store(false);
  std::string p = rp_str(plan), o = rp_str(output);
  try {
    std::thread([p, o]() {
      int32_t code = -1000;
      try {
        code = run_passthrough_concat(p, o);
      } catch (...) {
      }
      g_concat_code.store(code);
      g_concat_phase.store(2);
    }).detach();
  } catch (...) {
    g_concat_code.store(-1000);
    g_concat_phase.store(2);
  }
  return 1;
}

extern "C" int32_t rp_concat_state(void) { return g_concat_phase.load(); }

extern "C" double rp_concat_progress(void) { return g_join_permille.load() / 1000.0; }

extern "C" int32_t rp_concat_take(void) {
  int32_t code = g_concat_code.load();
  g_concat_phase.store(0);
  return code;
}

extern "C" void rp_concat_cancel(void) { g_join_stop.store(true); }

extern "C" double rp_duration(moonbit_bytes_t path) {
  std::string p = rp_str(path);
  if (p.empty()) return -1.0;
  if (has_gif_ext(p)) return gif_duration_ms(p);
  @autoreleasepool {
    NSString *nsPath = [NSString stringWithUTF8String:p.c_str()];
    if (!nsPath) return -1.0;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:nsPath]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    CMTime d = asset.duration;
    if (!CMTIME_IS_NUMERIC(d)) return -1.0;
    double ms = CMTimeGetSeconds(d) * 1000.0;
    return ms > 0.0 ? ms : -1.0;
  }
}

extern "C" int32_t rp_frame_copy_shown(int32_t stream) {
  if (g_frame_copying.exchange(1) == 1) return 0;
  g_grab_began = rp_mono_ms();
  if (mb_stream_grab(stream, on_stream_grabbed, nullptr) == 1) return 1;
  g_frame_copying.store(0);
  return 0;
}

extern "C" int32_t rp_frame_copy(moonbit_bytes_t path, double ms) {
  if (g_frame_copying.exchange(1) == 1) return 0;
  std::string file = rp_str(path);
  try {
    std::thread([file, ms]() {
      bool ok = false;
      CGImageRef img = decode_video_cgimage(file, ms, false);
      if (img) {
        std::vector<uint8_t> bgra;
        int w = 0, h = 0;
        if (rp_cgimage_to_bgra(img, 0, 0, 0, 0, 0, 0, bgra, w, h)) {
          ok = put_png_frame(bgra.data(), w, h, w * 4);
        }
        CGImageRelease(img);
      }
      g_frame_copying.store(ok ? 2 : 3);
    }).detach();
    return 1;
  } catch (...) {
    g_frame_copying.store(0);
    return 0;
  }
}

extern "C" void rp_frame_release(void) {
  std::lock_guard<std::mutex> dl(g_decoded_cache->mu);
  g_decoded_cache->clear();
}

extern "C" int32_t rp_frame_copy_state(void) {
  int s = g_frame_copying.load();
  if (s >= 2) g_frame_copying.compare_exchange_strong(s, 0);
  return s;
}
