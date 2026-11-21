// The replay app's media on Windows: a frame of a segment decoded small for the timeline's thumbnails (Media
// Foundation's source reader on the GPU with D3D11VA + ID3D11VideoProcessor cropping and scaling to BGRA, falling back
// to software RGB32 when unavailable), and a clip saved as recorded (the segments' samples copied into one MP4 by a
// sink writer, not encoded again: rp_concat); a saved GIF's first picture (WIC) and length.
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3d10.h>
#include <wincodec.h>
#include <algorithm>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <deque>
#include <atomic>
#include <memory>
#include "moonbit.h"

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "windowscodecs.lib")

static std::wstring rp_w(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
  return w;
}

static bool rp_mf_ready() {
  static thread_local int state = 0;
  if (state == 0) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    state = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE)) ? 1 : -1;
  }
  return state == 1;
}

template <class T> static void rp_release(T *&p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

// A BMP (32-bit, top-down) of `w` x `h` from BGRA rows.
static std::vector<uint8_t> rp_bmp(const std::vector<uint8_t> &bgra, int w, int h) {
  const int header = 14 + 40;
  const int size = header + w * h * 4;
  std::vector<uint8_t> b(size, 0);
  uint8_t *p = b.data();
  p[0] = 'B';
  p[1] = 'M';
  memcpy(p + 2, &size, 4);
  int off = header;
  memcpy(p + 10, &off, 4);
  int32_t info = 40, hh = -h;
  uint16_t planes = 1, bits = 32;
  memcpy(p + 14, &info, 4);
  memcpy(p + 18, &w, 4);
  memcpy(p + 22, &hh, 4);
  memcpy(p + 26, &planes, 2);
  memcpy(p + 28, &bits, 2);
  memcpy(p + header, bgra.data(), (size_t)w * h * 4);
  return b;
}

// A frame of the file at `ms` (the first decoded at or after it), at most `max_w` x `max_h` keeping its shape, as a
// BMP; none when it cannot be decoded.
static std::vector<uint8_t> rp_gif_pixels(const std::wstring &file, int32_t max_w, int32_t max_h);

static bool rp_is_gif(const std::wstring &file) {
  return file.size() > 4 && _wcsicmp(file.c_str() + file.size() - 4, L".gif") == 0;
}

// A frame of `file` at `ms` decoded on the GPU (IMFSourceReader with D3D11VA into NV12, so frames before `ms` cost no
// colour conversion or scaling), then cropped to (cx, cy, cw, ch) and scaled to fit max_w x max_h by ID3D11VideoProcessor
// into a small staging texture read back as a BMP; empty when the GPU path cannot decode it.
struct GpuThumb {
    int state = 0;  // 0 uninit, 1 ready, -1 unavailable
    ID3D11Device *dev = nullptr;
    ID3D11DeviceContext *ctx = nullptr;
    ID3D11VideoDevice *vdev = nullptr;
    ID3D11VideoContext *vctx = nullptr;
    IMFDXGIDeviceManager *mgr = nullptr;
    IMFSourceReader *reader = nullptr;
    std::wstring cached_file;
    UINT32 display_w = 0, display_h = 0;
    int bt601 = 0, full = 0;
    ID3D11Texture2D *nv12 = nullptr;
    UINT32 nv12_w = 0, nv12_h = 0;
    std::wstring nv12_file;
    LONGLONG nv12_target = -1;
    ID3D11VideoProcessorEnumerator *vpe = nullptr;
    ID3D11VideoProcessor *vp = nullptr;
    ID3D11VideoProcessorInputView *in_view = nullptr;
    ID3D11Texture2D *bgra = nullptr;
    ID3D11VideoProcessorOutputView *out_view = nullptr;
    ID3D11Texture2D *staging = nullptr;
    UINT32 vp_in_w = 0, vp_in_h = 0, vp_out_w = 0, vp_out_h = 0;
    // The file let go of (its reader holds it open: a clip previewed last could not be deleted, nor a segment's
    // space given back), the frame kept of it with it.
    void drop_reader() {
      rp_release(reader);
      cached_file.clear();
      rp_release(in_view);
      rp_release(nv12);
      nv12_w = nv12_h = 0;
      nv12_file.clear();
      nv12_target = -1;
    }
    // All of it let go of (the device, its decoder's and its video processor's memory): made again at the next ask.
    void drop() {
      drop_reader();
      rp_release(out_view);
      rp_release(bgra);
      rp_release(staging);
      rp_release(vp);
      rp_release(vpe);
      vp_in_w = vp_in_h = vp_out_w = vp_out_h = 0;
      rp_release(mgr);
      rp_release(vctx);
      rp_release(vdev);
      rp_release(ctx);
      rp_release(dev);
      state = 0;
    }
};

// (the thumbnail worker's own: rp_thumb_job's thread alone uses them)
static thread_local GpuThumb rp_gpu_thumb;
static thread_local IMFSourceReader *rp_sw_reader = nullptr;
static thread_local std::wstring rp_sw_file;

static std::vector<uint8_t> rp_thumb_gpu_pixels(const std::wstring &file, double ms, int32_t max_w, int32_t max_h,
                                                int32_t cx, int32_t cy, int32_t cw, int32_t ch) {
  GpuThumb &g = rp_gpu_thumb;
  std::vector<uint8_t> out;
  if (g.state == 0) {
    g.state = -1;
    D3D_FEATURE_LEVEL level;
    UINT token = 0;
    ID3D10Multithread *mt = nullptr;
    if (SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                    D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                    nullptr, 0, D3D11_SDK_VERSION, &g.dev, &level, &g.ctx)) &&
        SUCCEEDED(g.dev->QueryInterface(IID_PPV_ARGS(&g.vdev))) &&
        SUCCEEDED(g.ctx->QueryInterface(IID_PPV_ARGS(&g.vctx))) &&
        SUCCEEDED(MFCreateDXGIDeviceManager(&token, &g.mgr)) &&
        SUCCEEDED(g.mgr->ResetDevice(g.dev, token))) {
      if (SUCCEEDED(g.dev->QueryInterface(IID_PPV_ARGS(&mt)))) {
        mt->SetMultithreadProtected(TRUE);
        mt->Release();
      }
      g.state = 1;
    } else {
      rp_release(g.mgr);
      rp_release(g.vctx);
      rp_release(g.vdev);
      rp_release(g.ctx);
      rp_release(g.dev);
    }
  }
  if (g.state < 0) return out;

  IMFAttributes *attrs = nullptr;
  IMFMediaType *nat = nullptr, *want = nullptr, *got = nullptr;
  IMFSample *sample = nullptr;
  IMFMediaBuffer *buffer = nullptr;
  IMFDXGIBuffer *dxgi = nullptr;
  ID3D11Texture2D *src_tex = nullptr;
  do {
    if (!g.reader || g.cached_file != file) {
      rp_release(g.reader);
      g.cached_file.clear();
      if (FAILED(MFCreateAttributes(&attrs, 3))) break;
      attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, g.mgr);
      attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
      attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
      if (FAILED(MFCreateSourceReaderFromURL(file.c_str(), attrs, &g.reader))) break;
      g.reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
      g.reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
      g.display_w = g.display_h = 0;
      g.bt601 = g.full = 0;
      if (SUCCEEDED(g.reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &nat))) {
        MFGetAttributeSize(nat, MF_MT_FRAME_SIZE, &g.display_w, &g.display_h);
        MFVideoArea area{};
        UINT32 cb = 0;
        if ((SUCCEEDED(nat->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area, &cb)) ||
             SUCCEEDED(nat->GetBlob(MF_MT_GEOMETRIC_APERTURE, (UINT8 *)&area, sizeof area, &cb))) &&
            cb == sizeof area && area.Area.cx > 0 && area.Area.cy > 0) {
          g.display_w = (UINT32)area.Area.cx;
          g.display_h = (UINT32)area.Area.cy;
        }
        UINT32 m = 0, r = 0;
        g.bt601 = SUCCEEDED(nat->GetUINT32(MF_MT_YUV_MATRIX, &m)) && m == MFVideoTransferMatrix_BT601;
        g.full = SUCCEEDED(nat->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &r)) && r == MFNominalRange_0_255;
      }
      if (FAILED(MFCreateMediaType(&want))) break;
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
      if (FAILED(g.reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want))) {
        rp_release(g.reader);
        break;
      }
      if (g.display_w == 0 || g.display_h == 0) {
        if (SUCCEEDED(g.reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) {
          MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &g.display_w, &g.display_h);
        }
      }
      g.cached_file = file;
    }
    UINT32 fw = g.display_w, fh = g.display_h;
    if (fw < 2 || fh < 2) break;
    const LONGLONG target = (LONGLONG)(ms * 10000.0);
    UINT32 tw = fw & ~1u, th = fh & ~1u;
    if (!g.nv12 || g.nv12_file != file || g.nv12_target != target) {
      PROPVARIANT at;
      PropVariantInit(&at);
      at.vt = VT_I8;
      at.hVal.QuadPart = target;
      g.reader->SetCurrentPosition(GUID_NULL, at);
      for (int tries = 0; tries < 600; tries++) {
        DWORD flags = 0;
        LONGLONG ts = 0;
        rp_release(sample);
        if (FAILED(g.reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &sample))) break;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (sample && ts + 400000 >= target) break;
      }
      if (!sample) break;
      UINT sub = 0;
      if (FAILED(sample->GetBufferByIndex(0, &buffer)) ||
          FAILED(buffer->QueryInterface(IID_PPV_ARGS(&dxgi))) ||
          FAILED(dxgi->GetResource(IID_PPV_ARGS(&src_tex))) ||
          FAILED(dxgi->GetSubresourceIndex(&sub))) {
        break;
      }
      D3D11_TEXTURE2D_DESC sdesc{};
      src_tex->GetDesc(&sdesc);
      tw = std::min<UINT32>(fw, sdesc.Width) & ~1u;
      th = std::min<UINT32>(fh, sdesc.Height) & ~1u;
      if (tw < 2 || th < 2) break;

      if (!g.nv12 || g.nv12_w != tw || g.nv12_h != th) {
        rp_release(g.in_view);
        rp_release(g.nv12);
        g.nv12_file.clear();
        D3D11_TEXTURE2D_DESC td{};
        td.Width = tw;
        td.Height = th;
        td.MipLevels = td.ArraySize = 1;
        td.Format = DXGI_FORMAT_NV12;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_DECODER;
        if (FAILED(g.dev->CreateTexture2D(&td, nullptr, &g.nv12))) break;
        g.nv12_w = tw;
        g.nv12_h = th;
      }
      D3D11_BOX copy_box = {0, 0, 0, tw, th, 1};
      g.ctx->CopySubresourceRegion(g.nv12, 0, 0, 0, 0, src_tex, sub, &copy_box);
      g.nv12_file = file;
      g.nv12_target = target;
    } else {
      tw = g.nv12_w;
      th = g.nv12_h;
    }

    int ox = 0, oy = 0, pw = (int)tw, ph = (int)th;
    if (cw > 0 && ch > 0) {
      ox = cx < 0 ? 0 : (cx >= (int)tw ? (int)tw - 1 : cx);
      oy = cy < 0 ? 0 : (cy >= (int)th ? (int)th - 1 : cy);
      pw = cw > (int)tw - ox ? (int)tw - ox : cw;
      ph = ch > (int)th - oy ? (int)th - oy : ch;
    }
    double k = 1.0;
    if (pw > max_w) k = (double)max_w / pw;
    if (ph * k > max_h) k = (double)max_h / ph;
    int w = std::max(1, (int)(pw * k)), h = std::max(1, (int)(ph * k));

    if (!g.vp || g.vp_in_w != tw || g.vp_in_h != th || g.vp_out_w != (UINT32)w || g.vp_out_h != (UINT32)h) {
      rp_release(g.in_view);
      rp_release(g.out_view);
      rp_release(g.bgra);
      rp_release(g.staging);
      rp_release(g.vp);
      rp_release(g.vpe);
      D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
      cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
      cd.InputFrameRate = {60, 1};
      cd.InputWidth = tw;
      cd.InputHeight = th;
      cd.OutputFrameRate = {60, 1};
      cd.OutputWidth = (UINT)w;
      cd.OutputHeight = (UINT)h;
      cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
      if (FAILED(g.vdev->CreateVideoProcessorEnumerator(&cd, &g.vpe)) ||
          FAILED(g.vdev->CreateVideoProcessor(g.vpe, 0, &g.vp))) {
        rp_release(g.vpe);
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
      if (FAILED(g.dev->CreateTexture2D(&bdesc, nullptr, &g.bgra)) ||
          FAILED(g.vdev->CreateVideoProcessorOutputView(g.bgra, g.vpe, &ovd, &g.out_view)) ||
          FAILED(g.dev->CreateTexture2D(&stdesc, nullptr, &g.staging))) {
        rp_release(g.out_view);
        rp_release(g.bgra);
        rp_release(g.staging);
        rp_release(g.vp);
        rp_release(g.vpe);
        break;
      }
      g.vp_in_w = tw;
      g.vp_in_h = th;
      g.vp_out_w = (UINT32)w;
      g.vp_out_h = (UINT32)h;
    }
    if (!g.in_view) {
      D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
      ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
      if (FAILED(g.vdev->CreateVideoProcessorInputView(g.nv12, g.vpe, &ivd, &g.in_view))) break;
    }

    g.vctx->VideoProcessorSetStreamFrameFormat(g.vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    g.vctx->VideoProcessorSetStreamAutoProcessingMode(g.vp, 0, FALSE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs{};
    in_cs.YCbCr_Matrix = g.bt601 ? 0 : 1;
    in_cs.Nominal_Range = g.full ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255 : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    g.vctx->VideoProcessorSetStreamColorSpace(g.vp, 0, &in_cs);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs{};
    out_cs.RGB_Range = 0;
    g.vctx->VideoProcessorSetOutputColorSpace(g.vp, &out_cs);

    RECT srect = {ox & ~1, oy & ~1, std::min<LONG>((LONG)tw, (ox + pw + 1) & ~1), std::min<LONG>((LONG)th, (oy + ph + 1) & ~1)};
    if (srect.right <= srect.left) srect.right = std::min<LONG>((LONG)tw, srect.left + 2);
    if (srect.bottom <= srect.top) srect.bottom = std::min<LONG>((LONG)th, srect.top + 2);
    RECT drect = {0, 0, w, h};
    g.vctx->VideoProcessorSetStreamSourceRect(g.vp, 0, TRUE, &srect);
    g.vctx->VideoProcessorSetStreamDestRect(g.vp, 0, TRUE, &drect);
    g.vctx->VideoProcessorSetOutputTargetRect(g.vp, TRUE, &drect);

    D3D11_VIDEO_PROCESSOR_STREAM st{};
    st.Enable = TRUE;
    st.pInputSurface = g.in_view;
    if (FAILED(g.vctx->VideoProcessorBlt(g.vp, g.out_view, 0, 1, &st))) break;

    g.ctx->CopyResource(g.staging, g.bgra);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(g.ctx->Map(g.staging, 0, D3D11_MAP_READ, 0, &mapped))) break;
    std::vector<uint8_t> px((size_t)w * h * 4);
    for (int y = 0; y < h; y++) {
      const uint8_t *row = (const uint8_t *)mapped.pData + (size_t)y * mapped.RowPitch;
      uint8_t *dst = &px[(size_t)y * w * 4];
      memcpy(dst, row, (size_t)w * 4);
      for (int x = 0; x < w; x++) dst[x * 4 + 3] = 255;
    }
    g.ctx->Unmap(g.staging, 0);
    out = rp_bmp(px, w, h);
  } while (false);
  rp_release(src_tex);
  rp_release(dxgi);
  rp_release(buffer);
  rp_release(sample);
  rp_release(got);
  rp_release(want);
  rp_release(nat);
  rp_release(attrs);
  return out;
}

// A frame of `path` at `ms`, cut to the crop (cx, cy, cw, ch in the picture's pixels; cw 0: the whole of it), scaled
// down to fit max_w x max_h.
static std::vector<uint8_t> rp_thumb_pixels(const char *path, double ms, int32_t max_w, int32_t max_h,
                                            int32_t cx = 0, int32_t cy = 0, int32_t cw = 0, int32_t ch = 0) {
  std::vector<uint8_t> none;
  if (!rp_mf_ready()) return none;
  std::wstring file = rp_w(path);
  // (a GIF saved from a clip: its first picture, which it holds whole)
  if (rp_is_gif(file)) return rp_gif_pixels(file, max_w, max_h);
  std::vector<uint8_t> gpu = rp_thumb_gpu_pixels(file, ms, max_w, max_h, cx, cy, cw, ch);
  if (!gpu.empty()) return gpu;
  IMFSourceReader *&cached_reader = rp_sw_reader;
  std::wstring &cached_file = rp_sw_file;
  static thread_local UINT32 display_w = 0, display_h = 0;
  IMFAttributes *attrs = nullptr;
  IMFSourceReader *reader = nullptr;
  IMFMediaType *want = nullptr, *got = nullptr;
  IMFSample *sample = nullptr;
  IMFMediaBuffer *buffer = nullptr;
  IMF2DBuffer *surface = nullptr;
  std::vector<uint8_t> out;
  do {
    if (cached_reader && cached_file == file) {
      reader = cached_reader;
      reader->AddRef();
    } else {
    if (FAILED(MFCreateAttributes(&attrs, 2))) break;
    attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    if (FAILED(MFCreateSourceReaderFromURL(file.c_str(), attrs, &reader))) break;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(MFCreateMediaType(&want))) break;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want))) break;
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &display_w, &display_h);
    rp_release(got);
    rp_release(cached_reader);
    cached_reader = reader;
    cached_reader->AddRef();
    cached_file = file;
    }
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    UINT32 fw = display_w, fh = display_h;
    if (fw == 0 || fh == 0) break;
    LONG stride = (LONG)MFGetAttributeUINT32(got, MF_MT_DEFAULT_STRIDE, fw * 4);
    PROPVARIANT at;
    PropVariantInit(&at);
    at.vt = VT_I8;
    at.hVal.QuadPart = (LONGLONG)(ms * 10000.0);
    reader->SetCurrentPosition(GUID_NULL, at);
    const LONGLONG target = at.hVal.QuadPart;
    for (int tries = 0; tries < 600; tries++) {
      DWORD flags = 0;
      LONGLONG ts = 0;
      rp_release(sample);
      if (FAILED(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &sample))) break;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
      if (sample && ts + 400000 >= target) break;
    }
    if (!sample) break;
    // The converter may negotiate aligned storage on its first output sample.
    // Read the current type after decoding, not only before the first ReadSample.
    rp_release(got);
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    UINT32 storage_w = fw, storage_h = fh;
    MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &storage_w, &storage_h);
    stride = (LONG)MFGetAttributeUINT32(got, MF_MT_DEFAULT_STRIDE, storage_w * 4);
    // Keep the original display dimensions: aligned padding is not picture content.
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) break;
    BYTE *data = nullptr;
    DWORD len = 0;
    bool locked2d = SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&surface))) &&
                    SUCCEEDED(surface->Lock2D(&data, &stride));
    if (!locked2d && FAILED(buffer->Lock(&data, nullptr, &len))) break;
    // (the part kept: the crop, held inside the picture)
    int ox = 0, oy = 0, pw = (int)fw, ph = (int)fh;
    if (cw > 0 && ch > 0) {
      ox = cx < 0 ? 0 : (cx >= (int)fw ? (int)fw - 1 : cx);
      oy = cy < 0 ? 0 : (cy >= (int)fh ? (int)fh - 1 : cy);
      pw = cw > (int)fw - ox ? (int)fw - ox : cw;
      ph = ch > (int)fh - oy ? (int)fh - oy : ch;
    }
    double k = 1.0;
    if (pw > max_w) k = (double)max_w / pw;
    if (ph * k > max_h) k = (double)max_h / ph;
    int w = (int)(pw * k), h = (int)(ph * k);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    std::vector<uint8_t> px((size_t)w * h * 4);
    LONG pitch = stride < 0 ? -stride : stride;
    for (int y = 0; y < h; y++) {
      int sy = oy + (int)((y + 0.5) / k);
      if (sy >= (int)fh) sy = fh - 1;
      const BYTE *row = locked2d ? data + (ptrdiff_t)sy * stride :
        (stride < 0 ? data + (size_t)(fh - 1 - sy) * pitch : data + (size_t)sy * pitch);
      for (int x = 0; x < w; x++) {
        int sx = ox + (int)((x + 0.5) / k);
        if (sx >= (int)fw) sx = fw - 1;
        if (!locked2d && (size_t)(row - data) + (size_t)sx * 4 + 4 > len) continue;
        memcpy(&px[((size_t)y * w + x) * 4], row + (size_t)sx * 4, 4);
        px[((size_t)y * w + x) * 4 + 3] = 255;
      }
    }
    if (locked2d) surface->Unlock2D(); else buffer->Unlock();
    out = rp_bmp(px, w, h);
  } while (false);
  rp_release(surface);
  rp_release(buffer);
  rp_release(sample);
  rp_release(got);
  rp_release(want);
  rp_release(reader);
  rp_release(attrs);
  return out;
}

static moonbit_bytes_t rp_copy_bmp(const std::vector<uint8_t> &pixels) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)pixels.size(), 0);
  if (!pixels.empty()) memcpy(out, pixels.data(), pixels.size());
  return out;
}

extern "C" moonbit_bytes_t rp_thumb(moonbit_bytes_t path, double ms, int32_t max_w, int32_t max_h) {
  return rp_copy_bmp(rp_thumb_pixels((const char *)path, ms, max_w, max_h));
}

// Only one decode runs at a time. The worker owns ordinary C++ data; MoonBit
// allocations and image registration stay on the UI thread. One byte means
// pending (0) or unavailable (1); a completed result is a BMP.
//
// What the worker holds is let go of as it rests: the file it read (its reader holds it open, so a clip previewed
// last could not be deleted) after 2 s with nothing asked, its device and all it made on it after 30 s, and at once
// when the window is put away (rp_thumb_release). Made again at the next ask (some tens of ms, once).
struct RpThumbJob {
  std::mutex mutex;
  std::condition_variable changed;
  std::string key;
  std::string file;
  double ms = 0;
  int32_t max_w = 320, max_h = 180, cx = 0, cy = 0, cw = 0, ch = 0;
  std::deque<std::pair<std::string, std::vector<uint8_t>>> cache;
  bool busy = false;
  bool started = false;
  bool release = false;
};

// Process lifetime: a window may close while the worker is finishing.
static RpThumbJob *rp_thumb_jobs = new RpThumbJob;

static void rp_thumb_drop_readers() {
  rp_gpu_thumb.drop_reader();
  rp_release(rp_sw_reader);
  rp_sw_file.clear();
}

static void rp_thumb_worker() {
  RpThumbJob *job = rp_thumb_jobs;
  // (what it holds: 0 nothing, 1 a file, 2 a device too)
  int holds = 0;
  for (;;) {
    std::unique_lock<std::mutex> lock(job->mutex);
    while (!job->busy) {
      if (job->release) {
        job->release = false;
        lock.unlock();
        rp_gpu_thumb.drop();
        rp_thumb_drop_readers();
        holds = 0;
        lock.lock();
        continue;
      }
      if (holds == 0) {
        job->changed.wait(lock);
      } else if (!job->changed.wait_for(lock, std::chrono::seconds(holds == 1 ? 30 : 2),
                                        [job] { return job->busy || job->release; })) {
        lock.unlock();
        if (holds == 2) {
          rp_thumb_drop_readers();
          holds = 1;
        } else {
          rp_gpu_thumb.drop();
          holds = 0;
        }
        lock.lock();
      }
    }
    std::string file = job->file, key = job->key;
    double ms = job->ms;
    int32_t mw = job->max_w, mh = job->max_h, x = job->cx, y = job->cy, w = job->cw, h = job->ch;
    lock.unlock();
    ULONGLONG began = GetTickCount64();
    std::vector<uint8_t> pixels;
    try { pixels = rp_thumb_pixels(file.c_str(), ms, mw, mh, x, y, w, h); } catch (...) { }
    holds = 2;
    const char *trace = getenv("REPLAY_TRACE");
    if (trace && strcmp(trace, "1") == 0) {
      printf("REPLAY_DECODE %llu ms offset=%.0f bytes=%zu\n", GetTickCount64() - began, ms, pixels.size());
      fflush(stdout);
    }
    lock.lock();
    job->cache.emplace_back(key, std::move(pixels));
    // Bounded to at most 32 frames (~30 MB at 640 x 360).
    if (job->cache.size() > 32) job->cache.pop_front();
    job->busy = false;
  }
}

static moonbit_bytes_t rp_thumb_job(const char *path, const char *identity, double ms, int32_t max_w, int32_t max_h,
                                    int32_t cx, int32_t cy, int32_t cw, int32_t ch) {
  RpThumbJob *job = rp_thumb_jobs;
  std::lock_guard<std::mutex> guard(job->mutex);
  std::string key(identity);
  for (auto &entry : job->cache) {
    if (entry.first == key) return entry.second.empty() ? moonbit_make_bytes(1, 1) : rp_copy_bmp(entry.second);
  }
  if (!job->started) {
    try {
      std::thread(rp_thumb_worker).detach();
      job->started = true;
    } catch (...) {
      return moonbit_make_bytes(1, 1);
    }
  }
  if (!job->busy) {
    job->key = key;
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

// The window put away: the frames made let go of (up to ~30 MB), and the worker's file, device and decoder as soon as
// it rests (at once where it rests now).
extern "C" void rp_thumb_release(void) {
  RpThumbJob *job = rp_thumb_jobs;
  std::lock_guard<std::mutex> guard(job->mutex);
  job->cache.clear();
  job->cache.shrink_to_fit();
  if (job->started) {
    job->release = true;
    job->changed.notify_one();
  }
}

extern "C" moonbit_bytes_t rp_clip_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms) {
  // (640 x 360 at most: a card of the saved clips is some 300 to 700 pixels wide; made at 320 it was drawn blurred,
  // seen in the Store's screenshots, 2026-11-18)
  return rp_thumb_job((const char *)path, (const char *)identity, ms, 640, 360, 0, 0, 0, 0);
}

// The save dialog's preview of a crop (a region, a window picked): the frame at `ms` cut to it, made as
// rp_clip_thumb's are (the same worker, one at a time; its answers the same), up to 480 x 270.
extern "C" moonbit_bytes_t rp_crop_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms, int32_t cx, int32_t cy,
                                         int32_t cw, int32_t ch) {
  return rp_thumb_job((const char *)path, (const char *)identity, ms, 480, 270, cx, cy, cw, ch);
}

// One segment of a clip's plan: its file, where its first kept moment lands in the clip, and the stretch kept (all
// 100 ns; the times kept are the file's own).
struct ClipPart {
  std::wstring path;
  LONGLONG offset, trim, end;
};

// The first video and audio streams of a reader (-1 none).
static void rp_streams(IMFSourceReader *reader, int *video, int *audio) {
  *video = *audio = -1;
  for (DWORD i = 0; i < 8; i++) {
    IMFMediaType *type = nullptr;
    if (FAILED(reader->GetNativeMediaType(i, 0, &type))) break;
    GUID major = GUID_NULL;
    type->GetGUID(MF_MT_MAJOR_TYPE, &major);
    if (major == MFMediaType_Video && *video < 0) *video = (int)i;
    else if (major == MFMediaType_Audio && *audio < 0) *audio = (int)i;
    type->Release();
  }
}

// Where a joined clip's tracks begin and what it shows, on the clip's times (100 ns): the first picture and the first
// sound written (-1 none), and the moments asked for, from and to.
struct ClipSpan {
  LONGLONG video = -1, audio = -1, from = 0, to = 0;
};

// The parts joined into `out` without encoding again: each file's samples read as they are (the source reader, no
// decoder) and written in turn to one sink writer, their times moved to the clip's. The file starts on the keyframe at
// or before the moment asked for (found by seeking there and reading the first frame; the file then read again from
// that frame's time, its sound with it), so its first frame is whole; `span` says where, for the edit list that has it
// shown from the moment itself (rp_edit_list). S_OK, or the HRESULT that stopped it.
// How far the clip being joined is (0..1000) and whether it is to stop (rp_concat_start, rp_concat_cancel).
static std::atomic<int> rp_join_permille{0};
static std::atomic<bool> rp_join_stop{false};

static HRESULT rp_join(const std::vector<ClipPart> &parts, const std::wstring &out, ClipSpan *span) {
  IMFSinkWriter *writer = nullptr;
  DWORD video_out = 0, audio_out = 0;
  bool has_audio_out = false;
  bool shifted = false;
  LONGLONG shift = 0;
  // (where the last part read ends on the clip's times, and where its file's 0 lands on the plan's: a later part's
  // offset is where its trim lands, so its file's 0 is that less its trim)
  LONGLONG last_end = 0, zero = 0;
  HRESULT hr = S_OK;
  for (size_t p = 0; p < parts.size() && SUCCEEDED(hr); p++) {
    const ClipPart &part = parts[p];
    zero = p == 0 ? part.offset : part.offset - part.trim;
    IMFSourceReader *reader = nullptr;
    hr = MFCreateSourceReaderFromURL(part.path.c_str(), nullptr, &reader);
    if (FAILED(hr)) break;
    int video, audio;
    rp_streams(reader, &video, &audio);
    if (video < 0) {
      reader->Release();
      continue;
    }
    if (!writer) {
      IMFAttributes *attrs = nullptr;
      MFCreateAttributes(&attrs, 1);
      if (attrs) attrs->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
      hr = MFCreateSinkWriterFromURL(out.c_str(), nullptr, attrs, &writer);
      if (attrs) attrs->Release();
      IMFMediaType *type = nullptr;
      if (SUCCEEDED(hr)) hr = reader->GetNativeMediaType((DWORD)video, 0, &type);
      if (SUCCEEDED(hr)) hr = writer->AddStream(type, &video_out);
      if (SUCCEEDED(hr)) hr = writer->SetInputMediaType(video_out, type, nullptr);
      rp_release(type);
      if (SUCCEEDED(hr) && audio >= 0 && SUCCEEDED(reader->GetNativeMediaType((DWORD)audio, 0, &type))) {
        hr = writer->AddStream(type, &audio_out);
        if (SUCCEEDED(hr)) hr = writer->SetInputMediaType(audio_out, type, nullptr);
        has_audio_out = SUCCEEDED(hr);
        rp_release(type);
      }
      if (SUCCEEDED(hr)) hr = writer->BeginWriting();
      if (FAILED(hr)) {
        reader->Release();
        break;
      }
    }
    bool take_audio = audio >= 0 && has_audio_out;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)video, TRUE);
    if (take_audio) reader->SetStreamSelection((DWORD)audio, TRUE);
    LONGLONG start = 0;
    if (part.trim > 0) {
      PROPVARIANT at;
      PropVariantInit(&at);
      at.vt = VT_I8;
      at.hVal.QuadPart = part.trim;
      reader->SetCurrentPosition(GUID_NULL, at);
      DWORD flags = 0;
      LONGLONG key = 0;
      IMFSample *first = nullptr;
      if (SUCCEEDED(reader->ReadSample((DWORD)video, 0, nullptr, &flags, &key, &first)) && first &&
          !(flags & MF_SOURCE_READERF_ENDOFSTREAM))
        start = key < part.trim ? key : part.trim;
      rp_release(first);
      at.hVal.QuadPart = start;
      reader->SetCurrentPosition(GUID_NULL, at);
    }
    // (the clip's times from the first part read: its keyframe is 0, the moment asked for after it)
    if (!shifted) {
      shift = zero + start;
      shifted = true;
      span->from = zero + part.trim - shift;
    } else if (part.trim > 0 && zero + start - shift < last_end) {
      // (a part cut in from the middle of its file, what was skipped before it left out: it starts on the keyframe
      // before its moment, so it is put on from where the last ended, its few frames of lead-in kept, not over it)
      zero += last_end - (zero + start - shift);
    }
    bool video_done = false, audio_done = !take_audio;
    while (!video_done || !audio_done) {
      DWORD stream = 0, flags = 0;
      LONGLONG t = 0;
      IMFSample *sample = nullptr;
      hr = reader->ReadSample((DWORD)MF_SOURCE_READER_ANY_STREAM, 0, &stream, &flags, &t, &sample);
      if (FAILED(hr)) break;
      bool is_video = (int)stream == video;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        if (is_video) video_done = true;
        else audio_done = true;
      } else if (sample && !(is_video ? video_done : audio_done)) {
        if (t >= part.end) {
          if (is_video) video_done = true;
          else audio_done = true;
        } else if (t >= start) {
          const LONGLONG at = zero + t - shift;
          LONGLONG &first = is_video ? span->video : span->audio;
          if (first < 0) first = at;
          sample->SetSampleTime(at);
          hr = writer->WriteSample(is_video ? video_out : audio_out, sample);
          if (is_video && part.end > start) {
            double in_part = (double)(t - start) / (double)(part.end - start);
            rp_join_permille = (int)((p + (in_part < 1.0 ? in_part : 1.0)) * 1000.0 / (double)parts.size());
          }
        }
      }
      rp_release(sample);
      if (SUCCEEDED(hr) && rp_join_stop.load()) hr = E_ABORT;
      if (FAILED(hr)) break;
    }
    reader->Release();
    last_end = zero + part.end - shift;
  }
  span->to = last_end;
  if (!writer) return FAILED(hr) ? hr : E_FAIL;
  if (SUCCEEDED(hr)) hr = writer->Finalize();
  writer->Release();
  return hr;
}

// An MP4's numbers, big-endian.
static uint64_t rp_be(const uint8_t *p, int n) {
  uint64_t v = 0;
  for (int i = 0; i < n; i++) v = (v << 8) | p[i];
  return v;
}

static void rp_put_be(uint8_t *p, int n, uint64_t v) {
  for (int i = n - 1; i >= 0; i--, v >>= 8) p[i] = (uint8_t)v;
}

static void rp_push_be(std::vector<uint8_t> &b, int n, uint64_t v) {
  b.resize(b.size() + n);
  rp_put_be(b.data() + b.size() - n, n, v);
}

// A box's place in `b` from `at`: its kind, where its content starts and where it ends; false where none fits before
// `end`.
static bool rp_box(const uint8_t *b, size_t at, size_t end, uint32_t *kind, size_t *content, size_t *box_end) {
  if (at + 8 > end) return false;
  uint64_t size = rp_be(b + at, 4);
  size_t head = 8;
  if (size == 1) {
    if (at + 16 > end) return false;
    size = rp_be(b + at + 8, 8);
    head = 16;
  } else if (size == 0) {
    size = end - at;
  }
  if (size < head || size > end - at) return false;
  *kind = (uint32_t)rp_be(b + at + 4, 4);
  *content = at + head;
  *box_end = at + (size_t)size;
  return true;
}

static constexpr uint32_t rp_fourcc(const char *s) {
  return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) | ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}

// The content of the first box `kind` among those from `at` to `end` (false: none).
static bool rp_child(const uint8_t *b, size_t at, size_t end, uint32_t kind, size_t *content, size_t *box_end) {
  uint32_t k;
  size_t c, e;
  while (rp_box(b, at, end, &k, &c, &e)) {
    if (k == kind) {
      *content = c;
      *box_end = e;
      return true;
    }
    at = e;
  }
  return false;
}

// A box of `kind` around `content`.
static void rp_push_box(std::vector<uint8_t> &out, uint32_t kind, const uint8_t *content, size_t n) {
  rp_push_be(out, 4, (uint64_t)(n + 8));
  rp_push_be(out, 4, kind);
  out.insert(out.end(), content, content + n);
}

// A track's `trak` again, with an edit list that shows its media from the clip's moment on (an `edts` after its
// `tkhd`, any it had replaced; its `tkhd`'s duration the clip's): `first` its first sample's time on the clip's times
// (100 ns), `movie_scale` the `mvhd`'s. Where the track starts after the moment (its first sound a little later), an
// empty edit first holds it back to its place. False where it is not read whole (left as it was).
static bool rp_edit_trak(const uint8_t *b, size_t s, size_t e, LONGLONG first, const ClipSpan &span, uint64_t movie_scale,
                         std::vector<uint8_t> &out) {
  size_t th, the, md, mde, mh, mhe, st, ste;
  if (!rp_child(b, s, e, rp_fourcc("tkhd"), &th, &the) || !rp_child(b, s, e, rp_fourcc("mdia"), &md, &mde) ||
      !rp_child(b, md, mde, rp_fourcc("mdhd"), &mh, &mhe))
    return false;
  const bool mdhd1 = b[mh] == 1;
  if (mh + (mdhd1 ? 32 : 20) > mhe) return false;
  const uint64_t scale = rp_be(b + mh + (mdhd1 ? 20 : 12), 4);
  const uint64_t media_dur = rp_be(b + mh + (mdhd1 ? 24 : 16), mdhd1 ? 8 : 4);
  if (scale == 0) return false;
  // (the first sample's composition time: MF's sink writer puts a track's start in its ctts, the sound's ~13 ms after
  // the picture's keyframe)
  int64_t cts0 = 0;
  size_t mi, mie;
  if (rp_child(b, md, mde, rp_fourcc("minf"), &mi, &mie) && rp_child(b, mi, mie, rp_fourcc("stbl"), &st, &ste)) {
    size_t ct, cte;
    if (rp_child(b, st, ste, rp_fourcc("ctts"), &ct, &cte) && ct + 16 <= cte && rp_be(b + ct + 4, 4) > 0)
      cts0 = b[ct] == 1 ? (int64_t)(int32_t)rp_be(b + ct + 12, 4) : (int64_t)rp_be(b + ct + 12, 4);
  }
  const LONGLONG length = std::max<LONGLONG>(0, span.to - span.from);
  const LONGLONG lead = span.from - first;
  // the edits: (duration in the movie's scale, media time in the track's; -1 empty)
  std::vector<std::pair<uint64_t, int64_t>> edits;
  uint64_t shown = (uint64_t)(length * (LONGLONG)movie_scale / 10000000);
  int64_t media_at = cts0;
  if (lead < 0) {
    const uint64_t wait = std::min<uint64_t>(shown, (uint64_t)(-lead * (LONGLONG)movie_scale / 10000000));
    edits.push_back({wait, -1});
    shown -= wait;
  } else {
    media_at = cts0 + (int64_t)(lead * (LONGLONG)scale / 10000000);
  }
  // (not past the media's end: a track that stops short ends there)
  const int64_t media_left = cts0 + (int64_t)media_dur - media_at;
  if (media_left <= 0) return false;
  shown = std::min<uint64_t>(shown, (uint64_t)media_left * movie_scale / scale);
  edits.push_back({shown, media_at});
  bool wide = false;
  for (auto &x : edits) wide = wide || x.first > 0xFFFFFFFFull || x.second > 0x7FFFFFFF;
  std::vector<uint8_t> elst;
  rp_push_be(elst, 4, wide ? 0x01000000u : 0u);
  rp_push_be(elst, 4, edits.size());
  for (auto &x : edits) {
    rp_push_be(elst, wide ? 8 : 4, x.first);
    rp_push_be(elst, wide ? 8 : 4, (uint64_t)x.second);
    rp_push_be(elst, 4, 0x00010000u);  // a rate of 1.0
  }
  std::vector<uint8_t> edts;
  rp_push_box(edts, rp_fourcc("elst"), elst.data(), elst.size());
  const uint64_t total = (edits.size() > 1 ? edits[0].first : 0) + shown;
  std::vector<uint8_t> inner;
  uint32_t k;
  size_t c, x, at = s;
  while (rp_box(b, at, e, &k, &c, &x)) {
    if (k == rp_fourcc("edts")) {
      // (MF's own, if it wrote one: this one instead)
    } else if (k == rp_fourcc("tkhd")) {
      std::vector<uint8_t> tkhd(b + c, b + x);
      const bool v1 = tkhd.size() > 0 && tkhd[0] == 1;
      if (tkhd.size() >= (size_t)(v1 ? 36 : 24)) rp_put_be(tkhd.data() + (v1 ? 28 : 20), v1 ? 8 : 4, v1 ? total : std::min<uint64_t>(total, 0xFFFFFFFFull));
      rp_push_box(inner, k, tkhd.data(), tkhd.size());
      rp_push_box(inner, rp_fourcc("edts"), edts.data(), edts.size());
    } else {
      inner.insert(inner.end(), b + at, b + x);
    }
    at = x;
  }
  rp_push_box(out, rp_fourcc("trak"), inner.data(), inner.size());
  return true;
}

// The chunk offsets of every track in `moov` (its content, `b`) past `from` moved by `by` (the media data after a
// `moov` taken from before it).
static void rp_move_chunks(uint8_t *b, size_t s, size_t e, uint64_t from, int64_t by) {
  uint32_t k;
  size_t c, x;
  while (rp_box(b, s, e, &k, &c, &x)) {
    if (k == rp_fourcc("trak") || k == rp_fourcc("mdia") || k == rp_fourcc("minf") || k == rp_fourcc("stbl")) {
      rp_move_chunks(b, c, x, from, by);
    } else if ((k == rp_fourcc("stco") || k == rp_fourcc("co64")) && c + 8 <= x) {
      const int w = k == rp_fourcc("co64") ? 8 : 4;
      const uint64_t n = rp_be(b + c + 4, 4);
      for (uint64_t i = 0; i < n && c + 8 + (i + 1) * w <= x; i++) {
        uint8_t *p = b + c + 8 + i * w;
        const uint64_t v = rp_be(p, w);
        if (v >= from) rp_put_be(p, w, (uint64_t)((int64_t)v + by));
      }
    }
    s = x;
  }
}

static bool rp_read_at(HANDLE f, uint64_t at, void *to, DWORD n) {
  LARGE_INTEGER p;
  p.QuadPart = (LONGLONG)at;
  DWORD got = 0;
  return SetFilePointerEx(f, p, nullptr, FILE_BEGIN) && ReadFile(f, to, n, &got, nullptr) && got == n;
}

static bool rp_write_at(HANDLE f, uint64_t at, const void *from, DWORD n) {
  LARGE_INTEGER p;
  p.QuadPart = (LONGLONG)at;
  DWORD put = 0;
  return SetFilePointerEx(f, p, nullptr, FILE_BEGIN) && WriteFile(f, from, n, &put, nullptr) && put == n;
}

// The joined clip at `path` shown from the moment asked for to its end, not from the keyframe before it (the clip is
// cut on that keyframe, so nothing is encoded again; the frames before the moment are there for the decoder only): an
// edit list in each track that starts its media at that moment (its picture's and its sound's each from their own
// first sample, so the two keep together), the movie's and the tracks' durations the clip's length. The `moov` is put
// back at the file's end, where the sink writer writes it (moved there, the media's chunk offsets with it, were it
// before). S_OK; S_FALSE where the file is not as expected (left as written, its lead-in shown); E_FAIL where writing
// it stopped part way (the clip is not to be kept).
static HRESULT rp_edit_list(const std::wstring &path, const ClipSpan &span) {
  HANDLE f = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return S_FALSE;
  HRESULT hr = S_FALSE;
  do {
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(f, &size)) break;
    const uint64_t total = (uint64_t)size.QuadPart;
    // the top boxes by their heads alone: where the moov is
    uint64_t at = 0, moov_at = 0, moov_end = 0;
    bool found = false;
    while (at + 8 <= total) {
      uint8_t h[16];
      const DWORD n = (DWORD)std::min<uint64_t>(16, total - at);
      if (!rp_read_at(f, at, h, n)) break;
      uint64_t box = rp_be(h, 4);
      if (box == 1 && n == 16) box = rp_be(h + 8, 8);
      else if (box == 0) box = total - at;
      if (box < 8 || box > total - at) break;
      if (rp_be(h + 4, 4) == rp_fourcc("moov")) {
        moov_at = at;
        moov_end = at + box;
        found = true;
        break;
      }
      at += box;
    }
    if (!found || moov_end - moov_at > (64u << 20)) break;
    std::vector<uint8_t> moov((size_t)(moov_end - moov_at));
    if (!rp_read_at(f, moov_at, moov.data(), (DWORD)moov.size())) break;
    const uint8_t *b = moov.data();
    uint32_t k;
    size_t c, e;
    if (!rp_box(b, 0, moov.size(), &k, &c, &e)) break;
    const size_t s = c, end = e;
    size_t mv, mve;
    if (!rp_child(b, s, end, rp_fourcc("mvhd"), &mv, &mve)) break;
    const bool mv1 = b[mv] == 1;
    if (mv + (mv1 ? 32 : 20) > mve) break;
    const uint64_t movie_scale = rp_be(b + mv + (mv1 ? 20 : 12), 4);
    if (movie_scale == 0) break;
    const uint64_t length = (uint64_t)(std::max<LONGLONG>(0, span.to - span.from) * (LONGLONG)movie_scale / 10000000);
    std::vector<uint8_t> inner;
    bool edited = true;
    size_t x;
    at = s;
    while (rp_box(b, (size_t)at, end, &k, &c, &x)) {
      if (k == rp_fourcc("mvhd")) {
        std::vector<uint8_t> mvhd(b + c, b + x);
        rp_put_be(mvhd.data() + (mv1 ? 24 : 16), mv1 ? 8 : 4, mv1 ? length : std::min<uint64_t>(length, 0xFFFFFFFFull));
        rp_push_box(inner, k, mvhd.data(), mvhd.size());
      } else if (k == rp_fourcc("trak")) {
        size_t md, mde, hd, hde;
        uint32_t handler = 0;
        if (rp_child(b, c, x, rp_fourcc("mdia"), &md, &mde) && rp_child(b, md, mde, rp_fourcc("hdlr"), &hd, &hde) && hd + 12 <= hde)
          handler = (uint32_t)rp_be(b + hd + 8, 4);
        const LONGLONG first = handler == rp_fourcc("vide") ? span.video : handler == rp_fourcc("soun") ? span.audio : -1;
        if (first < 0 || !rp_edit_trak(b, c, x, first, span, movie_scale, inner)) {
          edited = edited && first < 0;
          inner.insert(inner.end(), b + (size_t)at, b + x);
        }
      } else {
        inner.insert(inner.end(), b + (size_t)at, b + x);
      }
      at = x;
    }
    if (!edited) break;
    std::vector<uint8_t> out;
    rp_push_box(out, rp_fourcc("moov"), inner.data(), inner.size());
    // (from here the file is being written: a stop is the clip's failure)
    hr = E_FAIL;
    if (moov_end != total) {
      // (a moov before the media: the media after it moved up by its size, the moov written after it)
      rp_move_chunks(out.data(), 8, out.size(), moov_end, -(int64_t)(moov_end - moov_at));
      std::vector<uint8_t> buf(1 << 20);
      uint64_t from = moov_end, to = moov_at;
      while (from < total) {
        const DWORD n = (DWORD)std::min<uint64_t>(buf.size(), total - from);
        if (!rp_read_at(f, from, buf.data(), n) || !rp_write_at(f, to, buf.data(), n)) break;
        from += n;
        to += n;
      }
      if (from < total) break;
      moov_at = to;
    }
    if (!rp_write_at(f, moov_at, out.data(), (DWORD)out.size())) break;
    LARGE_INTEGER cut;
    cut.QuadPart = (LONGLONG)(moov_at + out.size());
    if (SetFilePointerEx(f, cut, nullptr, FILE_BEGIN) && SetEndOfFile(f)) hr = S_OK;
  } while (false);
  CloseHandle(f);
  return hr;
}

// The clip `plan` describes saved to `output`:the plan a line a segment, `path\toffsetMs\ttrimStartMs\tendMs` (the
// replay window's clip_plan). 0 when it was written; -1001 an empty plan; else the HRESULT that stopped it.
static int32_t rp_concat_run(const char *plan, const char *output) {
  if (!rp_mf_ready()) return -1000;
  std::vector<ClipPart> parts;
  const char *p = plan;
  while (*p) {
    const char *end = strchr(p, '\n');
    std::string line = end ? std::string(p, end - p) : std::string(p);
    p = end ? end + 1 : p + strlen(p);
    char path[2048];
    double off = 0, trim = 0, stop = 0;
    if (sscanf_s(line.c_str(), "%2047[^\t]\t%lf\t%lf\t%lf", path, (unsigned)sizeof path, &off, &trim, &stop) != 4) continue;
    parts.push_back({rp_w(path), (LONGLONG)(off * 10000.0), (LONGLONG)(trim * 10000.0), (LONGLONG)(stop * 10000.0)});
  }
  if (parts.empty()) return -1001;
  ClipSpan span;
  const std::wstring out = rp_w(output);
  HRESULT hr = rp_join(parts, out, &span);
  if (SUCCEEDED(hr)) hr = rp_edit_list(out, span);
  return SUCCEEDED(hr) ? 0 : (int32_t)hr;
}

extern "C" int32_t rp_concat(moonbit_bytes_t plan, moonbit_bytes_t output) {
  return rp_concat_run((const char *)plan, (const char *)output);
}

// The clip joined as recorded in the background (a few minutes of 4K is some hundreds of MB written: on the window's
// thread it stood still, white, till it was done). 0 when one is being joined already.
static std::atomic<int> rp_concat_phase{0};  // 0 none, 1 joining, 2 done
static std::atomic<int> rp_concat_code{0};

extern "C" int32_t rp_concat_start(moonbit_bytes_t plan, moonbit_bytes_t output) {
  int idle = 0;
  if (!rp_concat_phase.compare_exchange_strong(idle, 1)) return 0;
  rp_join_permille = 0;
  rp_join_stop = false;
  std::string the_plan((const char *)plan), the_out((const char *)output);
  try {
    std::thread([the_plan, the_out]() {
      int32_t code = -1000;
      try { code = rp_concat_run(the_plan.c_str(), the_out.c_str()); } catch (...) { }
      rp_concat_code = code;
      rp_concat_phase = 2;
    }).detach();
  } catch (...) {
    rp_concat_code = -1000;
    rp_concat_phase = 2;
  }
  return 1;
}

// 1 joining, 2 done (its code: rp_concat_take), 0 none.
extern "C" int32_t rp_concat_state(void) { return rp_concat_phase.load(); }

// How far the join is, 0..1.
extern "C" double rp_concat_progress(void) { return rp_join_permille.load() / 1000.0; }

// The finished join's code (0 joined; E_ABORT cancelled), the next one then free to start.
extern "C" int32_t rp_concat_take(void) {
  int32_t code = rp_concat_code.load();
  rp_concat_phase = 0;
  return code;
}

extern "C" void rp_concat_cancel(void) { rp_join_stop = true; }

// A GIF's first frame by WIC, at most `max_w` x `max_h` keeping its shape, as a BMP; none when it cannot be read.
static std::vector<uint8_t> rp_gif_pixels(const std::wstring &file, int32_t max_w, int32_t max_h) {
  std::vector<uint8_t> none;
  IWICImagingFactory *wic = nullptr;
  IWICBitmapDecoder *decoder = nullptr;
  IWICBitmapFrameDecode *frame = nullptr;
  IWICBitmapScaler *scaler = nullptr;
  IWICFormatConverter *bgra = nullptr;
  std::vector<uint8_t> out;
  do {
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) break;
    if (FAILED(wic->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder))) break;
    if (FAILED(decoder->GetFrame(0, &frame))) break;
    UINT fw = 0, fh = 0;
    frame->GetSize(&fw, &fh);
    if (fw == 0 || fh == 0) break;
    double k = 1.0;
    if ((int)fw > max_w) k = (double)max_w / fw;
    if (fh * k > max_h) k = (double)max_h / fh;
    const UINT w = std::max<UINT>(1, (UINT)(fw * k)), h = std::max<UINT>(1, (UINT)(fh * k));
    if (FAILED(wic->CreateBitmapScaler(&scaler)) || FAILED(scaler->Initialize(frame, w, h, WICBitmapInterpolationModeFant))) break;
    if (FAILED(wic->CreateFormatConverter(&bgra)) ||
        FAILED(bgra->Initialize(scaler, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom)))
      break;
    std::vector<uint8_t> px((size_t)w * h * 4);
    if (FAILED(bgra->CopyPixels(nullptr, w * 4, (UINT)px.size(), px.data()))) break;
    for (size_t i = 3; i < px.size(); i += 4) px[i] = 255;
    out = rp_bmp(px, (int)w, (int)h);
  } while (false);
  rp_release(bgra);
  rp_release(scaler);
  rp_release(frame);
  rp_release(decoder);
  rp_release(wic);
  return out.empty() ? none : out;
}

// How long a GIF plays, in ms: its frames' delays added up (read from its blocks, its pictures skipped); -1 when it
// is not one.
static double rp_gif_duration(const std::wstring &file) {
  HANDLE f = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                         FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (f == INVALID_HANDLE_VALUE) return -1;
  // (read through in 1 MB pieces, never the whole file at once: a 4K GIF of some minutes is hundreds of MB, and the
  // whole of it was read into memory for its length)
  std::vector<uint8_t> buf(1 << 20);
  size_t have = 0, at = 0;
  bool end = false;
  // byte `i` ahead of where it reads (false: the file ends first)
  auto peek = [&](size_t i, uint8_t &out) -> bool {
    while (at + i >= have && !end) {
      if (at > 0) {
        memmove(buf.data(), buf.data() + at, have - at);
        have -= at;
        at = 0;
      }
      if (have == buf.size()) buf.resize(buf.size() * 2);
      DWORD got = 0;
      if (!ReadFile(f, buf.data() + have, (DWORD)(buf.size() - have), &got, nullptr) || got == 0) end = true;
      have += got;
    }
    if (at + i >= have) return false;
    out = buf[at + i];
    return true;
  };
  // `n` bytes passed over (false: the file ends first)
  auto skip_n = [&](size_t n) -> bool {
    uint8_t b;
    while (n > 0) {
      size_t step = std::min(n, have - at);
      at += step;
      n -= step;
      if (n > 0 && !peek(0, b)) return false;
    }
    return true;
  };
  // sub-blocks passed over, the terminator with them
  auto skip_blocks = [&]() -> bool {
    uint8_t len;
    for (;;) {
      if (!peek(0, len)) return false;
      if (!skip_n(1)) return false;
      if (len == 0) return true;
      if (!skip_n(len)) return false;
    }
  };
  double cs = 0;
  uint8_t h[13];
  bool ok = true;
  for (int i = 0; i < 13 && ok; i++) ok = peek(i, h[i]);
  if (!ok || memcmp(h, "GIF8", 4) != 0) {
    CloseHandle(f);
    return -1;
  }
  skip_n(13);
  if (h[10] & 0x80) skip_n(3 * ((size_t)2 << (h[10] & 7)));
  uint8_t b0, b1;
  while (peek(0, b0)) {
    if (b0 == 0x3B) break;
    if (b0 == 0x21 && peek(1, b1)) {
      if (b1 == 0xF9) {
        uint8_t lo, hi;
        if (peek(4, lo) && peek(5, hi)) cs += lo | (hi << 8);
      }
      if (!skip_n(2) || !skip_blocks()) break;
    } else if (b0 == 0x2C) {
      uint8_t flags;
      if (!peek(9, flags) || !skip_n(10)) break;
      if ((flags & 0x80) && !skip_n(3 * ((size_t)2 << (flags & 7)))) break;
      if (!skip_n(1) || !skip_blocks()) break;
    } else {
      break;
    }
  }
  CloseHandle(f);
  return cs * 10.0;
}

// A video file's length (ms) as its movie header says (moov's mvhd: its duration over its timescale), read from the
// boxes' heads alone; -1 where it cannot be (then asked of Media Foundation). The library asks it of each saved clip as
// its card is made, on the window's thread: a source reader made for each took tens of ms a clip.
static double rp_mp4_header_duration(const std::wstring &file) {
  HANDLE f = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return -1;
  auto read_at = [&](uint64_t at, uint8_t *to, DWORD n) -> bool {
    OVERLAPPED o = {};
    o.Offset = (DWORD)at;
    o.OffsetHigh = (DWORD)(at >> 32);
    DWORD got = 0;
    return ReadFile(f, to, n, &got, &o) && got == n;
  };
  auto be = [](const uint8_t *p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v = v << 8 | p[i];
    return v;
  };
  LARGE_INTEGER size{};
  GetFileSizeEx(f, &size);
  const uint64_t end = (uint64_t)size.QuadPart;
  double ms = -1;
  // the top level's boxes, then moov's, to its mvhd
  uint64_t at = 0, stop = end;
  bool in_moov = false;
  for (int guard = 0; guard < 4096 && at + 8 <= stop; guard++) {
    uint8_t hd[16];
    if (!read_at(at, hd, 8)) break;
    uint64_t len = be(hd, 4);
    uint32_t head = 8;
    if (len == 1) {
      if (!read_at(at + 8, hd + 8, 8)) break;
      len = be(hd + 8, 8);
      head = 16;
    } else if (len == 0) {
      len = stop - at;
    }
    if (len < head || at + len > stop) break;
    if (!in_moov && memcmp(hd + 4, "moov", 4) == 0) {
      in_moov = true;
      stop = at + len;
      at += head;
      continue;
    }
    if (in_moov && memcmp(hd + 4, "mvhd", 4) == 0) {
      uint8_t m[32];
      if (!read_at(at + head, m, 32)) break;
      // version 0: 32-bit times; 1: 64-bit
      uint64_t scale, dur;
      if (m[0] == 1) {
        scale = be(m + 20, 4);
        dur = be(m + 24, 8);
      } else {
        scale = be(m + 12, 4);
        dur = be(m + 16, 4);
      }
      if (scale > 0 && dur > 0 && dur != 0xFFFFFFFFull && dur != ~0ull) ms = (double)dur * 1000.0 / (double)scale;
      break;
    }
    at += len;
  }
  CloseHandle(f);
  return ms;
}

// How long a video file plays, in ms (its presentation's duration); -1 when it cannot be read.
extern "C" double rp_duration(moonbit_bytes_t path) {
  if (rp_is_gif(rp_w((const char *)path))) return rp_gif_duration(rp_w((const char *)path));
  const double header = rp_mp4_header_duration(rp_w((const char *)path));
  if (header > 0) return header;
  if (!rp_mf_ready()) return -1;
  IMFSourceReader *reader = nullptr;
  double ms = -1;
  if (SUCCEEDED(MFCreateSourceReaderFromURL(rp_w((const char *)path).c_str(), nullptr, &reader))) {
    PROPVARIANT v;
    PropVariantInit(&v);
    if (SUCCEEDED(reader->GetPresentationAttribute((DWORD)MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &v)) && v.vt == VT_UI8)
      ms = (double)v.uhVal.QuadPart / 10000.0;
    PropVariantClear(&v);
    reader->Release();
  }
  return ms;
}

// ---- a frame copied to the clipboard (the picture's menu: 复制当前帧) ----

// The picture's own size and colour (its native type: the decoder's may be taller, HEVC's 2160 rows coded as 2176).
static void rp_native_picture(IMFSourceReader *reader, UINT32 &w, UINT32 &h, int &bt601, int &full) {
  IMFMediaType *nat = nullptr;
  w = h = 0;
  bt601 = full = 0;
  if (FAILED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &nat))) return;
  MFGetAttributeSize(nat, MF_MT_FRAME_SIZE, &w, &h);
  MFVideoArea area{};
  UINT32 cb = 0;
  if ((SUCCEEDED(nat->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area, &cb)) ||
       SUCCEEDED(nat->GetBlob(MF_MT_GEOMETRIC_APERTURE, (UINT8 *)&area, sizeof area, &cb))) &&
      cb == sizeof area && area.Area.cx > 0 && area.Area.cy > 0 && (UINT32)area.Area.cx <= w &&
      (UINT32)area.Area.cy <= h) {
    w = (UINT32)area.Area.cx;
    h = (UINT32)area.Area.cy;
  }
  UINT32 m = 0, r = 0;
  bt601 = SUCCEEDED(nat->GetUINT32(MF_MT_YUV_MATRIX, &m)) && m == MFVideoTransferMatrix_BT601;
  full = SUCCEEDED(nat->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &r)) && r == MFNominalRange_0_255;
  nat->Release();
}

static inline uint8_t rp_clamp8(double v) { return v <= 0 ? 0 : v >= 255 ? 255 : (uint8_t)(v + 0.5); }

// NV12 rows (`pitch` apart, the chroma pairs' rows after `rows` luma rows) as top-down BGRA of w x h.
static void rp_nv12_to_bgra(const uint8_t *data, size_t pitch, size_t rows, int w, int h, int bt601, int full,
                            std::vector<uint8_t> &bgra) {
  const double ky = full ? 1.0 : 255.0 / 219.0, kc = full ? 1.0 : 255.0 / 224.0, y0 = full ? 0.0 : 16.0;
  const double rv = bt601 ? 1.402 : 1.5748, gu = bt601 ? 0.344136 : 0.187324, gv = bt601 ? 0.714136 : 0.468124,
               bu = bt601 ? 1.772 : 1.8556;
  bgra.assign((size_t)w * h * 4, 255);
  const uint8_t *uv_plane = data + pitch * rows;
  for (int y = 0; y < h; y++) {
    const uint8_t *yr = data + pitch * y;
    const uint8_t *uvr = uv_plane + pitch * (y / 2);
    uint8_t *o = &bgra[(size_t)y * w * 4];
    for (int x = 0; x < w; x++) {
      double Y = (yr[x] - y0) * ky;
      double U = (uvr[(x & ~1)] - 128.0) * kc, V = (uvr[(x & ~1) + 1] - 128.0) * kc;
      o[x * 4 + 0] = rp_clamp8(Y + bu * U);
      o[x * 4 + 1] = rp_clamp8(Y - gu * U - gv * V);
      o[x * 4 + 2] = rp_clamp8(Y + rv * V);
    }
  }
}

// rp_frame_at on the GPU: the frames from the key frame on decoded by the GPU's decoder into its own memory (no colour
// conversion of any but the one kept: the CPU path converted every one of them, 1-4 s for a 4K frame two seconds after
// its key frame), the last one not after `ms` copied aside, read back once and converted. False when the GPU cannot.
// (made at the first copy and kept: making a device and its manager each time cost tens of ms of each copy; one copy
// runs at a time, rp_frame_copying; let go of as the window is put away, rp_frame_release)
static ID3D11Device *rp_copy_dev = nullptr;
static ID3D11DeviceContext *rp_copy_ctx = nullptr;
static IMFDXGIDeviceManager *rp_copy_mgr = nullptr;

static bool rp_frame_at_gpu(const std::wstring &file, double ms, std::vector<uint8_t> &bgra, int &w, int &h) {
  ID3D11Device *&dev = rp_copy_dev;
  ID3D11DeviceContext *&ctx = rp_copy_ctx;
  IMFDXGIDeviceManager *&mgr = rp_copy_mgr;
  IMFAttributes *attrs = nullptr;
  IMFSourceReader *reader = nullptr;
  IMFMediaType *want = nullptr;
  IMFSample *sample = nullptr;
  ID3D11Texture2D *kept = nullptr, *staging = nullptr;
  bool ok = false;
  do {
    if (!mgr) {
      D3D_FEATURE_LEVEL level;
      UINT token = 0;
      bool made = SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                              nullptr, 0, D3D11_SDK_VERSION, &dev, &level, &ctx));
      if (made) {
        ID3D10Multithread *mt = nullptr;
        if (SUCCEEDED(dev->QueryInterface(IID_PPV_ARGS(&mt)))) {
          mt->SetMultithreadProtected(TRUE);
          mt->Release();
        }
        made = SUCCEEDED(MFCreateDXGIDeviceManager(&token, &mgr)) && SUCCEEDED(mgr->ResetDevice(dev, token));
      }
      if (!made) {
        rp_release(mgr);
        rp_release(ctx);
        rp_release(dev);
        break;
      }
    }
    if (FAILED(MFCreateAttributes(&attrs, 2))) break;
    attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, mgr);
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (FAILED(MFCreateSourceReaderFromURL(file.c_str(), attrs, &reader))) break;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    UINT32 fw = 0, fh = 0;
    int bt601 = 0, full = 0;
    rp_native_picture(reader, fw, fh, bt601, full);
    if (fw < 2 || fh < 2) break;
    if (FAILED(MFCreateMediaType(&want))) break;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want))) break;
    const LONGLONG target = (LONGLONG)(ms * 10000.0);
    PROPVARIANT at;
    PropVariantInit(&at);
    at.vt = VT_I8;
    at.hVal.QuadPart = target;
    if (FAILED(reader->SetCurrentPosition(GUID_NULL, at))) break;
    UINT32 tw = 0, th = 0;
    bool have = false, failed = false;
    for (int reads = 0; reads < 2000 && !failed; reads++) {
      DWORD flags = 0;
      LONGLONG ts = 0;
      rp_release(sample);
      if (FAILED(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &sample))) break;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
      if (!sample) continue;
      if (ts > target + 10000 && have) break;
      // (this one kept: copied aside on the GPU, the decoder's picture given back)
      IMFMediaBuffer *buffer = nullptr;
      IMFDXGIBuffer *dxgi = nullptr;
      ID3D11Texture2D *src = nullptr;
      UINT sub = 0;
      if (SUCCEEDED(sample->GetBufferByIndex(0, &buffer)) && SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&dxgi))) &&
          SUCCEEDED(dxgi->GetResource(IID_PPV_ARGS(&src))) && SUCCEEDED(dxgi->GetSubresourceIndex(&sub))) {
        if (!kept) {
          D3D11_TEXTURE2D_DESC sd{};
          src->GetDesc(&sd);
          tw = std::min<UINT32>(fw, sd.Width) & ~1u;
          th = std::min<UINT32>(fh, sd.Height) & ~1u;
          D3D11_TEXTURE2D_DESC td{};
          td.Width = tw;
          td.Height = th;
          td.MipLevels = td.ArraySize = 1;
          td.Format = DXGI_FORMAT_NV12;
          td.SampleDesc.Count = 1;
          td.Usage = D3D11_USAGE_DEFAULT;
          if (tw < 2 || th < 2 || sd.Format != DXGI_FORMAT_NV12 || FAILED(dev->CreateTexture2D(&td, nullptr, &kept))) failed = true;
        }
        if (kept) {
          D3D11_BOX box = {0, 0, 0, tw, th, 1};
          ctx->CopySubresourceRegion(kept, 0, 0, 0, 0, src, sub, &box);
          have = true;
        }
      } else {
        failed = true;
      }
      rp_release(src);
      rp_release(dxgi);
      rp_release(buffer);
      if (ts > target + 10000) break;
    }
    rp_release(sample);
    if (!have || failed) break;
    D3D11_TEXTURE2D_DESC td{};
    kept->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(dev->CreateTexture2D(&td, nullptr, &staging))) break;
    ctx->CopyResource(staging, kept);
    D3D11_MAPPED_SUBRESOURCE map{};
    if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &map))) break;
    w = (int)tw;
    h = (int)th;
    rp_nv12_to_bgra((const uint8_t *)map.pData, map.RowPitch, th, w, h, bt601, full, bgra);
    ctx->Unmap(staging, 0);
    ok = true;
  } while (false);
  rp_release(sample);
  rp_release(staging);
  rp_release(kept);
  rp_release(want);
  rp_release(reader);
  rp_release(attrs);
  // (a device lost, a driver updated: made anew at the next copy)
  if (!ok && dev && FAILED(dev->GetDeviceRemovedReason())) {
    rp_release(mgr);
    rp_release(ctx);
    rp_release(dev);
  }
  return ok;
}

// The frame shown at `ms` into `file` (the last one at or before it), whole, as top-down BGRA rows; false when it
// cannot be decoded.
static bool rp_frame_at(const std::wstring &file, double ms, std::vector<uint8_t> &bgra, int &w, int &h) {
  IMFAttributes *attrs = nullptr;
  IMFSourceReader *reader = nullptr;
  IMFMediaType *want = nullptr, *got = nullptr;
  IMFSample *best = nullptr, *sample = nullptr;
  IMFMediaBuffer *buffer = nullptr;
  IMF2DBuffer *surface = nullptr;
  bool ok = false;
  do {
    if (FAILED(MFCreateAttributes(&attrs, 2))) break;
    attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (FAILED(MFCreateSourceReaderFromURL(file.c_str(), attrs, &reader))) break;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(MFCreateMediaType(&want))) break;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want))) break;
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    UINT32 fw = 0, fh = 0;
    MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &fw, &fh);
    // (the picture shown, where the coded frame is taller: HEVC's 2160 rows coded as 2176)
    MFVideoArea area;
    if (SUCCEEDED(got->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area, nullptr)) &&
        area.Area.cx > 0 && area.Area.cy > 0 && (UINT32)area.Area.cx <= fw && (UINT32)area.Area.cy <= fh) {
      fw = (UINT32)area.Area.cx;
      fh = (UINT32)area.Area.cy;
    }
    rp_release(got);
    {
      UINT32 nw = 0, nh = 0;
      int b6 = 0, fr = 0;
      rp_native_picture(reader, nw, nh, b6, fr);
      if (nw && nh && nw <= fw && nh <= fh) {
        fw = nw;
        fh = nh;
      }
    }
    if (!fw || !fh) break;
    const LONGLONG target = (LONGLONG)(ms * 10000.0);
    PROPVARIANT at;
    PropVariantInit(&at);
    at.vt = VT_I8;
    at.hVal.QuadPart = target;
    if (FAILED(reader->SetCurrentPosition(GUID_NULL, at))) break;
    // (from the key frame before it on: the last one not after it, as the player shows it; a millisecond's slack for
    // the time asked being the frame's own, rounded)
    for (int reads = 0; reads < 2000; reads++) {
      DWORD flags = 0;
      LONGLONG ts = 0;
      if (FAILED(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &sample))) break;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
      if (!sample) continue;
      if (ts > target + 10000 && best) {
        rp_release(sample);
        break;
      }
      rp_release(best);
      best = sample;
      sample = nullptr;
      if (ts > target + 10000) break;
    }
    if (!best) break;
    // (the converter's storage may be wider than the picture: its type after decoding says)
    if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got))) break;
    UINT32 sw = fw, sh = fh;
    MFGetAttributeSize(got, MF_MT_FRAME_SIZE, &sw, &sh);
    LONG stride = (LONG)MFGetAttributeUINT32(got, MF_MT_DEFAULT_STRIDE, sw * 4);
    if (FAILED(best->ConvertToContiguousBuffer(&buffer))) break;
    BYTE *data = nullptr;
    DWORD len = 0;
    bool locked2d = SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&surface))) && SUCCEEDED(surface->Lock2D(&data, &stride));
    if (!locked2d && FAILED(buffer->Lock(&data, nullptr, &len))) break;
    LONG pitch = stride < 0 ? -stride : stride;
    if (!locked2d && ((size_t)pitch * fh > len || (size_t)pitch < (size_t)fw * 4)) {
      buffer->Unlock();
      break;
    }
    w = (int)fw;
    h = (int)fh;
    bgra.assign((size_t)w * h * 4, 0);
    for (int y = 0; y < h; y++) {
      const BYTE *row = locked2d ? data + (ptrdiff_t)y * stride
                                 : (stride < 0 ? data + (size_t)(fh - 1 - y) * pitch : data + (size_t)y * pitch);
      uint8_t *o = &bgra[(size_t)y * w * 4];
      memcpy(o, row, (size_t)w * 4);
      for (int x = 0; x < w; x++) o[x * 4 + 3] = 255;
    }
    if (locked2d) surface->Unlock2D();
    else buffer->Unlock();
    ok = true;
  } while (false);
  rp_release(surface);
  rp_release(buffer);
  rp_release(sample);
  rp_release(best);
  rp_release(got);
  rp_release(want);
  rp_release(reader);
  rp_release(attrs);
  return ok;
}

// Top-down BGRA rows as a PNG file's bytes (none when it could not be encoded).
static std::vector<uint8_t> rp_png(const std::vector<uint8_t> &bgra, int w, int h) {
  std::vector<uint8_t> out;
  IWICImagingFactory *wic = nullptr;
  IStream *stream = nullptr;
  IWICBitmapEncoder *encoder = nullptr;
  IWICBitmapFrameEncode *frame = nullptr;
  do {
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) break;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) break;
    if (FAILED(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder))) break;
    if (FAILED(encoder->Initialize(stream, WICBitmapEncoderNoCache))) break;
    if (FAILED(encoder->CreateNewFrame(&frame, nullptr))) break;
    if (FAILED(frame->Initialize(nullptr))) break;
    if (FAILED(frame->SetSize((UINT)w, (UINT)h))) break;
    // (no alpha in it: a screen has none)
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGR;
    if (FAILED(frame->SetPixelFormat(&format))) break;
    // (the encoder's own format may differ, 24-bit: WriteSource converts)
    IWICBitmap *bitmap = nullptr;
    if (FAILED(wic->CreateBitmapFromMemory((UINT)w, (UINT)h, GUID_WICPixelFormat32bppBGR, (UINT)w * 4, (UINT)bgra.size(),
                                           (BYTE *)bgra.data(), &bitmap))) break;
    HRESULT wrote = frame->WriteSource(bitmap, nullptr);
    bitmap->Release();
    if (FAILED(wrote)) break;
    if (FAILED(frame->Commit()) || FAILED(encoder->Commit())) break;
    HGLOBAL g = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &g))) break;
    STATSTG st = {};
    if (FAILED(stream->Stat(&st, STATFLAG_NONAME))) break;
    const uint8_t *p = (const uint8_t *)GlobalLock(g);
    if (p) {
      out.assign(p, p + (size_t)st.cbSize.QuadPart);
      GlobalUnlock(g);
    }
  } while (false);
  rp_release(frame);
  rp_release(encoder);
  rp_release(stream);
  rp_release(wic);
  return out;
}

static HGLOBAL rp_global(const void *bytes, size_t n) {
  HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, n);
  if (!g) return nullptr;
  void *p = GlobalLock(g);
  if (!p) {
    GlobalFree(g);
    return nullptr;
  }
  memcpy(p, bytes, n);
  GlobalUnlock(g);
  return g;
}

// Now in ms, finer than GetTickCount64's 16 (the copy's times said in the trace).
static double rp_ms() {
  static LARGE_INTEGER f = {};
  if (!f.QuadPart) QueryPerformanceFrequency(&f);
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

// The clipboard's owner while a copied frame is on it: a window of its own on a thread of its own, so the PNG is made
// only when a program pasting asks for it (WM_RENDERFORMAT), not before the copy is said done (a 4K PNG takes some
// 200 ms, as long as the decode); the DIB, a copy of the rows, is put at once.
struct RpClip {
  HWND hwnd = nullptr;
  UINT png = 0;
  std::vector<uint8_t> bgra;  // the frame on the clipboard, till another program's copy takes its place
  int w = 0, h = 0;
};
static RpClip rp_clip;

struct RpPut {
  std::vector<uint8_t> dib, bgra;
  int w, h;
};

static HGLOBAL rp_png_global(const RpClip &c) {
  std::vector<uint8_t> png = rp_png(c.bgra, c.w, c.h);
  return png.empty() ? nullptr : rp_global(png.data(), png.size());
}

static LRESULT CALLBACK rp_clip_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_APP + 1: {
      // (put: the DIB now, the PNG promised; the frame kept here, on this thread, for when it is asked)
      RpPut *put = (RpPut *)lp;
      HGLOBAL dib_mem = rp_global(put->dib.data(), put->dib.size());
      bool open = false;
      for (int tries = 0; tries < 20 && !(open = OpenClipboard(hwnd) != 0); tries++) Sleep(25);
      LRESULT ok = 0;
      if (open) {
        EmptyClipboard();
        rp_clip.bgra.swap(put->bgra);
        rp_clip.w = put->w;
        rp_clip.h = put->h;
        if (dib_mem && SetClipboardData(CF_DIB, dib_mem)) {
          dib_mem = nullptr;
          ok = 1;
        }
        if (rp_clip.png) SetClipboardData(rp_clip.png, nullptr);
        CloseClipboard();
      }
      if (dib_mem) GlobalFree(dib_mem);
      return ok;
    }
    case WM_RENDERFORMAT:
      if ((UINT)wp == rp_clip.png && !rp_clip.bgra.empty()) {
        HGLOBAL g = rp_png_global(rp_clip);
        if (g && !SetClipboardData(rp_clip.png, g)) GlobalFree(g);
      }
      return 0;
    case WM_RENDERALLFORMATS:
      // (the program quitting while its frame is still on the clipboard: the PNG made now, kept there)
      if (OpenClipboard(hwnd)) {
        if (GetClipboardOwner() == hwnd && !rp_clip.bgra.empty()) {
          HGLOBAL g = rp_png_global(rp_clip);
          if (g && !SetClipboardData(rp_clip.png, g)) GlobalFree(g);
        }
        CloseClipboard();
      }
      return 0;
    case WM_DESTROYCLIPBOARD:
      // (emptied: another copy takes its place, or this one's next)
      rp_clip.bgra.clear();
      rp_clip.bgra.shrink_to_fit();
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

static HWND rp_clip_window() {
  static std::once_flag once;
  static HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::call_once(once, []() {
    std::thread([]() {
      WNDCLASSW wc = {};
      wc.lpfnWndProc = rp_clip_proc;
      wc.hInstance = GetModuleHandleW(nullptr);
      wc.lpszClassName = L"ScreenReplayFrameClip";
      RegisterClassW(&wc);
      rp_clip.png = RegisterClipboardFormatW(L"PNG");
      rp_clip.hwnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
      SetEvent(ready);
      MSG m;
      while (GetMessageW(&m, nullptr, 0, 0) > 0) DispatchMessageW(&m);
    }).detach();
  });
  WaitForSingleObject(ready, 2000);
  return rp_clip.hwnd;
}

// The picture put on the clipboard twice over: as a DIB (CF_DIB: what Paint, Word and most programs take), and as a PNG
// (the registered "PNG" format: what browsers and chats take), made only when asked for.
// REPLAY_TEST_COPY_FRAME=<file>: the PNG written there instead, the clipboard left alone (the test windows: never the
// clipboard of the person at this computer).
static bool rp_put_picture(std::vector<uint8_t> &bgra, int w, int h) {
  double began = rp_ms();
  // (the DIB: its rows from the bottom up, as every reader of CF_DIB takes them)
  BITMAPINFOHEADER info = {};
  info.biSize = sizeof info;
  info.biWidth = w;
  info.biHeight = h;
  info.biPlanes = 1;
  info.biBitCount = 32;
  info.biCompression = BI_RGB;
  info.biSizeImage = (DWORD)((size_t)w * h * 4);
  std::vector<uint8_t> dib(sizeof info + (size_t)w * h * 4);
  memcpy(dib.data(), &info, sizeof info);
  for (int y = 0; y < h; y++)
    memcpy(&dib[sizeof info + (size_t)(h - 1 - y) * w * 4], &bgra[(size_t)y * w * 4], (size_t)w * 4);
  const char *test = getenv("REPLAY_TEST_COPY_FRAME");
  if (test && *test) {
    // (what the clipboard would be given made all the same, its time said; the PNG written in its place)
    const char *trace = getenv("REPLAY_TRACE");
    if (trace && strcmp(trace, "1") == 0) {
      printf("REPLAY_COPY_DIB %.1f ms\n", rp_ms() - began);
      fflush(stdout);
    }
    std::vector<uint8_t> png = rp_png(bgra, w, h);
    if (png.empty()) return false;
    FILE *f = _wfopen(rp_w(test).c_str(), L"wb");
    if (!f) return false;
    bool ok = fwrite(png.data(), 1, png.size(), f) == png.size();
    fclose(f);
    return ok;
  }
  HWND owner = rp_clip_window();
  if (!owner) return false;
  RpPut put{std::move(dib), std::move(bgra), w, h};
  return SendMessageW(owner, WM_APP + 1, 0, (LPARAM)&put) == 1;
}

// 0 nothing asked, 1 being made, 2 copied, 3 could not be.
static std::atomic<int> rp_frame_copying{0};

// mbui's (win_stream.cpp): the frame a stream shows, read back off the GPU, its rows handed over on a thread of its own
extern "C" {
typedef void (*mb_stream_grabbed_fn)(void *arg, const unsigned char *rows, int w, int h, int pitch, double ts);
int mb_stream_grab(int id, mb_stream_grabbed_fn done, void *arg);
}

static double rp_grab_began = 0;
static void rp_frame_put(std::vector<uint8_t> &bgra, int w, int h, double read);

static void rp_frame_grabbed(void *, const unsigned char *rows, int w, int h, int pitch, double) {
  double read = rp_ms();
  if (!rows || w <= 0 || h <= 0) {
    rp_frame_copying = 3;
    return;
  }
  // (the rows taken and the GPU's texture given back at once; the clipboard's part on a thread of this file's)
  auto bgra = std::make_shared<std::vector<uint8_t>>((size_t)w * h * 4);
  for (int y = 0; y < h; y++) {
    uint8_t *o = &(*bgra)[(size_t)y * w * 4];
    memcpy(o, rows + (size_t)y * pitch, (size_t)w * 4);
    for (int x = 0; x < w; x++) o[x * 4 + 3] = 255;
  }
  try {
    std::thread([bgra, w, h, read]() { rp_frame_put(*bgra, w, h, read); }).detach();
  } catch (...) {
    rp_frame_copying = 3;
  }
}

static void rp_frame_put(std::vector<uint8_t> &bgra, int w, int h, double read) {
  bool ok = rp_put_picture(bgra, w, h);
  const char *trace = getenv("REPLAY_TRACE");
  if (trace && strcmp(trace, "1") == 0) {
    printf("REPLAY_COPY_SHOWN read %.1f ms, put %.1f ms %dx%d ok=%d\n", read - rp_grab_began, rp_ms() - read, w, h, (int)ok);
    fflush(stdout);
  }
  rp_frame_copying = ok ? 2 : 3;
}

// The frame the player's stream shows now copied to the clipboard as it is (read off the GPU where it is drawn from:
// no decode); 0 where it shows none or one is being copied (then rp_frame_copy).
extern "C" int32_t rp_frame_copy_shown(int32_t stream) {
  if (rp_frame_copying.exchange(1) == 1) return 0;
  rp_grab_began = rp_ms();
  if (mb_stream_grab(stream, rp_frame_grabbed, nullptr) == 1) return 1;
  rp_frame_copying = 0;
  return 0;
}

// The frame at `ms` into the segment `path` copied to the clipboard, in the background (a 4K frame decodes from the
// key frame before it); 0 when one is still being copied.
extern "C" int32_t rp_frame_copy(moonbit_bytes_t path, double ms) {
  if (rp_frame_copying.exchange(1) == 1) return 0;
  std::string file((const char *)path);
  try {
    std::thread([file, ms]() {
      bool ok = false;
      if (rp_mf_ready()) {
        std::vector<uint8_t> bgra;
        int w = 0, h = 0;
        ULONGLONG began = GetTickCount64();
        std::wstring wide = rp_w(file.c_str());
        bool on_gpu = rp_frame_at_gpu(wide, ms, bgra, w, h);
        ok = (on_gpu || rp_frame_at(wide, ms, bgra, w, h)) && rp_put_picture(bgra, w, h);
        const char *trace = getenv("REPLAY_TRACE");
        if (trace && strcmp(trace, "1") == 0) {
          printf("REPLAY_COPY_FRAME %llu ms %dx%d gpu=%d ok=%d\n", GetTickCount64() - began, w, h, (int)on_gpu, (int)ok);
          fflush(stdout);
        }
      }
      rp_frame_copying = ok ? 2 : 3;
    }).detach();
  } catch (...) {
    rp_frame_copying = 3;
  }
  return 1;
}

// The copy's device let go of (the window put away): made again at the next copy. Not while one is being made.
extern "C" void rp_frame_release(void) {
  int idle = 0;
  if (!rp_frame_copying.compare_exchange_strong(idle, 1)) return;
  rp_release(rp_copy_mgr);
  rp_release(rp_copy_ctx);
  rp_release(rp_copy_dev);
  rp_frame_copying = 0;
}

// How the last copy went (rp_frame_copying), a finished one told once (then 0).
extern "C" int32_t rp_frame_copy_state(void) {
  int s = rp_frame_copying.load();
  if (s >= 2) rp_frame_copying.compare_exchange_strong(s, 0);
  return s;
}
