import AppKit
import CoreGraphics
import Darwin
import Foundation

public final class HelperDaemon: @unchecked Sendable {
  public let socketPath: String
  public let token: String
  public let paths: RecorderPaths
  public let headlessTest: Bool
  public let startedGrants: (capture: Bool, microphone: Bool, inputMonitoring: Bool)

  private let logger: RecorderLogger
  private let lock = NSLock()
  private var serverFD: Int32 = -1
  private var watchers: [Channel] = []
  private var engine: ReplayCaptureEngine?
  private var configuredOptions: CaptureOptions
  private var wantsRecording = false
  private var stopping = false

  public var onQuitRequested: (() -> Void)?

  public init(socketPath: String, token: String, paths: RecorderPaths, headlessTest: Bool = false) {
    self.socketPath = socketPath
    self.token = token
    self.paths = paths
    self.headlessTest = headlessTest
    self.logger = RecorderLogger(paths: paths)
    self.startedGrants = (
      Status.captureAllowed(),
      Status.microphoneAllowed(),
      Status.inputMonitoringAllowed()
    )
    let settings = RecorderSettings.read(from: paths.settingsPath, defaultConsentIfPresent: headlessTest)
    let viewer = ViewerPrefs.read(from: paths.viewerPath)
    self.configuredOptions = CaptureOptions.from(paths: paths, settings: settings, viewer: viewer)
  }

  public func notify(_ event: [String: Any]) {
    lock.lock()
    let activeWatchers = watchers
    lock.unlock()
    for ch in activeWatchers {
      ch.line(event)
    }
  }

  public func start(autoResumeRecording: Bool = false) throws {
    let dir = (socketPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let staging = (dir as NSString).appendingPathComponent(".sr-h-\(getpid())")
    unlink(staging)
    guard socketPath.utf8CString.count <= 104, staging.utf8CString.count <= 104 else {
      throw HelperError("Socket path exceeds 104-byte Unix domain limit: \(socketPath)")
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw HelperError("socket(AF_UNIX) failed: \(String(cString: strerror(errno)))")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = staging.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
      bytes.withUnsafeBufferPointer { buf in
        UnsafeMutableRawPointer(ptr).copyMemory(from: buf.baseAddress!, byteCount: buf.count)
      }
    }
    let bound = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0,
          chmod(staging, S_IRUSR | S_IWUSR) == 0,
          listen(fd, 32) == 0,
          rename(staging, socketPath) == 0
    else {
      let why = String(cString: strerror(errno))
      close(fd)
      unlink(staging)
      throw HelperError("Failed to bind/listen on \(socketPath): \(why)")
    }

    self.serverFD = fd
    Thread.detachNewThread { [weak self] in
      self?.acceptLoop(fd)
    }

    if autoResumeRecording {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else { return }
        _ = self.startRecording(overrides: [:])
      }
    }
  }

  public func shutdown() {
    lock.lock()
    if stopping {
      lock.unlock()
      return
    }
    stopping = true
    let fd = serverFD
    serverFD = -1
    let activeEngine = engine
    engine = nil
    let activeWatchers = watchers
    watchers.removeAll()
    lock.unlock()

    activeEngine?.stop()
    unlink(socketPath)
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      close(fd)
    }
    for w in activeWatchers {
      w.closeFD()
    }
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        return
      }
      var noSigPipe: Int32 = 1
      _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      Thread.detachNewThread { [weak self] in
        self?.serveClient(client)
      }
    }
  }

  private func serveClient(_ fd: Int32) {
    defer { close(fd) }
    let channel = Channel(fd: fd)
    guard let line = channel.readLine(),
          let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    else { return }

    guard let givenToken = request["token"] as? String, constantTimeSame(givenToken, token) else {
      channel.line(["error": "unauthorized token", "code": "auth"])
      return
    }

    let op = (request["op"] as? String) ?? ""
    switch op {
    case "hello":
      lock.lock()
      let rec = engine?.isRunning == true
      lock.unlock()
      channel.line([
        "ok": true,
        "v": 1,
        "pid": Int(getpid()),
        "app": Bundle.main.bundlePath,
        "recording": rec,
        "capture": Status.captureAllowed(),
      ])

    case "status":
      var st = (headlessTest ? nil : Status.fresh()) ?? Status.now()
      st["live"] = [
        "capture": Status.captureAllowed(),
        "microphone": Status.microphoneAllowed(),
        "inputMonitoring": Status.inputMonitoringAllowed(),
      ]
      if !headlessTest && NSApp != nil {
        let permUI = DispatchQueue.main.sync {
          MainActor.assumeIsolated { (HelperPermissions.shared.isShown, HelperPermissions.shared.asked) }
        }
        st["asking"] = permUI.0
        st["asked"] = permUI.0 ? permUI.1 : []
      } else {
        st["asking"] = false
        st["asked"] = []
      }
      lock.lock()
      let recJSON = engine?.statusJSON() ?? ["recording": false]
      lock.unlock()
      st["recorder"] = recJSON
      channel.line(st)

    case "permissions.show":
      guard !headlessTest else {
        channel.line(["ok": false, "error": "permissions UI disabled in headless test mode", "code": "headless"])
        return
      }
      let words = (request["words"] as? [String: Any]) ?? [:]
      let grants = (request["grants"] as? [String]) ?? [HelperGrant.screenRecording.rawValue]
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          HelperPermissions.shared.show(words: words, grants: grants, daemon: self)
        }
      }
      channel.line(["ok": true])

    case "record.configure":
      let reply = configureRecording(request)
      channel.line(reply)

    case "record.start":
      let reply = startRecording(overrides: request)
      channel.line(reply)

    case "record.pause":
      pauseRecording()
      channel.line(["ok": true, "recording": false])

    case "record.flush":
      let minDur = (request["minDurationSeconds"] as? NSNumber)?.doubleValue ?? 0.0
      let seg = flushRecording(minDurationSeconds: minDur)
      var reply: [String: Any] = ["ok": true]
      if let seg {
        reply["segment"] = [
          "path": seg.path,
          "durationMs": seg.durationMs,
          "bytes": seg.bytes,
          "width": seg.width,
          "height": seg.height,
        ]
      }
      channel.line(reply)

    case "record.stop":
      stopRecording()
      channel.line(["ok": true, "recording": false])

    case "watch":
      channel.line(["ok": true, "pid": Int(getpid())])
      lock.lock()
      watchers.append(channel)
      lock.unlock()
      while channel.readLine() != nil {}
      lock.lock()
      watchers.removeAll { $0 === channel }
      lock.unlock()

    case "restart":
      channel.line(["ok": true])
      let resume = (request["autoResume"] as? Bool) ?? wantsRecording
      DispatchQueue.main.async {
        self.restart(autoResumeRecording: resume)
      }

    case "quit":
      lock.lock()
      let activeEngine = engine
      engine = nil
      lock.unlock()
      activeEngine?.stop()
      unlink(socketPath)
      if serverFD >= 0 {
        close(serverFD)
        serverFD = -1
      }
      channel.line(["ok": true])
      if let onQuitRequested {
        onQuitRequested()
      } else {
        DispatchQueue.main.async { exit(0) }
      }

    default:
      channel.line(["error": "unknown op \(op)", "code": "unknown_op"])
    }
  }

  private func buildOptions(from request: [String: Any]) -> CaptureOptions {
    let settings = RecorderSettings.read(from: paths.settingsPath, defaultConsentIfPresent: headlessTest)
    let viewer = ViewerPrefs.read(from: paths.viewerPath)
    var opts = CaptureOptions.from(paths: paths, settings: settings, viewer: viewer)

    if let buf = request["bufferDir"] as? String, !buf.isEmpty { opts.bufferDir = buf }
    if let root = request["replayRoot"] as? String, !root.isEmpty { opts.replayRoot = root }
    if let fps = (request["fps"] as? NSNumber)?.intValue { opts.fps = max(1, min(120, fps)) }
    if let maxH = (request["maxHeight"] as? NSNumber)?.intValue { opts.maxHeight = max(0, maxH) }
    if let codec = request["codec"] as? String { opts.codec = codec.lowercased() == "h264" ? "H264" : "HEVC" }
    if let quality = request["quality"] as? String { opts.quality = quality }
    if let sysAudio = request["systemAudio"] as? Bool { opts.systemAudio = sysAudio }
    if let mic = request["microphone"] as? Bool { opts.microphone = mic }
    if let cursor = request["recordCursor"] as? Bool { opts.recordCursor = cursor }
    if let excl = request["excludeSelf"] as? Bool { opts.excludeSelf = excl }
    if let p3 = request["wideGamutP3"] as? Bool { opts.wideGamutP3 = p3 }
    if let disp = (request["displayID"] as? NSNumber)?.uint32Value { opts.displayID = disp }
    if let segSec = (request["segmentSeconds"] as? NSNumber)?.doubleValue { opts.segmentSeconds = max(0.5, segSec) }
    if let keepMin = (request["windowMinutes"] as? NSNumber)?.doubleValue { opts.keepSeconds = max(60, keepMin * 60.0) }
    if let maxGB = (request["maxGB"] as? NSNumber)?.int64Value { opts.maxBytes = max(0, maxGB) << 30 }
    if let synth = request["synthetic"] as? Bool { opts.synthetic = synth }
    if let sw = (request["syntheticWidth"] as? NSNumber)?.intValue { opts.syntheticWidth = max(16, sw & ~1) }
    if let sh = (request["syntheticHeight"] as? NSNumber)?.intValue { opts.syntheticHeight = max(16, sh & ~1) }
    return opts
  }

  private func configureRecording(_ request: [String: Any]) -> [String: Any] {
    let nextOpts = buildOptions(from: request)
    lock.lock()
    let prevOpts = configuredOptions
    configuredOptions = nextOpts
    let wasRunning = engine?.isRunning == true
    lock.unlock()

    if wasRunning && prevOpts != nextOpts {
      stopRecording()
      return startRecording(overrides: request)
    }
    return ["ok": true, "recording": wasRunning]
  }

  private func startRecording(overrides: [String: Any]) -> [String: Any] {
    let opts = buildOptions(from: overrides)
    lock.lock()
    configuredOptions = opts
    wantsRecording = true
    if let existing = engine, existing.isRunning {
      let snap = existing.statusJSON()
      lock.unlock()
      return ["ok": true, "recorder": snap]
    }
    lock.unlock()

    if !opts.synthetic && !Status.captureAllowed() {
      let freshGranted = (!headlessTest ? (Status.fresh()?["capture"] as? Bool) : nil) ?? false
      if freshGranted {
        DispatchQueue.main.async {
          self.restart(autoResumeRecording: true)
        }
        return [
          "error": "restarting Helper to activate newly granted Screen Recording permission",
          "code": "restart",
          "capture": true,
        ]
      }
      return [
        "error": "Screen Recording permission is not granted",
        "code": "capture",
        "capture": false,
      ]
    }

    let newEngine = ReplayCaptureEngine(options: opts, logger: logger)
    newEngine.onSegmentClosed = { [weak self] seg in
      self?.notify([
        "event": "segment",
        "path": seg.path,
        "durationMs": seg.durationMs,
        "bytes": seg.bytes,
      ])
    }
    newEngine.onFault = { [weak self] message in
      self?.notify([
        "event": "fault",
        "message": message,
      ])
    }

    do {
      try newEngine.start()
      lock.lock()
      engine = newEngine
      lock.unlock()
      let snap = newEngine.statusJSON()
      notify(["event": "state", "recorder": snap])
      return ["ok": true, "recorder": snap]
    } catch let err as HelperError {
      return ["error": err.description, "code": err.code ?? "startFailed"]
    } catch {
      return ["error": error.localizedDescription, "code": "startFailed"]
    }
  }

  private func pauseRecording() {
    lock.lock()
    wantsRecording = false
    let active = engine
    engine = nil
    lock.unlock()
    active?.stop()
    notify(["event": "state", "recorder": ["recording": false]])
  }

  private func flushRecording(minDurationSeconds: Double) -> Segment? {
    lock.lock()
    let active = engine
    lock.unlock()
    return active?.flush(minDurationSeconds: minDurationSeconds)
  }

  private func stopRecording() {
    pauseRecording()
  }

  public func grantedCaptureSinceStart() -> Bool {
    guard !startedGrants.capture, let fresh = Status.fresh() else { return false }
    return (fresh["capture"] as? Bool) == true
  }

  /// Launches a new `ScreenReplay Helper.app` instance via LaunchServices with `SR_HELPER_TAKEOVER=1`
  /// so the newly granted TCC Screen Recording permission takes effect immediately without restarting
  /// `ScreenReplayMac` or `ScreenReplayViewer`.
  public func restart(autoResumeRecording: Bool) {
    guard !headlessTest else { return }
    lock.lock()
    let active = engine
    engine = nil
    lock.unlock()
    active?.stop()

    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.activates = false
    config.addsToRecentItems = false
    config.environment = [
      "SR_HELPER_SOCKET": socketPath,
      "SR_HELPER_TOKEN": token,
      "SR_REPLAY_ROOT": paths.root,
      "SR_HELPER_TAKEOVER": "1",
      "SR_AUTO_RESUME_RECORD": autoResumeRecording ? "1" : "0",
    ]
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
      if let error {
        FileHandle.standardError.write(Data("ScreenReplayHelper: takeover restart failed: \(error)\n".utf8))
      }
      exit(0)
    }
  }
}
