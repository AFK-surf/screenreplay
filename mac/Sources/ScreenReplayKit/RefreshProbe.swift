import AppKit
import Foundation
import Metal
import QuartzCore

public struct RefreshStats: Sendable, Equatable {
  public let sampleCount: Int
  public let p5Ms: Double
  public let p50Ms: Double
  public let p95Ms: Double
  public let meanMs: Double
  public let meanFps: Double
  public let pctNear180Hz: Double
  public let pctNear120Hz: Double
  public let pctNear60Hz: Double

  public func toJSON() -> [String: Any] {
    [
      "sampleCount": sampleCount,
      "p5Ms": round3(p5Ms),
      "p50Ms": round3(p50Ms),
      "p95Ms": round3(p95Ms),
      "meanMs": round3(meanMs),
      "meanFps": round2(meanFps),
      "pctNear180Hz": round2(pctNear180Hz),
      "pctNear120Hz": round2(pctNear120Hz),
      "pctNear60Hz": round2(pctNear60Hz),
    ]
  }

  private func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }
  private func round3(_ v: Double) -> Double { (v * 1000.0).rounded() / 1000.0 }
}

public enum RefreshProbe {
  public static func computeStats(deltasMs: [Double]) -> RefreshStats {
    let valid = deltasMs.filter { $0 > 0.5 && $0 < 250.0 }.sorted()
    guard !valid.isEmpty else {
      return RefreshStats(
        sampleCount: 0, p5Ms: 0, p50Ms: 0, p95Ms: 0,
        meanMs: 0, meanFps: 0, pctNear180Hz: 0, pctNear120Hz: 0, pctNear60Hz: 0
      )
    }
    func percentile(_ p: Double) -> Double {
      let idx = min(valid.count - 1, max(0, Int((Double(valid.count - 1) * p).rounded())))
      return valid[idx]
    }
    let sum = valid.reduce(0.0, +)
    let mean = sum / Double(valid.count)
    let fps = mean > 0 ? 1000.0 / mean : 0
    let near180 = Double(valid.filter { $0 <= 6.8 }.count) * 100.0 / Double(valid.count)
    let near120 = Double(valid.filter { $0 <= 10.5 }.count) * 100.0 / Double(valid.count)
    let near60 = Double(valid.filter { $0 >= 14.0 && $0 <= 19.5 }.count) * 100.0 / Double(valid.count)
    return RefreshStats(
      sampleCount: valid.count,
      p5Ms: percentile(0.05),
      p50Ms: percentile(0.50),
      p95Ms: percentile(0.95),
      meanMs: mean,
      meanFps: fps,
      pctNear180Hz: near180,
      pctNear120Hz: near120,
      pctNear60Hz: near60
    )
  }

  public static func runCLI(arguments: [String]) -> Never {
    var seconds: Double = 30.0
    var withRecording = false
    var synthetic = false
    var i = 0
    while i < arguments.count {
      switch arguments[i] {
      case "--seconds":
        if i + 1 < arguments.count, let v = Double(arguments[i + 1]), v > 0 {
          seconds = min(300.0, max(1.0, v))
          i += 1
        }
      case "--record":
        withRecording = true
      case "--synthetic":
        synthetic = true
      default:
        break
      }
      i += 1
    }

    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)

    let runner = MainActor.assumeIsolated {
      ProbeWindowRunner(seconds: seconds, withRecording: withRecording, synthetic: synthetic)
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        runner.start()
      }
    }
    app.run()
    exit(0)
  }
}

@MainActor
private final class ProbeMetalView: NSView {
  private let metalLayer = CAMetalLayer()
  private let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  private var link: CADisplayLink?
  private var tickCount: UInt64 = 0

  private let lock = NSLock()
  nonisolated(unsafe) private var lastLinkTimestamp: CFTimeInterval = 0
  nonisolated(unsafe) private var lastPresentedTime: CFTimeInterval = 0
  nonisolated(unsafe) private(set) var linkDeltasMs: [Double] = []
  nonisolated(unsafe) private(set) var presentedDeltasMs: [Double] = []

  override init(frame frameRect: NSRect) {
    let dev = MTLCreateSystemDefaultDevice()
    self.device = dev
    self.commandQueue = dev?.makeCommandQueue()
    super.init(frame: frameRect)
    wantsLayer = true
    metalLayer.device = dev
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.displaySyncEnabled = true
    metalLayer.drawableSize = CGSize(width: 128, height: 128)
    layer = metalLayer
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func startDisplayLink() {
    let dl = self.displayLink(target: self, selector: #selector(onDisplayLink(_:)))
    let maxHz = Float(max(60, self.window?.screen?.maximumFramesPerSecond ?? 120))
    dl.preferredFrameRateRange = CAFrameRateRange(minimum: maxHz, maximum: maxHz, preferred: maxHz)
    dl.add(to: .main, forMode: .common)
    self.link = dl
  }

  func stopDisplayLink() {
    link?.invalidate()
    link = nil
  }

  @objc private func onDisplayLink(_ sender: CADisplayLink) {
    let ts = sender.timestamp
    lock.lock()
    if lastLinkTimestamp > 0 {
      linkDeltasMs.append((ts - lastLinkTimestamp) * 1000.0)
    }
    lastLinkTimestamp = ts
    lock.unlock()

    guard let commandQueue,
          let drawable = metalLayer.nextDrawable(),
          let cmd = commandQueue.makeCommandBuffer()
    else { return }

    tickCount &+= 1
    let r = Double((tickCount &* 29) & 0xFF) / 255.0
    let g = Double((tickCount &* 53) & 0xFF) / 255.0
    let b = Double((tickCount &* 97) & 0xFF) / 255.0
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0.12 + 0.35 * r,
      green: 0.12 + 0.35 * g,
      blue: 0.14 + 0.35 * b,
      alpha: 0.96
    )
    if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
      enc.endEncoding()
    }

    drawable.addPresentedHandler { [weak self] presentedDrawable in
      guard let self else { return }
      let pt = presentedDrawable.presentedTime
      let actual = pt > 0 ? pt : CACurrentMediaTime()
      self.lock.lock()
      if self.lastPresentedTime > 0 {
        let delta = (actual - self.lastPresentedTime) * 1000.0
        if delta > 0.5 {
          self.presentedDeltasMs.append(delta)
        }
      }
      self.lastPresentedTime = actual
      self.lock.unlock()
    }

    cmd.present(drawable)
    cmd.commit()
  }

  func snapshotStats() -> (presented: RefreshStats, displayLink: RefreshStats) {
    lock.lock()
    let pCopy = presentedDeltasMs
    let lCopy = linkDeltasMs
    lock.unlock()
    return (
      RefreshProbe.computeStats(deltasMs: pCopy),
      RefreshProbe.computeStats(deltasMs: lCopy)
    )
  }
}

@MainActor
private final class ProbeWindowRunner {
  private let seconds: Double
  private let withRecording: Bool
  private let synthetic: Bool
  private var window: NSWindow?
  private var probeView: ProbeMetalView?
  private var engine: ReplayCaptureEngine?
  private var tempDir: String?

  init(seconds: Double, withRecording: Bool, synthetic: Bool) {
    self.seconds = seconds
    self.withRecording = withRecording
    self.synthetic = synthetic
  }

  func start() {
    let rect = NSRect(x: 16, y: 16, width: 64, height: 64)
    let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false
    win.ignoresMouseEvents = true
    win.level = .statusBar
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    let view = ProbeMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    win.contentView = view
    win.orderFrontRegardless()

    self.window = win
    self.probeView = view
    view.startDisplayLink()

    var recordError: String?
    if withRecording {
      let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("sr-probe-\(getpid())")
      self.tempDir = tmp
      let opts = CaptureOptions(
        replayRoot: tmp,
        bufferDir: (tmp as NSString).appendingPathComponent("Buffer"),
        fps: 60,
        codec: "HEVC",
        quality: "high",
        systemAudio: true,
        segmentSeconds: 15.0,
        synthetic: synthetic
      )
      let eng = ReplayCaptureEngine(options: opts)
      do {
        try eng.start()
        self.engine = eng
      } catch {
        recordError = "\(error)"
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      self.finish(recordError: recordError)
    }
  }

  private func finish(recordError: String?) {
    probeView?.stopDisplayLink()
    let stats = probeView?.snapshotStats()
    let recSnap = engine?.statusJSON()
    engine?.stop()
    engine = nil
    window?.orderOut(nil)
    window = nil
    if let tempDir {
      try? FileManager.default.removeItem(atPath: tempDir)
    }

    var out: [String: Any] = [
      "ok": true,
      "seconds": seconds,
      "recording": withRecording,
      "display": Status.display(CGMainDisplayID()),
      "presented": stats?.presented.toJSON() ?? [:],
      "displayLink": stats?.displayLink.toJSON() ?? [:],
    ]
    if let recSnap { out["recorder"] = recSnap }
    if let recordError { out["recordError"] = recordError }
    Channel(fd: 1).line(out)
    exit(0)
  }
}
