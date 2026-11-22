import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

public struct CaptureOptions: Sendable, Equatable {
  public var replayRoot: String
  public var bufferDir: String
  public var keepSeconds: TimeInterval
  public var maxBytes: Int64
  public var fps: Int
  public var maxHeight: Int
  public var codec: String // "HEVC" or "H264"
  public var quality: String // "low", "medium", "high", "ultra"
  public var systemAudio: Bool
  public var microphone: Bool
  public var recordCursor: Bool
  public var excludeSelf: Bool
  public var wideGamutP3: Bool
  public var displayID: UInt32
  public var segmentSeconds: Double
  public var synthetic: Bool
  public var syntheticWidth: Int
  public var syntheticHeight: Int

  public init(
    replayRoot: String,
    bufferDir: String,
    keepSeconds: TimeInterval = 7200,
    maxBytes: Int64 = 20 << 30,
    fps: Int = 60,
    maxHeight: Int = 0,
    codec: String = "HEVC",
    quality: String = "high",
    systemAudio: Bool = true,
    microphone: Bool = false,
    recordCursor: Bool = true,
    excludeSelf: Bool = true,
    wideGamutP3: Bool = false,
    displayID: UInt32 = 0,
    segmentSeconds: Double = 30.0,
    synthetic: Bool = ProcessInfo.processInfo.environment["SR_SYNTHETIC"] == "1",
    syntheticWidth: Int = 1280,
    syntheticHeight: Int = 720
  ) {
    self.replayRoot = replayRoot
    self.bufferDir = bufferDir
    self.keepSeconds = max(60, keepSeconds)
    self.maxBytes = max(0, maxBytes)
    self.fps = max(1, min(120, fps))
    self.maxHeight = max(0, maxHeight)
    self.codec = codec.lowercased() == "h264" ? "H264" : "HEVC"
    self.quality = ["low", "medium", "high", "ultra"].contains(quality) ? quality : "high"
    self.systemAudio = systemAudio
    self.microphone = microphone
    self.recordCursor = recordCursor
    self.excludeSelf = excludeSelf
    self.wideGamutP3 = wideGamutP3
    self.displayID = displayID
    self.segmentSeconds = max(0.5, segmentSeconds)
    self.synthetic = synthetic
    self.syntheticWidth = max(16, syntheticWidth & ~1)
    self.syntheticHeight = max(16, syntheticHeight & ~1)
  }

  public static func from(
    paths: RecorderPaths,
    settings: RecorderSettings,
    viewer: ViewerPrefs,
    bufferDir: String? = nil,
    syntheticOverride: Bool? = nil,
    segmentSecondsOverride: Double? = nil
  ) -> CaptureOptions {
    let resolvedBuffer = (bufferDir?.isEmpty == false) ? bufferDir! : (settings.bufferDir.isEmpty ? paths.defaultBuffer : settings.bufferDir)
    let isSynth = syntheticOverride ?? (ProcessInfo.processInfo.environment["SR_SYNTHETIC"] == "1")
    return CaptureOptions(
      replayRoot: paths.root,
      bufferDir: resolvedBuffer,
      keepSeconds: settings.windowSeconds,
      maxBytes: settings.maxBytes,
      fps: settings.frameRate,
      maxHeight: settings.maxHeight,
      codec: settings.codec,
      quality: settings.quality,
      systemAudio: settings.systemAudio,
      microphone: settings.microphone,
      recordCursor: settings.recordCursor,
      excludeSelf: viewer.hideFromCapture,
      wideGamutP3: false,
      displayID: settings.displayID,
      segmentSeconds: segmentSecondsOverride ?? 30.0,
      synthetic: isSynth
    )
  }
}

public struct CaptureMetrics: Sendable, Equatable {
  public var isRunning: Bool
  public var synthetic: Bool
  public var actualCodec: String
  public var codecFellBack: Bool
  public var width: Int
  public var height: Int
  public var screenWidth: Int
  public var screenHeight: Int
  public var fps: Int
  public var displayHz: Int
  public var bitrate: Int
  public var framesEncodedLast10s: Int
  public var framesSkippedLast10s: Int
  public var totalSegmentsClosed: Int
  public var audioTrouble: String
  public var bufferDir: String
}

/// Optional 48 kHz stereo microphone capture & ring buffer for mixing with system audio.
final class MicrophoneMixerSource: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var ring: [Int16] = [] // interleaved stereo samples
  private let maxStereoFrames = 48_000 / 2 // 500 ms cap
  private var running = false
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?

  func start() throws {
    guard Status.microphoneAllowed() else { return }
    let inputNode = engine.inputNode
    let hwFormat = inputNode.outputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
      throw HelperError("No valid microphone input format", code: "audio.micUnavailable")
    }
    guard let outFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(SegmentWriter.audioSampleRate),
      channels: 2,
      interleaved: true
    ), let conv = AVAudioConverter(from: hwFormat, to: outFormat) else {
      throw HelperError("Cannot create microphone converter", code: "audio.micFormat")
    }
    self.targetFormat = outFormat
    self.converter = conv

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
      self?.handleTap(buffer)
    }
    try engine.start()
    running = true
  }

  private func handleTap(_ buffer: AVAudioPCMBuffer) {
    guard let converter, let targetFormat else { return }
    let ratio = targetFormat.sampleRate / max(1.0, buffer.format.sampleRate)
    let cap = AVAudioFrameCount(max(64, Int(ceil(Double(buffer.frameLength) * ratio)) + 32))
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
    var supplied = false
    var err: NSError?
    let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, err == nil, outBuf.frameLength > 0, let ptr = outBuf.int16ChannelData?[0] else { return }
    let count = Int(outBuf.frameLength) * 2
    lock.lock()
    ring.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
    if ring.count > maxStereoFrames * 2 {
      ring.removeFirst(ring.count - maxStereoFrames * 2)
    }
    lock.unlock()
  }

  /// Mixes available microphone samples into `systemSamples` (`frames * 2` Int16 values).
  func mixInto(_ systemSamples: inout [Int16], frames: Int) {
    lock.lock()
    let take = min(frames * 2, ring.count)
    guard take > 0 else {
      lock.unlock()
      return
    }
    for i in 0..<take {
      let sum = Int32(systemSamples[i]) + Int32(ring[i])
      systemSamples[i] = Int16(clamping: sum)
    }
    ring.removeFirst(take)
    lock.unlock()
  }

  func drainAvailable(maxFrames: Int) -> [Int16] {
    lock.lock()
    defer { lock.unlock() }
    let availableFrames = min(maxFrames, ring.count / 2)
    guard availableFrames > 0 else { return [] }
    let out = Array(ring.prefix(availableFrames * 2))
    ring.removeFirst(availableFrames * 2)
    return out
  }

  func stop() {
    guard running else { return }
    running = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.lock()
    ring.removeAll()
    lock.unlock()
  }
}

/// Zero-Backpressure `ScreenCaptureKit` + `Synthetic` Rolling Segment Recorder.
public final class ReplayCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private static let excludedBundleIDs: Set<String> = [
    "dev.pengx17.screenreplay",
    "dev.pengx17.screenreplay.helper",
    "dev.pengx17.screenreplay.viewer",
  ]
  private static let excludedAppNames: Set<String> = [
    "ScreenReplay",
    "ScreenReplayMac",
    "ScreenReplayViewer",
    "ScreenReplay Helper",
    "ScreenReplayHelper",
  ]

  public let store: SegmentStore
  public let inputMonitor: InputActivityMonitor
  public let windowTracker: WindowTracker
  private let logger: RecorderLogger?

  private let videoCaptureQueue = DispatchQueue(label: "dev.pengx17.screenreplay.sc.video", qos: .userInteractive)
  private let audioCaptureQueue = DispatchQueue(label: "dev.pengx17.screenreplay.sc.audio", qos: .userInteractive)
  private let writerQueue = DispatchQueue(label: "dev.pengx17.screenreplay.writer", qos: .userInteractive)
  private let prepareQueue = DispatchQueue(label: "dev.pengx17.screenreplay.prepare", qos: .utility)
  private let finalizeQueue = DispatchQueue(label: "dev.pengx17.screenreplay.finalize", qos: .utility)
  private let finalizeGroup = DispatchGroup()

  private let stateLock = NSLock()
  private var inFlightVideoFrames = 0
  private var metricsState: CaptureMetrics

  private var options: CaptureOptions
  private var encodeConfig: SegmentEncodeConfig?
  private var stream: SCStream?
  private var micSource: MicrophoneMixerSource?
  private var micPumpTimer: DispatchSourceTimer?

  private var syntheticVideoTimer: DispatchSourceTimer?
  private var syntheticAudioTimer: DispatchSourceTimer?
  private var syntheticPool: CVPixelBufferPool?
  private var syntheticTick: Int = 0
  private var syntheticAudioFrameCounter: Int64 = 0

  private var running = false
  private var currentWriter: SegmentWriter?
  private var nextWriter: SegmentWriter?
  private var preparingNext = false
  private var lastPixelBuffer: CVPixelBuffer?

  private var segmentStartHns: Int64 = 0
  private var captureOriginPTS: CMTime = .invalid
  private var captureOriginHns: Int64 = 0

  private var paceWindowStartHns: Int64 = 0
  private var paceEncoded: Int = 0
  private var paceSkipped: Int = 0

  public var onSegmentClosed: ((Segment) -> Void)?
  public var onFault: ((String) -> Void)?

  public init(options: CaptureOptions, logger: RecorderLogger? = nil) {
    self.options = options
    self.store = SegmentStore(folder: options.bufferDir)
    self.inputMonitor = InputActivityMonitor()
    let paths = RecorderPaths(root: options.replayRoot, buffer: options.bufferDir)
    self.windowTracker = WindowTracker(paths: paths, logger: logger)
    self.logger = logger
    self.metricsState = CaptureMetrics(
      isRunning: false,
      synthetic: options.synthetic,
      actualCodec: "",
      codecFellBack: false,
      width: 0,
      height: 0,
      screenWidth: 0,
      screenHeight: 0,
      fps: options.fps,
      displayHz: 60,
      bitrate: 0,
      framesEncodedLast10s: 0,
      framesSkippedLast10s: 0,
      totalSegmentsClosed: 0,
      audioTrouble: "",
      bufferDir: options.bufferDir
    )
    super.init()
  }

  public var metrics: CaptureMetrics {
    stateLock.lock()
    defer { stateLock.unlock() }
    return metricsState
  }

  public var isRunning: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return metricsState.isRunning
  }

  public func start() throws {
    if isRunning { return }
    store.deleteUnfinished()

    if options.synthetic {
      try startSynthetic()
    } else {
      try startScreenCaptureKit()
    }
  }

  private func makeFirstWriter(width: Int, height: Int, wantHevc: Bool, hasAudio: Bool, wideGamutP3: Bool) throws -> (SegmentWriter, SegmentEncodeConfig, Bool) {
    let hevcBitrate = Bitrate.compute(width: width, height: height, frameRate: options.fps, quality: options.quality, codec: wantHevc ? "HEVC" : "H264")
    let cfg = SegmentEncodeConfig(
      width: width,
      height: height,
      frameRate: options.fps,
      bitrate: hevcBitrate,
      hevc: wantHevc,
      audio: hasAudio,
      wideGamutP3: wideGamutP3
    )
    do {
      let w = try SegmentWriter(folder: options.bufferDir, config: cfg)
      return (w, cfg, false)
    } catch {
      guard wantHevc else { throw error }
      logger?.log("warning video.hevcUnavailable: falling back to H.264 (\(error))")
      let h264Bitrate = Bitrate.compute(width: width, height: height, frameRate: options.fps, quality: options.quality, codec: "H264")
      let fallbackCfg = SegmentEncodeConfig(
        width: width,
        height: height,
        frameRate: options.fps,
        bitrate: h264Bitrate,
        hevc: false,
        audio: hasAudio,
        wideGamutP3: wideGamutP3
      )
      let w = try SegmentWriter(folder: options.bufferDir, config: fallbackCfg)
      return (w, fallbackCfg, true)
    }
  }

  private func startSynthetic() throws {
    let rawW = options.syntheticWidth
    let rawH = options.syntheticHeight
    let fitted = Bitrate.fitDimensions(width: rawW, height: rawH, maxHeight: options.maxHeight)
    let wantHevc = options.codec.uppercased() == "HEVC"
    let hasAudio = options.systemAudio || options.microphone
    let (firstWriter, cfg, fellBack) = try makeFirstWriter(
      width: fitted.width,
      height: fitted.height,
      wantHevc: wantHevc,
      hasAudio: hasAudio,
      wideGamutP3: false
    )

    var pool: CVPixelBufferPool?
    let poolAttrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferWidthKey: fitted.width,
      kCVPixelBufferHeightKey: fitted.height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &pool)
    guard let createdPool = pool else {
      firstWriter.abort()
      throw HelperError("Failed to create synthetic 420v IOSurface pool", code: "pool")
    }

    writerQueue.sync {
      self.encodeConfig = cfg
      self.syntheticPool = createdPool
      self.syntheticTick = 0
      self.syntheticAudioFrameCounter = 0
      self.running = true
      let nowHns = MonotonicClock.nowHns()
      self.captureOriginHns = nowHns
      self.captureOriginPTS = .invalid
      self.paceWindowStartHns = nowHns
      self.paceEncoded = 0
      self.paceSkipped = 0
      self.segmentStartHns = nowHns
      firstWriter.begin(startUtc: Date(), startHns: nowHns)
      self.currentWriter = firstWriter
      self.schedulePrepareNextWriter()
    }

    stateLock.lock()
    metricsState.isRunning = true
    metricsState.synthetic = true
    metricsState.actualCodec = cfg.hevc ? "HEVC" : "H264"
    metricsState.codecFellBack = fellBack
    metricsState.width = cfg.width
    metricsState.height = cfg.height
    metricsState.screenWidth = rawW
    metricsState.screenHeight = rawH
    metricsState.fps = cfg.frameRate
    metricsState.displayHz = 120
    metricsState.bitrate = cfg.bitrate
    metricsState.bufferDir = options.bufferDir
    stateLock.unlock()

    inputMonitor.start(synthetic: true)
    windowTracker.start(displayID: 0, excludeSelf: options.excludeSelf, synthetic: true)

    let frameIntervalNs = max(1_000_000, 1_000_000_000 / cfg.frameRate)
    let vTimer = DispatchSource.makeTimerSource(queue: videoCaptureQueue)
    vTimer.schedule(deadline: .now(), repeating: .nanoseconds(frameIntervalNs), leeway: .microseconds(500))
    vTimer.setEventHandler { [weak self] in
      self?.emitSyntheticVideoFrame()
    }
    syntheticVideoTimer = vTimer
    vTimer.resume()

    if hasAudio {
      let aTimer = DispatchSource.makeTimerSource(queue: audioCaptureQueue)
      aTimer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
      aTimer.setEventHandler { [weak self] in
        self?.emitSyntheticAudioPacket()
      }
      syntheticAudioTimer = aTimer
      aTimer.resume()
    }

    logger?.log("info recorder.started: SYNTHETIC \(cfg.hevc ? "HEVC" : "H264") \(cfg.width)x\(cfg.height) @ \(cfg.frameRate) fps (\(cfg.bitrate / 1000) kbps)")
  }

  private func emitSyntheticVideoFrame() {
    guard let pool = syntheticPool, let cfg = encodeConfig else { return }
    var pbOut: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess,
          let pb = pbOut
    else { return }

    let tick = syntheticTick
    syntheticTick += 1
    Self.fillSynthetic420vFrame(pb, width: cfg.width, height: cfg.height, tick: tick, fps: cfg.frameRate)

    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

    if tick % 15 == 0 {
      inputMonitor.activity.recordKey()
    }
    if tick % 30 == 0 {
      inputMonitor.activity.recordClick(1)
    }

    let frameHns = captureOriginHns + Int64((Double(tick) * 10_000_000.0 / Double(cfg.frameRate)).rounded())
    enqueueVideoFrame(pb, frameHns: frameHns)
  }

  private func emitSyntheticAudioPacket() {
    let frames = 960 // 20 ms @ 48 kHz
    let baseSample = syntheticAudioFrameCounter
    syntheticAudioFrameCounter += Int64(frames)

    var pcm = [Int16](repeating: 0, count: frames * 2)
    let rate = Double(SegmentWriter.audioSampleRate)
    for i in 0..<frames {
      let sampleIdx = baseSample + Int64(i)
      let t = Double(sampleIdx) / rate
      // 150 ms 440 Hz / 660 Hz beep pulse every 0.5 s, soft carrier otherwise.
      let phaseInHalfSec = sampleIdx % Int64(SegmentWriter.audioSampleRate / 2)
      let amp: Double = phaseInHalfSec < Int64(SegmentWriter.audioSampleRate * 15 / 100) ? 0.35 : 0.03
      pcm[i * 2] = Int16((sin(2.0 * .pi * 440.0 * t) * amp) * 32767.0)
      pcm[i * 2 + 1] = Int16((sin(2.0 * .pi * 660.0 * t) * amp) * 32767.0)
    }

    let packetHns = captureOriginHns + (baseSample * 10_000_000 / Int64(SegmentWriter.audioSampleRate))
    writerQueue.async { [weak self] in
      self?.handleAudioPCM(pcm, frames: frames, packetHns: packetHns)
    }
  }

  /// Renders a moving diagonal/vertical color bar + bottom timestamp progress bar directly into a `420v` `IOSurface`.
  public static func fillSynthetic420vFrame(_ pb: CVPixelBuffer, width: Int, height: Int, tick: Int, fps: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
    else { return }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

    let stripeWidth = max(24, width / 8)
    let stripeX = (tick * 12) % max(1, width - stripeWidth)
    let barHeight = max(16, height / 16)
    let barYStart = height - barHeight - 16
    let progressWidth = ((tick % max(1, fps * 2)) * (width - 64)) / max(1, fps * 2)

    // Plane 0: Y (video range 16...235)
    for y in 0..<height {
      let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
      memset(row, 30, width)
      let inStripeY = y >= height / 6 && y < (height * 5) / 6
      if inStripeY {
        let count = min(stripeWidth, width - stripeX)
        if count > 0 {
          memset(row.advanced(by: stripeX), 185, count)
        }
      }
      if y >= barYStart && y < barYStart + barHeight {
        memset(row.advanced(by: 32), 60, max(0, width - 64))
        if progressWidth > 0 {
          memset(row.advanced(by: 32), 215, min(progressWidth, width - 64))
        }
      }
    }

    // Plane 1: interleaved Cb, Cr (neutral = 128, 128)
    let uvW = width / 2
    let uvH = height / 2
    let uvStripeX = stripeX / 2
    let uvStripeW = stripeWidth / 2
    let uvProgressW = progressWidth / 2
    for uy in 0..<uvH {
      let row = uvBase.advanced(by: uy * uvStride).assumingMemoryBound(to: UInt8.self)
      memset(row, 128, uvW * 2)
      let y = uy * 2
      if y >= height / 6 && y < (height * 5) / 6 {
        let end = min(uvW, uvStripeX + uvStripeW)
        if end > uvStripeX {
          for ux in uvStripeX..<end {
            row[ux * 2] = 96     // Cb
            row[ux * 2 + 1] = 208 // Cr (warm red/coral)
          }
        }
      }
      if y >= barYStart && y < barYStart + barHeight {
        let startUX = 16
        let endUX = min(uvW - 16, startUX + uvProgressW)
        if endUX > startUX {
          for ux in startUX..<endUX {
            row[ux * 2] = 188    // Cb (cyan/blue accent)
            row[ux * 2 + 1] = 92 // Cr
          }
        }
      }
    }
  }

  private func startScreenCaptureKit() throws {
    guard Status.captureAllowed() else {
      throw HelperError("Screen Recording permission not granted", code: "capture")
    }

    var startError: Error?
    let sem = DispatchSemaphore(value: 0)

    Task {
      defer { sem.signal() }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targetID = self.options.displayID == 0 ? CGMainDisplayID() : self.options.displayID
        guard let scDisplay = content.displays.first(where: { $0.displayID == targetID }) ?? content.displays.first else {
          throw HelperError("No display available to capture", code: "noDisplay")
        }

        let dispInfo = Status.display(scDisplay.displayID)
        let rawW = (dispInfo["width"] as? Int) ?? scDisplay.width
        let rawH = (dispInfo["height"] as? Int) ?? scDisplay.height
        let dispHz = Int(((dispInfo["refreshRate"] as? Double) ?? 60.0).rounded())
        let useP3 = self.options.wideGamutP3 || ((dispInfo["wideGamut"] as? Bool) ?? false)

        let fitted = Bitrate.fitDimensions(width: rawW, height: rawH, maxHeight: self.options.maxHeight)
        let wantHevc = self.options.codec.uppercased() == "HEVC"
        let wantMic = self.options.microphone && Status.microphoneAllowed()
        let hasAudio = self.options.systemAudio || wantMic

        let (firstWriter, cfg, fellBack) = try self.makeFirstWriter(
          width: fitted.width,
          height: fitted.height,
          wantHevc: wantHevc,
          hasAudio: hasAudio,
          wideGamutP3: useP3
        )

        let ownPID = getpid()
        let excludedApps: [SCRunningApplication]
        if self.options.excludeSelf {
          excludedApps = content.applications.filter { app in
            app.processID == ownPID ||
              Self.excludedBundleIDs.contains(app.bundleIdentifier) ||
              Self.excludedAppNames.contains(app.applicationName)
          }
        } else {
          excludedApps = []
        }

        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        let scConfig = SCStreamConfiguration()
        scConfig.width = cfg.width
        scConfig.height = cfg.height
        scConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.frameRate))
        scConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        scConfig.colorSpaceName = useP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        scConfig.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        scConfig.queueDepth = 8
        scConfig.showsCursor = self.options.recordCursor

        if self.options.systemAudio {
          scConfig.capturesAudio = true
          scConfig.excludesCurrentProcessAudio = true
          scConfig.sampleRate = SegmentWriter.audioSampleRate
          scConfig.channelCount = SegmentWriter.audioChannels
          if #available(macOS 15.0, *) {
            scConfig.captureMicrophone = false
          }
        }

        let createdStream = SCStream(filter: filter, configuration: scConfig, delegate: self)
        try createdStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoCaptureQueue)

        var audioTrouble = ""
        if self.options.systemAudio {
          do {
            try createdStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioCaptureQueue)
          } catch {
            audioTrouble = "audio.systemFailed"
            self.logger?.log("warning audio.systemFailed: \(error.localizedDescription)")
          }
        }

        var mic: MicrophoneMixerSource?
        if wantMic {
          let m = MicrophoneMixerSource()
          do {
            try m.start()
            mic = m
          } catch {
            audioTrouble = "audio.micFailed"
            self.logger?.log("warning audio.micFailed: \(error)")
          }
        }

        self.writerQueue.sync {
          self.encodeConfig = cfg
          self.micSource = mic
          self.running = true
          let nowHns = MonotonicClock.nowHns()
          self.captureOriginHns = nowHns
          self.captureOriginPTS = .invalid
          self.paceWindowStartHns = nowHns
          self.paceEncoded = 0
          self.paceSkipped = 0
          self.segmentStartHns = nowHns
          firstWriter.begin(startUtc: Date(), startHns: nowHns)
          self.currentWriter = firstWriter
          self.schedulePrepareNextWriter()
        }

        do {
          try await createdStream.startCapture()
        } catch {
          self.writerQueue.sync {
            self.running = false
            self.currentWriter?.abort()
            self.currentWriter = nil
            self.nextWriter?.abort()
            self.nextWriter = nil
            self.micSource?.stop()
            self.micSource = nil
          }
          throw error
        }

        if !self.options.systemAudio, let mic {
          let mTimer = DispatchSource.makeTimerSource(queue: self.audioCaptureQueue)
          mTimer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
          mTimer.setEventHandler { [weak self, weak mic] in
            guard let self, let mic else { return }
            let samples = mic.drainAvailable(maxFrames: 1920)
            guard !samples.isEmpty else { return }
            let hns = MonotonicClock.nowHns()
            self.writerQueue.async {
              self.handleAudioPCM(samples, frames: samples.count / 2, packetHns: hns)
            }
          }
          mTimer.resume()
          self.micPumpTimer = mTimer
        }

        self.stream = createdStream
        self.stateLock.lock()
        self.metricsState.isRunning = true
        self.metricsState.synthetic = false
        self.metricsState.actualCodec = cfg.hevc ? "HEVC" : "H264"
        self.metricsState.codecFellBack = fellBack
        self.metricsState.width = cfg.width
        self.metricsState.height = cfg.height
        self.metricsState.screenWidth = rawW
        self.metricsState.screenHeight = rawH
        self.metricsState.fps = cfg.frameRate
        self.metricsState.displayHz = dispHz
        self.metricsState.bitrate = cfg.bitrate
        self.metricsState.audioTrouble = audioTrouble
        self.metricsState.bufferDir = self.options.bufferDir
        self.stateLock.unlock()

        self.inputMonitor.start(synthetic: false)
        self.windowTracker.start(displayID: scDisplay.displayID, excludeSelf: self.options.excludeSelf, synthetic: false)
        self.logger?.log("info recorder.started: \(cfg.hevc ? "HEVC" : "H264") \(cfg.width)x\(cfg.height) @ \(cfg.frameRate) fps (\(cfg.bitrate / 1000) kbps), displayHz=\(dispHz)")
      } catch {
        startError = error
      }
    }

    sem.wait()
    if let startError {
      throw startError
    }
  }

  // MARK: - SCStreamOutput & SCStreamDelegate (Zero-Backpressure)

  public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    switch type {
    case .screen:
      guard CMSampleBufferIsValid(sample), let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
         let rawStatus = attachments.first?[.status] as? Int,
         let status = SCFrameStatus(rawValue: rawStatus),
         status != .complete
      {
        // Skip .idle / .blank / .suspended frames immediately with zero work.
        return
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      let frameHns = timestampToHns(pts)
      enqueueVideoFrame(imageBuffer, frameHns: frameHns)

    case .audio:
      guard CMSampleBufferIsValid(sample),
            let format = CMSampleBufferGetFormatDescription(sample),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            Int(asbd.mSampleRate) == SegmentWriter.audioSampleRate,
            var pcm = Self.extractStereoPCM16(sample, asbd: asbd)
      else { return }

      let frames = pcm.count / 2
      guard frames > 0 else { return }
      micSource?.mixInto(&pcm, frames: frames)
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      let packetHns = timestampToHns(pts)
      writerQueue.async { [weak self] in
        self?.handleAudioPCM(pcm, frames: frames, packetHns: packetHns)
      }

    default:
      break
    }
  }

  public func stream(_ stream: SCStream, didStopWithError error: Error) {
    logger?.log("error capture.stopped: \(error.localizedDescription)")
    stateLock.lock()
    metricsState.isRunning = false
    stateLock.unlock()
    onFault?(error.localizedDescription)
  }

  private func timestampToHns(_ pts: CMTime) -> Int64 {
    guard pts.isValid && !pts.isIndefinite else {
      return MonotonicClock.nowHns()
    }
    stateLock.lock()
    if !captureOriginPTS.isValid {
      captureOriginPTS = pts
      captureOriginHns = MonotonicClock.nowHns()
    }
    let originPTS = captureOriginPTS
    let originHns = captureOriginHns
    stateLock.unlock()
    let deltaSec = CMTimeGetSeconds(CMTimeSubtract(pts, originPTS))
    return originHns + Int64((deltaSec * 10_000_000.0).rounded())
  }

  private func enqueueVideoFrame(_ pixelBuffer: CVPixelBuffer, frameHns: Int64) {
    // Strict zero-backpressure gate: never hold more than 2 frames in flight to `writerQueue`
    // so WindowServer's `IOSurface` pool (queueDepth = 8) always has >= 6 free buffers.
    stateLock.lock()
    if inFlightVideoFrames >= 2 {
      stateLock.unlock()
      writerQueue.async { [weak self] in
        self?.recordPace(encoded: false)
      }
      return
    }
    inFlightVideoFrames += 1
    stateLock.unlock()

    writerQueue.async { [weak self] in
      defer {
        if let self {
          self.stateLock.lock()
          self.inFlightVideoFrames -= 1
          self.stateLock.unlock()
        }
      }
      self?.handleVideoFrameOnWriterQueue(pixelBuffer, frameHns: frameHns)
    }
  }

  private func handleVideoFrameOnWriterQueue(_ pixelBuffer: CVPixelBuffer, frameHns: Int64) {
    guard running, let writer = currentWriter else { return }
    lastPixelBuffer = pixelBuffer

    let segLimitHns = Int64((options.segmentSeconds * 10_000_000.0).rounded())
    let elapsedHns = max(0, frameHns - segmentStartHns)
    if elapsedHns >= segLimitHns && writer.framesWritten > 0 {
      rotateSegmentOnWriterQueue(boundaryHns: frameHns, seedFrame: pixelBuffer)
      return
    }

    let relSeconds = Double(elapsedHns) / 10_000_000.0
    let relPTS = CMTime(seconds: max(0, relSeconds), preferredTimescale: 60_000)
    let ok = writer.appendVideo(pixelBuffer: pixelBuffer, relativeTime: relPTS)
    recordPace(encoded: ok)
  }

  private func handleAudioPCM(_ pcm: [Int16], frames: Int, packetHns: Int64) {
    guard running, let writer = currentWriter else { return }
    let offsetHns = max(0, packetHns - segmentStartHns)
    let frameOffset = (offsetHns * Int64(SegmentWriter.audioSampleRate)) / 10_000_000
    writer.appendAudio(pcmInt16: pcm, frames: frames, targetFrameOffset: frameOffset)
  }

  private func recordPace(encoded: Bool) {
    if encoded {
      paceEncoded += 1
    } else {
      paceSkipped += 1
    }
    let nowHns = MonotonicClock.nowHns()
    if nowHns - paceWindowStartHns >= 100_000_000 { // 10 s
      let enc = paceEncoded
      let skp = paceSkipped
      paceEncoded = 0
      paceSkipped = 0
      paceWindowStartHns = nowHns
      stateLock.lock()
      metricsState.framesEncodedLast10s = enc
      metricsState.framesSkippedLast10s = skp
      stateLock.unlock()
    }
  }

  private func schedulePrepareNextWriter() {
    guard !preparingNext, nextWriter == nil, let cfg = encodeConfig else { return }
    preparingNext = true
    let folder = options.bufferDir
    prepareQueue.async { [weak self] in
      let made = try? SegmentWriter(folder: folder, config: cfg)
      self?.writerQueue.async {
        guard let self else {
          made?.abort()
          return
        }
        self.preparingNext = false
        if self.running && self.nextWriter == nil {
          self.nextWriter = made
        } else {
          made?.abort()
        }
      }
    }
  }

  @discardableResult
  private func rotateSegmentOnWriterQueue(boundaryHns: Int64, seedFrame: CVPixelBuffer?) -> Bool {
    guard running, let closing = currentWriter, let cfg = encodeConfig else { return false }

    let replacement: SegmentWriter
    if let prewarmed = nextWriter {
      nextWriter = nil
      replacement = prewarmed
    } else if let fresh = try? SegmentWriter(folder: options.bufferDir, config: cfg) {
      replacement = fresh
    } else {
      return false
    }

    let durationSec = max(1.0 / Double(cfg.frameRate), Double(max(0, boundaryHns - segmentStartHns)) / 10_000_000.0)
    if closing.framesWritten == 0, let fallbackFrame = seedFrame ?? lastPixelBuffer {
      _ = closing.appendVideo(pixelBuffer: fallbackFrame, relativeTime: .zero)
    }

    segmentStartHns = boundaryHns
    replacement.begin(startUtc: Date(), startHns: boundaryHns)
    if let firstFrame = seedFrame ?? lastPixelBuffer {
      _ = replacement.appendVideo(pixelBuffer: firstFrame, relativeTime: .zero)
      recordPace(encoded: true)
    }
    currentWriter = replacement
    schedulePrepareNextWriter()

    finalizeClosedWriter(closing, durationSeconds: durationSec)
    return true
  }

  private func finalizeClosedWriter(_ writer: SegmentWriter, durationSeconds: Double) {
    let activity = inputMonitor.activity
    let keepSeconds = options.keepSeconds
    let maxBytes = options.maxBytes
    finalizeGroup.enter()
    finalizeQueue.async { [weak self] in
      defer { self?.finalizeGroup.leave() }
      let seg = writer.finishSync(durationSeconds: durationSeconds, inputActivity: activity)
      guard let self, let seg else { return }
      _ = self.store.prune(before: Date().addingTimeInterval(-keepSeconds))
      _ = self.store.pruneToLimits(maxBytes: maxBytes)
      self.stateLock.lock()
      self.metricsState.totalSegmentsClosed += 1
      self.stateLock.unlock()
      self.onSegmentClosed?(seg)
    }
  }

  /// Flushes the active segment on demand (`flush.request` / `record.flush`) and waits until it lands in `Buffer/`.
  @discardableResult
  public func flush(minDurationSeconds: Double = 0.0) -> Segment? {
    var rotated = false
    writerQueue.sync {
      guard self.running, let cur = self.currentWriter else { return }
      let nowHns = MonotonicClock.nowHns()
      let elapsedSec = Double(max(0, nowHns - self.segmentStartHns)) / 10_000_000.0
      if elapsedSec < minDurationSeconds {
        return
      }
      if cur.framesWritten == 0 && self.lastPixelBuffer == nil {
        return
      }
      rotated = self.rotateSegmentOnWriterQueue(boundaryHns: nowHns, seedFrame: self.lastPixelBuffer)
    }
    if rotated {
      _ = finalizeGroup.wait(timeout: .now() + 10.0)
    }
    return store.list().last
  }

  /// Stops capture and finalizes the active segment cleanly.
  public func stop() {
    syntheticVideoTimer?.cancel()
    syntheticVideoTimer = nil
    syntheticAudioTimer?.cancel()
    syntheticAudioTimer = nil
    micPumpTimer?.cancel()
    micPumpTimer = nil

    if let activeStream = stream {
      stream = nil
      let sem = DispatchSemaphore(value: 0)
      activeStream.stopCapture { _ in sem.signal() }
      _ = sem.wait(timeout: .now() + 3.0)
    }

    micSource?.stop()
    micSource = nil
    inputMonitor.stop()
    windowTracker.stop()

    var closing: (SegmentWriter, Double)?
    writerQueue.sync {
      guard self.running else { return }
      self.running = false
      self.nextWriter?.abort()
      self.nextWriter = nil
      if let cur = self.currentWriter {
        let nowHns = MonotonicClock.nowHns()
        let durSec = max(1.0 / Double(max(1, self.options.fps)), Double(max(0, nowHns - self.segmentStartHns)) / 10_000_000.0)
        closing = (cur, durSec)
        self.currentWriter = nil
      }
      self.lastPixelBuffer = nil
      self.syntheticPool = nil
    }

    if let (writer, durSec) = closing {
      finalizeClosedWriter(writer, durationSeconds: durSec)
    }
    _ = finalizeGroup.wait(timeout: .now() + 10.0)

    stateLock.lock()
    metricsState.isRunning = false
    stateLock.unlock()
    logger?.log("info recorder.stopped")
  }

  public func statusJSON() -> [String: Any] {
    let m = metrics
    return [
      "recording": m.isRunning,
      "synthetic": m.synthetic,
      "codec": m.actualCodec,
      "codecWhy": m.codecFellBack ? "fallback" : "",
      "width": m.width,
      "height": m.height,
      "screenWidth": m.screenWidth,
      "screenHeight": m.screenHeight,
      "fps": m.fps,
      "displayHz": m.displayHz,
      "bitrate": m.bitrate,
      "framesEncoded": m.framesEncodedLast10s,
      "framesSkipped": m.framesSkippedLast10s,
      "segmentsClosed": m.totalSegmentsClosed,
      "audioTrouble": m.audioTrouble,
      "bufferDir": m.bufferDir,
    ]
  }

  // MARK: - Audio Conversion Helper (48 kHz Float32 / Int16 Planar or Interleaved -> Stereo Int16)

  public static func extractStereoPCM16(_ sample: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Int16]? {
    let frames = CMSampleBufferGetNumSamples(sample)
    let channels = Int(asbd.mChannelsPerFrame)
    guard frames > 0, channels > 0 else { return [] }

    let isFloat = asbd.mFormatID == kAudioFormatLinearPCM &&
      (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
      asbd.mBitsPerChannel == 32
    let isInt16 = asbd.mFormatID == kAudioFormatLinearPCM &&
      (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
      asbd.mBitsPerChannel == 16 &&
      (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
    guard isFloat || isInt16 else { return nil }

    let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    var needed = 0
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: &needed,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil
    ) == noErr, needed > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: nil,
      bufferListOut: list,
      bufferListSize: needed,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &block
    ) == noErr else { return nil }

    let buffers = UnsafeMutableAudioBufferListPointer(list).map {
      UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize))
    }
    let sampleWidth = isFloat ? 4 : 2

    func sampleValue(_ ch: Int, _ frame: Int) -> Int16 {
      let buf: UnsafeRawBufferPointer?
      let idx: Int
      if planar {
        buf = ch < buffers.count ? buffers[ch] : nil
        idx = frame
      } else {
        buf = buffers.first
        idx = frame * channels + ch
      }
      guard let buf, let base = buf.baseAddress, (idx + 1) * sampleWidth <= buf.count else { return 0 }
      if !isFloat {
        return base.loadUnaligned(fromByteOffset: idx * 2, as: Int16.self)
      }
      let v = base.loadUnaligned(fromByteOffset: idx * 4, as: Float32.self)
      guard v.isFinite else { return 0 }
      return Int16((min(1.0, max(-1.0, v)) * 32767.0).rounded())
    }

    var out = [Int16](repeating: 0, count: frames * 2)
    let rightCh = min(1, channels - 1)
    for f in 0..<frames {
      out[f * 2] = sampleValue(0, f)
      out[f * 2 + 1] = sampleValue(rightCh, f)
    }
    return out
  }
}
