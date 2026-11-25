import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct SegmentEncodeConfig: Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var frameRate: Int
  public var bitrate: Int
  public var hevc: Bool
  public var audio: Bool
  public var wideGamutP3: Bool

  public init(
    width: Int,
    height: Int,
    frameRate: Int,
    bitrate: Int,
    hevc: Bool = true,
    audio: Bool = true,
    wideGamutP3: Bool = false
  ) {
    self.width = max(2, width & ~1)
    self.height = max(2, height & ~1)
    self.frameRate = max(1, frameRate)
    self.bitrate = max(500_000, bitrate)
    self.hevc = hevc
    self.audio = audio
    self.wideGamutP3 = wideGamutP3
  }
}

public final class SegmentWriter: @unchecked Sendable {
  public static let audioSampleRate = 48_000
  public static let audioChannels = 2
  public static let audioBitrate = 160_000
  private static let levelWindowFrames = audioSampleRate / 10

  public let folder: String
  public let config: SegmentEncodeConfig
  public let tempPath: String

  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let audioInput: AVAssetWriterInput?
  private let pcmFormatDesc: CMAudioFormatDescription?

  private var started = false
  private var finished = false
  private var startUtc = Date()
  private var startHns: Int64 = 0
  private var stem = ""

  public private(set) var framesWritten: Int = 0
  public private(set) var framesDroppedNotReady: Int = 0
  private var lastVideoPTS: CMTime = .invalid
  private var audioFramesWritten: Int64 = 0

  private var levels: [UInt8] = []
  private var windowSquareSum: Double = 0.0
  private var windowFrameCount: Int = 0

  public init(folder: String, config: SegmentEncodeConfig) throws {
    self.folder = (folder as NSString).standardizingPath
    self.config = config
    try FileManager.default.createDirectory(atPath: self.folder, withIntermediateDirectories: true)

    let randID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    self.tempPath = (self.folder as NSString).appendingPathComponent("writing-\(randID).mp4.writing")
    try? FileManager.default.removeItem(atPath: tempPath)

    let url = URL(fileURLWithPath: tempPath)
    let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
    assetWriter.shouldOptimizeForNetworkUse = false

    let codecType: AVVideoCodecType = config.hevc ? .hevc : .h264
    var compressionProps: [String: Any] = [
      AVVideoAverageBitRateKey: config.bitrate,
      AVVideoExpectedSourceFrameRateKey: config.frameRate,
      AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
      AVVideoAllowFrameReorderingKey: false,
      kVTCompressionPropertyKey_RealTime as String: true,
    ]
    if !config.hevc {
      compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    } else {
      compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
    }

    let colorProps: [String: Any] = [
      AVVideoColorPrimariesKey: config.wideGamutP3 ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codecType,
      AVVideoWidthKey: config.width,
      AVVideoHeightKey: config.height,
      AVVideoCompressionPropertiesKey: compressionProps,
      AVVideoColorPropertiesKey: colorProps,
    ]

    guard assetWriter.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw HelperError("Video encoder cannot apply settings for \(codecType.rawValue) \(config.width)x\(config.height)", code: "noEncoder")
    }

    let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    vInput.expectsMediaDataInRealTime = true
    guard assetWriter.canAdd(vInput) else {
      throw HelperError("Cannot add video input to AVAssetWriter", code: "noEncoder")
    }
    assetWriter.add(vInput)

    let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: vInput,
      sourcePixelBufferAttributes: nil
    )

    var aInput: AVAssetWriterInput?
    var audioDesc: CMAudioFormatDescription?
    if config.audio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Self.audioSampleRate,
        AVNumberOfChannelsKey: Self.audioChannels,
        AVEncoderBitRateKey: Self.audioBitrate,
      ]
      if assetWriter.canApply(outputSettings: audioSettings, forMediaType: .audio) {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        if assetWriter.canAdd(input) {
          assetWriter.add(input)
          aInput = input
          var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.audioSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
          )
          CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &audioDesc
          )
        }
      }
    }

    guard assetWriter.startWriting() else {
      let msg = assetWriter.error?.localizedDescription ?? "unknown AVAssetWriter error"
      try? FileManager.default.removeItem(atPath: tempPath)
      throw HelperError("AVAssetWriter.startWriting failed: \(msg)", code: "writer")
    }
    assetWriter.startSession(atSourceTime: .zero)

    self.writer = assetWriter
    self.videoInput = vInput
    self.adaptor = pixelAdaptor
    self.audioInput = aInput
    self.pcmFormatDesc = audioDesc
  }

  public var isStarted: Bool { started }
  public var startTimestampUtc: Date { startUtc }
  public var startTimestampHns: Int64 { startHns }

  public func begin(startUtc: Date, startHns: Int64) {
    guard !started else { return }
    self.started = true
    self.startUtc = startUtc
    self.startHns = startHns
    self.stem = SegmentStore.formatStem(startUtc: startUtc)
  }

  /// Non-blocking video append (MUST be called on the engine's serial `writerQueue`).
  /// If `videoInput.isReadyForMoreMediaData` is false, drops immediately so WindowServer's `IOSurface` pool is never stalled.
  @discardableResult
  public func appendVideo(pixelBuffer: CVPixelBuffer, relativeTime: CMTime) -> Bool {
    guard started, !finished, writer.status == .writing else { return false }
    guard videoInput.isReadyForMoreMediaData else {
      framesDroppedNotReady += 1
      return false
    }

    var pts = relativeTime.isValid && relativeTime >= .zero ? relativeTime : .zero
    if framesWritten == 0 {
      pts = .zero
    } else if lastVideoPTS.isValid && pts <= lastVideoPTS {
      // Strictly monotonic PTS (+1 ms minimum step in 60000 timescale = 60 ticks).
      pts = CMTimeAdd(lastVideoPTS, CMTime(value: 60, timescale: 60_000))
    }

    if adaptor.append(pixelBuffer, withPresentationTime: pts) {
      lastVideoPTS = pts
      framesWritten += 1
      return true
    }
    return false
  }

  public func appendAudio(pcmInt16: [Int16], frames: Int, targetFrameOffset: Int64) {
    guard started, !finished, writer.status == .writing,
          let audioInput, let pcmFormatDesc, frames > 0, pcmInt16.count >= frames * 2
    else { return }

    if targetFrameOffset > audioFramesWritten {
      let gap = min(targetFrameOffset - audioFramesWritten, Int64(Self.audioSampleRate * 60))
      writeSilence(frames: gap)
      if targetFrameOffset > audioFramesWritten {
        audioFramesWritten = targetFrameOffset
      }
    }

    let skip = Int(max(0, audioFramesWritten - targetFrameOffset))
    guard skip < frames else { return }
    let remainingFrames = frames - skip

    guard audioInput.isReadyForMoreMediaData else { return }
    let slice = Array(pcmInt16[(skip * 2)..<((skip + remainingFrames) * 2)])
    if appendPCM16Buffer(slice, frames: remainingFrames, input: audioInput, desc: pcmFormatDesc) {
      for k in 0..<remainingFrames {
        let l = Double(slice[k * 2]) / 32768.0
        let r = Double(slice[k * 2 + 1]) / 32768.0
        windowSquareSum += (l * l + r * r) * 0.5
        windowFrameCount += 1
        if windowFrameCount == Self.levelWindowFrames {
          flushLevelWindow()
        }
      }
    }
  }

  private func writeSilence(frames totalFrames: Int64) {
    guard let audioInput, let pcmFormatDesc, totalFrames > 0 else { return }
    var left = totalFrames
    let chunkMax = Self.audioSampleRate / 5
    let zeroChunk = [Int16](repeating: 0, count: chunkMax * 2)
    while left > 0 && audioInput.isReadyForMoreMediaData && writer.status == .writing {
      let n = Int(min(left, Int64(chunkMax)))
      let samples = n == chunkMax ? zeroChunk : Array(zeroChunk.prefix(n * 2))
      guard appendPCM16Buffer(samples, frames: n, input: audioInput, desc: pcmFormatDesc) else {
        break
      }
      for _ in 0..<n {
        windowFrameCount += 1
        if windowFrameCount == Self.levelWindowFrames {
          flushLevelWindow()
        }
      }
      left -= Int64(n)
    }
  }

  private func appendPCM16Buffer(
    _ samples: [Int16],
    frames: Int,
    input: AVAssetWriterInput,
    desc: CMAudioFormatDescription
  ) -> Bool {
    let byteCount = frames * 4
    var blockBuffer: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockBuffer
    )
    guard createStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return false }

    let copyStatus = samples.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base,
        blockBuffer: block,
        offsetIntoDestination: 0,
        dataLength: byteCount
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else { return false }

    var sampleBuffer: CMSampleBuffer?
    let pts = CMTime(value: audioFramesWritten, timescale: CMTimeScale(Self.audioSampleRate))
    let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: desc,
      sampleCount: frames,
      presentationTimeStamp: pts,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard sbStatus == noErr, let sb = sampleBuffer else { return false }
    guard input.append(sb) else { return false }
    audioFramesWritten += Int64(frames)
    return true
  }

  private func flushLevelWindow() {
    guard windowFrameCount > 0 else { return }
    let rms = sqrt(windowSquareSum / Double(windowFrameCount))
    windowSquareSum = 0.0
    windowFrameCount = 0
    levels.append(Self.levelByte(rms: rms))
  }

  public static func levelByte(rms: Double) -> UInt8 {
    guard rms > 0 else { return 0 }
    let db = 20.0 * log10(rms)
    let mapped = ((db + 50.0) / 50.0 * 255.0).rounded()
    return UInt8(min(255, max(0, Int(mapped))))
  }

  public static func bucketCount(durationMs: Double) -> Int {
    max(1, Int(ceil(durationMs / 100.0)))
  }

  public func finish(durationSeconds: Double, inputActivity: InputActivity?, completion: @escaping (Segment?) -> Void) {
    guard started, !finished else {
      abort()
      completion(nil)
      return
    }
    finished = true

    if framesWritten == 0 || writer.status != .writing {
      writer.cancelWriting()
      try? FileManager.default.removeItem(atPath: tempPath)
      completion(nil)
      return
    }

    let videoSpanSeconds = lastVideoPTS.isValid ? CMTimeGetSeconds(lastVideoPTS) + (1.0 / Double(config.frameRate)) : 0.0
    let effectiveSeconds = max(durationSeconds, videoSpanSeconds, 1.0 / Double(config.frameRate))
    let durationMs = effectiveSeconds * 1000.0

    if audioInput != nil {
      let wantAudioFrames = Int64((effectiveSeconds * Double(Self.audioSampleRate)).rounded())
      if wantAudioFrames > audioFramesWritten {
        writeSilence(frames: min(wantAudioFrames - audioFramesWritten, Int64(Self.audioSampleRate * 5)))
      }
    }
    flushLevelWindow()

    let endTime = CMTime(seconds: effectiveSeconds, preferredTimescale: 60_000)
    writer.endSession(atSourceTime: endTime)
    videoInput.markAsFinished()
    audioInput?.markAsFinished()

    let buckets = Self.bucketCount(durationMs: durationMs)
    let inputData = inputActivity?.read(startHns: startHns, count: buckets) ?? Data(repeating: 0, count: buckets)
    var levelBytes = levels
    while levelBytes.count < buckets { levelBytes.append(0) }
    if levelBytes.count > buckets { levelBytes.removeSubrange(buckets..<levelBytes.count) }

    let finalStem = stem.isEmpty ? SegmentStore.formatStem(startUtc: startUtc) : stem
    let folderCopy = folder
    let tempCopy = tempPath
    let startCopy = startUtc
    let cfg = config
    let hasAudio = audioInput != nil

    writer.finishWriting { [writer] in
      guard writer.status == .completed else {
        try? FileManager.default.removeItem(atPath: tempCopy)
        completion(nil)
        return
      }

      let basePath = (folderCopy as NSString).appendingPathComponent(finalStem)
      let mp4Path = basePath + ".mp4"
      if hasAudio {
        try? Data(levelBytes).write(to: URL(fileURLWithPath: basePath + ".levels"))
      }
      try? inputData.write(to: URL(fileURLWithPath: basePath + ".input"))

      let startISO = SegmentStore.formatISO8601UTC(startCopy)
      let durFormatted = String(format: "%.3f", durationMs)
      let jsonText = "{\"startUtc\":\"\(startISO)\",\"durationMs\":\(durFormatted),\"width\":\(cfg.width),\"height\":\(cfg.height),\"fps\":\(cfg.frameRate)}"
      AtomicFile.writeWhole(path: basePath + ".json", text: jsonText)

      if rename(tempCopy, mp4Path) != 0 {
        do {
          if FileManager.default.fileExists(atPath: mp4Path) {
            try FileManager.default.removeItem(atPath: mp4Path)
          }
          try FileManager.default.moveItem(atPath: tempCopy, toPath: mp4Path)
        } catch {
          try? FileManager.default.removeItem(atPath: tempCopy)
          completion(nil)
          return
        }
      }

      let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: mp4Path)[.size]) as? NSNumber)?.int64Value ?? 0
      let seg = Segment(
        path: mp4Path,
        startUtc: startCopy,
        endUtc: startCopy.addingTimeInterval(durationMs / 1000.0),
        bytes: fileBytes,
        width: cfg.width,
        height: cfg.height,
        durationMs: durationMs,
        fps: cfg.frameRate
      )
      completion(seg)
    }
  }

  public func finishSync(durationSeconds: Double, inputActivity: InputActivity?) -> Segment? {
    let sem = DispatchSemaphore(value: 0)
    var result: Segment?
    finish(durationSeconds: durationSeconds, inputActivity: inputActivity) { seg in
      result = seg
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10.0)
    return result
  }

  public func abort() {
    guard !finished else { return }
    finished = true
    if writer.status == .writing {
      writer.cancelWriting()
    }
    try? FileManager.default.removeItem(atPath: tempPath)
  }
}
