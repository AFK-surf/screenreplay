#define NOMINMAX
#include <windows.h>
#include <wincodec.h>
#include <propvarutil.h>
#include <algorithm>
#include <map>
#include <string>
#include <vector>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include "moonbit.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "propsys.lib")

namespace {

struct GifFrame {
  int x = 0, y = 0, w = 0, h = 0;
  int delay = 100;    // ms
  int disposal = 0;   // 0 / 1 kept, 2 cleared, 3 put back
};

struct Gif {
  std::string path;
  IWICImagingFactory *wic = nullptr;
  IWICBitmapDecoder *decoder = nullptr;
  int w = 0, h = 0;
  std::vector<GifFrame> frames;
  std::vector<uint8_t> base;
  int cur = 0;
  int step = 16;
  std::map<int, std::vector<uint8_t>> kept;
  ~Gif() {
    if (decoder) decoder->Release();
    if (wic) wic->Release();
  }
};

Gif *open_gif = nullptr;

std::wstring wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
  return w;
}

int meta_int(IWICMetadataQueryReader *q, const wchar_t *name, int otherwise) {
  PROPVARIANT v;
  PropVariantInit(&v);
  int out = otherwise;
  if (q && SUCCEEDED(q->GetMetadataByName(name, &v))) {
    switch (v.vt) {
      case VT_UI1: out = v.bVal; break;
      case VT_UI2: out = v.uiVal; break;
      case VT_UI4: out = (int)v.ulVal; break;
      case VT_I4: out = v.lVal; break;
      default: break;
    }
  }
  PropVariantClear(&v);
  return out;
}

Gif *gif_of(const char *path) {
  if (open_gif && open_gif->path == path) return open_gif;
  delete open_gif;
  open_gif = nullptr;
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Gif *g = new Gif;
  g->path = path;
  bool ok = false;
  do {
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g->wic)))) break;
    if (FAILED(g->wic->CreateDecoderFromFilename(wide(path).c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
                                                 &g->decoder)))
      break;
    UINT n = 0;
    if (FAILED(g->decoder->GetFrameCount(&n)) || n == 0) break;
    IWICMetadataQueryReader *top = nullptr;
    g->decoder->GetMetadataQueryReader(&top);
    g->w = meta_int(top, L"/logscrdesc/Width", 0);
    g->h = meta_int(top, L"/logscrdesc/Height", 0);
    if (top) top->Release();
    for (UINT i = 0; i < n; i++) {
      IWICBitmapFrameDecode *f = nullptr;
      if (FAILED(g->decoder->GetFrame(i, &f))) break;
      GifFrame fr;
      UINT fw = 0, fh = 0;
      f->GetSize(&fw, &fh);
      fr.w = (int)fw;
      fr.h = (int)fh;
      IWICMetadataQueryReader *q = nullptr;
      f->GetMetadataQueryReader(&q);
      fr.x = meta_int(q, L"/imgdesc/Left", 0);
      fr.y = meta_int(q, L"/imgdesc/Top", 0);
      // GIF delay is in centiseconds; < 2 defaults to 10 (100 ms), matching browsers.
      int cs = meta_int(q, L"/grctlext/Delay", 10);
      fr.delay = (cs < 2 ? 10 : cs) * 10;
      fr.disposal = meta_int(q, L"/grctlext/Disposal", 0);
      if (q) q->Release();
      f->Release();
      g->frames.push_back(fr);
    }
    if (g->frames.size() != n) break;
    if (g->w <= 0 || g->h <= 0) {
      g->w = g->frames[0].x + g->frames[0].w;
      g->h = g->frames[0].y + g->frames[0].h;
    }
    if (g->w <= 0 || g->h <= 0 || (int64_t)g->w * g->h > 16 * 1024 * 1024) break;
    g->base.assign((size_t)g->w * g->h * 4, 0);
    const size_t canvas = (size_t)g->w * g->h * 4;
    const int most = (int)std::max<size_t>(2, std::min<size_t>(30, (256u << 20) / std::max<size_t>(1, canvas)));
    g->step = std::max(16, (int)(n + most - 1) / most);
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

bool draw(Gif *g, int k, std::vector<uint8_t> &canvas) {
  IWICBitmapFrameDecode *f = nullptr;
  IWICFormatConverter *conv = nullptr;
  bool ok = false;
  do {
    if (FAILED(g->decoder->GetFrame((UINT)k, &f))) break;
    if (FAILED(g->wic->CreateFormatConverter(&conv)) ||
        FAILED(conv->Initialize(f, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom)))
      break;
    const GifFrame &fr = g->frames[k];
    std::vector<uint8_t> px((size_t)fr.w * fr.h * 4);
    if (FAILED(conv->CopyPixels(nullptr, fr.w * 4, (UINT)px.size(), px.data()))) break;
    for (int y = 0; y < fr.h; y++) {
      const int cy = fr.y + y;
      if (cy < 0 || cy >= g->h) continue;
      for (int x = 0; x < fr.w; x++) {
        const int cx = fr.x + x;
        if (cx < 0 || cx >= g->w) continue;
        const uint8_t *s = &px[((size_t)y * fr.w + x) * 4];
        if (s[3] < 128) continue;
        uint8_t *d = &canvas[((size_t)cy * g->w + cx) * 4];
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = 255;
      }
    }
    ok = true;
  } while (false);
  if (conv) conv->Release();
  if (f) f->Release();
  return ok;
}

void leave(Gif *g, int k, const std::vector<uint8_t> &shown, std::vector<uint8_t> &base) {
  const GifFrame &fr = g->frames[k];
  if (fr.disposal == 3) return;
  base = shown;
  if (fr.disposal == 2) {
    for (int y = std::max(0, fr.y); y < std::min(g->h, fr.y + fr.h); y++)
      for (int x = std::max(0, fr.x); x < std::min(g->w, fr.x + fr.w); x++) memset(&base[((size_t)y * g->w + x) * 4], 0, 4);
  }
}

bool compose(Gif *g, int k, std::vector<uint8_t> &out) {
  if (k < g->cur) {
    auto it = g->kept.upper_bound(k);
    --it;
    g->cur = it->first;
    g->base = it->second;
  }
  while (g->cur < k) {
    std::vector<uint8_t> shown = g->base;
    if (!draw(g, g->cur, shown)) return false;
    leave(g, g->cur, shown, g->base);
    g->cur++;
    if (g->cur % g->step == 0 && !g->kept.count(g->cur)) g->kept[g->cur] = g->base;
  }
  out = g->base;
  return draw(g, k, out);
}

moonbit_bytes_t bmp_of(Gif *g, std::vector<uint8_t> &px, int w, int h, int max_w) {
  for (size_t i = 0; i < px.size(); i += 4) {
    if (px[i + 3] == 0) px[i] = px[i + 1] = px[i + 2] = 0;
    px[i + 3] = 255;
  }
  if (max_w > 0 && w > max_w) {
    IWICBitmap *bmp = nullptr;
    IWICBitmapScaler *sc = nullptr;
    const int sw = max_w, sh = std::max(1, (int)((double)h * max_w / w + 0.5));
    std::vector<uint8_t> scaled((size_t)sw * sh * 4);
    bool ok = SUCCEEDED(g->wic->CreateBitmapFromMemory(w, h, GUID_WICPixelFormat32bppBGRA, w * 4, (UINT)px.size(), px.data(), &bmp)) &&
              SUCCEEDED(g->wic->CreateBitmapScaler(&sc)) &&
              SUCCEEDED(sc->Initialize(bmp, sw, sh, WICBitmapInterpolationModeFant)) &&
              SUCCEEDED(sc->CopyPixels(nullptr, sw * 4, (UINT)scaled.size(), scaled.data()));
    if (sc) sc->Release();
    if (bmp) bmp->Release();
    if (ok) {
      px.swap(scaled);
      w = sw;
      h = sh;
    }
  }
  const int header = 14 + 40;
  const int size = header + w * h * 4;
  moonbit_bytes_t b = moonbit_make_bytes(size, 0);
  uint8_t *p = (uint8_t *)b;
  p[0] = 'B';
  p[1] = 'M';
  memcpy(p + 2, &size, 4);
  memcpy(p + 10, &header, 4);
  int32_t info = 40, hh = -h;
  uint16_t planes = 1, bits = 32;
  memcpy(p + 14, &info, 4);
  memcpy(p + 18, &w, 4);
  memcpy(p + 22, &hh, 4);
  memcpy(p + 26, &planes, 2);
  memcpy(p + 28, &bits, 2);
  memcpy(p + header, px.data(), (size_t)w * h * 4);
  return b;
}

moonbit_bytes_t bytes_of(const std::string &s) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)s.size(), 0);
  if (!s.empty()) memcpy(b, s.data(), s.size());
  return b;
}

}

extern "C" moonbit_bytes_t rp_gif_info(moonbit_bytes_t path) {
  Gif *g = gif_of((const char *)path);
  if (!g) return bytes_of("");
  std::string s = std::to_string(g->w) + " " + std::to_string(g->h);
  for (const GifFrame &f : g->frames) s += " " + std::to_string(f.delay);
  return bytes_of(s);
}

extern "C" moonbit_bytes_t rp_gif_frame(moonbit_bytes_t path, int32_t k, int32_t max_w) {
  Gif *g = gif_of((const char *)path);
  if (!g || k < 0 || k >= (int32_t)g->frames.size()) return moonbit_make_bytes(0, 0);
  std::vector<uint8_t> px;
  if (!compose(g, k, px)) return moonbit_make_bytes(0, 0);
  return bmp_of(g, px, g->w, g->h, max_w);
}

extern "C" void rp_gif_drop(moonbit_bytes_t path) {
  if (open_gif && open_gif->path == (const char *)path) {
    delete open_gif;
    open_gif = nullptr;
  }
}
