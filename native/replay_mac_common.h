#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#include <algorithm>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>

#include "moonbit.h"

extern "C" {
void rp_play_release(void);
void rp_aac_release_all(void);
void rp_thumb_release(void);
void rp_frame_release(void);
}

static inline std::string rp_str(moonbit_bytes_t b) {
  if (!b) return std::string();
  int32_t cap = Moonbit_array_length(b);
  if (cap <= 0) return std::string();
  const char *p = (const char *)b;
  size_t n = strnlen(p, (size_t)cap);
  return std::string(p, n);
}

static inline moonbit_bytes_t rp_bytes_from(const void *p, size_t n) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  if (n > 0 && p) memcpy(out, p, n);
  return out;
}

static inline moonbit_bytes_t rp_bytes_str(const std::string &s) {
  return rp_bytes_from(s.data(), s.size());
}

static inline double rp_mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static inline bool rp_env_set(const char *name) {
  const char *v = getenv(name);
  return v && v[0] != '\0' && strcmp(v, "0") != 0;
}

static inline bool rp_write_file_raw(const char *path, const void *data, size_t len) {
  if (!path || !path[0]) return false;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return false;
  const uint8_t *p = (const uint8_t *)data;
  size_t off = 0;
  while (off < len) {
    ssize_t put = write(fd, p + off, len - off);
    if (put < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return false;
    }
    off += (size_t)put;
  }
  close(fd);
  return true;
}

// 32-bit top-down BMP (54-byte header + w*h*4 BGRA with opaque alpha=255), matching replay_mf.cpp / replay_gif.cpp.
static inline std::vector<uint8_t> rp_bmp_from_bgra(const uint8_t *bgra, int w, int h, int stride) {
  if (!bgra || w <= 0 || h <= 0 || stride < w * 4) return {};
  const int32_t header = 14 + 40;
  const int32_t size = header + w * h * 4;
  std::vector<uint8_t> b((size_t)size, 0);
  uint8_t *p = b.data();
  p[0] = 'B';
  p[1] = 'M';
  memcpy(p + 2, &size, 4);
  memcpy(p + 10, &header, 4);
  int32_t info = 40;
  int32_t hh = -h;  // top-down
  uint16_t planes = 1, bits = 32;
  memcpy(p + 14, &info, 4);
  memcpy(p + 18, &w, 4);
  memcpy(p + 22, &hh, 4);
  memcpy(p + 26, &planes, 2);
  memcpy(p + 28, &bits, 2);
  uint8_t *dst = p + header;
  for (int y = 0; y < h; y++) {
    const uint8_t *src = bgra + (size_t)y * (size_t)stride;
    uint8_t *row = dst + (size_t)y * (size_t)w * 4;
    memcpy(row, src, (size_t)w * 4);
    for (int x = 0; x < w; x++) row[x * 4 + 3] = 255;
  }
  return b;
}

static inline std::vector<uint8_t> rp_encode_cgimage(CGImageRef img, CFStringRef uti, float quality) {
  std::vector<uint8_t> out;
  if (!img) return out;
  CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
  if (!data) return out;
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, nullptr);
  if (dest) {
    CFDictionaryRef props = nullptr;
    if (quality > 0.0f && quality < 1.0f) {
      CFNumberRef q = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &quality);
      const void *keys[] = {kCGImageDestinationLossyCompressionQuality};
      const void *vals[] = {q};
      props = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFRelease(q);
    }
    CGImageDestinationAddImage(dest, img, props);
    if (props) CFRelease(props);
    if (CGImageDestinationFinalize(dest)) {
      const UInt8 *ptr = CFDataGetBytePtr(data);
      CFIndex len = CFDataGetLength(data);
      if (ptr && len > 0) out.assign(ptr, ptr + len);
    }
    CFRelease(dest);
  }
  CFRelease(data);
  return out;
}

static inline std::vector<uint8_t> rp_png_from_bgra(const uint8_t *bgra, int w, int h, int stride) {
  if (!bgra || w <= 0 || h <= 0 || stride < w * 4) return {};
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef prov = CGDataProviderCreateWithData(nullptr, bgra, (size_t)stride * (size_t)h, nullptr);
  CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)stride, cs,
                                 (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little,
                                 prov, nullptr, false, kCGRenderingIntentDefault);
  std::vector<uint8_t> png = rp_encode_cgimage(img, CFSTR("public.png"), 1.0f);
  if (img) CGImageRelease(img);
  if (prov) CGDataProviderRelease(prov);
  if (cs) CGColorSpaceRelease(cs);
  return png;
}

static inline std::vector<uint8_t> rp_jpeg_from_bgra(const uint8_t *bgra, int w, int h, int stride, float quality = 0.82f) {
  if (!bgra || w <= 0 || h <= 0 || stride < w * 4) return {};
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef prov = CGDataProviderCreateWithData(nullptr, bgra, (size_t)stride * (size_t)h, nullptr);
  CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)stride, cs,
                                 (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little,
                                 prov, nullptr, false, kCGRenderingIntentDefault);
  std::vector<uint8_t> jpg = rp_encode_cgimage(img, CFSTR("public.jpeg"), quality);
  if (img) CGImageRelease(img);
  if (prov) CGDataProviderRelease(prov);
  if (cs) CGColorSpaceRelease(cs);
  return jpg;
}

// Convert any CGImageRef into top-down BGRA rows (with optional crop in source image pixels and fit into max_w x max_h).
static inline bool rp_cgimage_to_bgra(CGImageRef img, int max_w, int max_h,
                                      int cx, int cy, int cw, int ch,
                                      std::vector<uint8_t> &bgra, int &out_w, int &out_h) {
  if (!img) return false;
  int fw = (int)CGImageGetWidth(img);
  int fh = (int)CGImageGetHeight(img);
  if (fw <= 0 || fh <= 0) return false;

  int ox = 0, oy = 0, pw = fw, ph = fh;
  if (cw > 0 && ch > 0) {
    ox = cx < 0 ? 0 : (cx >= fw ? fw - 1 : cx);
    oy = cy < 0 ? 0 : (cy >= fh ? fh - 1 : cy);
    pw = cw > fw - ox ? fw - ox : cw;
    ph = ch > fh - oy ? fh - oy : ch;
  }
  if (pw <= 0 || ph <= 0) return false;

  double k = 1.0;
  if (max_w > 0 && pw > max_w) k = (double)max_w / (double)pw;
  if (max_h > 0 && ph * k > max_h) k = (double)max_h / (double)ph;
  int w = std::max(1, (int)(pw * k));
  int h = std::max(1, (int)(ph * k));

  CGImageRef sub = nullptr;
  if (ox != 0 || oy != 0 || pw != fw || ph != fh) {
    sub = CGImageCreateWithImageInRect(img, CGRectMake(ox, oy, pw, ph));
    if (!sub) return false;
  }
  CGImageRef draw_img = sub ? sub : img;

  bgra.assign((size_t)w * (size_t)h * 4, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(bgra.data(), (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
                                           (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    if (sub) CGImageRelease(sub);
    bgra.clear();
    return false;
  }
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), draw_img);
  CGContextRelease(ctx);
  if (sub) CGImageRelease(sub);
  for (size_t i = 3; i < bgra.size(); i += 4) bgra[i] = 255;
  out_w = w;
  out_h = h;
  return true;
}
