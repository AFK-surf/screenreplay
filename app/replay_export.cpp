// A clip encoded again (the export dialog's "by size" and "custom"): the buffer's segments read in turn (Media
// Foundation's source reader, decoding on the GPU and scaling there with its video processor), their frames and sound
// written to one MP4 (the sink writer: H.264 High, H.265 Main or AV1 Main on the GPU's encoder, AAC), or their frames
// alone to an animated GIF (written here, its own palettes and LZW), on a thread of its own, its progress asked for by
// the window each frame. The encoder is asked for a variable bitrate bounded by the one the dialog worked out,
// measured over a quarter of a second (peak-constrained VBR, its peak that bitrate, its buffer 250 ms of it): a quiet
// picture takes less, a busy one never more, so the file is no larger than the dialog said.
//
// The recording has a frame only where the screen changed, so its frames come at no steady rate: one closer to the
// last written than the rate asked for is held, and written at the next moment the rate allows when a later one comes
// (or the part ends) first; what showed is never left out because the frame after it came soon.
#define NOMINMAX
#include <windows.h>
#include <timeapi.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include <climits>
#include <cstdlib>
#include "moonbit.h"

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winmm.lib")

using Microsoft::WRL::ComPtr;

namespace {

// What is written (rp_export_start's `codec`).
enum Codec { kH264 = 0, kHevc = 1, kAv1 = 2, kGif = 3 };

struct Part {
  std::wstring path;
  LONGLONG offset;  // where its first kept moment lands in the clip, 100 ns
  LONGLONG trim;    // where in the segment the clip starts
  LONGLONG end;     // where in the segment it ends
};

// A crop from a moment of the clip on (100 ns into it), in the recording's pixels (and scaled by `job.scale` in x..h).
struct Crop {
  LONGLONG at;
  int x, y, w, h;
  int rx, ry, rw, rh;
};

struct Job {
  std::vector<Part> parts;
  // (none: the whole picture, scaled to the size asked for by the reader; some: one window's or region's part of it,
  // cut out on the GPU and put in the middle of the picture, which is as large as it ever is)
  std::vector<Crop> crops;
  std::wstring output;
  int width = 0, height = 0, fps = 30, bitrate = 8000000;
  // the recording's picture, as the reader gives it when cropping
  int srcWidth = 0, srcHeight = 0;
  int bt601 = 0, full = 0;
  int codec = kH264;
  // what the recording is scaled by when cropping (a GIF's picture, smaller than the part cut out; the crops' x..h
  // are in the scaled picture's pixels, rx..rh in the recording's)
  double scale = 1.0;
  LONGLONG total = 1;
};

std::atomic<int> state{0};  // 0 idle, 1 running, 2 done, -1 failed, -2 cancelled
std::atomic<double> progress{0.0};
std::atomic<bool> cancel{false};
std::atomic<long> failure{0};
std::mutex mu;
std::thread worker;

std::wstring wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
  return w;
}

#define CHECK(x)                \
  do {                          \
    HRESULT hr_ = (x);          \
    if (FAILED(hr_)) return hr_; \
  } while (0)

HRESULT video_output_type(const Job &job, IMFMediaType **out) {
  ComPtr<IMFMediaType> t;
  CHECK(MFCreateMediaType(&t));
  CHECK(t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
  CHECK(t->SetGUID(MF_MT_SUBTYPE, job.codec == kHevc ? MFVideoFormat_HEVC : job.codec == kAv1 ? MFVideoFormat_AV1 : MFVideoFormat_H264));
  CHECK(t->SetUINT32(MF_MT_AVG_BITRATE, (UINT32)job.bitrate));
  CHECK(t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
  CHECK(MFSetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, job.width, job.height));
  CHECK(MFSetAttributeRatio(t.Get(), MF_MT_FRAME_RATE, job.fps, 1));
  CHECK(MFSetAttributeRatio(t.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
  // (AV1's profile left to the encoder: Main, 8 bits, the one it makes from BGRA)
  if (job.codec != kAv1)
    CHECK(t->SetUINT32(MF_MT_MPEG2_PROFILE, job.codec == kHevc ? (UINT32)eAVEncH265VProfile_Main_420_8 : (UINT32)eAVEncH264VProfile_High));
  CHECK(t->SetUINT32(MF_MT_MAX_KEYFRAME_SPACING, (UINT32)(job.fps * 2)));
  t->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB);
  t->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
  t->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
  t->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  *out = t.Detach();
  return S_OK;
}

HRESULT video_input_type(const Job &job, IMFMediaType **out) {
  ComPtr<IMFMediaType> t;
  CHECK(MFCreateMediaType(&t));
  CHECK(t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
  CHECK(t->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32));
  CHECK(t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
  CHECK(MFSetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, job.width, job.height));
  CHECK(MFSetAttributeRatio(t.Get(), MF_MT_FRAME_RATE, job.fps, 1));
  CHECK(MFSetAttributeRatio(t.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
  *out = t.Detach();
  return S_OK;
}

HRESULT pcm_type(IMFMediaType **out) {
  ComPtr<IMFMediaType> t;
  CHECK(MFCreateMediaType(&t));
  CHECK(t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
  CHECK(t->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM));
  CHECK(t->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2));
  CHECK(t->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000));
  CHECK(t->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
  CHECK(t->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4));
  CHECK(t->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48000 * 4));
  CHECK(t->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE));
  *out = t.Detach();
  return S_OK;
}

HRESULT aac_type(IMFMediaType **out) {
  ComPtr<IMFMediaType> t;
  CHECK(MFCreateMediaType(&t));
  CHECK(t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
  CHECK(t->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC));
  CHECK(t->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2));
  CHECK(t->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000));
  CHECK(t->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
  CHECK(t->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 128000 / 8));
  CHECK(t->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0));
  CHECK(t->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29));
  *out = t.Detach();
  return S_OK;
}

// The rate control asked of the encoder, most first; an encoder that rejects it gets the next. NVIDIA's AV1 encoder
// (2026-11-14, RTX 5080) keeps to the bitrate as a constant rate in every bitrate mode it has, a still screen too (a
// still desktop's 30 s 15 MB, twice H.264's), and its quality mode keeps to no size at all (a busy screen's 30 s
// 64-94 MB against 15 allowed); a cap with either changed neither. What it does honour is a floor under its QP: a
// frame that needs few bits to look so stops there and is not filled up to the rate, so a still desktop's 30 s is
// 2.2 MB (51 dB against a near-lossless copy; H.265's 8.1 MB, 55 dB: its type alike to the eye), a busy one's still
// held to the rate. So AV1 is asked that first (14, of 0-51), then as the others are.
HRESULT encoding_parameters(const Job &job, int level, IMFAttributes **out) {
  *out = nullptr;
  // (the steps: 0 a peak and a floor under the QP, AV1 only; 1 a peak; 2 a mean; 3 nothing asked)
  const int step = job.codec == kAv1 ? level : level + 1;
  if (step >= 3) return S_OK;
  ComPtr<IMFAttributes> a;
  CHECK(MFCreateAttributes(&a, 8));
  a->SetUINT32(CODECAPI_AVEncCommonMeanBitRate, (UINT32)job.bitrate);
  a->SetUINT32(CODECAPI_AVEncMPVGOPSize, (UINT32)(job.fps * 2));
  if (step <= 1) {
    a->SetUINT32(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_PeakConstrainedVBR);
    a->SetUINT32(CODECAPI_AVEncCommonMaxBitRate, (UINT32)job.bitrate);
    a->SetUINT32(CODECAPI_AVEncCommonBufferSize, (UINT32)((uint64_t)job.bitrate * 250 / 1000));
    // AV1 hardware MFTs run much slower at high QualityVsSpeed; 25 keeps throughput high while MinQP guards quality.
    a->SetUINT32(CODECAPI_AVEncCommonQualityVsSpeed, job.codec == kAv1 ? 25u : 70u);
  }
  if (step == 0) a->SetUINT32(CODECAPI_AVEncVideoMinQP, 14);
  *out = a.Detach();
  return S_OK;
}

// The crop in force at `t` (100 ns into the clip).
const Crop &crop_at(const Job &job, LONGLONG t) {
  size_t i = 0;
  for (size_t k = 0; k < job.crops.size(); k++) {
    if (job.crops[k].at <= t) i = k;
  }
  return job.crops[i];
}

// A frame cut to the crop in force at `t` on the GPU (ID3D11VideoProcessor from NV12, or CopySubresourceRegion from
// BGRA) and put in the middle of a `job.width` x `job.height` black D3D11 texture wrapped in a DXGI surface buffer,
// with zero CPU copy; falls back to `cropped` in CPU memory when `source` has no DXGI surface.
struct GpuCropper {
  ComPtr<ID3D11Device> dev;
  ComPtr<ID3D11DeviceContext> ctx;
  ComPtr<ID3D11VideoDevice> vdev;
  ComPtr<ID3D11VideoContext> vctx;
  ComPtr<ID3D11Texture2D> nv12;
  UINT32 nv12_w = 0, nv12_h = 0;
  ComPtr<ID3D11VideoProcessorEnumerator> vpe;
  ComPtr<ID3D11VideoProcessor> vp;
  ComPtr<ID3D11VideoProcessorInputView> in_view;
  UINT32 vp_in_w = 0, vp_in_h = 0, vp_out_w = 0, vp_out_h = 0;
  std::vector<ComPtr<ID3D11Texture2D>> pool;
  // the video processor's output view of each pooled texture, made once (made for every frame before), while the
  // processor they were made for stands
  std::vector<std::pair<ID3D11Texture2D *, ComPtr<ID3D11VideoProcessorOutputView>>> out_views;
  ComPtr<ID3D11Texture2D> staging;
  UINT32 st_w = 0, st_h = 0;

  void init(ID3D11Device *d, ID3D11DeviceContext *c) {
    dev = d;
    ctx = c;
    if (dev) dev.As(&vdev);
    if (ctx) ctx.As(&vctx);
  }

  HRESULT take_dst(int dw, int dh, ComPtr<ID3D11Texture2D> &dst) {
    for (auto &t : pool) {
      t->AddRef();
      if (t->Release() == 1) {
        dst = t;
        return S_OK;
      }
    }
    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)dw;
    td.Height = (UINT)dh;
    td.MipLevels = td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    CHECK(dev->CreateTexture2D(&td, nullptr, &dst));
    if (pool.size() < 16) pool.push_back(dst);
    return S_OK;
  }

  HRESULT clear_black(ID3D11Texture2D *dst) {
    ComPtr<ID3D11RenderTargetView> rtv;
    CHECK(dev->CreateRenderTargetView(dst, nullptr, &rtv));
    const float black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    ctx->ClearRenderTargetView(rtv.Get(), black);
    return S_OK;
  }

  HRESULT crop(const Job &job, IMFSample *source, LONGLONG t, IMFSample **out) {
    *out = nullptr;
    if (!dev || !ctx) return E_FAIL;
    ComPtr<IMFMediaBuffer> in;
    ComPtr<IMFDXGIBuffer> dxgi;
    ComPtr<ID3D11Texture2D> src_tex;
    UINT sub = 0;
    CHECK(source->GetBufferByIndex(0, &in));
    CHECK(in.As(&dxgi));
    CHECK(dxgi->GetResource(IID_PPV_ARGS(&src_tex)));
    CHECK(dxgi->GetSubresourceIndex(&sub));

    D3D11_TEXTURE2D_DESC sdesc{};
    src_tex->GetDesc(&sdesc);
    const int dw = job.width, dh = job.height;
    const Crop &c = crop_at(job, t);
    const int cw = c.w < 2 || c.h < 2 ? 0 : std::min(c.w, dw), ch = cw == 0 ? 0 : std::min(c.h, dh);
    const int ox = (dw - cw) / 2, oy = (dh - ch) / 2;

    ComPtr<ID3D11Texture2D> dst_tex;
    CHECK(take_dst(dw, dh, dst_tex));

    if (sdesc.Format == DXGI_FORMAT_NV12) {
      if (!vdev || !vctx) return E_FAIL;
      UINT32 fw = job.srcWidth > 0 ? std::min<UINT32>((UINT32)job.srcWidth, sdesc.Width) : sdesc.Width;
      UINT32 fh = job.srcHeight > 0 ? std::min<UINT32>((UINT32)job.srcHeight, sdesc.Height) : sdesc.Height;
      UINT32 tw = fw & ~1u, th = fh & ~1u;
      if (tw < 2 || th < 2) return E_FAIL;

      int sx = c.rx, sy = c.ry;
      int sw = job.scale < 1.0 ? (int)(cw / job.scale + 0.5) : cw;
      int sh = job.scale < 1.0 ? (int)(ch / job.scale + 0.5) : ch;
      int dx = ox, dy = oy, w = cw, h = ch;
      if (sx < 0) {
        int cut = (int)(-sx * job.scale + 0.5);
        dx += cut;
        w -= cut;
        sw += sx;
        sx = 0;
      }
      if (sy < 0) {
        int cut = (int)(-sy * job.scale + 0.5);
        dy += cut;
        h -= cut;
        sh += sy;
        sy = 0;
      }
      if (sx + sw > (int)tw) {
        int over = sx + sw - (int)tw;
        sw = (int)tw - sx;
        w -= (int)(over * job.scale + 0.5);
      }
      if (sy + sh > (int)th) {
        int over = sy + sh - (int)th;
        sh = (int)th - sy;
        h -= (int)(over * job.scale + 0.5);
      }

      if (w <= 0 || h <= 0 || sw < 2 || sh < 2) {
        CHECK(clear_black(dst_tex.Get()));
      } else {
        if (!nv12 || nv12_w != tw || nv12_h != th) {
          in_view.Reset();
          nv12.Reset();
          D3D11_TEXTURE2D_DESC td{};
          td.Width = tw;
          td.Height = th;
          td.MipLevels = td.ArraySize = 1;
          td.Format = DXGI_FORMAT_NV12;
          td.SampleDesc.Count = 1;
          td.Usage = D3D11_USAGE_DEFAULT;
          td.BindFlags = D3D11_BIND_DECODER;
          CHECK(dev->CreateTexture2D(&td, nullptr, &nv12));
          nv12_w = tw;
          nv12_h = th;
        }
        D3D11_BOX cbox = {0, 0, 0, tw, th, 1};
        ctx->CopySubresourceRegion(nv12.Get(), 0, 0, 0, 0, src_tex.Get(), sub, &cbox);

        if (!vp || vp_in_w != tw || vp_in_h != th || vp_out_w != (UINT32)dw || vp_out_h != (UINT32)dh) {
          in_view.Reset();
          out_views.clear();
          vp.Reset();
          vpe.Reset();
          D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
          cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
          cd.InputFrameRate = {(UINT)job.fps, 1};
          cd.InputWidth = tw;
          cd.InputHeight = th;
          cd.OutputFrameRate = {(UINT)job.fps, 1};
          cd.OutputWidth = (UINT)dw;
          cd.OutputHeight = (UINT)dh;
          cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
          CHECK(vdev->CreateVideoProcessorEnumerator(&cd, &vpe));
          CHECK(vdev->CreateVideoProcessor(vpe.Get(), 0, &vp));
          vp_in_w = tw;
          vp_in_h = th;
          vp_out_w = (UINT32)dw;
          vp_out_h = (UINT32)dh;
        }
        if (!in_view) {
          D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
          ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
          CHECK(vdev->CreateVideoProcessorInputView(nv12.Get(), vpe.Get(), &ivd, &in_view));
        }
        ComPtr<ID3D11VideoProcessorOutputView> out_view;
        for (auto &e : out_views) {
          if (e.first == dst_tex.Get()) {
            out_view = e.second;
            break;
          }
        }
        if (!out_view) {
          D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
          ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
          CHECK(vdev->CreateVideoProcessorOutputView(dst_tex.Get(), vpe.Get(), &ovd, &out_view));
          // (kept only for a texture of the pool, which lives as long as this: one outside it may be let go, and another
          // made at its address)
          for (auto &t : pool) {
            if (t.Get() == dst_tex.Get()) {
              out_views.emplace_back(dst_tex.Get(), out_view);
              break;
            }
          }
        }

        vctx->VideoProcessorSetStreamFrameFormat(vp.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
        vctx->VideoProcessorSetStreamAutoProcessingMode(vp.Get(), 0, FALSE);
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs{};
        in_cs.YCbCr_Matrix = job.bt601 ? 0 : 1;
        in_cs.Nominal_Range = job.full ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255 : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
        vctx->VideoProcessorSetStreamColorSpace(vp.Get(), 0, &in_cs);
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs{};
        out_cs.RGB_Range = 0;
        vctx->VideoProcessorSetOutputColorSpace(vp.Get(), &out_cs);

        RECT srect = {sx & ~1, sy & ~1, std::min<LONG>((LONG)tw, (sx + sw + 1) & ~1), std::min<LONG>((LONG)th, (sy + sh + 1) & ~1)};
        if (srect.right <= srect.left) srect.right = std::min<LONG>((LONG)tw, srect.left + 2);
        if (srect.bottom <= srect.top) srect.bottom = std::min<LONG>((LONG)th, srect.top + 2);
        RECT drect = {dx, dy, std::min(dw, dx + w), std::min(dh, dy + h)};
        RECT trect = {0, 0, dw, dh};
        vctx->VideoProcessorSetStreamSourceRect(vp.Get(), 0, TRUE, &srect);
        vctx->VideoProcessorSetStreamDestRect(vp.Get(), 0, TRUE, &drect);
        vctx->VideoProcessorSetOutputTargetRect(vp.Get(), TRUE, &trect);

        D3D11_VIDEO_PROCESSOR_STREAM st{};
        st.Enable = TRUE;
        st.pInputSurface = in_view.Get();
        CHECK(vctx->VideoProcessorBlt(vp.Get(), out_view.Get(), 0, 1, &st));
      }
    } else if (sdesc.Format == DXGI_FORMAT_B8G8R8A8_UNORM) {
      const int src_w = job.srcWidth > 0 ? std::min(job.srcWidth, (int)sdesc.Width) : (int)sdesc.Width;
      const int src_h = job.srcHeight > 0 ? std::min(job.srcHeight, (int)sdesc.Height) : (int)sdesc.Height;
      int sx = c.x, w = cw, dx = ox;
      if (sx < 0) {
        dx -= sx;
        w += sx;
        sx = 0;
      }
      if (sx + w > src_w) w = src_w - sx;
      int sy = c.y, h = ch, dy = oy;
      if (sy < 0) {
        dy -= sy;
        h += sy;
        sy = 0;
      }
      if (sy + h > src_h) h = src_h - sy;
      if (w < dw || h < dh || dx > 0 || dy > 0) CHECK(clear_black(dst_tex.Get()));
      if (w > 0 && h > 0) {
        D3D11_BOX box = {(UINT)sx, (UINT)sy, 0, (UINT)(sx + w), (UINT)(sy + h), 1};
        ctx->CopySubresourceRegion(dst_tex.Get(), 0, (UINT)dx, (UINT)dy, 0, src_tex.Get(), sub, &box);
      }
    } else {
      return E_FAIL;
    }

    ComPtr<IMFMediaBuffer> ob;
    CHECK(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), dst_tex.Get(), 0, FALSE, &ob));
    ComPtr<IMF2DBuffer> ob2d;
    DWORD cb = (DWORD)(dw * dh * 4);
    if (SUCCEEDED(ob.As(&ob2d))) ob2d->GetContiguousLength(&cb);
    ob->SetCurrentLength(cb);
    ComPtr<IMFSample> sample;
    CHECK(MFCreateSample(&sample));
    CHECK(sample->AddBuffer(ob.Get()));
    *out = sample.Detach();
    return S_OK;
  }
};

// A frame (BGRA, the recording's size) cut to the crop in force at `t`, put in the middle of a `job.width` x
// `job.height` black picture: a sample of memory, top row first (CPU fallback when a sample is not on the GPU).
HRESULT cropped(const Job &job, IMFSample *source, LONGLONG t, IMFSample **out) {
  *out = nullptr;
  ComPtr<IMFMediaBuffer> in;
  CHECK(source->ConvertToContiguousBuffer(&in));
  ComPtr<IMF2DBuffer> in2d;
  BYTE *src = nullptr;
  LONG pitch = 0;
  DWORD srcLen = 0;
  bool locked2d = SUCCEEDED(in.As(&in2d)) && SUCCEEDED(in2d->Lock2D(&src, &pitch));
  if (!locked2d) CHECK(in->Lock(&src, nullptr, &srcLen));
  // (the recording's own size: its type's; the buffer's length when the type does not say)
  const Crop &c = crop_at(job, t);
  const int dw = job.width, dh = job.height;
  ComPtr<IMFMediaBuffer> ob;
  HRESULT hr = MFCreateMemoryBuffer((DWORD)(dw * dh * 4), &ob);
  if (SUCCEEDED(hr)) {
    BYTE *dst = nullptr;
    hr = ob->Lock(&dst, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
      memset(dst, 0, (size_t)dw * dh * 4);
      const int cw = c.w < 2 || c.h < 2 ? 0 : std::min(c.w, dw), ch = cw == 0 ? 0 : std::min(c.h, dh);
      const int ox = (dw - cw) / 2, oy = (dh - ch) / 2;
      if (pitch == 0) pitch = job.srcWidth * 4;
      for (int y = 0; y < ch; y++) {
        const int sy = c.y + y;
        if (sy < 0 || sy >= job.srcHeight) continue;
        int sx = c.x, w = cw, dx = ox;
        if (sx < 0) {
          dx -= sx;
          w += sx;
          sx = 0;
        }
        if (sx + w > job.srcWidth) w = job.srcWidth - sx;
        if (w <= 0) continue;
        memcpy(dst + ((size_t)(oy + y) * dw + dx) * 4, src + (ptrdiff_t)sy * pitch + (size_t)sx * 4, (size_t)w * 4);
      }
      ob->Unlock();
      ob->SetCurrentLength((DWORD)(dw * dh * 4));
    }
  }
  if (locked2d) in2d->Unlock2D();
  else in->Unlock();
  CHECK(hr);
  ComPtr<IMFSample> sample;
  CHECK(MFCreateSample(&sample));
  CHECK(sample->AddBuffer(ob.Get()));
  *out = sample.Detach();
  return S_OK;
}

// A frame's pixels as rows, top first: the sample locked (a GPU surface copied into a reused staging texture, or by its
// 2D buffer) for `use`.
template <class F>
HRESULT with_pixels(GpuCropper &gpu, IMFSample *sample, int width, F use) {
  ComPtr<IMFMediaBuffer> b;
  if (gpu.dev && gpu.ctx && SUCCEEDED(sample->GetBufferByIndex(0, &b))) {
    ComPtr<IMFDXGIBuffer> dxgi;
    ComPtr<ID3D11Texture2D> src;
    UINT sub = 0;
    if (SUCCEEDED(b.As(&dxgi)) && SUCCEEDED(dxgi->GetResource(IID_PPV_ARGS(&src))) &&
        SUCCEEDED(dxgi->GetSubresourceIndex(&sub))) {
      D3D11_TEXTURE2D_DESC sd{};
      src->GetDesc(&sd);
      if (sd.Format == DXGI_FORMAT_B8G8R8A8_UNORM && sd.Width > 0 && sd.Height > 0) {
        if (!gpu.staging || gpu.st_w != sd.Width || gpu.st_h != sd.Height) {
          gpu.staging.Reset();
          D3D11_TEXTURE2D_DESC td = sd;
          td.MipLevels = td.ArraySize = 1;
          td.Usage = D3D11_USAGE_STAGING;
          td.BindFlags = 0;
          td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
          td.MiscFlags = 0;
          if (SUCCEEDED(gpu.dev->CreateTexture2D(&td, nullptr, &gpu.staging))) {
            gpu.st_w = sd.Width;
            gpu.st_h = sd.Height;
          }
        }
        if (gpu.staging) {
          D3D11_BOX box = {0, 0, 0, sd.Width, sd.Height, 1};
          gpu.ctx->CopySubresourceRegion(gpu.staging.Get(), 0, 0, 0, 0, src.Get(), sub, &box);
          D3D11_MAPPED_SUBRESOURCE mapped{};
          if (SUCCEEDED(gpu.ctx->Map(gpu.staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
            HRESULT hr = use((const BYTE *)mapped.pData, (LONG)mapped.RowPitch);
            gpu.ctx->Unmap(gpu.staging.Get(), 0);
            return hr;
          }
        }
      }
    }
  }
  b.Reset();
  CHECK(sample->ConvertToContiguousBuffer(&b));
  ComPtr<IMF2DBuffer> b2d;
  BYTE *px = nullptr;
  LONG pitch = 0;
  DWORD len = 0;
  if (SUCCEEDED(b.As(&b2d)) && SUCCEEDED(b2d->Lock2D(&px, &pitch))) {
    HRESULT hr = use(px, pitch);
    b2d->Unlock2D();
    return hr;
  }
  CHECK(b->Lock(&px, nullptr, &len));
  HRESULT hr = use(px, (LONG)width * 4);
  b->Unlock();
  return hr;
}

// An animated GIF written as its frames come, looping for ever (NETSCAPE2.0). Each frame is what changed since the one
// before: the box round the pixels that differ, those not changed in it transparent, so the one under them shows
// (disposal: kept). Its colours are its own table's, at most 256, found by median cut over the changed pixels' colours
// (counted in 6 bits a channel, each bin's colour its pixels' mean). A frame with no more colours than the table is shown
// exactly; one with more is dithered only where it is a smooth gradient (a wallpaper, a shadow: gif_smooth's 16 x 16
// blocks of small steps that are not one flat colour), between the table's two colours either side of each pixel by a
// fixed 4 x 4 pattern (ordered), so a gradient is not cut into bands and a still one does not crawl from frame to frame; flat colours and type, which a dither's dots would
// fray, never are (the user, 2026-11-14). A frame's
// delay is how long until the next one (the clip's end for the last), in hundredths of a second counted from the
// clip's start, so the delays add up to the clip's length whatever the rate. A frame like the one before is no frame:
// that one stays longer.
class Gif {
 public:
  ~Gif() {
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
  }

  // `path` "": nothing written, its frames' bytes only counted (the estimate's).
  HRESULT open(const std::wstring &path, int w, int h) {
    w_ = w;
    h_ = h;
    if (!path.empty()) {
      file_ = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file_ == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    }
    last_.assign((size_t)w * h, 0);
    shown_ = false;
    const uint8_t head[] = {'G', 'I', 'F', '8', '9', 'a', (uint8_t)w, (uint8_t)(w >> 8), (uint8_t)h, (uint8_t)(h >> 8), 0, 0, 0,
                            // looping for ever
                            0x21, 0xFF, 11, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0', 3, 1, 0, 0, 0};
    out_.insert(out_.end(), head, head + sizeof head);
    return S_OK;
  }

  // A frame (BGRA rows, top first, `pitch` apart, the GIF's size) shown from `t` (100 ns into the clip).
  HRESULT add(const BYTE *px, LONG pitch, LONGLONG t) {
    const int w = w_, h = h_;
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    cur_.resize((size_t)w * h);
    for (int y = 0; y < h; y++) {
      const BYTE *row = px + (ptrdiff_t)y * pitch;
      uint32_t *c = &cur_[(size_t)y * w];
      const uint32_t *l = &last_[(size_t)y * w];
      for (int x = 0; x < w; x++) {
        c[x] = ((uint32_t)row[x * 4 + 2] << 16) | ((uint32_t)row[x * 4 + 1] << 8) | row[x * 4];
        if (!shown_ || !same(c[x], l[x])) {
          x0 = std::min(x0, x);
          x1 = std::max(x1, x);
          y0 = std::min(y0, y);
          y1 = std::max(y1, y);
        }
      }
    }
    if (x1 < 0) return S_OK;
    CHECK(flush(t));
    // (the first frame from the GIF's start: a GIF has nothing before it)
    pending_at_ = shown_ ? t : 0;
    frame(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
    shown_ = true;
    return out_.size() > (1 << 20) ? drain() : S_OK;
  }

  // The last frame shown till `end`, and the file closed.
  HRESULT finish(LONGLONG end) {
    CHECK(flush(end));
    out_.push_back(0x3B);
    CHECK(drain());
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
    file_ = INVALID_HANDLE_VALUE;
    return S_OK;
  }

  // The bytes of the first frame written, and of those after it, and how many those are.
  uint64_t first_bytes() const { return first_bytes_; }
  uint64_t later_bytes() const { return later_bytes_; }
  uint64_t frames() const { return frames_; }

 private:
  struct Box {
    size_t from, to;  // into colors_
    uint64_t count;
    uint64_t score;
  };
  struct Color {
    uint32_t r, g, b, count;  // the bin's sums and how many it holds
    uint32_t bin;
  };

  static LONGLONG hundredths(LONGLONG t) { return (t + 50000) / 100000; }

  // The frame waiting for its delay written, its delay to `t`.
  HRESULT flush(LONGLONG t) {
    if (pending_.empty()) return S_OK;
    const LONGLONG d = std::max<LONGLONG>(1, std::min<LONGLONG>(65535, hundredths(t) - hundredths(pending_at_)));
    const uint8_t gce[] = {0x21, 0xF9, 4, (uint8_t)((1 << 2) | (pending_transparent_ >= 0 ? 1 : 0)), (uint8_t)d, (uint8_t)(d >> 8),
                           (uint8_t)(pending_transparent_ >= 0 ? pending_transparent_ : 0), 0};
    out_.insert(out_.end(), gce, gce + sizeof gce);
    out_.insert(out_.end(), pending_.begin(), pending_.end());
    (frames_ == 0 ? first_bytes_ : later_bytes_) += sizeof gce + pending_.size();
    frames_++;
    pending_.clear();
    return S_OK;
  }

  HRESULT drain() {
    if (file_ == INVALID_HANDLE_VALUE) {
      out_.clear();
      return S_OK;
    }
    size_t at = 0;
    while (at < out_.size()) {
      DWORD put = 0;
      if (!WriteFile(file_, out_.data() + at, (DWORD)std::min<size_t>(out_.size() - at, 1 << 24), &put, nullptr))
        return HRESULT_FROM_WIN32(GetLastError());
      at += put;
    }
    out_.clear();
    return S_OK;
  }

  // Whether a pixel is as it was shown: each channel within 3 (what decoding the recording again leaves on a still
  // picture is no change; what was shown is kept to be told from, so no drift adds up unshown).
  static bool same(uint32_t a, uint32_t b) {
    if (a == b) return true;
    const int dr = (int)((a >> 16) & 0xFF) - (int)((b >> 16) & 0xFF), dg = (int)((a >> 8) & 0xFF) - (int)((b >> 8) & 0xFF),
              db = (int)(a & 0xFF) - (int)(b & 0xFF);
    return dr <= 3 && dr >= -3 && dg <= 3 && dg >= -3 && db <= 3 && db >= -3;
  }

  static uint32_t bin_of(uint32_t c) { return ((c >> 18) & 0x3F) << 12 | ((c >> 10) & 0x3F) << 6 | ((c >> 2) & 0x3F); }

  // The frame's box (x, y, w, h) made ready: its table and its pixels, waiting for its delay.
  void frame(int bx, int by, int bw, int bh) {
    const bool first = !shown_;
    // the changed pixels' colours, binned
    if (bins_.empty()) bins_.assign(1 << 18, -1);
    colors_.clear();
    bool unchanged = false;
    for (int y = by; y < by + bh; y++) {
      const uint32_t *c = &cur_[(size_t)y * w_], *l = &last_[(size_t)y * w_];
      for (int x = bx; x < bx + bw; x++) {
        if (!first && same(c[x], l[x])) {
          unchanged = true;
          continue;
        }
        const uint32_t b = bin_of(c[x]);
        int32_t &k = bins_[b];
        if (k < 0) {
          k = (int32_t)colors_.size();
          colors_.push_back({0, 0, 0, 0, b});
        }
        Color &e = colors_[k];
        e.r += (c[x] >> 16) & 0xFF;
        e.g += (c[x] >> 8) & 0xFF;
        e.b += c[x] & 0xFF;
        e.count++;
      }
    }
    const size_t room = unchanged ? 255 : 256;
    std::vector<uint32_t> table;  // 0xRRGGBB
    std::vector<uint8_t> index_of_color(colors_.size());
    if (colors_.size() <= room) {
      for (size_t i = 0; i < colors_.size(); i++) {
        const Color &e = colors_[i];
        table.push_back(mean(e.r, e.count) << 16 | mean(e.g, e.count) << 8 | mean(e.b, e.count));
        index_of_color[i] = (uint8_t)i;
      }
    } else {
      median_cut(room, table);
      // each bin to the nearest of the table
      for (size_t i = 0; i < colors_.size(); i++) {
        const Color &e = colors_[i];
        const int r = (int)mean(e.r, e.count), g = (int)mean(e.g, e.count), b = (int)mean(e.b, e.count);
        int best = 0, bestd = INT_MAX;
        for (size_t k = 0; k < table.size(); k++) {
          const int dr = r - (int)(table[k] >> 16), dg = g - (int)((table[k] >> 8) & 0xFF), db = b - (int)(table[k] & 0xFF);
          const int d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
          if (d < bestd) {
            bestd = d;
            best = (int)k;
          }
        }
        index_of_color[i] = (uint8_t)best;
      }
    }
    // where it is dithered (a table that could not hold every colour): 16 x 16 blocks of the box that are smooth
    const bool dither = colors_.size() > room;
    const int bw16 = (bw + 15) / 16, bh16 = (bh + 15) / 16;
    if (dither) {
      smooth_.assign((size_t)bw16 * bh16, 0);
      for (int j = 0; j < bh16; j++)
        for (int i = 0; i < bw16; i++) smooth_[(size_t)j * bw16 + i] = gif_smooth(bx + i * 16, by + j * 16, std::min(16, bw - i * 16), std::min(16, bh - j * 16), first) ? 1 : 0;
      if (near_.empty()) near_.assign(1 << 18, -1);
    }
    const int transparent = unchanged ? (int)table.size() : -1;
    int bits = 1;
    while ((1u << bits) < table.size() + (unchanged ? 1 : 0)) bits++;
    // its pixels as indices; what is shown now kept for the next frame to be told from
    indices_.resize((size_t)bw * bh);
    size_t n = 0;
    for (int y = by; y < by + bh; y++) {
      const uint32_t *c = &cur_[(size_t)y * w_];
      uint32_t *l = &last_[(size_t)y * w_];
      for (int x = bx; x < bx + bw; x++) {
        if (!first && same(c[x], l[x])) {
          indices_[n++] = (uint8_t)transparent;
        } else {
          if (dither && smooth_[(size_t)((y - by) / 16) * bw16 + (x - bx) / 16]) {
            indices_[n++] = ordered(c[x], x, y, table);
          } else {
            indices_[n++] = index_of_color[bins_[bin_of(c[x])]];
          }
          l[x] = c[x];
        }
      }
    }
    for (const Color &e : colors_) bins_[e.bin] = -1;
    for (uint32_t b : near_used_) near_[b] = -1;
    near_used_.clear();
    // the image: its place, its table, its LZW
    const uint8_t desc[] = {0x2C, (uint8_t)bx, (uint8_t)(bx >> 8), (uint8_t)by, (uint8_t)(by >> 8), (uint8_t)bw, (uint8_t)(bw >> 8),
                            (uint8_t)bh, (uint8_t)(bh >> 8), (uint8_t)(0x80 | (bits - 1))};
    pending_.assign(desc, desc + sizeof desc);
    for (size_t k = 0; k < (1u << bits); k++) {
      const uint32_t c = k < table.size() ? table[k] : 0;
      pending_.push_back((uint8_t)(c >> 16));
      pending_.push_back((uint8_t)(c >> 8));
      pending_.push_back((uint8_t)c);
    }
    pending_transparent_ = transparent;
    lzw(std::max(2, bits));
  }

  static uint32_t mean(uint32_t sum, uint32_t count) { return count ? (sum + count / 2) / count : 0; }

  static int clamp255(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

  // Pixel `c` at (x, y) of a smooth block, dithered between the two colours of the table on either side of it: the
  // nearest, and the nearest to `c` mirrored through it (2c - nearest); the other one taken where the 4 x 4 Bayer
  // threshold at (x, y) is under how far `c` lies from the nearest towards it (0 at the nearest, 1 at the other), so
  // the two mix in proportion and a gradient is not cut into bands. One within 3 of its nearest in each channel (as
  // good as exact) is that one: a flat colour stays flat.
  uint8_t ordered(uint32_t c, int x, int y, const std::vector<uint32_t> &table) {
    static const int bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
    const uint8_t a = nearest(c, table);
    const int v[3] = {(int)((c >> 16) & 0xFF), (int)((c >> 8) & 0xFF), (int)(c & 0xFF)};
    const int p[3] = {(int)(table[a] >> 16), (int)((table[a] >> 8) & 0xFF), (int)(table[a] & 0xFF)};
    const int e[3] = {v[0] - p[0], v[1] - p[1], v[2] - p[2]};
    if (std::abs(e[0]) <= 3 && std::abs(e[1]) <= 3 && std::abs(e[2]) <= 3) return a;
    const uint32_t mirror = (uint32_t)clamp255(v[0] + e[0]) << 16 | (uint32_t)clamp255(v[1] + e[1]) << 8 | (uint32_t)clamp255(v[2] + e[2]);
    const uint8_t b = nearest(mirror, table);
    if (b == a) return a;
    const int q[3] = {(int)(table[b] >> 16), (int)((table[b] >> 8) & 0xFF), (int)(table[b] & 0xFF)};
    const double s[3] = {(double)(q[0] - p[0]), (double)(q[1] - p[1]), (double)(q[2] - p[2])};
    const double len = s[0] * s[0] + s[1] * s[1] + s[2] * s[2];
    const double along = len > 0 ? (e[0] * s[0] + e[1] * s[1] + e[2] * s[2]) / len : 0;
    const double threshold = (bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0;
    return along > threshold ? b : a;
  }

  // The table's colour nearest `c` (0xRRGGBB), by its 6-bit bin, found once a frame (near_).
  uint8_t nearest(uint32_t c, const std::vector<uint32_t> &table) {
    const uint32_t b = bin_of(c);
    if (near_[b] >= 0) return (uint8_t)near_[b];
    const int r = (int)((c >> 16) & 0xFF), g = (int)((c >> 8) & 0xFF), bl = (int)(c & 0xFF);
    int best = 0, bestd = INT_MAX;
    for (size_t k = 0; k < table.size(); k++) {
      const int dr = r - (int)(table[k] >> 16), dg = g - (int)((table[k] >> 8) & 0xFF), db = bl - (int)(table[k] & 0xFF);
      const int d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
      if (d < bestd) {
        bestd = d;
        best = (int)k;
      }
    }
    near_[b] = best;
    near_used_.push_back(b);
    return (uint8_t)best;
  }

  // Whether the block at (x, y), w x h, of the frame is a smooth gradient: its changed pixels many and varying (a channel
  // spanning 10 or more across it: not one flat colour with the recording's noise on it) by small steps alone (no pixel more than 8 off the one beside
  // it or above it, in any channel: no edge, no type), and with at least 6 colours of the 6-bit bins (not two flat
  // colours meeting). Flat UI, type and pictures with edges come out false and are not dithered.
  bool gif_smooth(int x0, int y0, int w, int h, bool first) const {
    int lo[3] = {255, 255, 255}, hi[3] = {0, 0, 0};
    int count = 0;
    uint32_t seen[8];
    int distinct = 0;
    for (int y = y0; y < y0 + h; y++) {
      const uint32_t *c = &cur_[(size_t)y * w_], *l = &last_[(size_t)y * w_];
      for (int x = x0; x < x0 + w; x++) {
        if (!first && same(c[x], l[x])) continue;
        count++;
        const int v[3] = {(int)((c[x] >> 16) & 0xFF), (int)((c[x] >> 8) & 0xFF), (int)(c[x] & 0xFF)};
        for (int k = 0; k < 3; k++) {
          lo[k] = std::min(lo[k], v[k]);
          hi[k] = std::max(hi[k], v[k]);
        }
        // (a step to the pixel before it, across and down)
        const uint32_t nb[2] = {x > x0 ? c[x - 1] : c[x], y > y0 ? c[x - w_] : c[x]};
        for (uint32_t m : nb) {
          const int dr = (int)((m >> 16) & 0xFF) - v[0], dg = (int)((m >> 8) & 0xFF) - v[1], db = (int)(m & 0xFF) - v[2];
          if (dr > 8 || dr < -8 || dg > 8 || dg < -8 || db > 8 || db < -8) return false;
        }
        if (distinct < 8) {
          const uint32_t b = bin_of(c[x]);
          bool have = false;
          for (int i = 0; i < distinct; i++) have = have || seen[i] == b;
          if (!have) seen[distinct++] = b;
        }
      }
    }
    if (count < w * h / 2) return false;
    const int span = std::max(hi[0] - lo[0], std::max(hi[1] - lo[1], hi[2] - lo[2]));
    return span >= 10 && distinct >= 6;
  }

  // `room` colours for colors_: the box that is furthest from its own colour (measure) cut in two at its median along
  // its longest side, till there are as many boxes as colours; each box's colour its pixels' mean.
  void median_cut(size_t room, std::vector<uint32_t> &table) {
    std::vector<Box> boxes;
    // a box's error: how far its pixels are from its colour, squared and added up (a few pixels of a colour far from
    // the rest, a line of coloured type among grey, weigh as much as many a little off)
    auto measure = [&](size_t from, size_t to) {
      uint64_t count = 0, sum[3] = {0, 0, 0};
      for (size_t i = from; i < to; i++) {
        const Color &e = colors_[i];
        sum[0] += e.r;
        sum[1] += e.g;
        sum[2] += e.b;
        count += e.count;
      }
      if (to - from < 2 || count == 0) return Box{from, to, count, 0};
      const double m[3] = {(double)sum[0] / count, (double)sum[1] / count, (double)sum[2] / count};
      double error = 0;
      for (size_t i = from; i < to; i++) {
        const Color &e = colors_[i];
        const double d[3] = {(double)e.r / e.count - m[0], (double)e.g / e.count - m[1], (double)e.b / e.count - m[2]};
        error += e.count * (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
      }
      return Box{from, to, count, (uint64_t)error};
    };
    boxes.push_back(measure(0, colors_.size()));
    while (boxes.size() < room) {
      size_t pick = 0;
      for (size_t i = 1; i < boxes.size(); i++)
        if (boxes[i].score > boxes[pick].score) pick = i;
      Box b = boxes[pick];
      if (b.score == 0) break;
      // its longest side
      uint32_t lo[3] = {255, 255, 255}, hi[3] = {0, 0, 0};
      for (size_t i = b.from; i < b.to; i++) {
        const Color &e = colors_[i];
        const uint32_t v[3] = {mean(e.r, e.count), mean(e.g, e.count), mean(e.b, e.count)};
        for (int k = 0; k < 3; k++) {
          lo[k] = std::min(lo[k], v[k]);
          hi[k] = std::max(hi[k], v[k]);
        }
      }
      int axis = 0;
      for (int k = 1; k < 3; k++)
        if (hi[k] - lo[k] > hi[axis] - lo[axis]) axis = k;
      std::sort(colors_.begin() + b.from, colors_.begin() + b.to, [axis](const Color &a, const Color &c) {
        const uint32_t va = axis == 0 ? mean(a.r, a.count) : axis == 1 ? mean(a.g, a.count) : mean(a.b, a.count);
        const uint32_t vc = axis == 0 ? mean(c.r, c.count) : axis == 1 ? mean(c.g, c.count) : mean(c.b, c.count);
        return va < vc;
      });
      uint64_t half = 0;
      size_t cut = b.from + 1;
      for (size_t i = b.from; i < b.to - 1; i++) {
        half += colors_[i].count;
        cut = i + 1;
        if (half * 2 >= b.count) break;
      }
      boxes[pick] = measure(b.from, cut);
      boxes.push_back(measure(cut, b.to));
    }
    // (the bins were moved by the sorting: found again)
    for (size_t i = 0; i < colors_.size(); i++) bins_[colors_[i].bin] = (int32_t)i;
    for (const Box &b : boxes) {
      uint64_t r = 0, g = 0, bl = 0, n = 0;
      for (size_t i = b.from; i < b.to; i++) {
        r += colors_[i].r;
        g += colors_[i].g;
        bl += colors_[i].b;
        n += colors_[i].count;
      }
      if (n == 0) n = 1;
      table.push_back((uint32_t)((r + n / 2) / n) << 16 | (uint32_t)((g + n / 2) / n) << 8 | (uint32_t)((bl + n / 2) / n));
    }
  }

  // indices_ compressed (GIF's LZW, codes up to 12 bits, the table cleared when full) into pending_'s sub-blocks.
  void lzw(int min_bits) {
    pending_.push_back((uint8_t)min_bits);
    const int clear = 1 << min_bits, eoi = clear + 1;
    int bits = min_bits + 1, next = eoi + 1, top = (1 << bits) - 1;
    bool cleared = false;
    static const int kSlots = 8192;
    if (keys_.empty()) {
      keys_.assign(kSlots, -1);
      codes_.assign(kSlots, 0);
    }
    std::fill(keys_.begin(), keys_.end(), -1);
    std::vector<uint8_t> data;
    uint32_t acc = 0;
    int held = 0;
    auto put = [&](int code) {
      acc |= (uint32_t)code << held;
      held += bits;
      while (held >= 8) {
        data.push_back((uint8_t)acc);
        acc >>= 8;
        held -= 8;
      }
      // (the width grows as the decoder's will: once the code just made no longer fits)
      if (cleared) {
        bits = min_bits + 1;
        top = (1 << bits) - 1;
        cleared = false;
      } else if (next > top && bits < 12) {
        bits++;
        top = bits == 12 ? 4096 : (1 << bits) - 1;
      }
    };
    put(clear);
    const size_t n = indices_.size();
    int prefix = n ? indices_[0] : 0;
    for (size_t i = 1; i < n; i++) {
      const int c = indices_[i];
      const int key = (prefix << 8) | c;
      int slot = (int)(((uint32_t)key * 2654435761u) >> 19) & (kSlots - 1);
      while (keys_[slot] >= 0 && keys_[slot] != key) slot = (slot + 1) & (kSlots - 1);
      if (keys_[slot] == key) {
        prefix = codes_[slot];
        continue;
      }
      put(prefix);
      if (next < 4096) {
        keys_[slot] = key;
        codes_[slot] = (int16_t)next++;
      } else {
        std::fill(keys_.begin(), keys_.end(), -1);
        next = eoi + 1;
        cleared = true;
        put(clear);
      }
      prefix = c;
    }
    put(prefix);
    put(eoi);
    if (held > 0) data.push_back((uint8_t)acc);
    for (size_t at = 0; at < data.size(); at += 255) {
      const size_t k = std::min<size_t>(255, data.size() - at);
      pending_.push_back((uint8_t)k);
      pending_.insert(pending_.end(), data.begin() + at, data.begin() + at + k);
    }
    pending_.push_back(0);
  }

  HANDLE file_ = INVALID_HANDLE_VALUE;
  int w_ = 0, h_ = 0;
  bool shown_ = false;
  std::vector<uint32_t> last_, cur_;
  std::vector<int32_t> bins_;
  // a frame's: each 16 x 16 block of its box smooth (dithered) or not; the table's nearest colour to each bin asked
  std::vector<uint8_t> smooth_;
  std::vector<int32_t> near_;
  std::vector<uint32_t> near_used_;
  std::vector<Color> colors_;
  std::vector<uint8_t> indices_;
  std::vector<int32_t> keys_;
  std::vector<int16_t> codes_;
  std::vector<uint8_t> out_, pending_;
  LONGLONG pending_at_ = 0;
  int pending_transparent_ = -1;
  uint64_t first_bytes_ = 0, later_bytes_ = 0, frames_ = 0;
};


// An AV1 MP4 told its picture's size. NVIDIA's AV1 encoder (2026-11-14, RTX 5080) declares 1920x1088 as its sequence's
// largest frame whatever the picture and codes each frame at its own size; the sink writer copies that into the av01
// entry. Windows' AV1 decoder then decodes nothing of a window's 820x664 clip (no thumbnail, no playback in its apps)
// and a 1080p one as 1088 rows; ffmpeg shows them squeezed or 0.7% wide. So each sequence header (the av1C's, and the
// one in each keyframe) has its largest frame written over with the picture's size, in the bits it already takes (a
// smaller size fits them), and the entry's width and height with it.
class Av1Sized {
 public:
  Av1Sized(HANDLE f, int w, int h) : f_(f), w_(w), h_(h) {}

  HRESULT run() {
    LARGE_INTEGER size{};
    GetFileSizeEx(f_, &size);
    walk(0, (uint64_t)size.QuadPart);
    return hr_;
  }

 private:
  struct Box {
    char type[5];
    uint64_t start, body, end;
  };

  bool read(uint64_t at, void *to, DWORD n) {
    LARGE_INTEGER p;
    p.QuadPart = (LONGLONG)at;
    DWORD got = 0;
    return SetFilePointerEx(f_, p, nullptr, FILE_BEGIN) && ReadFile(f_, to, n, &got, nullptr) && got == n;
  }

  void write(uint64_t at, const void *from, DWORD n) {
    LARGE_INTEGER p;
    p.QuadPart = (LONGLONG)at;
    DWORD put = 0;
    if (!SetFilePointerEx(f_, p, nullptr, FILE_BEGIN) || !WriteFile(f_, from, n, &put, nullptr)) hr_ = HRESULT_FROM_WIN32(GetLastError());
  }

  static uint32_t be32(const uint8_t *b) { return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; }

  std::vector<Box> boxes(uint64_t s, uint64_t e) {
    std::vector<Box> out;
    for (uint64_t at = s; at + 8 <= e;) {
      uint8_t h[16] = {};
      if (!read(at, h, at + 16 <= e ? 16 : 8)) break;
      uint64_t n = be32(h), head = 8;
      if (n == 1) {
        n = (uint64_t)be32(h + 8) << 32 | be32(h + 12);
        head = 16;
      } else if (n == 0) {
        n = e - at;
      }
      if (n < head || at + n > e) break;
      Box b;
      memcpy(b.type, h + 4, 4);
      b.type[4] = 0;
      b.start = at;
      b.body = at + head;
      b.end = at + n;
      out.push_back(b);
      at += n;
    }
    return out;
  }

  const Box *find(const std::vector<Box> &in, const char *type) {
    for (const Box &b : in)
      if (strcmp(b.type, type) == 0) return &b;
    return nullptr;
  }

  // moov, then each trak's stbl whose first entry is av01
  void walk(uint64_t s, uint64_t e) {
    const auto top = boxes(s, e);
    const Box *moov = find(top, "moov");
    if (!moov) return;
    for (const Box &trak : boxes(moov->body, moov->end)) {
      if (strcmp(trak.type, "trak") != 0) continue;
      const auto t = boxes(trak.body, trak.end);
      const Box *mdia = find(t, "mdia");
      if (!mdia) continue;
      const auto m = boxes(mdia->body, mdia->end);
      const Box *minf = find(m, "minf");
      if (!minf) continue;
      const auto mi = boxes(minf->body, minf->end);
      const Box *stbl = find(mi, "stbl");
      if (stbl) track(boxes(stbl->body, stbl->end));
    }
  }

  void track(const std::vector<Box> &stbl) {
    const Box *stsd = find(stbl, "stsd");
    if (!stsd) return;
    const auto entries = boxes(stsd->body + 8, stsd->end);
    if (entries.empty() || strcmp(entries[0].type, "av01") != 0) return;
    const Box &av01 = entries[0];
    const uint8_t wh[4] = {(uint8_t)(w_ >> 8), (uint8_t)w_, (uint8_t)(h_ >> 8), (uint8_t)h_};
    write(av01.body + 24, wh, 4);
    // the av1C's config OBUs (after its 4 bytes)
    if (const Box *c = find(boxes(av01.body + 78, av01.end), "av1C")) in_place(c->body + 4, c->end - c->body - 4);
    // each keyframe's OBUs: where the sample tables put it
    const Box *stsz = find(stbl, "stsz"), *stsc = find(stbl, "stsc"), *stss = find(stbl, "stss");
    const Box *stco = find(stbl, "stco"), *co64 = find(stbl, "co64");
    if (!stsz || !stsc || !stss || !(stco || co64)) return;
    std::vector<uint8_t> z(stsz->end - stsz->body), c((stco ? stco : co64)->end - (stco ? stco : co64)->body);
    std::vector<uint8_t> r(stsc->end - stsc->body), k(stss->end - stss->body);
    if (!read(stsz->body, z.data(), (DWORD)z.size()) || !read((stco ? stco : co64)->body, c.data(), (DWORD)c.size()) ||
        !read(stsc->body, r.data(), (DWORD)r.size()) || !read(stss->body, k.data(), (DWORD)k.size()))
      return;
    const uint32_t fixed = be32(&z[4]), count = be32(&z[8]);
    const uint32_t chunks = be32(&c[4]), runs = be32(&r[4]), keys = be32(&k[4]);
    std::vector<uint64_t> at(count, 0);
    std::vector<uint32_t> size(count, fixed);
    if (!fixed)
      for (uint32_t i = 0; i < count && 12 + 4 * (size_t)i + 4 <= z.size(); i++) size[i] = be32(&z[12 + 4 * i]);
    uint32_t n = 0;
    for (uint32_t i = 0; i < runs && 8 + 12 * (size_t)i + 12 <= r.size(); i++) {
      const uint32_t first = be32(&r[8 + 12 * i]) - 1, per = be32(&r[12 + 12 * i]);
      const uint32_t last = i + 1 < runs ? be32(&r[8 + 12 * (i + 1)]) - 1 : chunks;
      for (uint32_t ch = first; ch < last && ch < chunks; ch++) {
        uint64_t place = stco ? be32(&c[8 + 4 * ch]) : ((uint64_t)be32(&c[8 + 8 * ch]) << 32 | be32(&c[12 + 8 * ch]));
        for (uint32_t j = 0; j < per && n < count; j++, n++) {
          at[n] = place;
          place += size[n];
        }
      }
    }
    for (uint32_t i = 0; i < keys && 8 + 4 * (size_t)i + 4 <= k.size(); i++) {
      const uint32_t s = be32(&k[8 + 4 * i]) - 1;
      if (s < n) in_place(at[s], size[s]);
    }
  }

  // The OBUs at [at, at + n) read, each sequence header's largest frame written over, and written back.
  void in_place(uint64_t at, uint64_t n) {
    if (n == 0 || n > (64u << 20)) return;
    std::vector<uint8_t> b((size_t)n);
    if (!read(at, b.data(), (DWORD)n)) return;
    bool changed = false;
    for (size_t p = 0; p < b.size();) {
      const uint8_t h = b[p];
      const int type = (h >> 3) & 15, ext = (h >> 2) & 1, has_size = (h >> 1) & 1;
      size_t q = p + 1 + ext, len = 0;
      if (has_size) {
        for (int i = 0; q < b.size(); i++) {
          const uint8_t x = b[q++];
          len |= (size_t)(x & 0x7F) << (7 * i);
          if (!(x & 0x80)) break;
        }
      } else {
        len = b.size() - q;
      }
      if (q + len > b.size()) break;
      if (type == 1) changed |= sequence(b.data() + q, len);
      p = q + len;
    }
    if (changed) write(at, b.data(), (DWORD)n);
  }

  // A sequence header (AV1 5.5.1) read up to its largest frame's size, that written over.
  bool sequence(uint8_t *b, size_t n) {
    size_t at = 0;
    auto f = [&](int bits) {
      uint32_t v = 0;
      for (int i = 0; i < bits; i++, at++) v = v << 1 | (at < n * 8 ? (b[at >> 3] >> (7 - (at & 7))) & 1 : 0);
      return v;
    };
    f(3);
    f(1);
    if (f(1)) {
      f(5);
    } else {
      bool model = false;
      int delay_bits = 0;
      if (f(1)) {
        f(32);
        f(32);
        if (f(1)) {
          int zeros = 0;
          while (!f(1) && zeros < 32) zeros++;
          f(zeros);
        }
        model = f(1) != 0;
        if (model) {
          delay_bits = (int)f(5) + 1;
          f(32);
          f(5);
          f(5);
        }
      }
      const bool display = f(1) != 0;
      const int points = (int)f(5) + 1;
      for (int i = 0; i < points; i++) {
        f(12);
        if (f(5) > 7) f(1);
        if (model && f(1)) {
          f(delay_bits);
          f(delay_bits);
          f(1);
        }
        if (display && f(1)) f(4);
      }
    }
    const int wb = (int)f(4) + 1, hb = (int)f(4) + 1;
    if (at + wb + hb > n * 8 || w_ - 1 >= (1 << wb) || h_ - 1 >= (1 << hb)) return false;
    auto put = [&](int bits, uint32_t v) {
      for (int i = bits - 1; i >= 0; i--, at++) {
        const uint8_t m = (uint8_t)(1 << (7 - (at & 7)));
        if ((v >> i) & 1) b[at >> 3] |= m;
        else b[at >> 3] &= (uint8_t)~m;
      }
    };
    put(wb, (uint32_t)w_ - 1);
    put(hb, (uint32_t)h_ - 1);
    return true;
  }

  HANDLE f_;
  int w_, h_;
  HRESULT hr_ = S_OK;
};

HRESULT av1_sized(const std::wstring &path, int width, int height) {
  HANDLE f = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
  HRESULT hr = Av1Sized(f, width, height).run();
  CloseHandle(f);
  return hr;
}

// Rename HEVC sample entry 'hev1' to 'hvc1' in place so exported MP4s play in QuickTime, Safari, and iOS.
void hevc_hvc1(const std::wstring &path) {
  HANDLE f = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  auto be32 = [](const uint8_t *b) -> uint32_t { return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; };
  auto read_box = [&](uint64_t off, uint64_t limit, uint64_t &body, uint64_t &end, char type[4]) -> bool {
    if (off + 8 > limit) return false;
    LARGE_INTEGER p;
    p.QuadPart = (LONGLONG)off;
    uint8_t h[16] = {};
    DWORD got = 0;
    const DWORD want = (DWORD)std::min<uint64_t>(16, limit - off);
    if (!SetFilePointerEx(f, p, nullptr, FILE_BEGIN) || !ReadFile(f, h, want, &got, nullptr) || got < 8) return false;
    uint64_t n = be32(h), head = 8;
    if (n == 1) {
      if (got < 16) return false;
      n = (uint64_t)be32(h + 8) << 32 | be32(h + 12);
      head = 16;
    } else if (n == 0) {
      n = limit - off;
    }
    if (n < head || off + n > limit) return false;
    memcpy(type, h + 4, 4);
    body = off + head;
    end = off + n;
    return true;
  };
  auto find_child = [&](uint64_t from, uint64_t limit, const char want[4], uint64_t &body, uint64_t &end) -> bool {
    char ty[4];
    for (uint64_t off = from; read_box(off, limit, body, end, ty); off = end) {
      if (memcmp(ty, want, 4) == 0) return true;
    }
    return false;
  };
  LARGE_INTEGER fsz{};
  uint64_t moov_b = 0, moov_e = 0;
  if (GetFileSizeEx(f, &fsz) && fsz.QuadPart >= 16 && find_child(0, (uint64_t)fsz.QuadPart, "moov", moov_b, moov_e)) {
    uint64_t tb = 0, te = 0;
    char ty[4];
    for (uint64_t off = moov_b; read_box(off, moov_e, tb, te, ty); off = te) {
      if (memcmp(ty, "trak", 4) != 0) continue;
      uint64_t mb, me, nb, ne, sb, se, db, de, eb, ee;
      if (!find_child(tb, te, "mdia", mb, me)) continue;
      if (!find_child(mb, me, "minf", nb, ne)) continue;
      if (!find_child(nb, ne, "stbl", sb, se)) continue;
      if (!find_child(sb, se, "stsd", db, de)) continue;
      if (db + 8 >= de) continue;
      if (!read_box(db + 8, de, eb, ee, ty)) continue;
      if (memcmp(ty, "hev1", 4) == 0) {
        LARGE_INTEGER at;
        at.QuadPart = (LONGLONG)(db + 8 + 4);
        DWORD put = 0;
        if (SetFilePointerEx(f, at, nullptr, FILE_BEGIN)) WriteFile(f, "hvc1", 4, &put, nullptr);
      }
    }
  }
  CloseHandle(f);
}

struct ScopedTimerPeriod {
  bool active = false;
  ScopedTimerPeriod() { active = timeBeginPeriod(1) == TIMERR_NOERROR; }
  ~ScopedTimerPeriod() { if (active) timeEndPeriod(1); }
};

// Whether any of the job's segments has sound. The clip's file gets a sound track only where one does: a track given no
// samples fails the file as it is finished (MF_E_SINK_NO_SAMPLES_PROCESSED, 0xC00D4A3E: a recording made with its
// sound off could not be saved encoded again, 2026-11-17).
bool any_sound(const Job &job) {
  for (const auto &part : job.parts) {
    ComPtr<IMFSourceReader> reader;
    if (FAILED(MFCreateSourceReaderFromURL(part.path.c_str(), nullptr, &reader))) continue;
    ComPtr<IMFMediaType> native;
    if (SUCCEEDED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &native))) return true;
  }
  return false;
}

// Where the file is written till it is whole (then given its name).
std::wstring partial_of(const Job &job) { return job.output + (job.codec == kGif ? L".partial.gif" : L".partial.mp4"); }

// The job done: its file written, its progress told to `told`, stopped as `stop` is set. `count`: a GIF only counted,
// nothing written (the estimate's sample).
// The Direct3D device a run decodes, crops and encodes on, and its manager for Media Foundation: made for each run,
// or once for all of an estimate's samples (they were made and let go 8 times over for one estimate).
struct ExportDevice {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IMFDXGIDeviceManager> manager;

  HRESULT make() {
    if (manager) return S_OK;
    D3D_FEATURE_LEVEL level;
    CHECK(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                            nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context));
    ComPtr<ID3D10Multithread> mt;
    if (SUCCEEDED(device.As(&mt))) mt->SetMultithreadProtected(TRUE);
    UINT token = 0;
    CHECK(MFCreateDXGIDeviceManager(&token, &manager));
    HRESULT hr = manager->ResetDevice(device.Get(), token);
    if (FAILED(hr)) manager.Reset();
    return hr;
  }
};

HRESULT run(Job job, const std::atomic<bool> &stop, std::atomic<double> &told, Gif *count = nullptr,
            ExportDevice *shared = nullptr) {
  ExportDevice own_device;
  ExportDevice &made = shared ? *shared : own_device;
  CHECK(made.make());
  ScopedTimerPeriod timer_period;
  ComPtr<ID3D11Device> device = made.device;
  ComPtr<ID3D11DeviceContext> context = made.context;
  ComPtr<IMFDXGIDeviceManager> manager = made.manager;
  GpuCropper gpu_crop;
  gpu_crop.init(device.Get(), context.Get());

  const bool gif = job.codec == kGif;
  const bool sound = !gif && any_sound(job);
  const std::wstring partial = partial_of(job);
  Gif own;
  Gif &animation = count ? *count : own;
  ComPtr<IMFSinkWriter> writer;
  DWORD vout = 0, aout = 0;
  ComPtr<IMFMediaType> ai;
  if (gif) {
    if (!count) CHECK(animation.open(partial, job.width, job.height));
  } else {
    ComPtr<IMFAttributes> wattrs;
    CHECK(MFCreateAttributes(&wattrs, 3));
    wattrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    wattrs->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, manager.Get());
    CHECK(MFCreateSinkWriterFromURL(partial.c_str(), nullptr, wattrs.Get(), &writer));
    ComPtr<IMFMediaType> vo, vi, ao;
    CHECK(video_output_type(job, &vo));
    CHECK(writer->AddStream(vo.Get(), &vout));
    CHECK(video_input_type(job, &vi));
    if (!job.crops.empty()) vi->SetUINT32(MF_MT_DEFAULT_STRIDE, (UINT32)(job.width * 4));
    HRESULT set = E_FAIL;
    for (int level = 0; level < 4 && FAILED(set); level++) {
      ComPtr<IMFAttributes> p;
      CHECK(encoding_parameters(job, level, &p));
      set = writer->SetInputMediaType(vout, vi.Get(), p.Get());
    }
    CHECK(set);
    if (sound) {
      CHECK(aac_type(&ao));
      CHECK(writer->AddStream(ao.Get(), &aout));
      CHECK(pcm_type(&ai));
      CHECK(writer->SetInputMediaType(aout, ai.Get(), nullptr));
    }
    CHECK(writer->BeginWriting());
  }

  LONGLONG done = 0;
  const LONGLONG frame = 10000000LL / job.fps;
  // the first moment the rate lets a frame be written at, and the frame held till then
  LONGLONG next_video = LLONG_MIN;
  ComPtr<IMFSample> held;
  // a frame written, shown from `t`
  auto put = [&](IMFSample *sample, LONGLONG t) -> HRESULT {
    ComPtr<IMFSample> f = sample;
    if (!job.crops.empty()) {
      f.Reset();
      if (FAILED(gpu_crop.crop(job, sample, t, &f))) CHECK(cropped(job, sample, t, &f));
    }
    if (gif) {
      CHECK(with_pixels(gpu_crop, f.Get(), job.width, [&](const BYTE *px, LONG pitch) { return animation.add(px, pitch, t); }));
    } else {
      f->SetSampleTime(t);
      f->SetSampleDuration(frame);
      CHECK(writer->WriteSample(vout, f.Get()));
    }
    next_video = t + frame - frame / 10;
    done = std::max(done, t);
    told.store(std::min(0.99, (double)done / (double)job.total));
    return S_OK;
  };
  // a frame shown from `t`: written, or held while it is too soon after the last (one held is written where the rate
  // allows when it showed there for half a frame or more; less, this one takes its place)
  auto offer = [&](IMFSample *sample, LONGLONG t) -> HRESULT {
    if (held && t >= next_video) {
      if (t - next_video >= frame / 2) CHECK(put(held.Get(), next_video));
      held.Reset();
    }
    if (t >= next_video) return put(sample, t);
    held = sample;
    return S_OK;
  };
  for (const auto &part : job.parts) {
    ComPtr<IMFAttributes> rattrs;
    CHECK(MFCreateAttributes(&rattrs, 3));
    rattrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, manager.Get());
    rattrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    rattrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    ComPtr<IMFSourceReader> reader;
    CHECK(MFCreateSourceReaderFromURL(part.path.c_str(), rattrs.Get(), &reader));
    if (job.crops.empty()) {
      ComPtr<IMFMediaType> want;
      CHECK(MFCreateMediaType(&want));
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
      MFSetAttributeSize(want.Get(), MF_MT_FRAME_SIZE, job.width, job.height);
      CHECK(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want.Get()));
    } else {
      UINT32 w = 0, h = 0;
      job.bt601 = job.full = 0;
      ComPtr<IMFMediaType> nat;
      if (SUCCEEDED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &nat))) {
        MFGetAttributeSize(nat.Get(), MF_MT_FRAME_SIZE, &w, &h);
        MFVideoArea area{};
        UINT32 cb = 0;
        if ((SUCCEEDED(nat->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area, &cb)) ||
             SUCCEEDED(nat->GetBlob(MF_MT_GEOMETRIC_APERTURE, (UINT8 *)&area, sizeof area, &cb))) &&
            cb == sizeof area && area.Area.cx > 0 && area.Area.cy > 0) {
          w = (UINT32)area.Area.cx;
          h = (UINT32)area.Area.cy;
        }
        UINT32 m = 0, r = 0;
        job.bt601 = SUCCEEDED(nat->GetUINT32(MF_MT_YUV_MATRIX, &m)) && m == MFVideoTransferMatrix_BT601;
        job.full = SUCCEEDED(nat->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &r)) && r == MFNominalRange_0_255;
      }
      ComPtr<IMFMediaType> want;
      CHECK(MFCreateMediaType(&want));
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
      if (SUCCEEDED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want.Get()))) {
        if (w == 0 || h == 0) {
          ComPtr<IMFMediaType> got;
          if (SUCCEEDED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got)))
            MFGetAttributeSize(got.Get(), MF_MT_FRAME_SIZE, &w, &h);
        }
        job.srcWidth = (int)w;
        job.srcHeight = (int)h;
      } else {
        want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
        CHECK(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want.Get()));
        ComPtr<IMFMediaType> got;
        CHECK(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &got));
        MFGetAttributeSize(got.Get(), MF_MT_FRAME_SIZE, &w, &h);
        if (job.scale < 1.0) {
          w = (UINT32)(w * job.scale + 0.5) & ~1u;
          h = (UINT32)(h * job.scale + 0.5) & ~1u;
          MFSetAttributeSize(want.Get(), MF_MT_FRAME_SIZE, w, h);
          CHECK(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, want.Get()));
        }
        job.srcWidth = (int)w;
        job.srcHeight = (int)h;
      }
    }
    bool audio = sound && SUCCEEDED(reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, ai.Get()));
    if (!audio) reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, FALSE);
    if (part.trim > 0) {
      PROPVARIANT at;
      PropVariantInit(&at);
      at.vt = VT_I8;
      at.hVal.QuadPart = part.trim;
      reader->SetCurrentPosition(GUID_NULL, at);
    }
    bool video_done = false, audio_done = !audio;
    // the picture showing as the clip starts: the last frame before its start, written at its start (a screen
    // that did not change has no frame of its own there)
    ComPtr<IMFSample> before;
    while (!(video_done && audio_done)) {
      if (stop.load()) return E_ABORT;
      DWORD stream = 0, flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      CHECK(reader->ReadSample((DWORD)MF_SOURCE_READER_ANY_STREAM, 0, &stream, &flags, &ts, &sample));
      ComPtr<IMFMediaType> current;
      reader->GetCurrentMediaType(stream, &current);
      GUID major = GUID_NULL;
      if (current) current->GetGUID(MF_MT_MAJOR_TYPE, &major);
      const bool is_video = major == MFMediaType_Video;
      if (is_video && before && ((flags & MF_SOURCE_READERF_ENDOFSTREAM) || (sample && ts > part.end))) {
        CHECK(offer(before.Get(), part.offset));
        before.Reset();
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        if (is_video) video_done = true;
        else audio_done = true;
        continue;
      }
      if (!sample) continue;
      if (ts > part.end) {
        if (is_video) video_done = true;
        else audio_done = true;
        reader->SetStreamSelection(stream, FALSE);
        continue;
      }
      if (ts < part.trim) {
        if (is_video) before = sample;
        continue;
      }
      if (is_video && before) {
        CHECK(offer(before.Get(), part.offset));
        before.Reset();
      }
      const LONGLONG out = part.offset + (ts - part.trim);
      if (is_video) {
        CHECK(offer(sample.Get(), out));
      } else {
        sample->SetSampleTime(out);
        CHECK(writer->WriteSample(aout, sample.Get()));
      }
    }
    // a frame still held shows before the part ends: written at the first moment it may be
    if (held) {
      if (part.offset + (part.end - part.trim) - next_video >= frame / 2) CHECK(put(held.Get(), next_video));
      held.Reset();
    }
  }
  if (gif) {
    CHECK(animation.finish(job.total));
    if (count) return S_OK;
  } else {
    CHECK(writer->Finalize());
    writer.Reset();
    if (job.codec == kAv1) CHECK(av1_sized(partial, job.width, job.height));
    else if (job.codec == kHevc) hevc_hvc1(partial);
  }
  // (a new name, never an old clip's: the window made sure)
  if (!MoveFileExW(partial.c_str(), job.output.c_str(), MOVEFILE_WRITE_THROUGH)) return HRESULT_FROM_WIN32(GetLastError());
  return S_OK;
}

// The job the window asks for (rp_export_start's and rp_gif_estimate_start's words); false: nothing to do.
bool make_job(const char *plan, const char *crops, int width, int height, int fps, int bitrate, int codec, double scale, Job &job) {
  job.width = width & ~1;
  job.height = height & ~1;
  job.fps = fps > 0 ? fps : 30;
  job.bitrate = bitrate > 0 ? bitrate : 8000000;
  // (AV1 at a constant rate: given 2% under the dialog's, its file, sound and container with it, stays under what it
  // said, 15.4 MB for 15.6 on a busy screen's 30 s)
  if (codec == kAv1) job.bitrate = (int)((int64_t)job.bitrate * 98 / 100);
  job.codec = codec >= kH264 && codec <= kGif ? codec : kH264;
  job.scale = scale > 0.0 && scale < 1.0 ? scale : 1.0;
  for (const char *c = crops; *c;) {
    const char *nl = strchr(c, '\n');
    std::string line = nl ? std::string(c, nl - c) : std::string(c);
    c = nl ? nl + 1 : c + strlen(c);
    double at = 0, x = 0, y = 0, w = 0, h = 0;
    if (sscanf_s(line.c_str(), "%lf\t%lf\t%lf\t%lf\t%lf", &at, &x, &y, &w, &h) == 5 && w >= 0 && h >= 0)
      job.crops.push_back({(LONGLONG)(at * 10000.0), (int)(x * job.scale + 0.5), (int)(y * job.scale + 0.5), (int)(w * job.scale + 0.5),
                           (int)(h * job.scale + 0.5), (int)(x + 0.5), (int)(y + 0.5), (int)(w + 0.5), (int)(h + 0.5)});
  }
  const char *p = plan;
  LONGLONG last = 0;
  while (*p) {
    const char *nl = strchr(p, '\n');
    std::string line = nl ? std::string(p, nl - p) : std::string(p);
    p = nl ? nl + 1 : p + strlen(p);
    char path[2048];
    double off = 0, trim = 0, end = 0;
    if (sscanf_s(line.c_str(), "%2047[^\t]\t%lf\t%lf\t%lf", path, (unsigned)sizeof path, &off, &trim, &end) != 4) continue;
    Part part{wide(path), (LONGLONG)(off * 10000.0), (LONGLONG)(trim * 10000.0), (LONGLONG)(end * 10000.0)};
    // (offsets are of the segments' starts; the first's trim moves every later one back by as much)
    job.parts.push_back(part);
    last = std::max(last, part.offset + part.end);
  }
  if (job.parts.empty() || job.width < 2 || job.height < 2) return false;
  const LONGLONG first_trim = job.parts[0].trim;
  for (auto &part : job.parts) part.offset -= (part.offset == 0 ? 0 : first_trim);
  job.parts[0].offset = 0;
  // (each part's offset is where its trim lands: it ends its kept length after that; a later part cut in from the
  // middle of its file, what was skipped before it left out, has a trim of its own)
  last = 0;
  for (const auto &part : job.parts) last = std::max(last, part.offset + (part.end - part.trim));
  job.total = std::max<LONGLONG>(1, last);
  return true;
}

// The clip's stretch from `from` for `span` (100 ns into it) as a job of its own: its parts cut to it, its crops from
// its start.
Job stretch_of(const Job &job, LONGLONG from, LONGLONG span) {
  Job s = job;
  s.parts.clear();
  for (const Part &p : job.parts) {
    const LONGLONG a = std::max(from, p.offset), b = std::min(from + span, p.offset + (p.end - p.trim));
    if (b <= a) continue;
    s.parts.push_back({p.path, a - from, p.trim + (a - p.offset), p.trim + (b - p.offset)});
  }
  s.crops.clear();
  for (const Crop &c : job.crops)
    s.crops.push_back({std::max<LONGLONG>(0, c.at - from), c.x, c.y, c.w, c.h, c.rx, c.ry, c.rw, c.rh});
  // (the crop in force at the stretch's start, the latest at or before it, first)
  std::stable_sort(s.crops.begin(), s.crops.end(), [](const Crop &x, const Crop &y) { return x.at < y.at; });
  s.total = span;
  return s;
}

// A GIF's size estimated: one second of it made (counted, not written) at each of up to 8 places spread over the
// clip: its first picture whole, then what its frames add a second, as those seconds show, over the clip's length. A
// GIF's size follows what moves on the screen and how (type that scrolls, a gradient sliding: the recording's own bytes
// tell neither), so it is measured where nothing else would say it.
HRESULT estimate(const Job &job, const std::atomic<bool> &stop, double *bytes) {
  const LONGLONG second = 10000000LL;
  const int n = (int)std::max<LONGLONG>(1, std::min<LONGLONG>(8, job.total / second));
  uint64_t first = 0, later = 0;
  LONGLONG measured = 0;
  std::atomic<double> unused{0.0};
  ExportDevice shared;
  for (int i = 0; i < n; i++) {
    if (stop.load()) return E_ABORT;
    const LONGLONG span = std::min(second, job.total);
    const LONGLONG from = n == 1 ? 0 : (job.total - span) * i / (n - 1);
    Job s = stretch_of(job, from, span);
    if (s.parts.empty()) continue;
    Gif count;
    CHECK(count.open(L"", s.width, s.height));
    CHECK(run(s, stop, unused, &count, &shared));
    if (i == 0) first = count.first_bytes();
    later += count.later_bytes();
    // (what its frames after the first show: the second less the first frame's time)
    measured += span - std::min(span, 10000000LL / job.fps);
  }
  const double rate = measured > 0 ? (double)later / (double)measured : 0.0;
  *bytes = 64.0 + (double)first + rate * (double)std::max<LONGLONG>(0, job.total - 10000000LL / job.fps);
  return S_OK;
}

// The estimates: one thread of their own, kept (started at the first), given the newest asked for; what it makes
// stopped as a newer one is asked for (`estimate_stop`); its answer (-1 while it runs; -2 failed), kept only where it is
// of the newest ask (`estimate_gen`). Before, each ask waited on the window's thread for the one before to stop
// (estimator.join), its device and reader being made: the window stood still while a clip's end was dragged.
std::thread estimator;
std::atomic<bool> estimate_stop{false};
std::atomic<double> estimated{-2.0};
std::mutex estimate_mu;
std::condition_variable estimate_wake;
Job estimate_job;
uint64_t estimate_gen = 0;   // (under estimate_mu) the newest ask's number
uint64_t estimate_taken = 0; // (under estimate_mu) the one the thread took last
bool estimate_quit = false;

void estimate_loop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  MFStartup(MF_VERSION, MFSTARTUP_LITE);
  for (;;) {
    Job job;
    uint64_t gen = 0;
    {
      std::unique_lock<std::mutex> lock(estimate_mu);
      estimate_wake.wait(lock, [] { return estimate_quit || estimate_taken != estimate_gen; });
      if (estimate_quit) break;
      job = estimate_job;
      gen = estimate_gen;
      estimate_taken = gen;
      estimate_stop.store(false);
    }
    double bytes = 0;
    HRESULT hr = estimate(job, estimate_stop, &bytes);
    std::lock_guard<std::mutex> lock(estimate_mu);
    if (gen == estimate_gen && !estimate_stop.load()) estimated.store(SUCCEEDED(hr) ? bytes : -2.0);
  }
  MFShutdown();
  CoUninitialize();
}

}  // namespace

void rp_export_at_exit(void);

// rp_export_at_exit registered, once.
static void exit_registered() {
  static bool registered = false;
  if (!registered) {
    registered = true;
    atexit(rp_export_at_exit);
  }
}

// A clip encoded again into `output` (UTF-8): `plan` a line a segment, `path\toffsetMs\ttrimStartMs\tendMs`, the
// picture `width` x `height` (even) at most `fps` frames a second, `bitrate` bits a second, `codec` 0 H.264, 1 H.265,
// 2 AV1 (MP4s), 3 a GIF (no sound, no bitrate). 0 started; -1 one is running; -2 nothing to do.
// `crops`: one window's part of the picture, a line each change, `msIntoClip\tx\ty\tw\th` in the recording's pixels
// ("" the whole picture), the recording scaled by `scale` (at most 1) before it is cut out.
extern "C" int32_t rp_export_start(moonbit_bytes_t plan, moonbit_bytes_t output, int32_t width, int32_t height, int32_t fps,
                                   int32_t bitrate, int32_t codec, moonbit_bytes_t crops, double scale) {
  std::lock_guard<std::mutex> lock(mu);
  if (state.load() == 1) return -1;
  if (worker.joinable()) worker.join();
  Job job;
  job.output = wide((const char *)output);
  if (!make_job((const char *)plan, (const char *)crops, width, height, fps, bitrate, codec, scale, job)) return -2;
  cancel.store(false);
  progress.store(0.0);
  failure.store(0);
  state.store(1);
  exit_registered();
  worker = std::thread([job]() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_LITE);
    HRESULT hr = run(job, cancel, progress);
    MFShutdown();
    CoUninitialize();
    const std::wstring partial = partial_of(job);
    if (hr == E_ABORT) {
      DeleteFileW(partial.c_str());
      state.store(-2);
    } else if (FAILED(hr)) {
      failure.store((long)hr);
      DeleteFileW(partial.c_str());
      state.store(-1);
    } else {
      progress.store(1.0);
      state.store(2);
    }
  });
  return 0;
}

// A GIF's size estimated on a thread of its own (the words as rp_export_start's, no bitrate), one before it stopped;
// asked for by rp_gif_estimate.
extern "C" void rp_gif_estimate_start(moonbit_bytes_t plan, int32_t width, int32_t height, int32_t fps, moonbit_bytes_t crops, double scale) {
  Job job;
  const bool made = make_job((const char *)plan, (const char *)crops, width, height, fps, 0, kGif, scale, job);
  std::lock_guard<std::mutex> lock(estimate_mu);
  // (the one under way given up; the thread takes this one as it has stopped: nothing waited for here)
  estimate_stop.store(true);
  estimate_gen++;
  if (!made) {
    // (nothing to estimate: the thread takes nothing new)
    estimate_taken = estimate_gen;
    estimated.store(-2.0);
    return;
  }
  estimate_job = job;
  estimated.store(-1.0);
  if (!estimator.joinable()) {
    exit_registered();
    try {
      estimator = std::thread(estimate_loop);
    } catch (...) {
      estimated.store(-2.0);
      return;
    }
  }
  estimate_wake.notify_one();
}

// The estimate's bytes; -1 while it is made, -2 none (it failed, or nothing to estimate).
extern "C" double rp_gif_estimate(void) { return estimated.load(); }

// Registered once: at exit an export under way is cancelled and its thread waited for (an estimate's too).
void rp_export_at_exit(void) {
  cancel.store(true);
  {
    std::lock_guard<std::mutex> lock(estimate_mu);
    estimate_quit = true;
    estimate_stop.store(true);
  }
  estimate_wake.notify_one();
  if (worker.joinable()) worker.join();
  if (estimator.joinable()) estimator.join();
}

// How the export stands: 0 none, 1 running, 2 done, -1 failed, -2 cancelled.
extern "C" int32_t rp_export_state(void) { return state.load(); }

// How far it is, 0 to 1.
extern "C" double rp_export_progress(void) { return progress.load(); }

// Why it failed (an HRESULT).
extern "C" int32_t rp_export_failure(void) { return (int32_t)failure.load(); }

extern "C" void rp_export_cancel(void) { cancel.store(true); }

// The done (or failed) state taken: back to none.
extern "C" void rp_export_reset(void) {
  if (state.load() != 1) state.store(0);
}

// Whether this PC has an AV1 encoder in its GPU (a hardware encoder MFT that makes AV1), asked once. AV1 is offered
// only so: encoded in software it would take many times the clip's length.
extern "C" int32_t rp_av1_here(void) {
  static int here = -1;
  if (here >= 0) return here;
  here = 0;
  HRESULT ci = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    MFT_REGISTER_TYPE_INFO out = {MFMediaType_Video, MFVideoFormat_AV1};
    IMFActivate **found = nullptr;
    UINT32 n = 0;
    if (SUCCEEDED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, nullptr, &out, &found, &n))) {
      here = n > 0;
      for (UINT32 i = 0; i < n; i++) found[i]->Release();
      CoTaskMemFree(found);
    }
    MFShutdown();
  }
  if (SUCCEEDED(ci)) CoUninitialize();
  return here;
}
