// Background scrub thumbnail indexer on macOS (AVAssetImageGenerator + ImageIO JPEG + RPT1/RPT2 disk cache).
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <strings.h>
#include <atomic>
#include <condition_variable>
#include <map>
#include <mutex>
#include <thread>

#include "replay_mac_common.h"

__asm__(".linker_option \"-framework\", \"AVFoundation\"");
__asm__(".linker_option \"-framework\", \"CoreMedia\"");

namespace {

const int kThumbW = 384;
const int kThumbH = 216;
const int64_t kStepMs = 1000;

struct Thumb {
  int64_t ms = 0;
  std::vector<uint8_t> jpeg;  // empty when stored on disk in Seg::file (`len` bytes at `off`)
  int64_t off = 0;
  uint32_t len = 0;
};

struct Seg {
  std::string path;
  std::string stem;
  double dur = 0;
  int state = 0;  // 0 waiting, 1 being made, 2 ready, -1 could not be read
  int64_t prefer = 0;
  int dropped = 0;
  std::vector<Thumb> thumbs;
  std::string file;  // "" when kept in memory (rp_idx_add_clip)
};

// Heap-allocated so detached workers never touch destroyed globals at process exit.
std::mutex &mu = *new std::mutex;
std::condition_variable &work = *new std::condition_variable;
std::map<std::string, Seg> &segs = *new std::map<std::string, Seg>;
std::string &cache_dir = *new std::string;
std::atomic<int> pending_n{0};
int64_t prefer_clock = 0;
bool started = false;
std::atomic<int> made{0};

void recount() {
  int n = 0;
  for (auto &kv : segs) {
    if (kv.second.state == 0 || kv.second.state == 1) n++;
  }
  pending_n.store(n);
}

struct OpenThumbs {
  std::mutex mu;
  struct Entry {
    std::string file;
    int fd = -1;
    uint64_t used = 0;
  } e[4];
  uint64_t clock = 0;
};
OpenThumbs &open_thumbs = *new OpenThumbs;

void forget_open(const std::string &file) {
  std::lock_guard<std::mutex> lock(open_thumbs.mu);
  for (auto &x : open_thumbs.e) {
    if (x.fd >= 0 && x.file == file) {
      close(x.fd);
      x.fd = -1;
      x.file.clear();
    }
  }
}

bool read_thumb(const std::string &file, int64_t off, uint32_t len, std::vector<uint8_t> &bytes) {
  std::lock_guard<std::mutex> lock(open_thumbs.mu);
  OpenThumbs::Entry *at = nullptr;
  for (auto &x : open_thumbs.e) {
    if (x.fd >= 0 && x.file == file) {
      at = &x;
      break;
    }
  }
  if (!at) {
    int fd = open(file.c_str(), O_RDONLY);
    if (fd < 0) return false;
    at = &open_thumbs.e[0];
    for (auto &x : open_thumbs.e) {
      if (x.fd < 0) {
        at = &x;
        break;
      }
      if (x.used < at->used) at = &x;
    }
    if (at->fd >= 0) close(at->fd);
    at->fd = fd;
    at->file = file;
  }
  at->used = ++open_thumbs.clock;
  bytes.resize(len);
  uint32_t total = 0;
  while (total < len) {
    ssize_t got = pread(at->fd, bytes.data() + total, len - total, (off_t)(off + total));
    if (got < 0) {
      if (errno == EINTR) continue;
      bytes.clear();
      return false;
    }
    if (got == 0) {
      bytes.clear();
      return false;
    }
    total += (uint32_t)got;
  }
  return true;
}

std::string stem_of(const std::string &path) {
  size_t slash = path.find_last_of("/\\");
  std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
  size_t dot = name.find_last_of('.');
  return dot == std::string::npos ? name : name.substr(0, dot);
}

static bool mkdirs_path(const std::string &dir) {
  if (dir.empty()) return false;
  std::string p = dir;
  for (size_t i = 1; i < p.size(); i++) {
    if (p[i] == '/') {
      p[i] = '\0';
      mkdir(p.c_str(), 0755);
      p[i] = '/';
    }
  }
  return mkdir(p.c_str(), 0755) == 0 || errno == EEXIST;
}

bool load_thumbs(const std::string &file, std::vector<Thumb> &out) {
  FILE *f = fopen(file.c_str(), "rb");
  if (!f) return false;
  bool ok = false;
  char magic[4];
  uint32_t n = 0;
  if (fread(magic, 1, 4, f) == 4 && (memcmp(magic, "RPT1", 4) == 0 || memcmp(magic, "RPT2", 4) == 0) &&
      fread(&n, 4, 1, f) == 1 && n < 100000) {
    ok = true;
    for (uint32_t i = 0; i < n && ok; i++) {
      Thumb t;
      uint32_t len = 0;
      if (fread(&t.ms, 8, 1, f) != 1 || fread(&len, 4, 1, f) != 1 || len > (8u << 20)) {
        ok = false;
        break;
      }
      t.off = (int64_t)ftello(f);
      t.len = len;
      if (fseeko(f, (off_t)len, SEEK_CUR) != 0) ok = false;
      out.push_back(std::move(t));
    }
  }
  fclose(f);
  if (!ok) out.clear();
  return ok && !out.empty();
}

void save_cache(const std::string &cdir, const std::string &stem, std::vector<Thumb> &thumbs, std::string *saved_as) {
  if (cdir.empty() || stem.empty() || thumbs.empty()) return;
  mkdirs_path(cdir);
  std::string file = cdir + "/" + stem + ".thumbs";
  std::string tmp = file + ".tmp." + std::to_string((uintptr_t)pthread_self());
  FILE *f = fopen(tmp.c_str(), "wb");
  if (!f) return;
  uint32_t n = (uint32_t)thumbs.size();
  fwrite("RPT1", 1, 4, f);
  fwrite(&n, 4, 1, f);
  std::vector<int64_t> offs;
  offs.reserve(thumbs.size());
  for (auto &t : thumbs) {
    uint32_t len = (uint32_t)t.jpeg.size();
    fwrite(&t.ms, 8, 1, f);
    fwrite(&len, 4, 1, f);
    offs.push_back((int64_t)ftello(f));
    if (len) fwrite(t.jpeg.data(), 1, len, f);
  }
  bool ok = ferror(f) == 0;
  fclose(f);
  forget_open(file);
  if (ok && rename(tmp.c_str(), file.c_str()) == 0) {
    for (size_t k = 0; k < thumbs.size(); k++) {
      thumbs[k].off = offs[k];
      thumbs[k].len = (uint32_t)thumbs[k].jpeg.size();
      std::vector<uint8_t>().swap(thumbs[k].jpeg);
    }
    *saved_as = file;
  } else {
    unlink(tmp.c_str());
  }
}

bool make_thumbs(const std::string &path, double dur_ms, std::vector<Thumb> &out) {
  @autoreleasepool {
    NSString *ns = [NSString stringWithUTF8String:path.c_str()];
    if (!ns || ![[NSFileManager defaultManager] fileExistsAtPath:ns]) return false;
    NSURL *url = [NSURL fileURLWithPath:ns];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @NO}];
    if (!asset) return false;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack *> *vtracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
    if (vtracks.count == 0) return false;

    if (dur_ms <= 0.0) {
      CMTime adur = asset.duration;
      if (CMTIME_IS_NUMERIC(adur) && CMTimeGetSeconds(adur) > 0.0) {
        dur_ms = CMTimeGetSeconds(adur) * 1000.0;
      }
    }

    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(kThumbW, kThumbH);
    gen.requestedTimeToleranceBefore = CMTimeMake(350, 1000);
    gen.requestedTimeToleranceAfter = CMTimeMake(350, 1000);

    int64_t end_ms = (int64_t)dur_ms;
    int64_t last_ms = -1;
    for (int64_t at_ms = 0; at_ms < end_ms || at_ms == 0; at_ms += kStepMs) {
      if (last_ms >= 0 && at_ms <= last_ms) continue;
      @autoreleasepool {
        CMTime actual = kCMTimeInvalid;
        NSError *err = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CGImageRef img = [gen copyCGImageAtTime:CMTimeMake(at_ms, 1000) actualTime:&actual error:&err];
        if (!img && out.empty()) {
          gen.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
          gen.requestedTimeToleranceAfter = kCMTimePositiveInfinity;
          img = [gen copyCGImageAtTime:CMTimeMake(at_ms, 1000) actualTime:&actual error:&err];
        }
#pragma clang diagnostic pop
        if (!img) continue;
        int64_t got_ms = CMTIME_IS_NUMERIC(actual) ? (int64_t)llround(CMTimeGetSeconds(actual) * 1000.0) : at_ms;
        if (got_ms < 0) got_ms = 0;
        if (got_ms == last_ms) {
          CGImageRelease(img);
          continue;
        }
        std::vector<uint8_t> jpg = rp_encode_cgimage(img, CFSTR("public.jpeg"), 0.82f);
        CGImageRelease(img);
        if (!jpg.empty()) {
          Thumb t;
          t.ms = got_ms;
          t.jpeg = std::move(jpg);
          out.push_back(std::move(t));
          last_ms = got_ms;
        }
      }
    }
    return !out.empty();
  }
}

void worker() {
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
  for (;;) {
    std::string key, path, stem, cdir;
    double dur = 0;
    {
      std::unique_lock<std::mutex> lock(mu);
      for (;;) {
        Seg *best = nullptr;
        const std::string *best_key = nullptr;
        for (auto it = segs.rbegin(); it != segs.rend(); ++it) {
          Seg &s = it->second;
          if (s.state != 0) continue;
          if (!best || s.prefer > best->prefer) {
            best = &s;
            best_key = &it->first;
          }
        }
        if (best) {
          best->state = 1;
          key = *best_key;
          path = best->path;
          stem = best->stem;
          dur = best->dur;
          cdir = cache_dir;
          break;
        }
        work.wait(lock);
      }
    }

    std::vector<Thumb> thumbs;
    std::string file;
    std::string beside;
    size_t dot = path.find_last_of('.');
    size_t slash = path.find_last_of("/\\");
    if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) {
      beside = path.substr(0, dot) + ".thumbs";
    }
    bool cached = !stem.empty() && !beside.empty() && load_thumbs(beside, thumbs);
    if (cached) {
      file = beside;
    } else if (!stem.empty() && !cdir.empty()) {
      std::string kept = cdir + "/" + stem + ".thumbs";
      thumbs.clear();
      cached = load_thumbs(kept, thumbs);
      if (cached) file = kept;
      else thumbs.clear();
    }

    double began = rp_mono_ms();
    bool ok = cached ? true : make_thumbs(path, dur, thumbs);
    const char *trace = getenv("REPLAY_TRACE");
    if (trace && strcmp(trace, "1") == 0) {
      printf("REPLAY_INDEX %s %.0f ms %zu thumbs%s\n", key.c_str(), rp_mono_ms() - began, thumbs.size(),
             cached ? " (disk)" : "");
      fflush(stdout);
    }

    if (ok && !cached && !stem.empty()) {
      std::string cdir_now;
      {
        std::lock_guard<std::mutex> lock(mu);
        cdir_now = cache_dir;
      }
      save_cache(cdir_now, stem, thumbs, &file);
    }

    std::string gone;
    {
      std::lock_guard<std::mutex> lock(mu);
      auto it = segs.find(key);
      if (it != segs.end() && it->second.dropped) {
        if (!cache_dir.empty() && !it->second.stem.empty()) gone = cache_dir + "/" + it->second.stem + ".thumbs";
        segs.erase(it);
      } else if (it != segs.end()) {
        it->second.thumbs = std::move(thumbs);
        it->second.file = file;
        it->second.state = ok ? 2 : -1;
      }
      recount();
    }
    if (!gone.empty()) {
      forget_open(gone);
      unlink(gone.c_str());
    }
    made.fetch_add(1);
  }
}

void start_workers() {
  if (started) return;
  started = true;
  for (int i = 0; i < 3; i++) std::thread(worker).detach();
}

const Thumb *nearest(const Seg &s, double ms) {
  if (s.thumbs.empty()) return nullptr;
  size_t lo = 0, hi = s.thumbs.size();
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    if ((double)s.thumbs[mid].ms <= ms + 1.0) lo = mid + 1;
    else hi = mid;
  }
  return lo == 0 ? &s.thumbs[0] : &s.thumbs[lo - 1];
}

}  // namespace

extern "C" void rp_idx_dir(moonbit_bytes_t dir) {
  std::lock_guard<std::mutex> lock(mu);
  cache_dir = rp_str(dir);
  while (cache_dir.size() > 1 && (cache_dir.back() == '/' || cache_dir.back() == '\\')) cache_dir.pop_back();
}

extern "C" void rp_idx_add(moonbit_bytes_t path, double dur) {
  std::lock_guard<std::mutex> lock(mu);
  std::string key = rp_str(path);
  if (key.empty() || segs.count(key)) return;
  Seg s;
  s.path = key;
  s.stem = stem_of(key);
  s.dur = dur;
  segs.emplace(key, std::move(s));
  recount();
  start_workers();
  work.notify_all();
}

extern "C" void rp_idx_add_clip(moonbit_bytes_t path, double dur) {
  std::lock_guard<std::mutex> lock(mu);
  std::string key = rp_str(path);
  if (key.empty() || segs.count(key)) return;
  Seg s;
  s.path = key;
  s.dur = dur;
  s.prefer = ++prefer_clock;
  segs.emplace(key, std::move(s));
  recount();
  start_workers();
  work.notify_all();
}

extern "C" void rp_idx_drop(moonbit_bytes_t path) {
  std::string gone, read_from;
  {
    std::lock_guard<std::mutex> lock(mu);
    auto it = segs.find(rp_str(path));
    if (it == segs.end()) return;
    if (it->second.state == 1) {
      it->second.dropped = 1;
      return;
    }
    if (!cache_dir.empty() && !it->second.stem.empty()) gone = cache_dir + "/" + it->second.stem + ".thumbs";
    read_from = it->second.file;
    segs.erase(it);
    recount();
  }
  if (!read_from.empty()) forget_open(read_from);
  if (!gone.empty()) {
    forget_open(gone);
    unlink(gone.c_str());
  }
}

extern "C" void rp_idx_prefer(moonbit_bytes_t path) {
  std::lock_guard<std::mutex> lock(mu);
  auto it = segs.find(rp_str(path));
  if (it != segs.end() && it->second.state == 0) it->second.prefer = ++prefer_clock;
}

extern "C" double rp_idx_at(moonbit_bytes_t path, double ms) {
  std::lock_guard<std::mutex> lock(mu);
  auto it = segs.find(rp_str(path));
  if (it == segs.end()) return -1.0;
  if (it->second.state == -1) return -2.0;
  const Thumb *t = nearest(it->second, ms);
  return t ? (double)t->ms : -1.0;
}

extern "C" moonbit_bytes_t rp_idx_jpeg(moonbit_bytes_t path, double ms) {
  std::vector<uint8_t> bytes;
  std::string file;
  int64_t off = 0;
  uint32_t len = 0;
  {
    std::lock_guard<std::mutex> lock(mu);
    auto it = segs.find(rp_str(path));
    const Thumb *t = it == segs.end() ? nullptr : nearest(it->second, ms);
    if (t && !t->jpeg.empty()) {
      bytes = t->jpeg;
    } else if (t && t->len && !it->second.file.empty()) {
      file = it->second.file;
      off = t->off;
      len = t->len;
    }
  }
  if (len) read_thumb(file, off, len, bytes);
  return rp_bytes_from(bytes.data(), bytes.size());
}

extern "C" int32_t rp_idx_pending(void) { return pending_n.load(); }

extern "C" int32_t rp_idx_made(void) { return made.load(); }
