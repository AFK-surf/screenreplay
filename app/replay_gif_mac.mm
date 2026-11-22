// Saved GIF playback on macOS: GIF89a header/disposal parsing + ImageIO frame decode + canvas composition -> 32-bit BMP.
#include <map>

#include "replay_mac_common.h"

namespace {

struct GifFrame {
  int x = 0, y = 0, w = 0, h = 0;
  int delay = 100;   // ms
  int disposal = 0;  // 0 / 1 kept, 2 cleared, 3 put back
};

struct Gif {
  std::string path;
  CGImageSourceRef src = nullptr;
  int w = 0, h = 0;
  std::vector<GifFrame> frames;
  std::vector<uint8_t> base;
  int cur = 0;
  int step = 16;
  std::map<int, std::vector<uint8_t>> kept;

  ~Gif() {
    if (src) CFRelease(src);
  }
};

Gif *open_gif = nullptr;

// Stream-read GIF89a blocks to obtain exact Logical Screen size and per-frame (Left, Top, Width, Height, Delay, Disposal).
bool parse_gif_stream(const char *path, int &scr_w, int &scr_h, std::vector<GifFrame> &frames) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return false;
  std::vector<uint8_t> buf(1 << 20);
  size_t have = 0, at = 0;
  bool end = false;

  auto peek = [&](size_t i, uint8_t &out) -> bool {
    while (at + i >= have && !end) {
      if (at > 0) {
        memmove(buf.data(), buf.data() + at, have - at);
        have -= at;
        at = 0;
      }
      if (have == buf.size()) buf.resize(buf.size() * 2);
      ssize_t got = read(fd, buf.data() + have, buf.size() - have);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) end = true;
      else have += (size_t)got;
    }
    if (at + i >= have) return false;
    out = buf[at + i];
    return true;
  };

  auto skip_n = [&](size_t n) -> bool {
    uint8_t b = 0;
    while (n > 0) {
      size_t s = std::min(n, have - at);
      at += s;
      n -= s;
      if (n > 0 && !peek(0, b)) return false;
    }
    return true;
  };

  auto skip_blocks = [&]() -> bool {
    uint8_t len = 0;
    for (;;) {
      if (!peek(0, len) || !skip_n(1)) return false;
      if (len == 0) return true;
      if (!skip_n(len)) return false;
    }
  };

  uint8_t h[13];
  bool ok = true;
  for (int i = 0; i < 13 && ok; i++) ok = peek((size_t)i, h[i]);
  if (!ok || memcmp(h, "GIF8", 4) != 0) {
    close(fd);
    return false;
  }
  scr_w = (int)h[6] | ((int)h[7] << 8);
  scr_h = (int)h[8] | ((int)h[9] << 8);
  skip_n(13);
  if (h[10] & 0x80) skip_n(3 * ((size_t)2 << (h[10] & 7)));

  int gce_delay_cs = 10;
  int gce_disposal = 0;
  uint8_t b0 = 0, b1 = 0;
  while (peek(0, b0)) {
    if (b0 == 0x3B) break;
    if (b0 == 0x21 && peek(1, b1)) {
      if (b1 == 0xF9) {
        uint8_t packed = 0, lo = 0, hi = 0;
        if (peek(3, packed) && peek(4, lo) && peek(5, hi)) {
          gce_disposal = (packed >> 2) & 7;
          gce_delay_cs = (int)lo | ((int)hi << 8);
        }
      }
      if (!skip_n(2) || !skip_blocks()) break;
    } else if (b0 == 0x2C) {
      uint8_t desc[10];
      bool desc_ok = true;
      for (int i = 0; i < 10 && desc_ok; i++) desc_ok = peek((size_t)i, desc[i]);
      if (!desc_ok || !skip_n(10)) break;
      GifFrame fr;
      fr.x = (int)desc[1] | ((int)desc[2] << 8);
      fr.y = (int)desc[3] | ((int)desc[4] << 8);
      fr.w = (int)desc[5] | ((int)desc[6] << 8);
      fr.h = (int)desc[7] | ((int)desc[8] << 8);
      int cs = gce_delay_cs;
      fr.delay = (cs < 2 ? 10 : cs) * 10;
      fr.disposal = gce_disposal;
      gce_delay_cs = 10;
      gce_disposal = 0;

      uint8_t flags = desc[9];
      if ((flags & 0x80) && !skip_n(3 * ((size_t)2 << (flags & 7)))) break;
      if (!skip_n(1) || !skip_blocks()) break;
      frames.push_back(fr);
    } else {
      break;
    }
  }
  close(fd);
  return !frames.empty();
}

Gif *gif_of(const std::string &path) {
  if (path.empty()) return nullptr;
  if (open_gif && open_gif->path == path) return open_gif;
  delete open_gif;
  open_gif = nullptr;

  @autoreleasepool {
    Gif *g = new Gif;
    g->path = path;
    bool ok = false;
    do {
      NSString *ns = [NSString stringWithUTF8String:path.c_str()];
      if (!ns) break;
      NSURL *url = [NSURL fileURLWithPath:ns];
      if (!url) break;
      NSDictionary *opts = @{(id)kCGImageSourceShouldCache : @NO};
      g->src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)opts);
      if (!g->src) break;
      size_t count = CGImageSourceGetCount(g->src);
      if (count == 0) break;

      if (!parse_gif_stream(path.c_str(), g->w, g->h, g->frames)) break;
      if (g->frames.size() > count) g->frames.resize(count);
      if (g->frames.empty()) break;

      if (g->w <= 0 || g->h <= 0) {
        g->w = g->frames[0].x + g->frames[0].w;
        g->h = g->frames[0].y + g->frames[0].h;
      }
      if (g->w <= 0 || g->h <= 0 || (int64_t)g->w * g->h > 16 * 1024 * 1024) break;
      g->base.assign((size_t)g->w * (size_t)g->h * 4, 0);
      const size_t canvas = (size_t)g->w * (size_t)g->h * 4;
      const int most = (int)std::max<size_t>(2, std::min<size_t>(30, (256u << 20) / std::max<size_t>(1, canvas)));
      g->step = std::max(16, (int)(g->frames.size() + (size_t)most - 1) / most);
      g->kept[0] = g->base;
      ok = true;
    } while (false);

    if (!ok) {
      delete g;
      return nullptr;
    }
    open_gif = g;
    return g;
  }
}

bool draw_frame(Gif *g, int k, std::vector<uint8_t> &canvas) {
  NSDictionary *opts = @{(id)kCGImageSourceShouldCache : @NO};
  CGImageRef img = CGImageSourceCreateImageAtIndex(g->src, (size_t)k, (__bridge CFDictionaryRef)opts);
  if (!img) return false;
  int iw = (int)CGImageGetWidth(img);
  int ih = (int)CGImageGetHeight(img);
  if (iw <= 0 || ih <= 0) {
    CGImageRelease(img);
    return false;
  }

  std::vector<uint8_t> px((size_t)iw * (size_t)ih * 4, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(px.data(), (size_t)iw, (size_t)ih, 8, (size_t)iw * 4, cs,
                                           (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    CGImageRelease(img);
    return false;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), img);
  CGContextRelease(ctx);
  CGImageRelease(img);

  const GifFrame &fr = g->frames[(size_t)k];
  // ImageIO on macOS returns a full logical-screen CGImage with the sub-rect positioned at (fr.x, fr.y);
  // handle both full-canvas and raw sub-rect images cleanly.
  if (iw == g->w && ih == g->h) {
    int y0 = std::max(0, fr.y), y1 = std::min(g->h, fr.y + fr.h);
    int x0 = std::max(0, fr.x), x1 = std::min(g->w, fr.x + fr.w);
    if (fr.w <= 0 || fr.h <= 0) {
      x0 = 0; y0 = 0; x1 = g->w; y1 = g->h;
    }
    for (int y = y0; y < y1; y++) {
      for (int x = x0; x < x1; x++) {
        const uint8_t *s = &px[((size_t)y * (size_t)iw + (size_t)x) * 4];
        if (s[3] < 128) continue;
        uint8_t *d = &canvas[((size_t)y * (size_t)g->w + (size_t)x) * 4];
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = 255;
      }
    }
  } else {
    for (int y = 0; y < ih; y++) {
      int cy = fr.y + y;
      if (cy < 0 || cy >= g->h) continue;
      for (int x = 0; x < iw; x++) {
        int cx = fr.x + x;
        if (cx < 0 || cx >= g->w) continue;
        const uint8_t *s = &px[((size_t)y * (size_t)iw + (size_t)x) * 4];
        if (s[3] < 128) continue;
        uint8_t *d = &canvas[((size_t)cy * (size_t)g->w + (size_t)cx) * 4];
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = 255;
      }
    }
  }
  return true;
}

void leave_frame(Gif *g, int k, const std::vector<uint8_t> &shown, std::vector<uint8_t> &base) {
  const GifFrame &fr = g->frames[(size_t)k];
  if (fr.disposal == 3) return;
  base = shown;
  if (fr.disposal == 2) {
    for (int y = std::max(0, fr.y); y < std::min(g->h, fr.y + fr.h); y++) {
      for (int x = std::max(0, fr.x); x < std::min(g->w, fr.x + fr.w); x++) {
        memset(&base[((size_t)y * (size_t)g->w + (size_t)x) * 4], 0, 4);
      }
    }
  }
}

bool compose_frame(Gif *g, int k, std::vector<uint8_t> &out) {
  if (k < g->cur) {
    auto it = g->kept.upper_bound(k);
    --it;
    g->cur = it->first;
    g->base = it->second;
  }
  while (g->cur < k) {
    std::vector<uint8_t> shown = g->base;
    if (!draw_frame(g, g->cur, shown)) return false;
    leave_frame(g, g->cur, shown, g->base);
    g->cur++;
    if (g->cur % g->step == 0 && !g->kept.count(g->cur)) g->kept[g->cur] = g->base;
  }
  out = g->base;
  return draw_frame(g, k, out);
}

moonbit_bytes_t gif_bmp_of(std::vector<uint8_t> &px, int w, int h, int max_w) {
  for (size_t i = 0; i < px.size(); i += 4) {
    if (px[i + 3] == 0) px[i] = px[i + 1] = px[i + 2] = 0;
    px[i + 3] = 255;
  }
  if (max_w > 0 && w > max_w) {
    int sw = max_w;
    int sh = std::max(1, (int)((double)h * (double)max_w / (double)w + 0.5));
    std::vector<uint8_t> scaled((size_t)sw * (size_t)sh * 4, 0);
    vImage_Buffer src_buf = {px.data(), (vImagePixelCount)h, (vImagePixelCount)w, (size_t)w * 4};
    vImage_Buffer dst_buf = {scaled.data(), (vImagePixelCount)sh, (vImagePixelCount)sw, (size_t)sw * 4};
    if (vImageScale_ARGB8888(&src_buf, &dst_buf, nullptr, kvImageHighQualityResampling) == kvImageNoError) {
      px.swap(scaled);
      w = sw;
      h = sh;
    }
  }
  std::vector<uint8_t> bmp = rp_bmp_from_bgra(px.data(), w, h, w * 4);
  return rp_bytes_from(bmp.data(), bmp.size());
}

}  // namespace

extern "C" moonbit_bytes_t rp_gif_info(moonbit_bytes_t path) {
  Gif *g = gif_of(rp_str(path));
  if (!g) return moonbit_make_bytes(0, 0);
  std::string s = std::to_string(g->w) + " " + std::to_string(g->h);
  for (const GifFrame &f : g->frames) s += " " + std::to_string(f.delay);
  return rp_bytes_str(s);
}

extern "C" moonbit_bytes_t rp_gif_frame(moonbit_bytes_t path, int32_t k, int32_t max_w) {
  Gif *g = gif_of(rp_str(path));
  if (!g || k < 0 || k >= (int32_t)g->frames.size()) return moonbit_make_bytes(0, 0);
  std::vector<uint8_t> px;
  if (!compose_frame(g, k, px)) return moonbit_make_bytes(0, 0);
  return gif_bmp_of(px, g->w, g->h, max_w);
}

extern "C" void rp_gif_drop(moonbit_bytes_t path) {
  std::string p = rp_str(path);
  if (open_gif && open_gif->path == p) {
    delete open_gif;
    open_gif = nullptr;
  }
}
