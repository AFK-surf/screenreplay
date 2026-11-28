#import "replay_mac_common.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <VideoToolbox/VideoToolbox.h>

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "wsola.h"

namespace {

enum ExportCodec {
  kH264 = 0,
  kHevc = 1,
  kAv1 = 2,
  kGif = 3,
};

struct SegPlan {
  std::string path;
  double offset_ms = 0.0;
  double trim_ms = 0.0;
  double end_ms = 0.0;
};

struct CropStep {
  double at_ms = 0.0;
  double x = 0.0, y = 0.0, w = 0.0, h = 0.0;
};

struct ExportJob {
  std::vector<SegPlan> segs;
  std::vector<CropStep> crops;
  std::string output;
  int width = 0;
  int height = 0;
  int fps = 30;
  int bitrate = 4000000;
  int codec = kH264;
  double scale = 1.0;
  double speed = 1.0;
  double total_ms = 0.0;
};

static bool parse_export_job(const std::string &plan_str, const std::string &crops_str,
                             int width, int height, int fps, int bitrate, int codec, double scale, double speed,
                             const std::string &output, ExportJob &job) {
  job = ExportJob{};
  job.output = output;
  job.codec = codec;
  job.fps = std::max(1, std::min(120, fps > 0 ? fps : 30));
  job.bitrate = std::max(100000, bitrate > 0 ? bitrate : 4000000);
  job.scale = (scale > 0.0 && scale <= 1.0) ? scale : 1.0;
  job.speed = (speed >= 0.25 && speed <= 32.0) ? speed : 1.0;
  if (codec == kGif) {
    job.width = std::max(2, width);
    job.height = std::max(2, height);
  } else {
    job.width = std::max(2, width & ~1);
    job.height = std::max(2, height & ~1);
  }

  {
    std::istringstream ss(plan_str);
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
      SegPlan s;
      s.path = line.substr(0, t1);
      try {
        s.offset_ms = std::stod(line.substr(t1 + 1, t2 - t1 - 1));
        s.trim_ms = std::stod(line.substr(t2 + 1, t3 - t2 - 1));
        s.end_ms = std::stod(line.substr(t3 + 1));
      } catch (...) {
        continue;
      }
      if (!s.path.empty() && s.end_ms > s.trim_ms) {
        double seg_end = s.offset_ms + (s.end_ms - s.trim_ms);
        if (seg_end > job.total_ms) job.total_ms = seg_end;
        job.segs.push_back(std::move(s));
      }
    }
  }
  if (job.segs.empty() || job.total_ms <= 0.0) return false;

  if (!crops_str.empty()) {
    std::istringstream cs(crops_str);
    std::string line;
    while (std::getline(cs, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      double at = 0, x = 0, y = 0, w = 0, h = 0;
      if (sscanf(line.c_str(), "%lf\t%lf\t%lf\t%lf\t%lf", &at, &x, &y, &w, &h) == 5 && w > 0 && h > 0) {
        job.crops.push_back({at, x, y, w, h});
      }
    }
    std::sort(job.crops.begin(), job.crops.end(), [](const CropStep &a, const CropStep &b) { return a.at_ms < b.at_ms; });
  }
  return true;
}

static CropStep crop_at(const std::vector<CropStep> &crops, double clip_ms) {
  if (crops.empty()) return {0, 0, 0, 0, 0};
  const CropStep *cur = &crops.front();
  for (const auto &c : crops) {
    if (c.at_ms <= clip_ms + 0.5) cur = &c;
    else break;
  }
  return *cur;
}

static bool render_cropped_pixelbuffer(CIContext *ciCtx, CVPixelBufferRef srcBuf,
                                       double scale, const CropStep &crop,
                                       CVPixelBufferRef dstBuf, int dstW, int dstH) {
  if (!ciCtx || !srcBuf || !dstBuf) return false;
  @autoreleasepool {
    CIImage *img = [CIImage imageWithCVPixelBuffer:srcBuf];
    if (!img) return false;
    CGRect ext = img.extent;
    if (ext.size.width <= 0 || ext.size.height <= 0) return false;

    if (scale > 0.0 && scale < 0.9999) {
      img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
      ext = img.extent;
    }

    if (crop.w > 0 && crop.h > 0) {
      // `crop` uses top-left origin; CoreImage uses bottom-left origin.
      double cx = std::max(0.0, std::min((double)ext.size.width - 1.0, crop.x));
      double cy_top = std::max(0.0, std::min((double)ext.size.height - 1.0, crop.y));
      double cw = std::max(1.0, std::min((double)ext.size.width - cx, crop.w));
      double ch = std::max(1.0, std::min((double)ext.size.height - cy_top, crop.h));
      double cy_bottom = (double)ext.size.height - cy_top - ch;
      CGRect rect = CGRectMake(ext.origin.x + cx, ext.origin.y + cy_bottom, cw, ch);
      img = [img imageByCroppingToRect:rect];
      img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-rect.origin.x, -rect.origin.y)];
      ext = img.extent;
    }

    if (ext.size.width <= 0 || ext.size.height <= 0) return false;
    double sx = (double)dstW / ext.size.width;
    double sy = (double)dstH / ext.size.height;
    if (std::abs(sx - 1.0) > 1e-4 || std::abs(sy - 1.0) > 1e-4) {
      img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    }

    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ciCtx render:img toCVPixelBuffer:dstBuf bounds:CGRectMake(0, 0, dstW, dstH) colorSpace:srgb];
    CGColorSpaceRelease(srgb);
    return true;
  }
}

static std::mutex g_export_mu;
static std::atomic<int> g_export_state{0};     // 0 none, 1 running, 2 done, -1 failed, -2 cancelled
static std::atomic<double> g_export_prog{0.0};
static std::atomic<int32_t> g_export_fail{0};
static std::atomic<bool> g_export_cancel{false};

// Stretched 16-bit stereo PCM appended at a frame count of 48 kHz.
static bool append_pcm(AVAssetWriterInput *input, CMFormatDescriptionRef fmt, const std::vector<int16_t> &pcm, int64_t at) {
  if (pcm.empty() || !fmt) return true;
  const size_t bytes = pcm.size() * sizeof(int16_t);
  CMBlockBufferRef block = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes, kCFAllocatorDefault, nullptr, 0, bytes,
                                         kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || !block) return false;
  CMBlockBufferReplaceDataBytes(pcm.data(), block, 0, bytes);
  CMSampleBufferRef sb = nullptr;
  OSStatus st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, fmt, (CMItemCount)(pcm.size() / 2),
                                                                     CMTimeMake(at, 48000), nullptr, &sb);
  CFRelease(block);
  if (st != noErr || !sb) return false;
  BOOL ok = [input appendSampleBuffer:sb];
  CFRelease(sb);
  return ok;
}

static int run_video_export(const ExportJob &job) {
  @autoreleasepool {
    unlink(job.output.c_str());
    NSURL *outURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:job.output.c_str()]];
    NSError *err = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outURL fileType:AVFileTypeMPEG4 error:&err];
    if (!writer || err) {
      g_export_fail.store(err ? (int32_t)err.code : -2001);
      return -1;
    }

    AVVideoCodecType codecType = AVVideoCodecTypeH264;
    if (job.codec == kHevc) codecType = AVVideoCodecTypeHEVC;
#ifdef AVVideoCodecTypeAV1
    else if (job.codec == kAv1) codecType = AVVideoCodecTypeAV1;
#endif

    NSDictionary *compProps = @{
      AVVideoAverageBitRateKey : @(job.bitrate),
      AVVideoExpectedSourceFrameRateKey : @(job.fps),
      AVVideoMaxKeyFrameIntervalKey : @(std::max(1, job.fps * 2)),
    };
    NSDictionary *colorProps = @{
      AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2,
    };
    NSDictionary *vSettings = @{
      AVVideoCodecKey : codecType,
      AVVideoWidthKey : @(job.width),
      AVVideoHeightKey : @(job.height),
      AVVideoCompressionPropertiesKey : compProps,
      AVVideoColorPropertiesKey : colorProps,
    };
    if (![writer canApplyOutputSettings:vSettings forMediaType:AVMediaTypeVideo]) {
      vSettings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(job.width),
        AVVideoHeightKey : @(job.height),
        AVVideoCompressionPropertiesKey : compProps,
        AVVideoColorPropertiesKey : colorProps,
      };
    }

    AVAssetWriterInput *vInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vSettings];
    vInput.expectsMediaDataInRealTime = NO;
    NSDictionary *pbAttrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferWidthKey : @(job.width),
      (id)kCVPixelBufferHeightKey : @(job.height),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vInput
                                                                         sourcePixelBufferAttributes:pbAttrs];
    [writer addInput:vInput];

    bool anyAudioSource = false;
    for (const auto &seg : job.segs) {
      AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:seg.path.c_str()]] options:nil];
      if ([a tracksWithMediaType:AVMediaTypeAudio].count > 0) {
        anyAudioSource = true;
        break;
      }
    }

    AVAssetWriterInput *aInput = nil;
    if (anyAudioSource && job.speed <= 4.0) {
      AudioChannelLayout acl = {};
      acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
      NSDictionary *aSettings = @{
        AVFormatIDKey : @(kAudioFormatMPEG4AAC),
        AVSampleRateKey : @(48000),
        AVNumberOfChannelsKey : @(2),
        AVEncoderBitRateKey : @(160000),
        AVChannelLayoutKey : [NSData dataWithBytes:&acl length:sizeof(acl)],
      };
      if ([writer canApplyOutputSettings:aSettings forMediaType:AVMediaTypeAudio]) {
        aInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aSettings];
        aInput.expectsMediaDataInRealTime = NO;
        [writer addInput:aInput];
      }
    }

    if (![writer startWriting]) {
      g_export_fail.store(writer.error ? (int32_t)writer.error.code : -2002);
      unlink(job.output.c_str());
      return -1;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    CIContext *ciCtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    const double step_ms = 1000.0 / (double)job.fps;
    const ExportJob *jobPtr = &job;

    dispatch_group_t group = dispatch_group_create();

    // Video pull queue (independent AVAssetReader per segment so video & audio never block each other)
    dispatch_group_enter(group);
    dispatch_queue_t vQueue = dispatch_queue_create("dev.pengx17.screenreplay.export.video", DISPATCH_QUEUE_SERIAL);
    __block size_t vSegIdx = 0;
    __block AVAssetReader *vReader = nil;
    __block AVAssetReaderTrackOutput *vOut = nil;
    __block double next_due_ms = 0.0;
    __block int64_t last_pts_ticks = -1;
    __block bool vFinished = false;

    auto finishVideo = ^{
      if (vFinished) return;
      vFinished = true;
      if (vReader) {
        [vReader cancelReading];
        vReader = nil;
        vOut = nil;
      }
      [vInput markAsFinished];
      dispatch_group_leave(group);
    };

    [vInput requestMediaDataWhenReadyOnQueue:vQueue usingBlock:^{
      if (vFinished) return;
      while (vInput.isReadyForMoreMediaData) {
        @autoreleasepool {
          if (g_export_cancel.load() || writer.status != AVAssetWriterStatusWriting) {
            finishVideo();
            return;
          }
          if (!vOut) {
            while (vSegIdx < jobPtr->segs.size() && !vOut) {
              const auto &seg = jobPtr->segs[vSegIdx];
              NSString *nsPath = [NSString stringWithUTF8String:seg.path.c_str()];
              AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:nsPath]
                                                      options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
              NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
              if (vTracks.count == 0) {
                vSegIdx++;
                continue;
              }
              NSError *rErr = nil;
              AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:asset error:&rErr];
              if (!r || rErr) {
                vSegIdx++;
                continue;
              }
              CMTime rangeStart = CMTimeMakeWithSeconds(std::max(0.0, seg.trim_ms) / 1000.0, 60000);
              CMTime rangeDur = CMTimeMakeWithSeconds(std::max(0.001, (seg.end_ms - seg.trim_ms) / 1000.0), 60000);
              r.timeRange = CMTimeRangeMake(rangeStart, rangeDur);
              NSDictionary *vOutAttrs = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                (id)kCVPixelBufferMetalCompatibilityKey : @YES,
              };
              AVAssetReaderTrackOutput *out =
                  [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vTracks.firstObject outputSettings:vOutAttrs];
              out.alwaysCopiesSampleData = NO;
              if (![r canAddOutput:out]) {
                vSegIdx++;
                continue;
              }
              [r addOutput:out];
              if (![r startReading]) {
                vSegIdx++;
                continue;
              }
              vReader = r;
              vOut = out;
            }
            if (!vOut) {
              finishVideo();
              return;
            }
          }

          const auto &seg = jobPtr->segs[vSegIdx];
          CMSampleBufferRef sb = [vOut copyNextSampleBuffer];
          if (!sb) {
            [vReader cancelReading];
            vReader = nil;
            vOut = nil;
            vSegIdx++;
            continue;
          }

          CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
          double src_ms = CMTimeGetSeconds(pts) * 1000.0;
          double clip_ms = seg.offset_ms + std::max(0.0, src_ms - seg.trim_ms);
          double out_ms = clip_ms / jobPtr->speed;
          if (out_ms + step_ms * 0.35 >= next_due_ms) {
            CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sb);
            CVPixelBufferRef dstBuf = nullptr;
            if (imgBuf && adaptor.pixelBufferPool &&
                CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &dstBuf) == kCVReturnSuccess && dstBuf) {
              CropStep cs = crop_at(jobPtr->crops, clip_ms);
              if (render_cropped_pixelbuffer(ciCtx, imgBuf, jobPtr->scale, cs, dstBuf, jobPtr->width, jobPtr->height)) {
                int64_t ticks = (int64_t)std::llround(out_ms * 60.0);
                if (ticks <= last_pts_ticks) ticks = last_pts_ticks + 1;
                last_pts_ticks = ticks;
                [adaptor appendPixelBuffer:dstBuf withPresentationTime:CMTimeMake(ticks, 60000)];
                next_due_ms = out_ms + step_ms;
                g_export_prog.store(std::min(0.99, clip_ms / jobPtr->total_ms));
              }
              CVPixelBufferRelease(dstBuf);
            }
          }
          CFRelease(sb);
        }
      }
    }];

    if (aInput) {
      dispatch_group_enter(group);
      dispatch_queue_t aQueue = dispatch_queue_create("dev.pengx17.screenreplay.export.audio", DISPATCH_QUEUE_SERIAL);
      __block size_t aSegIdx = 0;
      __block AVAssetReader *aReader = nil;
      __block AVAssetReaderTrackOutput *aOut = nil;
      __block int64_t last_audio_sample = -1;
      __block bool aFinished = false;
      const bool sped = jobPtr->speed != 1.0;
      __block Wsola *stretch = sped ? new Wsola(jobPtr->speed) : nullptr;
      __block CMFormatDescriptionRef pcmFormat = nullptr;
      __block double fed_to_ms = 0.0;
      __block int64_t audio_out = 0;

      auto finishAudio = ^{
        if (aFinished) return;
        aFinished = true;
        if (stretch) {
          std::vector<int16_t> tail;
          stretch->feed(nullptr, 0, true, tail);
          const int64_t most = (int64_t)(jobPtr->total_ms / jobPtr->speed * 48.0) - audio_out;
          if ((int64_t)tail.size() / 2 > most) tail.resize((size_t)std::max<int64_t>(0, most) * 2);
          if (aInput.isReadyForMoreMediaData) append_pcm(aInput, pcmFormat, tail, audio_out);
          delete stretch;
          stretch = nullptr;
        }
        if (pcmFormat) {
          CFRelease(pcmFormat);
          pcmFormat = nullptr;
        }
        if (aReader) {
          [aReader cancelReading];
          aReader = nil;
          aOut = nil;
        }
        [aInput markAsFinished];
        dispatch_group_leave(group);
      };

      [aInput requestMediaDataWhenReadyOnQueue:aQueue usingBlock:^{
        if (aFinished) return;
        while (aInput.isReadyForMoreMediaData) {
          @autoreleasepool {
            if (g_export_cancel.load() || writer.status != AVAssetWriterStatusWriting) {
              finishAudio();
              return;
            }
            if (!aOut) {
              while (aSegIdx < jobPtr->segs.size() && !aOut) {
                const auto &seg = jobPtr->segs[aSegIdx];
                NSString *nsPath = [NSString stringWithUTF8String:seg.path.c_str()];
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:nsPath]
                                                        options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
                NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
                if (aTracks.count == 0) {
                  aSegIdx++;
                  continue;
                }
                NSError *rErr = nil;
                AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:asset error:&rErr];
                if (!r || rErr) {
                  aSegIdx++;
                  continue;
                }
                CMTime rangeStart = CMTimeMakeWithSeconds(std::max(0.0, seg.trim_ms) / 1000.0, 60000);
                CMTime rangeDur = CMTimeMakeWithSeconds(std::max(0.001, (seg.end_ms - seg.trim_ms) / 1000.0), 60000);
                r.timeRange = CMTimeRangeMake(rangeStart, rangeDur);
                NSDictionary *aOutAttrs = @{
                  AVFormatIDKey : @(kAudioFormatLinearPCM),
                  AVSampleRateKey : @(48000),
                  AVNumberOfChannelsKey : @(2),
                  AVLinearPCMBitDepthKey : @(16),
                  AVLinearPCMIsFloatKey : @NO,
                  AVLinearPCMIsBigEndianKey : @NO,
                  AVLinearPCMIsNonInterleaved : @NO,
                };
                AVAssetReaderTrackOutput *out =
                    [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:aTracks.firstObject outputSettings:aOutAttrs];
                out.alwaysCopiesSampleData = NO;
                if (![r canAddOutput:out]) {
                  aSegIdx++;
                  continue;
                }
                [r addOutput:out];
                if (![r startReading]) {
                  aSegIdx++;
                  continue;
                }
                aReader = r;
                aOut = out;
              }
              if (!aOut) {
                finishAudio();
                return;
              }
            }

            const auto &seg = jobPtr->segs[aSegIdx];
            CMSampleBufferRef asb = [aOut copyNextSampleBuffer];
            if (!asb) {
              [aReader cancelReading];
              aReader = nil;
              aOut = nil;
              aSegIdx++;
              continue;
            }

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(asb);
            double src_ms = CMTimeGetSeconds(pts) * 1000.0;
            double clip_ms = seg.offset_ms + std::max(0.0, src_ms - seg.trim_ms);
            if (stretch) {
              if (!pcmFormat) {
                pcmFormat = CMSampleBufferGetFormatDescription(asb);
                if (pcmFormat) CFRetain(pcmFormat);
              }
              CMItemCount frames = CMSampleBufferGetNumSamples(asb);
              std::vector<int16_t> pcm((size_t)frames * 2);
              CMBlockBufferRef data = CMSampleBufferGetDataBuffer(asb);
              if (data && frames > 0 && CMBlockBufferCopyDataBytes(data, 0, pcm.size() * sizeof(int16_t), pcm.data()) == noErr) {
                std::vector<int16_t> out;
                if (clip_ms > fed_to_ms + 1.0) stretch->feed(nullptr, (long)((clip_ms - fed_to_ms) * 48.0), false, out);
                const int64_t skip = clip_ms < fed_to_ms ? std::min<int64_t>(frames, (int64_t)((fed_to_ms - clip_ms) * 48.0)) : 0;
                stretch->feed(pcm.data() + skip * 2, (long)(frames - skip), false, out);
                fed_to_ms = std::max(fed_to_ms, clip_ms + frames / 48.0);
                append_pcm(aInput, pcmFormat, out, audio_out);
                audio_out += (int64_t)(out.size() / 2);
              }
              CFRelease(asb);
              continue;
            }
            int64_t startSample = (int64_t)std::llround(clip_ms * 48.0);
            if (startSample <= last_audio_sample) startSample = last_audio_sample + 1;
            CMItemCount numSamples = CMSampleBufferGetNumSamples(asb);
            last_audio_sample = startSample + std::max<int64_t>(0, (int64_t)numSamples - 1);

            CMSampleTimingInfo timing = {};
            timing.duration = CMTimeMake(1, 48000);
            timing.presentationTimeStamp = CMTimeMake(startSample, 48000);
            timing.decodeTimeStamp = kCMTimeInvalid;
            CMSampleBufferRef retimed = nullptr;
            if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, asb, 1, &timing, &retimed) == noErr && retimed) {
              [aInput appendSampleBuffer:retimed];
              CFRelease(retimed);
            }
            CFRelease(asb);
          }
        }
      }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (g_export_cancel.load()) {
      [writer cancelWriting];
      unlink(job.output.c_str());
      return -2;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (writer.status != AVAssetWriterStatusCompleted) {
      g_export_fail.store(writer.error ? (int32_t)writer.error.code : -2003);
      unlink(job.output.c_str());
      return -1;
    }
    g_export_prog.store(1.0);
    return 2;
  }
}

static bool encode_gif_common(const ExportJob &job, bool to_file, std::atomic<bool> &stop_flag,
                              bool update_progress, size_t *out_bytes, int max_sample_frames = 0) {
  @autoreleasepool {
    CIContext *ciCtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    const double step_ms = 1000.0 / (double)job.fps;
    const int expected_frames = std::max(1, (int)std::ceil(job.total_ms / job.speed / step_ms));
    const int stride_frames = (max_sample_frames > 0 && expected_frames > max_sample_frames)
                                  ? std::max(1, expected_frames / max_sample_frames)
                                  : 1;

    CFMutableDataRef memData = nullptr;
    CGImageDestinationRef dest = nullptr;
    if (to_file) {
      unlink(job.output.c_str());
      NSURL *outURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:job.output.c_str()]];
      dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)outURL, UTTypeGIF.identifier ? (__bridge CFStringRef)UTTypeGIF.identifier : CFSTR("com.compuserve.gif"),
                                             (size_t)expected_frames, nullptr);
    } else {
      memData = CFDataCreateMutable(kCFAllocatorDefault, 0);
      if (memData) {
        int cap = std::max(1, (expected_frames + stride_frames - 1) / stride_frames);
        dest = CGImageDestinationCreateWithData(memData, UTTypeGIF.identifier ? (__bridge CFStringRef)UTTypeGIF.identifier : CFSTR("com.compuserve.gif"),
                                                (size_t)cap, nullptr);
      }
    }
    if (!dest) {
      if (memData) CFRelease(memData);
      return false;
    }

    NSDictionary *fileProps = @{(id)kCGImagePropertyGIFDictionary : @{(id)kCGImagePropertyGIFLoopCount : @0}};
    CGImageDestinationSetProperties(dest, (__bridge CFDictionaryRef)fileProps);
    NSDictionary *frameProps = @{
      (id)kCGImagePropertyGIFDictionary : @{
        (id)kCGImagePropertyGIFUnclampedDelayTime : @(1.0 / (double)job.fps),
        (id)kCGImagePropertyGIFDelayTime : @(1.0 / (double)job.fps),
      }
    };

    NSDictionary *pbAttrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferWidthKey : @(job.width),
      (id)kCVPixelBufferHeightKey : @(job.height),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVPixelBufferRef dstBuf = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)job.width, (size_t)job.height,
                            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs, &dstBuf) != kCVReturnSuccess || !dstBuf) {
      CFRelease(dest);
      if (memData) CFRelease(memData);
      return false;
    }

    double next_due_ms = 0.0;
    int frame_idx = 0;
    int added = 0;
    const int target_count = to_file ? expected_frames : std::max(1, (expected_frames + stride_frames - 1) / stride_frames);
    CGImageRef last_cg = nullptr;

    for (const auto &seg : job.segs) {
      if (stop_flag.load() || added >= target_count) break;
      @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:seg.path.c_str()];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:nsPath]
                                                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
        NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (vTracks.count == 0) continue;

        NSError *rErr = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&rErr];
        if (!reader || rErr) continue;
        reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(std::max(0.0, seg.trim_ms) / 1000.0, 60000),
                                           CMTimeMakeWithSeconds((seg.end_ms - seg.trim_ms) / 1000.0, 60000));
        NSDictionary *vOutAttrs = @{
          (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
          (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        AVAssetReaderTrackOutput *vOut = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vTracks.firstObject
                                                                                    outputSettings:vOutAttrs];
        vOut.alwaysCopiesSampleData = NO;
        [reader addOutput:vOut];
        if (![reader startReading]) continue;

        while (!stop_flag.load() && added < target_count) {
          CMSampleBufferRef sb = [vOut copyNextSampleBuffer];
          if (!sb) break;
          CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
          double src_ms = CMTimeGetSeconds(pts) * 1000.0;
          double clip_ms = seg.offset_ms + std::max(0.0, src_ms - seg.trim_ms);
          double out_ms = clip_ms / job.speed;
          if (out_ms + step_ms * 0.35 >= next_due_ms) {
            next_due_ms = out_ms + step_ms;
            if ((frame_idx % stride_frames) == 0 && added < target_count) {
              CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sb);
              CropStep cs = crop_at(job.crops, clip_ms);
              if (imgBuf && render_cropped_pixelbuffer(ciCtx, imgBuf, job.scale, cs, dstBuf, job.width, job.height)) {
                CGImageRef cgImg = nullptr;
                if (VTCreateCGImageFromCVPixelBuffer(dstBuf, nullptr, &cgImg) == noErr && cgImg) {
                  CGImageDestinationAddImage(dest, cgImg, (__bridge CFDictionaryRef)frameProps);
                  if (last_cg) CGImageRelease(last_cg);
                  last_cg = cgImg;
                  added++;
                }
              }
            }
            frame_idx++;
            if (update_progress) g_export_prog.store(std::min(0.98, clip_ms / job.total_ms));
          }
          CFRelease(sb);
        }
        [reader cancelReading];
      }
    }

    CVPixelBufferRelease(dstBuf);
    if (stop_flag.load() || added == 0) {
      if (last_cg) CGImageRelease(last_cg);
      CFRelease(dest);
      if (memData) CFRelease(memData);
      if (to_file) unlink(job.output.c_str());
      return false;
    }

    // ImageIO requires exact `target_count` images added before CGImageDestinationFinalize succeeds.
    while (added < target_count && last_cg) {
      CGImageDestinationAddImage(dest, last_cg, (__bridge CFDictionaryRef)frameProps);
      added++;
    }
    if (last_cg) CGImageRelease(last_cg);

    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    if (ok && out_bytes && memData) {
      size_t sample_len = (size_t)CFDataGetLength(memData);
      *out_bytes = (size_t)((double)sample_len * ((double)std::max(1, frame_idx) / (double)std::max(1, added)));
    }
    if (memData) CFRelease(memData);
    if (!ok && to_file) unlink(job.output.c_str());
    if (ok && update_progress) g_export_prog.store(1.0);
    return ok;
  }
}

static std::mutex g_est_mu;
static std::condition_variable g_est_cv;
static ExportJob g_est_job;
static bool g_est_has_job = false;
static bool g_est_started = false;
static std::atomic<bool> g_est_stop{false};
static std::atomic<double> g_estimated{-2.0};

static void gif_estimator_loop() {
  for (;;) {
    ExportJob job;
    {
      std::unique_lock<std::mutex> lock(g_est_mu);
      g_est_cv.wait(lock, [] { return g_est_has_job; });
      job = std::move(g_est_job);
      g_est_has_job = false;
      g_est_stop.store(false);
    }
    size_t bytes = 0;
    bool ok = encode_gif_common(job, false, g_est_stop, false, &bytes, 24);
    if (!g_est_stop.load()) {
      g_estimated.store(ok && bytes > 0 ? (double)bytes : -2.0);
    }
  }
}

}

extern "C" int32_t rp_export_start(moonbit_bytes_t plan, moonbit_bytes_t output, int32_t width, int32_t height, int32_t fps,
                                   int32_t bitrate, int32_t codec, moonbit_bytes_t crops, double scale, double speed) {
  std::lock_guard<std::mutex> lock(g_export_mu);
  if (g_export_state.load() == 1) return -1;

  ExportJob job;
  if (!parse_export_job(rp_str(plan), rp_str(crops), width, height, fps, bitrate, codec, scale, speed, rp_str(output), job)) {
    return -2;
  }

  g_export_cancel.store(false);
  g_export_prog.store(0.0);
  g_export_fail.store(0);
  g_export_state.store(1);

  try {
    std::thread([job]() {
      int st = -1;
      try {
        if (job.codec == kGif) {
          bool ok = encode_gif_common(job, true, g_export_cancel, true, nullptr, 0);
          if (g_export_cancel.load()) st = -2;
          else if (ok) st = 2;
          else {
            g_export_fail.store(-2010);
            st = -1;
          }
        } else {
          st = run_video_export(job);
        }
      } catch (...) {
        g_export_fail.store(-2099);
        st = -1;
      }
      g_export_state.store(st);
    }).detach();
  } catch (...) {
    g_export_state.store(0);
    return -1;
  }
  return 0;
}

extern "C" void rp_gif_estimate_start(moonbit_bytes_t plan, int32_t width, int32_t height, int32_t fps,
                                      moonbit_bytes_t crops, double scale, double speed) {
  ExportJob job;
  bool valid = parse_export_job(rp_str(plan), rp_str(crops), width, height, fps, 0, kGif, scale, speed, "", job);
  std::lock_guard<std::mutex> lock(g_est_mu);
  g_est_stop.store(true);
  if (!valid) {
    g_est_has_job = false;
    g_estimated.store(-2.0);
    return;
  }
  g_estimated.store(-1.0);
  g_est_job = std::move(job);
  g_est_has_job = true;
  if (!g_est_started) {
    try {
      std::thread(gif_estimator_loop).detach();
      g_est_started = true;
    } catch (...) {
      g_est_has_job = false;
      g_estimated.store(-2.0);
      return;
    }
  }
  g_est_cv.notify_one();
}

extern "C" double rp_gif_estimate(void) { return g_estimated.load(); }

extern "C" int32_t rp_export_state(void) { return g_export_state.load(); }

extern "C" double rp_export_progress(void) { return g_export_prog.load(); }

extern "C" int32_t rp_export_failure(void) { return g_export_fail.load(); }

extern "C" void rp_export_cancel(void) { g_export_cancel.store(true); }

extern "C" void rp_export_reset(void) {
  if (g_export_state.load() != 1) g_export_state.store(0);
}

extern "C" int32_t rp_av1_here(void) {
  static int here = -1;
  if (here >= 0) return here;
  here = 0;
  CFArrayRef list = nullptr;
  if (VTCopyVideoEncoderList(nullptr, &list) == noErr && list) {
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
      CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
      if (!d) continue;
      CFNumberRef codec = (CFNumberRef)CFDictionaryGetValue(d, kVTVideoEncoderList_CodecType);
      CFBooleanRef hw = (CFBooleanRef)CFDictionaryGetValue(d, kVTVideoEncoderList_IsHardwareAccelerated);
      int32_t c = 0;
      if (codec && CFNumberGetValue(codec, kCFNumberSInt32Type, &c) && c == (int32_t)kCMVideoCodecType_AV1 &&
          hw && CFBooleanGetValue(hw)) {
        here = 1;
        break;
      }
    }
    CFRelease(list);
  }
  return here;
}
