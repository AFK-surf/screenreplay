#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wincodec.h>
#include <codecapi.h>
#include <d3d11.h>
#include <d3d10.h>
#include <strmif.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <atomic>
#include <memory>
#include "moonbit.h"

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "d3d11.lib")

namespace {

const int kThumbW = 384;
const int kThumbH = 216;
const LONGLONG kStep = 10000000;  // 1 s (100 ns units)

struct Thumb {
  int64_t ms;
  std::vector<uint8_t> jpeg;  // empty when stored in Seg::file at [off, off + len)
  int64_t off = 0;
  uint32_t len = 0;
};

struct Seg {
  std::wstring path;
  std::wstring stem;
  double dur = 0;
  int state = 0;  // 0 waiting, 1 being made, 2 ready, -1 could not be read
  int64_t prefer = 0;
  int dropped = 0;
  int plain = 0;  // retry without MF thumbnail mode after decoder hang
  std::vector<Thumb> thumbs;
  std::wstring file;
};

// Heap-allocated so detached workers never touch destroyed globals at process exit.
std::mutex &mu = *new std::mutex;
std::condition_variable &work = *new std::condition_variable;
std::map<std::string, Seg> &segs = *new std::map<std::string, Seg>;
std::wstring &cache_dir = *new std::wstring;
std::atomic<int> pending_n{0};

// Caller must hold mu.
void recount() {
  int n = 0;
  for (auto &kv : segs)
    if (kv.second.state == 0 || kv.second.state == 1) n++;
  pending_n.store(n);
}

// Keep recent .thumbs files open with FILE_SHARE_DELETE; call forget_open before replacing or deleting.
struct OpenThumbs {
  std::mutex mu;
  struct Entry {
    std::wstring file;
    HANDLE h = INVALID_HANDLE_VALUE;
    uint64_t used = 0;
  } e[4];
  uint64_t clock = 0;
};
OpenThumbs &open_thumbs = *new OpenThumbs;

void forget_open(const std::wstring &file) {
  std::lock_guard<std::mutex> lock(open_thumbs.mu);
  for (auto &x : open_thumbs.e) {
    if (x.h != INVALID_HANDLE_VALUE && x.file == file) {
      CloseHandle(x.h);
      x.h = INVALID_HANDLE_VALUE;
      x.file.clear();
    }
  }
}

bool read_thumb(const std::wstring &file, int64_t off, uint32_t len, std::vector<uint8_t> &bytes) {
  std::lock_guard<std::mutex> lock(open_thumbs.mu);
  OpenThumbs::Entry *at = nullptr;
  for (auto &x : open_thumbs.e)
    if (x.h != INVALID_HANDLE_VALUE && x.file == file) at = &x;
  if (!at) {
    HANDLE h = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    at = &open_thumbs.e[0];
    for (auto &x : open_thumbs.e) {
      if (x.h == INVALID_HANDLE_VALUE) {
        at = &x;
        break;
      }
      if (x.used < at->used) at = &x;
    }
    if (at->h != INVALID_HANDLE_VALUE) CloseHandle(at->h);
    at->h = h;
    at->file = file;
  }
  at->used = ++open_thumbs.clock;
  bytes.resize(len);
  OVERLAPPED o = {};
  o.Offset = (DWORD)off;
  o.OffsetHigh = (DWORD)((uint64_t)off >> 32);
  DWORD got = 0;
  if (!ReadFile(at->h, bytes.data(), len, &got, &o) || got != len) {
    bytes.clear();
    return false;
  }
  return true;
}
int64_t prefer_clock = 0;
bool started = false;
std::atomic<int> made{0};
// Leaked D3D11 devices from hung decoders; fall back to CPU indexing once kAbandonedMost is reached.
std::atomic<int> abandoned{0};
const int kAbandonedMost = 3;

std::wstring wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
  return w;
}

template <class T> void release(T *&p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

std::wstring stem_of(const std::wstring &path) {
  size_t slash = path.find_last_of(L"\\/");
  std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
  size_t dot = name.find_last_of(L'.');
  return dot == std::wstring::npos ? name : name.substr(0, dot);
}

// Binary cache format: "RPT1"/"RPT2" magic, uint32 count, then (int64 ms, uint32 len, jpeg[len]) per entry.
bool load_thumbs(const std::wstring &file, std::vector<Thumb> &out) {
  FILE *f = _wfopen(file.c_str(), L"rb");
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
      t.off = _ftelli64(f);
      t.len = len;
      if (_fseeki64(f, len, SEEK_CUR) != 0) ok = false;
      out.push_back(std::move(t));
    }
  }
  fclose(f);
  if (!ok) out.clear();
  return ok && !out.empty();
}

void save_cache(const std::wstring &stem, std::vector<Thumb> &thumbs, std::wstring *saved_as) {
  if (cache_dir.empty() || stem.empty() || thumbs.empty()) return;
  CreateDirectoryW(cache_dir.c_str(), nullptr);
  std::wstring file = cache_dir + L"\\" + stem + L".thumbs";
  std::wstring tmp = file + L".tmp";
  FILE *f = _wfopen(tmp.c_str(), L"wb");
  if (!f) return;
  uint32_t n = (uint32_t)thumbs.size();
  fwrite("RPT1", 1, 4, f);
  fwrite(&n, 4, 1, f);
  std::vector<int64_t> offs;
  for (auto &t : thumbs) {
    uint32_t len = (uint32_t)t.jpeg.size();
    fwrite(&t.ms, 8, 1, f);
    fwrite(&len, 4, 1, f);
    offs.push_back(_ftelli64(f));
    if (len) fwrite(t.jpeg.data(), 1, len, f);
  }
  bool ok = ferror(f) == 0;
  fclose(f);
  forget_open(file);
  if (ok && MoveFileExW(tmp.c_str(), file.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    for (size_t k = 0; k < thumbs.size(); k++) {
      thumbs[k].off = offs[k];
      thumbs[k].len = (uint32_t)thumbs[k].jpeg.size();
      std::vector<uint8_t>().swap(thumbs[k].jpeg);
    }
    *saved_as = file;
  } else {
    DeleteFileW(tmp.c_str());
  }
}

std::vector<uint8_t> encode_jpeg(IWICImagingFactory *wic, const std::vector<uint8_t> &bgr, int w, int h) {
  std::vector<uint8_t> out;
  IStream *stream = nullptr;
  IWICBitmapEncoder *enc = nullptr;
  IWICBitmapFrameEncode *frame = nullptr;
  IPropertyBag2 *props = nullptr;
  do {
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) break;
    if (FAILED(wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &enc))) break;
    if (FAILED(enc->Initialize(stream, WICBitmapEncoderNoCache))) break;
    if (FAILED(enc->CreateNewFrame(&frame, &props))) break;
    PROPBAG2 opt = {};
    opt.pstrName = (LPOLESTR)L"ImageQuality";
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_R4;
    v.fltVal = 0.82f;
    props->Write(1, &opt, &v);
    if (FAILED(frame->Initialize(props))) break;
    if (FAILED(frame->SetSize(w, h))) break;
    WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
    if (FAILED(frame->SetPixelFormat(&fmt)) || fmt != GUID_WICPixelFormat24bppBGR) break;
    if (FAILED(frame->WritePixels(h, w * 3, (UINT)bgr.size(), (BYTE *)bgr.data()))) break;
    if (FAILED(frame->Commit()) || FAILED(enc->Commit())) break;
    HGLOBAL mem = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &mem))) break;
    STATSTG st = {};
    stream->Stat(&st, STATFLAG_NONAME);
    void *p = GlobalLock(mem);
    if (p) {
      out.assign((uint8_t *)p, (uint8_t *)p + st.cbSize.LowPart);
      GlobalUnlock(mem);
    }
  } while (false);
  release(props);
  release(frame);
  release(enc);
  release(stream);
  return out;
}

// BT.709 video-range NV12 -> BGR box downscale.
std::vector<uint8_t> shrink_nv12(const BYTE *data, LONG pitch, int rows, int fw, int fh, int w, int h) {
  std::vector<uint8_t> out((size_t)w * h * 3);
  const BYTE *uv = data + (ptrdiff_t)pitch * rows;
  auto clamp = [](double v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5); };
  for (int y = 0; y < h; y++) {
    int y0 = (int)((int64_t)y * fh / h), y1 = (int)((int64_t)(y + 1) * fh / h);
    if (y1 <= y0) y1 = y0 + 1;
    for (int x = 0; x < w; x++) {
      int x0 = (int)((int64_t)x * fw / w), x1 = (int)((int64_t)(x + 1) * fw / w);
      if (x1 <= x0) x1 = x0 + 1;
      uint32_t ys = 0, us = 0, vs = 0, n = 0, m = 0;
      for (int yy = y0; yy < y1; yy += 2) {
        const BYTE *row = data + (ptrdiff_t)yy * pitch;
        const BYTE *crow = uv + (ptrdiff_t)(yy / 2) * pitch;
        for (int xx = x0; xx < x1; xx += 2) {
          ys += row[xx];
          n++;
          us += crow[(xx / 2) * 2];
          vs += crow[(xx / 2) * 2 + 1];
          m++;
        }
      }
      double Y = 1.164383 * ((double)ys / n - 16.0), U = (double)us / m - 128.0, V = (double)vs / m - 128.0;
      uint8_t *o = &out[((size_t)y * w + x) * 3];
      o[0] = clamp(Y + 2.112402 * U);
      o[1] = clamp(Y - 0.213249 * U - 0.532909 * V);
      o[2] = clamp(Y + 1.792741 * V);
    }
  }
  return out;
}

// Concurrency budget: up to 3 decoders <=1440p, or 1 at 4K (software 4K HEVC decoders use hundreds of MB each).
std::mutex room_mu;
std::condition_variable room_cv;
int room_free = 3;

struct Room {
  int n;
  explicit Room(int want) : n(want) {
    std::unique_lock<std::mutex> lock(room_mu);
    room_cv.wait(lock, [&] { return room_free >= n; });
    room_free -= n;
  }
  ~Room() {
    {
      std::lock_guard<std::mutex> lock(room_mu);
      room_free += n;
    }
    room_cv.notify_all();
  }
};

// Hint MF decoder for keyframe-only thumbnail mode (2 threads, no reference frames) where supported.
void thumbnail_mode(IMFSourceReader *reader) {
  IMFSourceReaderEx *ex = nullptr;
  if (FAILED(reader->QueryInterface(IID_PPV_ARGS(&ex)))) return;
  for (DWORD i = 0;; i++) {
    GUID category;
    IMFTransform *mft = nullptr;
    if (FAILED(ex->GetTransformForStream((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &category, &mft))) break;
    if (category == MFT_CATEGORY_VIDEO_DECODER) {
      ICodecAPI *api = nullptr;
      if (SUCCEEDED(mft->QueryInterface(IID_PPV_ARGS(&api)))) {
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_UI4;
        v.ulVal = 1;
        api->SetValue(&CODECAPI_AVDecVideoThumbnailGenerationMode, &v);
        v.ulVal = 2;
        api->SetValue(&CODECAPI_AVDecNumWorkerThreads, &v);
        api->Release();
      }
    }
    mft->Release();
  }
  ex->Release();
}

struct GpuIndexer {
  ID3D11Device *dev = nullptr;
  ID3D11DeviceContext *ctx = nullptr;
  ID3D11VideoDevice *vdev = nullptr;
  ID3D11VideoContext *vctx = nullptr;
  IMFDXGIDeviceManager *manager = nullptr;
  ID3D11Texture2D *nv12 = nullptr;
  UINT32 nv12_w = 0, nv12_h = 0;
  ID3D11VideoProcessorEnumerator *vpe = nullptr;
  ID3D11VideoProcessor *vp = nullptr;
  ID3D11VideoProcessorInputView *in_view = nullptr;
  ID3D11Texture2D *bgra = nullptr;
  ID3D11VideoProcessorOutputView *out_view = nullptr;
  ID3D11Texture2D *staging = nullptr;
  UINT32 vp_in_w = 0, vp_in_h = 0, vp_out_w = 0, vp_out_h = 0;

  bool holds() const { return manager != nullptr || dev != nullptr; }

  bool ensure() {
    if (manager) return true;
    D3D_FEATURE_LEVEL level;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, &dev, &level, &ctx)))
      return false;
    ID3D10Multithread *mt = nullptr;
    if (SUCCEEDED(dev->QueryInterface(IID_PPV_ARGS(&mt)))) {
      mt->SetMultithreadProtected(TRUE);
      mt->Release();
    }
    UINT token = 0;
    if (FAILED(dev->QueryInterface(IID_PPV_ARGS(&vdev))) ||
        FAILED(ctx->QueryInterface(IID_PPV_ARGS(&vctx))) ||
        FAILED(MFCreateDXGIDeviceManager(&token, &manager)) ||
        FAILED(manager->ResetDevice(dev, token))) {
      drop();
      return false;
    }
    return true;
  }

  bool shrink_gpu(IMFSample *sample, UINT32 fw, UINT32 fh, int bt601, int full, int w, int h, std::vector<uint8_t> &bgr) {
    if (!vdev || !vctx) return false;
    IMFMediaBuffer *buf = nullptr;
    IMFDXGIBuffer *dxgi = nullptr;
    ID3D11Texture2D *src_tex = nullptr;
    UINT sub = 0;
    bool ok = false;
    do {
      if (FAILED(sample->GetBufferByIndex(0, &buf)) ||
          FAILED(buf->QueryInterface(IID_PPV_ARGS(&dxgi))) ||
          FAILED(dxgi->GetResource(IID_PPV_ARGS(&src_tex))) ||
          FAILED(dxgi->GetSubresourceIndex(&sub)))
        break;
      D3D11_TEXTURE2D_DESC sdesc{};
      src_tex->GetDesc(&sdesc);
      UINT32 tw = std::min<UINT32>(fw, sdesc.Width) & ~1u;
      UINT32 th = std::min<UINT32>(fh, sdesc.Height) & ~1u;
      if (tw < 2 || th < 2) break;
      if (!nv12 || nv12_w != tw || nv12_h != th) {
        release(in_view);
        release(nv12);
        D3D11_TEXTURE2D_DESC td{};
        td.Width = tw;
        td.Height = th;
        td.MipLevels = td.ArraySize = 1;
        td.Format = DXGI_FORMAT_NV12;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_DECODER;
        if (FAILED(dev->CreateTexture2D(&td, nullptr, &nv12))) break;
        nv12_w = tw;
        nv12_h = th;
      }
      D3D11_BOX cbox = {0, 0, 0, tw, th, 1};
      ctx->CopySubresourceRegion(nv12, 0, 0, 0, 0, src_tex, sub, &cbox);

      if (!vp || vp_in_w != tw || vp_in_h != th || vp_out_w != (UINT32)w || vp_out_h != (UINT32)h) {
        release(in_view);
        release(out_view);
        release(bgra);
        release(staging);
        release(vp);
        release(vpe);
        D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
        cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
        cd.InputFrameRate = {60, 1};
        cd.InputWidth = tw;
        cd.InputHeight = th;
        cd.OutputFrameRate = {60, 1};
        cd.OutputWidth = (UINT)w;
        cd.OutputHeight = (UINT)h;
        cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
        if (FAILED(vdev->CreateVideoProcessorEnumerator(&cd, &vpe)) ||
            FAILED(vdev->CreateVideoProcessor(vpe, 0, &vp))) {
          release(vpe);
          break;
        }
        D3D11_TEXTURE2D_DESC bdesc{};
        bdesc.Width = (UINT)w;
        bdesc.Height = (UINT)h;
        bdesc.MipLevels = bdesc.ArraySize = 1;
        bdesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        bdesc.SampleDesc.Count = 1;
        bdesc.Usage = D3D11_USAGE_DEFAULT;
        bdesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        D3D11_TEXTURE2D_DESC stdesc = bdesc;
        stdesc.Usage = D3D11_USAGE_STAGING;
        stdesc.BindFlags = 0;
        stdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
        ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        if (FAILED(dev->CreateTexture2D(&bdesc, nullptr, &bgra)) ||
            FAILED(vdev->CreateVideoProcessorOutputView(bgra, vpe, &ovd, &out_view)) ||
            FAILED(dev->CreateTexture2D(&stdesc, nullptr, &staging))) {
          release(out_view);
          release(bgra);
          release(staging);
          release(vp);
          release(vpe);
          break;
        }
        vp_in_w = tw;
        vp_in_h = th;
        vp_out_w = (UINT32)w;
        vp_out_h = (UINT32)h;
      }
      if (!in_view) {
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
        ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        if (FAILED(vdev->CreateVideoProcessorInputView(nv12, vpe, &ivd, &in_view))) break;
      }

      vctx->VideoProcessorSetStreamFrameFormat(vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
      vctx->VideoProcessorSetStreamAutoProcessingMode(vp, 0, FALSE);
      D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs{};
      in_cs.YCbCr_Matrix = bt601 ? 0 : 1;
      in_cs.Nominal_Range = full ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255 : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
      vctx->VideoProcessorSetStreamColorSpace(vp, 0, &in_cs);
      D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs{};
      out_cs.RGB_Range = 0;
      vctx->VideoProcessorSetOutputColorSpace(vp, &out_cs);
      RECT srect = {0, 0, (LONG)tw, (LONG)th};
      RECT drect = {0, 0, w, h};
      vctx->VideoProcessorSetStreamSourceRect(vp, 0, TRUE, &srect);
      vctx->VideoProcessorSetStreamDestRect(vp, 0, TRUE, &drect);
      vctx->VideoProcessorSetOutputTargetRect(vp, TRUE, &drect);

      D3D11_VIDEO_PROCESSOR_STREAM st{};
      st.Enable = TRUE;
      st.pInputSurface = in_view;
      if (FAILED(vctx->VideoProcessorBlt(vp, out_view, 0, 1, &st))) break;

      ctx->CopyResource(staging, bgra);
      D3D11_MAPPED_SUBRESOURCE mapped{};
      if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) break;
      bgr.resize((size_t)w * h * 3);
      for (int y = 0; y < h; y++) {
        const uint8_t *row = (const uint8_t *)mapped.pData + (size_t)y * mapped.RowPitch;
        uint8_t *dst = &bgr[(size_t)y * w * 3];
        for (int x = 0; x < w; x++) {
          dst[x * 3 + 0] = row[x * 4 + 0];
          dst[x * 3 + 1] = row[x * 4 + 1];
          dst[x * 3 + 2] = row[x * 4 + 2];
        }
      }
      ctx->Unmap(staging, 0);
      ok = true;
    } while (false);
    release(src_tex);
    release(dxgi);
    release(buf);
    return ok;
  }

  void drop() {
    release(in_view);
    release(out_view);
    release(bgra);
    release(staging);
    release(vp);
    release(vpe);
    release(nv12);
    nv12_w = nv12_h = vp_in_w = vp_in_h = vp_out_w = vp_out_h = 0;
    if (ctx) ctx->Flush();
    release(manager);
    release(vctx);
    release(vdev);
    release(ctx);
    release(dev);
  }

  // Intentionally leak COM refs: releasing a device with a hung decoder blocks indefinitely.
  void abandon() {
    abandoned++;
    dev = nullptr;
    ctx = nullptr;
    vdev = nullptr;
    vctx = nullptr;
    manager = nullptr;
    nv12 = nullptr;
    vpe = nullptr;
    vp = nullptr;
    in_view = nullptr;
    bgra = nullptr;
    out_view = nullptr;
    staging = nullptr;
    nv12_w = nv12_h = vp_in_w = vp_in_h = vp_out_w = vp_out_h = 0;
  }

  ~GpuIndexer() { drop(); }
};

// Async reader callback so hung MF HEVC ReadSample calls can time out instead of blocking forever.
struct Reads : IMFSourceReaderCallback {
  LONG refs = 1;
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  HRESULT hr = S_OK;
  DWORD flags = 0;
  LONGLONG ts = 0;
  IMFSample *sample = nullptr;

  ~Reads() {
    release(sample);
    if (ready) CloseHandle(ready);
  }
  STDMETHODIMP QueryInterface(REFIID iid, void **out) override {
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFSourceReaderCallback)) {
      *out = static_cast<IMFSourceReaderCallback *>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs); }
  STDMETHODIMP_(ULONG) Release() override {
    LONG n = InterlockedDecrement(&refs);
    if (n == 0) delete this;
    return n;
  }
  STDMETHODIMP OnReadSample(HRESULT status, DWORD, DWORD f, LONGLONG t, IMFSample *s) override {
    {
      std::lock_guard<std::mutex> lock(mu_);
      hr = status;
      flags = f;
      ts = t;
      release(sample);
      sample = s;
      if (sample) sample->AddRef();
    }
    SetEvent(ready);
    return S_OK;
  }
  STDMETHODIMP OnFlush(DWORD) override { return S_OK; }
  STDMETHODIMP OnEvent(DWORD, IMFMediaEvent *) override { return S_OK; }

  bool read(IMFSourceReader *reader, DWORD ms, HRESULT &status, DWORD &f, LONGLONG &t, IMFSample *&s) {
    ResetEvent(ready);
    status = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, nullptr, nullptr, nullptr);
    if (FAILED(status)) return true;
    if (WaitForSingleObject(ready, ms) != WAIT_OBJECT_0) return false;
    std::lock_guard<std::mutex> lock(mu_);
    status = hr;
    f = flags;
    t = ts;
    s = sample;
    sample = nullptr;
    return true;
  }

 private:
  std::mutex mu_;
};

const DWORD kReadPatience = 8000;

enum Made { kMadeNone = 0, kMadeOk = 1, kMadeStuck = 2 };

Made make_thumbs(IWICImagingFactory *wic, GpuIndexer *gpu, const std::wstring &path, double dur_ms, bool plain,
                 std::vector<Thumb> &out) {
  IMFAttributes *attrs = nullptr;
  IMFSourceReader *reader = nullptr;
  IMFMediaType *want = nullptr, *got = nullptr;
  Reads *reads = new Reads();
  std::unique_ptr<Room> room;
  bool ok = false;
  bool stuck = false;
  do {
    if (!reads->ready || FAILED(MFCreateAttributes(&attrs, 4))) break;
    attrs->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, reads);
    if (gpu && gpu->manager) {
      attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, gpu->manager);
      attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    }
    if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), attrs, &reader))) break;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(MFCreateMediaType(&want))) break;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want))) break;
    if (!plain) thumbnail_mode(reader);
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    UINT32 fw = 0, fh = 0;
    MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &fw, &fh);
    // Use display aperture when coded height is padded (e.g. HEVC 2160 -> 2176).
    MFVideoArea area;
    if (SUCCEEDED(got->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area, nullptr)) &&
        area.Area.cx > 0 && area.Area.cy > 0 && (UINT32)area.Area.cx <= fw && (UINT32)area.Area.cy <= fh) {
      fw = (UINT32)area.Area.cx;
      fh = (UINT32)area.Area.cy;
    }
    UINT32 m = 0, r = 0;
    int bt601 = SUCCEEDED(got->GetUINT32(MF_MT_YUV_MATRIX, &m)) && m == MFVideoTransferMatrix_BT601;
    int full = SUCCEEDED(got->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &r)) && r == MFNominalRange_0_255;
    release(got);
    if (!fw || !fh) break;
    room.reset(new Room(!(gpu && gpu->manager) && (uint64_t)fw * fh > 2560ull * 1440ull ? 3 : 1));
    int w = kThumbW, h = (int)((int64_t)kThumbW * fh / fw);
    if (h > kThumbH) {
      h = kThumbH;
      w = (int)((int64_t)kThumbH * fw / fh);
    }
    LONGLONG last = -1;
    LONGLONG end = (LONGLONG)(dur_ms * 10000.0);
    std::vector<uint8_t> bgr;
    for (LONGLONG at = 0; at < end || at == 0; at += kStep) {
      if (last >= 0 && at <= last) continue;
      PROPVARIANT pos;
      PropVariantInit(&pos);
      pos.vt = VT_I8;
      pos.hVal.QuadPart = at;
      // Async IMFSourceReader returns MF_E_INVALIDREQUEST until the previous callback unwinds.
      HRESULT moved = reader->SetCurrentPosition(GUID_NULL, pos);
      for (int wait = 0; moved == MF_E_INVALIDREQUEST && wait < 250; wait++) {
        Sleep(2);
        moved = reader->SetCurrentPosition(GUID_NULL, pos);
      }
      if (FAILED(moved)) break;
      IMFSample *sample = nullptr;
      LONGLONG ts = 0;
      bool eos = false;
      for (int tries = 0; tries < 8 && !sample; tries++) {
        DWORD flags = 0;
        HRESULT hr = S_OK;
        if (!reads->read(reader, kReadPatience, hr, flags, ts, sample)) {
          stuck = true;
          break;
        }
        if (FAILED(hr)) {
          eos = true;
          break;
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
          eos = true;
          break;
        }
      }
      if (stuck) break;
      if (!sample) {
        if (eos) break;
        continue;
      }
      if (ts == last) {
        release(sample);
        continue;
      }
      if (gpu && gpu->shrink_gpu(sample, fw, fh, bt601, full, w, h, bgr)) {
        Thumb t;
        t.ms = ts / 10000;
        t.jpeg = encode_jpeg(wic, bgr, w, h);
        if (!t.jpeg.empty()) out.push_back(std::move(t));
        release(sample);
        last = ts;
        continue;
      }
      // Re-query output type after first decode for aligned storage stride.
      UINT32 sw = fw, sh = fh;
      LONG stride = 0;
      if (SUCCEEDED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) {
        MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &sw, &sh);
        stride = (LONG)MFGetAttributeUINT32(got, MF_MT_DEFAULT_STRIDE, sw);
        release(got);
      }
      IMFMediaBuffer *buffer = nullptr;
      IMF2DBuffer *surface = nullptr;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
        BYTE *data = nullptr;
        DWORD len = 0;
        LONG pitch = stride;
        bool locked2d = SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&surface))) && SUCCEEDED(surface->Lock2D(&data, &pitch));
        if (!locked2d && SUCCEEDED(buffer->Lock(&data, nullptr, &len))) {
          if (pitch == 0) pitch = (LONG)sw;
          // bottom-up buffer
          if (pitch < 0) data += (size_t)(sh - 1) * (size_t)(-pitch);
        }
        if (data) {
          auto sw_bgr = shrink_nv12(data, pitch, (int)sh, (int)fw, (int)fh, w, h);
          if (locked2d) surface->Unlock2D();
          else buffer->Unlock();
          Thumb t;
          t.ms = ts / 10000;
          t.jpeg = encode_jpeg(wic, sw_bgr, w, h);
          if (!t.jpeg.empty()) out.push_back(std::move(t));
        }
      }
      release(surface);
      release(buffer);
      release(sample);
      last = ts;
    }
    ok = !stuck && !out.empty();
  } while (false);
  release(got);
  release(want);
  if (stuck) {
    // Leak hung reader so Release() does not block on the stalled decoder; still release Room.
    reader = nullptr;
    out.clear();
  }
  release(reader);
  release(attrs);
  reads->Release();
  room.reset();
  return stuck ? kMadeStuck : ok ? kMadeOk : kMadeNone;
}

void worker() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  MFStartup(MF_VERSION, MFSTARTUP_LITE);
  IWICImagingFactory *wic = nullptr;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
  const bool software = getenv("REPLAY_INDEX_SOFTWARE") != nullptr;
  GpuIndexer gpu;
  for (;;) {
    std::string key;
    std::wstring path, stem;
    double dur = 0;
    bool plain = false;
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
          plain = best->plain != 0;
          break;
        }
        // Release GPU device outside mu when idle.
        if (gpu.holds()) {
          lock.unlock();
          gpu.drop();
          lock.lock();
          continue;
        }
        work.wait(lock);
      }
    }
    std::vector<Thumb> thumbs;
    std::wstring file;
    std::wstring beside = path.size() > 4 ? path.substr(0, path.size() - 4) + L".thumbs" : L"";
    bool cached = !stem.empty() && !beside.empty() && load_thumbs(beside, thumbs);
    if (cached) {
      file = beside;
    } else if (!stem.empty() && !cache_dir.empty()) {
      std::wstring kept = cache_dir + L"\\" + stem + L".thumbs";
      thumbs.clear();
      cached = load_thumbs(kept, thumbs);
      if (cached) file = kept;
      else thumbs.clear();
    }
    ULONGLONG began = GetTickCount64();
    GpuIndexer *use_gpu = !cached && !software && abandoned.load() < kAbandonedMost && gpu.ensure() ? &gpu : nullptr;
    Made made_as = cached ? kMadeOk : wic ? make_thumbs(wic, use_gpu, path, dur, plain, thumbs) : kMadeNone;
    bool ok = made_as == kMadeOk;
    if (made_as == kMadeStuck && use_gpu) gpu.abandon();
    const char *trace = getenv("REPLAY_TRACE");
    if (trace && strcmp(trace, "1") == 0) {
      printf("REPLAY_INDEX %s %llu ms %zu thumbs%s%s%s\n", key.c_str(), GetTickCount64() - began, thumbs.size(), cached ? " (disk)" : "",
             plain ? " (plain)" : "", made_as == kMadeStuck ? " STUCK" : "");
      fflush(stdout);
    }
    if (made_as == kMadeStuck && !plain) {
      std::lock_guard<std::mutex> lock(mu);
      auto it = segs.find(key);
      if (it != segs.end() && !it->second.dropped) {
        it->second.plain = 1;
        it->second.state = 0;
        continue;
      }
    }
    if (ok && !cached) save_cache(stem, thumbs, &file);
    std::wstring gone;
    {
      std::lock_guard<std::mutex> lock(mu);
      auto it = segs.find(key);
      if (it != segs.end() && it->second.dropped) {
        if (!cache_dir.empty() && !it->second.stem.empty()) gone = cache_dir + L"\\" + it->second.stem + L".thumbs";
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
      DeleteFileW(gone.c_str());
    }
    made++;
  }
}

void start() {
  if (started) return;
  started = true;
  for (int i = 0; i < 3; i++) std::thread(worker).detach();
}

const Thumb *nearest(const Seg &s, double ms) {
  if (s.thumbs.empty()) return nullptr;
  size_t lo = 0, hi = s.thumbs.size();
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    if (s.thumbs[mid].ms <= ms + 1) lo = mid + 1;
    else hi = mid;
  }
  return lo == 0 ? &s.thumbs[0] : &s.thumbs[lo - 1];
}

}

extern "C" void rp_idx_dir(moonbit_bytes_t dir) {
  std::lock_guard<std::mutex> lock(mu);
  cache_dir = wide((const char *)dir);
}

extern "C" void rp_idx_add(moonbit_bytes_t path, double dur) {
  std::lock_guard<std::mutex> lock(mu);
  std::string key((const char *)path);
  if (segs.count(key)) return;
  Seg s;
  s.path = wide(key.c_str());
  s.stem = stem_of(s.path);
  s.dur = dur;
  segs.emplace(key, std::move(s));
  recount();
  start();
  work.notify_all();
}

extern "C" void rp_idx_add_clip(moonbit_bytes_t path, double dur) {
  std::lock_guard<std::mutex> lock(mu);
  std::string key((const char *)path);
  if (segs.count(key)) return;
  Seg s;
  s.path = wide(key.c_str());
  s.dur = dur;
  s.prefer = ++prefer_clock;
  segs.emplace(key, std::move(s));
  recount();
  start();
  work.notify_all();
}

extern "C" void rp_idx_drop(moonbit_bytes_t path) {
  std::wstring gone, read_from;
  {
    std::lock_guard<std::mutex> lock(mu);
    auto it = segs.find(std::string((const char *)path));
    if (it == segs.end()) return;
    if (it->second.state == 1) {
      it->second.dropped = 1;
      return;
    }
    if (!cache_dir.empty() && !it->second.stem.empty()) gone = cache_dir + L"\\" + it->second.stem + L".thumbs";
    read_from = it->second.file;
    segs.erase(it);
    recount();
  }
  if (!read_from.empty()) forget_open(read_from);
  if (!gone.empty()) {
    forget_open(gone);
    DeleteFileW(gone.c_str());
  }
}

extern "C" void rp_idx_prefer(moonbit_bytes_t path) {
  std::lock_guard<std::mutex> lock(mu);
  auto it = segs.find(std::string((const char *)path));
  if (it != segs.end() && it->second.state == 0) it->second.prefer = ++prefer_clock;
}

// Returns thumbnail timestamp (ms), -1 if pending, -2 if unreadable.
extern "C" double rp_idx_at(moonbit_bytes_t path, double ms) {
  std::lock_guard<std::mutex> lock(mu);
  auto it = segs.find(std::string((const char *)path));
  if (it == segs.end()) return -1;
  if (it->second.state == -1) return -2;
  const Thumb *t = nearest(it->second, ms);
  return t ? (double)t->ms : -1;
}

extern "C" moonbit_bytes_t rp_idx_jpeg(moonbit_bytes_t path, double ms) {
  std::vector<uint8_t> bytes;
  std::wstring file;
  int64_t off = 0;
  uint32_t len = 0;
  {
    std::lock_guard<std::mutex> lock(mu);
    auto it = segs.find(std::string((const char *)path));
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
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)bytes.size(), 0);
  if (!bytes.empty()) memcpy(out, bytes.data(), bytes.size());
  return out;
}

extern "C" int32_t rp_idx_pending(void) { return pending_n.load(); }

extern "C" int32_t rp_idx_made(void) { return made.load(); }
