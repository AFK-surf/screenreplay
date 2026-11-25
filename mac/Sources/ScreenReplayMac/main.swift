import AppKit
import Carbon
import CryptoKit
import Darwin
import Foundation
import ScreenReplayKit
import ServiceManagement

/// Installs and supervises `ScreenReplay Helper.app` in `<REPLAY_ROOT>/helper/`, modeled after Monoid's `helper_app.mbt`.
/// Launched via `/usr/bin/open -n -g` so LaunchServices makes `ScreenReplay Helper.app` its own TCC responsible process.
final class HelperSupervisor: @unchecked Sendable {
  let paths: RecorderPaths
  let logger: RecorderLogger
  let headlessTest: Bool
  let directProcess: Bool

  private let lock = NSLock()
  private var token: String = ""
  private var watchFD: Int32 = -1
  private var directChild: Process?
  private var stopping = false
  private var revivals: [Date] = []

  var onHelperEvent: (([String: Any]) -> Void)?

  init(paths: RecorderPaths, logger: RecorderLogger, headlessTest: Bool, directProcess: Bool) {
    self.paths = paths
    self.logger = logger
    self.headlessTest = headlessTest
    self.directProcess = directProcess
  }

  private static let comparedBundleFiles = [
    "Contents/MacOS/ScreenReplayHelper",
    "Contents/Info.plist",
    "Contents/_CodeSignature/CodeResources",
  ]

  /// Finds the release's `ScreenReplay Helper.app` (env override or `ScreenReplay.app/Contents/Helpers/ScreenReplay Helper.app`).
  func bundledHelperApp() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let override = env["SR_BUNDLED_HELPER_APP"], !override.isEmpty,
       FileManager.default.fileExists(atPath: (override as NSString).appendingPathComponent("Contents/Info.plist"))
    {
      return override
    }
    let bundleHelpers = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Helpers/ScreenReplay Helper.app")
    if FileManager.default.fileExists(atPath: (bundleHelpers as NSString).appendingPathComponent("Contents/Info.plist")) {
      return bundleHelpers
    }
    return nil
  }

  /// Copies `ScreenReplay Helper.app` to `<REPLAY_ROOT>/helper/ScreenReplay Helper.app` atomically if changed.
  func installHelperIfNeeded() throws -> String? {
    guard let srcApp = bundledHelperApp() else { return nil }
    let dstApp = paths.installedHelperApp
    let fm = FileManager.default
    var identical = fm.fileExists(atPath: dstApp)
    if identical {
      for rel in Self.comparedBundleFiles {
        let a = try? Data(contentsOf: URL(fileURLWithPath: (srcApp as NSString).appendingPathComponent(rel)))
        let b = try? Data(contentsOf: URL(fileURLWithPath: (dstApp as NSString).appendingPathComponent(rel)))
        if a != b {
          identical = false
          break
        }
      }
    }
    if identical { return dstApp }

    try fm.createDirectory(atPath: paths.helperDir, withIntermediateDirectories: true)
    let nonce = UUID().uuidString.prefix(8)
    let staging = (paths.helperDir as NSString).appendingPathComponent(".staging-\(nonce)")
    let backup = "\(dstApp).old-\(nonce)"
    try? fm.removeItem(atPath: staging)
    try fm.copyItem(atPath: srcApp, toPath: staging)
    if fm.fileExists(atPath: dstApp) {
      try? fm.removeItem(atPath: backup)
      try fm.moveItem(atPath: dstApp, toPath: backup)
    }
    try fm.moveItem(atPath: staging, toPath: dstApp)
    try? fm.removeItem(atPath: backup)
    logger.log("helper.install updated \(dstApp)")
    return dstApp
  }

  func ensureToken() throws -> String {
    lock.lock()
    if !token.isEmpty {
      let t = token
      lock.unlock()
      return t
    }
    lock.unlock()

    try FileManager.default.createDirectory(atPath: paths.helperDir, withIntermediateDirectories: true)
    if let existing = try? String(contentsOfFile: paths.tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       existing.count >= 32
    {
      lock.lock()
      token = existing
      lock.unlock()
      return existing
    }

    var random = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
    let fresh = random.map { String(format: "%02x", $0) }.joined()
    let fd = open(paths.tokenPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw HelperError("Cannot create helper token at \(paths.tokenPath)") }
    _ = fresh.withCString { Darwin.write(fd, $0, strlen($0)) }
    close(fd)
    lock.lock()
    token = fresh
    lock.unlock()
    return fresh
  }

  func ensureRunning() throws {
    let tok = try ensureToken()
    if (try? UnixSocketClient.request(socketPath: paths.socketPath, token: tok, op: "hello", timeoutMs: 800)) != nil {
      ensureWatching(token: tok)
      return
    }

    if directProcess || bundledHelperApp() == nil {
      try launchDirectExecutable(token: tok)
    } else if let appPath = try installHelperIfNeeded() {
      try launchViaOpen(appPath: appPath, token: tok)
    } else {
      try launchDirectExecutable(token: tok)
    }

    let deadline = Date().addingTimeInterval(15.0)
    while Date() < deadline {
      if (try? UnixSocketClient.request(socketPath: paths.socketPath, token: tok, op: "hello", timeoutMs: 500)) != nil {
        ensureWatching(token: tok)
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw HelperError("Timed out waiting for ScreenReplayHelper on \(paths.socketPath)")
  }

  private func launchViaOpen(appPath: String, token: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = [
      "-n", "-g",
      "--env", "SR_HELPER_SOCKET=\(paths.socketPath)",
      "--env", "SR_HELPER_TOKEN=\(token)",
      "--env", "SR_REPLAY_ROOT=\(paths.root)",
      appPath,
    ]
    let errPipe = Pipe()
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
      let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "open failed"
      throw HelperError("Failed to launch \(appPath): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    logger.log("helper.open started \(appPath)")
  }

  private func launchDirectExecutable(token: String) throws {
    let env = ProcessInfo.processInfo.environment
    let exeDir = ((Bundle.main.executablePath ?? CommandLine.arguments.first ?? "") as NSString).deletingLastPathComponent
    var candidates: [String] = []
    if let explicit = env["SR_HELPER_BIN"], !explicit.isEmpty {
      candidates.append(explicit)
    }
    if let installed = try? installHelperIfNeeded() {
      candidates.append((installed as NSString).appendingPathComponent("Contents/MacOS/ScreenReplayHelper"))
    }
    if let bundled = bundledHelperApp() {
      candidates.append((bundled as NSString).appendingPathComponent("Contents/MacOS/ScreenReplayHelper"))
    }
    candidates.append((exeDir as NSString).appendingPathComponent("ScreenReplayHelper"))
    guard let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw HelperError("ScreenReplayHelper binary not found in \(candidates)")
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: candidate)
    var childEnv = env
    childEnv["SR_HELPER_SOCKET"] = paths.socketPath
    childEnv["SR_HELPER_TOKEN"] = token
    childEnv["SR_REPLAY_ROOT"] = paths.root
    if headlessTest { childEnv["SR_HELPER_HEADLESS_TEST"] = "1" }
    child.environment = childEnv
    try child.run()
    lock.lock()
    directChild = child
    lock.unlock()
    logger.log("helper.direct started pid=\(child.processIdentifier)")
  }

  private func ensureWatching(token: String) {
    lock.lock()
    if watchFD >= 0 || stopping {
      lock.unlock()
      return
    }
    lock.unlock()

    guard let fd = try? UnixSocketClient.dial(paths.socketPath, timeoutMs: 2000) else { return }
    var zero = timeval(tv_sec: 0, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    let ch = Channel(fd: fd)
    ch.line(["op": "watch", "token": token])
    guard let ackData = ch.readLine(),
          let ack = (try? JSONSerialization.jsonObject(with: ackData)) as? [String: Any],
          (ack["ok"] as? Bool) == true
    else {
      close(fd)
      return
    }

    lock.lock()
    watchFD = fd
    lock.unlock()

    Thread.detachNewThread { [weak self] in
      while let line = ch.readLine() {
        if let ev = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
          self?.onHelperEvent?(ev)
        }
      }
      close(fd)
      guard let self else { return }
      self.lock.lock()
      if self.watchFD == fd { self.watchFD = -1 }
      let shouldRevive = !self.stopping
      self.lock.unlock()
      if shouldRevive {
        self.reviveAfterDisconnect()
      }
    }
  }

  private func reviveAfterDisconnect() {
    // Give Helper 3s to come back on its own (e.g. during PermissionFlow `restart()` takeover).
    Thread.sleep(forTimeInterval: 3.0)
    lock.lock()
    if stopping {
      lock.unlock()
      return
    }
    let now = Date()
    revivals.removeAll { now.timeIntervalSince($0) > 60.0 }
    if revivals.count >= 5 {
      lock.unlock()
      logger.log("helper.revive capped after 5 attempts in 60s")
      return
    }
    revivals.append(now)
    lock.unlock()

    do {
      try ensureRunning()
      onHelperEvent?(["event": "reconnected"])
    } catch {
      logger.log("helper.revive failed: \(error)")
    }
  }

  @discardableResult
  func call(_ op: String, fields: [String: Any] = [:], timeoutMs: Int = 8000) throws -> [String: Any] {
    try ensureRunning()
    let tok = try ensureToken()
    return try UnixSocketClient.request(socketPath: paths.socketPath, token: tok, op: op, fields: fields, timeoutMs: timeoutMs)
  }

  func stopAll() {
    lock.lock()
    stopping = true
    let wfd = watchFD
    watchFD = -1
    let tok = token
    let child = directChild
    directChild = nil
    lock.unlock()

    if wfd >= 0 {
      Darwin.shutdown(wfd, SHUT_RDWR)
      close(wfd)
    }
    if !tok.isEmpty {
      _ = try? UnixSocketClient.request(socketPath: paths.socketPath, token: tok, op: "quit", timeoutMs: 1500)
    }
    if let child, child.isRunning {
      child.terminate()
    }
  }
}

/// Coordinates `REPLAY_ROOT` state/requests, Helper RPC, Instant Replay saves, Launch at Login, menu bar, and Carbon hotkeys.
final class HostCoordinator: NSObject, @unchecked Sendable {
  let paths: RecorderPaths
  let logger: RecorderLogger
  let helper: HelperSupervisor
  let updater: Updater
  let headlessTest: Bool
  let syntheticOverride: Bool

  private let queue = DispatchQueue(label: "dev.pengx17.screenreplay.host", qos: .utility)
  private var pollTimer: DispatchSourceTimer?
  private let startedAt = Date()

  private var pausedUntil: Date?
  private var screenLockedOrAsleep = false
  private var lastStatusCode = "starting"
  private var lastStatusArg = ""
  private var isCurrentlyRecording = false
  private var lastAutostartApplied: Bool?
  private var viewerProcess: Process?
  private var lastPermissionPrompted = false

  // Menu bar UI (MainActor)
  @MainActor private var statusItem: NSStatusItem?
  @MainActor private var statusSummaryItem: NSMenuItem?
  @MainActor private var pauseResumeItem: NSMenuItem?
  @MainActor private var permissionItem: NSMenuItem?
  private var hotKeyRefs: [EventHotKeyRef?] = []

  init(paths: RecorderPaths, headlessTest: Bool, directHelper: Bool, syntheticOverride: Bool) {
    self.paths = paths
    self.logger = RecorderLogger(paths: paths)
    self.headlessTest = headlessTest
    self.syntheticOverride = syntheticOverride
    self.helper = HelperSupervisor(paths: paths, logger: logger, headlessTest: headlessTest, directProcess: directHelper)
    self.updater = Updater(paths: paths, logger: logger, headlessTest: headlessTest)
    super.init()

    // (an update waits while the replay window is open; before the new app takes this one's place, the helper and the
    // window this run started end with it)
    updater.isReplayShown = { [weak self] in self?.viewerProcess?.isRunning ?? false }
    updater.beforeQuit = { [weak self] in
      guard let self else { return }
      if let v = self.viewerProcess, v.isRunning { v.terminate() }
      self.shutdown()
    }
    updater.notify = { [weak self] title, body in self?.logger.log("update: \(title): \(body)") }

    helper.onHelperEvent = { [weak self] ev in
      self?.queue.async {
        self?.handleHelperEvent(ev)
      }
    }
  }

  func start() {
    if !headlessTest {
      observeSleepAndLock()
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.setupMenuBar()
          self.registerCarbonHotKeys()
        }
      }
    }

    queue.async { [self] in
      try? self.helper.ensureRunning()
      self.tick()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + 1.0, repeating: 1.5)
      timer.setEventHandler { [weak weakSelf = self] in
        weakSelf?.tick()
      }
      timer.resume()
      self.pollTimer = timer
    }
  }

  func shutdown() {
    pollTimer?.cancel()
    pollTimer = nil
    helper.stopAll()
    for ref in hotKeyRefs {
      if let ref { UnregisterEventHotKey(ref) }
    }
    hotKeyRefs.removeAll()
  }

  private func observeSleepAndLock() {
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
      self?.queue.async {
        self?.screenLockedOrAsleep = true
        self?.tick()
      }
    }
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
      self?.queue.async {
        self?.screenLockedOrAsleep = false
        self?.tick()
      }
    }
    let dist = DistributedNotificationCenter.default()
    dist.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
      self?.queue.async {
        self?.screenLockedOrAsleep = true
        self?.tick()
      }
    }
    dist.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
      self?.queue.async {
        self?.screenLockedOrAsleep = false
        self?.tick()
      }
    }
  }

  private func handleHelperEvent(_ ev: [String: Any]) {
    let kind = (ev["event"] as? String) ?? ""
    if kind == "grants" || kind == "reconnected" || kind == "state" {
      tick()
    }
  }

  private func consumeRequest(_ name: String) -> String? {
    let p = paths.requestPath(name)
    guard FileManager.default.fileExists(atPath: p) else { return nil }
    let content = ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try? FileManager.default.removeItem(atPath: p)
    return content
  }

  private func tick() {
    if consumeRequest("quit.request") != nil {
      logger.log("host.quit requested")
      shutdown()
      exit(0)
    }

    if consumeRequest("open.request") != nil {
      openReplayWindow(openSettings: false)
    }

    if let trayCmdStr = consumeRequest("tray.command"), let cmd = Int(trayCmdStr) {
      handleTrayCommand(cmd)
    }

    if consumeRequest("purge.request") != nil {
      _ = try? helper.call("record.pause")
      let settings = RecorderSettings.read(from: paths.settingsPath, defaultConsentIfPresent: headlessTest)
      let bufDir = settings.bufferDir.isEmpty ? paths.defaultBuffer : settings.bufferDir
      if let files = try? FileManager.default.contentsOfDirectory(atPath: bufDir) {
        for f in files where f.hasSuffix(".mp4") || f.hasSuffix(".json") || f.hasSuffix(".input") {
          try? FileManager.default.removeItem(atPath: (bufDir as NSString).appendingPathComponent(f))
        }
      }
    }

    if let pauseReq = consumeRequest("pause.request") {
      if pauseReq == "resume" {
        pausedUntil = nil
      } else if pauseReq == "permissions" {
        showPermissionsUI()
      } else if let mins = Int(pauseReq), mins > 0 {
        pausedUntil = Date().addingTimeInterval(Double(mins) * 60.0)
      }
    }

    if consumeRequest("permissions.request") != nil {
      showPermissionsUI()
    }

    if consumeRequest("flush.request") != nil {
      _ = try? helper.call("record.flush", fields: ["minDurationSeconds": 0.4])
    }

    if consumeRequest("save.request") != nil {
      saveInstantReplay()
    }

    if let until = pausedUntil, Date() >= until {
      pausedUntil = nil
    }

    let settings = RecorderSettings.read(from: paths.settingsPath, defaultConsentIfPresent: headlessTest)
    applyLaunchAtLoginIfNeeded(settings.autostart)
    updater.poll(
      autoUpdateEnabled: settings.autoUpdate,
      startedOverMinuteAgo: Date().timeIntervalSince(startedAt) >= 60.0,
      headlessTest: headlessTest
    )

    // Determine desired recording state
    var desiredRecord = false
    var statusCode = "disabled"
    var statusArg = ""

    if !settings.consented || !settings.enabled {
      statusCode = "disabled"
      desiredRecord = false
    } else if screenLockedOrAsleep && !syntheticOverride {
      statusCode = "locked"
      desiredRecord = false
    } else if let until = pausedUntil {
      let df = DateFormatter()
      df.dateFormat = "HH:mm"
      statusCode = "paused"
      statusArg = df.string(from: until)
      desiredRecord = false
    } else if settings.pauseInFullscreen && !syntheticOverride && isFrontmostAppFullscreen() {
      statusCode = "fullscreen"
      desiredRecord = false
    } else {
      desiredRecord = true
      statusCode = "recording"
    }

    var helperRecorder: [String: Any] = [:]
    if desiredRecord {
      var fields: [String: Any] = [:]
      if syntheticOverride {
        fields["synthetic"] = true
        if let segSecStr = ProcessInfo.processInfo.environment["SR_SEGMENT_SECONDS"],
           let segSec = Double(segSecStr), segSec >= 0.5
        {
          fields["segmentSeconds"] = segSec
        }
      }
      do {
        let res = try helper.call("record.start", fields: fields)
        helperRecorder = (res["recorder"] as? [String: Any]) ?? [:]
        isCurrentlyRecording = (helperRecorder["recording"] as? Bool) ?? true
        statusCode = isCurrentlyRecording ? "recording" : "starting"
        lastPermissionPrompted = false
      } catch let err as HelperError {
        isCurrentlyRecording = false
        if err.code == "capture" {
          statusCode = "noPermission"
          if !headlessTest && !lastPermissionPrompted {
            lastPermissionPrompted = true
            showPermissionsUI()
          }
        } else if err.code == "restart" {
          statusCode = "starting"
        } else if err.code == "noDisplay" || err.code == "display" {
          statusCode = "noDisplay"
        } else if err.code == "noEncoder" || err.code == "encoder" {
          statusCode = "noEncoder"
        } else {
          statusCode = "startFailed"
        }
      } catch {
        isCurrentlyRecording = false
        statusCode = "startFailed"
      }
    } else {
      if isCurrentlyRecording {
        _ = try? helper.call("record.pause")
        isCurrentlyRecording = false
      }
      if let st = try? helper.call("status", timeoutMs: 1500),
         let rec = st["recorder"] as? [String: Any]
      {
        helperRecorder = rec
      }
    }

    lastStatusCode = statusCode
    lastStatusArg = statusArg
    writeStateFile(statusCode: statusCode, statusArg: statusArg, recording: isCurrentlyRecording, recorderInfo: helperRecorder, settings: settings)

    if !headlessTest {
      let english = SRStrings.isEnglish(viewerPath: paths.viewerPath)
      let summary = SRStrings.status(statusCode, arg: statusArg, english: english)
      let recNow = isCurrentlyRecording
      let pausedNow = (pausedUntil != nil)
      let needPerm = (statusCode == "noPermission")
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.refreshMenuBar(recording: recNow, paused: pausedNow, needPermission: needPerm, summary: summary, english: english)
        }
      }
    }
  }

  private func writeStateFile(
    statusCode: String,
    statusArg: String,
    recording: Bool,
    recorderInfo: [String: Any],
    settings: RecorderSettings
  ) {
    let english = SRStrings.isEnglish(viewerPath: paths.viewerPath)
    let mainDisp = Status.display(CGMainDisplayID())
    let screenW = (recorderInfo["screenWidth"] as? Int) ?? (mainDisp["width"] as? Int) ?? 1920
    let screenH = (recorderInfo["screenHeight"] as? Int) ?? (mainDisp["height"] as? Int) ?? 1080
    let dispHz = (recorderInfo["displayHz"] as? Int) ?? Int(((mainDisp["refreshRate"] as? Double) ?? 60.0).rounded())
    let bufDir = (recorderInfo["bufferDir"] as? String) ?? (settings.bufferDir.isEmpty ? paths.defaultBuffer : settings.bufferDir)

    let stateObj: [String: Any] = [
      "at": Int64(Date().timeIntervalSince1970 * 1000.0),
      "recording": recording,
      "statusCode": statusCode,
      "statusArg": statusArg,
      "status": SRStrings.status(statusCode, arg: statusArg, english: english),
      "codec": (recorderInfo["codec"] as? String) ?? settings.codec,
      "width": (recorderInfo["width"] as? Int) ?? screenW,
      "height": (recorderInfo["height"] as? Int) ?? screenH,
      "screenWidth": screenW,
      "screenHeight": screenH,
      "displayHz": dispHz,
      "bufferDir": bufDir,
      "bufferTrouble": (recorderInfo["bufferTrouble"] as? String) ?? "",
      "audioTrouble": (recorderInfo["audioTrouble"] as? String) ?? "",
      "diskTight": (recorderInfo["diskTight"] as? Bool) ?? false,
      "fastSync": "",
      "sharedGpu": false,
      "framesEncoded": (recorderInfo["framesEncoded"] as? Int) ?? 0,
      "framesSkipped": (recorderInfo["framesSkipped"] as? Int) ?? 0,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: stateObj, options: []),
       let text = String(data: data, encoding: .utf8)
    {
      AtomicFile.writeWhole(path: paths.statePath, text: text)
    }
  }

  private func isFrontmostAppFullscreen() -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication else { return false }
    let screenBounds = CGDisplayBounds(CGMainDisplayID())
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      return false
    }
    for w in list {
      guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            pid == front.processIdentifier,
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            layer == 0,
            let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: boundsDict)
      else { continue }
      if abs(rect.width - screenBounds.width) <= 2 && abs(rect.height - screenBounds.height) <= 2 {
        return true
      }
    }
    return false
  }

  private func applyLaunchAtLoginIfNeeded(_ want: Bool) {
    guard !headlessTest, Updater.detectInstallKind() == 1 else { return }
    if lastAutostartApplied == want { return }
    lastAutostartApplied = want
    do {
      if want {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      logger.log("autostart(\(want)) error: \(error.localizedDescription)")
    }
  }

  func showPermissionsUI() {
    guard !headlessTest else { return }
    let english = SRStrings.isEnglish(viewerPath: paths.viewerPath)
    let words: [String: Any] = [
      "title": "ScreenReplay",
      "heading": SRStrings.t("开启屏幕录制权限", "Allow Screen Recording", english: english),
      "subtitle": SRStrings.t(
        "在系统设置中勾选「ScreenReplay Helper」，授权后后台自动生效，无需重启回放窗口。",
        "Enable ScreenReplay Helper in System Settings. Recording starts automatically without restarting the window.",
        english: english
      ),
    ]
    _ = try? helper.call("permissions.show", fields: ["words": words, "grants": ["capture"]])
  }

  func openReplayWindow(openSettings: Bool) {
    guard !headlessTest else { return }
    if openSettings {
      AtomicFile.writeWhole(path: paths.requestPath("settings.request"), text: "1")
    }
    if let existing = viewerProcess, existing.isRunning {
      if let app = NSRunningApplication(processIdentifier: existing.processIdentifier) {
        app.activate(options: [.activateAllWindows])
        return
      }
    }
    guard FileManager.default.isExecutableFile(atPath: paths.replayExe) else {
      logger.log("viewer.missing at \(paths.replayExe)")
      return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: paths.replayExe)
    var env = ProcessInfo.processInfo.environment
    env["REPLAY_ROOT"] = paths.root
    proc.environment = env
    do {
      try proc.run()
      viewerProcess = proc
    } catch {
      logger.log("viewer.launch failed: \(error)")
    }
  }

  func saveInstantReplay() {
    _ = try? helper.call("record.flush", fields: ["minDurationSeconds": 0.3])
    let settings = RecorderSettings.read(from: paths.settingsPath, defaultConsentIfPresent: headlessTest)
    let bufDir = settings.bufferDir.isEmpty ? paths.defaultBuffer : settings.bufferDir
    let store = SegmentStore(folder: bufDir)
    let segs = store.list()
    guard !segs.isEmpty else { return }

    let english = SRStrings.isEnglish(viewerPath: paths.viewerPath)
    let envOut = (ProcessInfo.processInfo.environment["REPLAY_OUT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let outDir = envOut.isEmpty ? SRStrings.clipsFolder(english: english) : envOut
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let prefix = english ? "Replay" : "回放"
    let outPath = (outDir as NSString).appendingPathComponent("\(prefix) \(df.string(from: Date())).mp4")

    if ClipJoiner.saveLast(segments: segs, duration: TimeInterval(settings.lastSeconds), outputPath: outPath) {
      logger.log("instant.saved \(outPath)")
      let note: [String: Any] = [
        "at": Int64(Date().timeIntervalSince1970 * 1000.0),
        "path": outPath,
        "seconds": settings.lastSeconds,
      ]
      if let d = try? JSONSerialization.data(withJSONObject: note), let s = String(data: d, encoding: .utf8) {
        AtomicFile.writeWhole(path: paths.notePath, text: s)
      }
    }
  }

  func addTimelineMarker() {
    let ms = Int64(Date().timeIntervalSince1970 * 1000.0)
    let line = "{\"at\":\(ms),\"label\":\"\"}\n"
    AtomicFile.appendLine(path: paths.markersPath, line: line)
  }

  private func handleTrayCommand(_ cmd: Int) {
    switch cmd {
    case 1: openReplayWindow(openSettings: false)
    case 2: saveInstantReplay()
    case 3: addTimelineMarker()
    case 4: pausedUntil = Date().addingTimeInterval(15 * 60)
    case 5: pausedUntil = Date().addingTimeInterval(60 * 60)
    case 6: pausedUntil = nil
    case 7: openReplayWindow(openSettings: true)
    case 9:
      shutdown()
      exit(0)
    default: break
    }
  }

  // MARK: - Menu Bar & Carbon Hotkeys

  @MainActor
  private func setupMenuBar() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.statusItem = item
    let english = SRStrings.isEnglish(viewerPath: paths.viewerPath)

    let menu = NSMenu()
    let summary = NSMenuItem(title: SRStrings.t("启动中…", "Starting…", english: english), action: nil, keyEquivalent: "")
    summary.isEnabled = false
    self.statusSummaryItem = summary
    menu.addItem(summary)
    menu.addItem(.separator())

    let openItem = NSMenuItem(title: SRStrings.t("打开回放窗口", "Open Replay Window", english: english), action: #selector(onMenuOpenReplay), keyEquivalent: "r")
    openItem.keyEquivalentModifierMask = [.control, .option]
    openItem.target = self
    menu.addItem(openItem)

    let saveItem = NSMenuItem(title: SRStrings.t("保存最近回放", "Save Instant Replay", english: english), action: #selector(onMenuSaveInstant), keyEquivalent: "s")
    saveItem.keyEquivalentModifierMask = [.control, .option]
    saveItem.target = self
    menu.addItem(saveItem)

    let markItem = NSMenuItem(title: SRStrings.t("添加时间线标记", "Add Timeline Marker", english: english), action: #selector(onMenuAddMarker), keyEquivalent: "m")
    markItem.keyEquivalentModifierMask = [.control, .option]
    markItem.target = self
    menu.addItem(markItem)

    menu.addItem(.separator())

    let permItem = NSMenuItem(title: SRStrings.t("开启屏幕录制权限…", "Grant Screen Recording…", english: english), action: #selector(onMenuPermissions), keyEquivalent: "")
    permItem.target = self
    permItem.isHidden = true
    self.permissionItem = permItem
    menu.addItem(permItem)

    let pauseItem = NSMenuItem(title: SRStrings.t("暂停 15 分钟", "Pause for 15 Minutes", english: english), action: #selector(onMenuTogglePause), keyEquivalent: "")
    pauseItem.target = self
    self.pauseResumeItem = pauseItem
    menu.addItem(pauseItem)

    let settingsItem = NSMenuItem(title: SRStrings.t("设置…", "Settings…", english: english), action: #selector(onMenuSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: SRStrings.t("退出 ScreenReplay", "Quit ScreenReplay", english: english), action: #selector(onMenuQuit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    item.menu = menu
    updateMenuBarIcon(recording: false)
  }

  @MainActor
  private func refreshMenuBar(recording: Bool, paused: Bool, needPermission: Bool, summary: String, english: Bool) {
    statusSummaryItem?.title = summary
    permissionItem?.isHidden = !needPermission
    pauseResumeItem?.title = paused
      ? SRStrings.t("继续录制", "Resume Recording", english: english)
      : SRStrings.t("暂停 15 分钟", "Pause for 15 Minutes", english: english)
    updateMenuBarIcon(recording: recording)
  }

  @MainActor
  private func updateMenuBarIcon(recording: Bool) {
    guard let button = statusItem?.button else { return }
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13))
      ring.lineWidth = 1.5
      (recording ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.65)).setStroke()
      ring.stroke()
      let dot = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6))
      (recording ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.45)).setFill()
      dot.fill()
      return true
    }
    img.isTemplate = !recording
    button.image = img
  }

  @objc private func onMenuOpenReplay() { queue.async { self.openReplayWindow(openSettings: false) } }
  @objc private func onMenuSaveInstant() { queue.async { self.saveInstantReplay() } }
  @objc private func onMenuAddMarker() { queue.async { self.addTimelineMarker() } }
  @objc private func onMenuPermissions() { queue.async { self.showPermissionsUI() } }
  @objc private func onMenuSettings() { queue.async { self.openReplayWindow(openSettings: true) } }
  @objc private func onMenuTogglePause() {
    queue.async {
      if self.pausedUntil != nil {
        self.pausedUntil = nil
      } else {
        self.pausedUntil = Date().addingTimeInterval(15 * 60)
      }
      self.tick()
    }
  }
  @objc private func onMenuQuit() {
    queue.async {
      self.shutdown()
      exit(0)
    }
  }

  @MainActor
  private func registerCarbonHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let event, let userData else { return noErr }
        var hkID = EventHotKeyID()
        let st = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hkID
        )
        guard st == noErr else { return noErr }
        let host = Unmanaged<HostCoordinator>.fromOpaque(userData).takeUnretainedValue()
        switch hkID.id {
        case 1: host.queue.async { host.openReplayWindow(openSettings: false) }
        case 2: host.queue.async { host.saveInstantReplay() }
        case 3: host.queue.async { host.addTimelineMarker() }
        default: break
        }
        return noErr
      },
      1,
      &spec,
      selfPtr,
      nil
    )

    let mods = UInt32(controlKey | optionKey)
    let bindings: [(UInt32, UInt32)] = [
      (1, UInt32(kVK_ANSI_R)), // ⌃⌥R Open Replay
      (2, UInt32(kVK_ANSI_S)), // ⌃⌥S Save Instant Replay
      (3, UInt32(kVK_ANSI_M)), // ⌃⌥M Add Marker
    ]
    for (id, keyCode) in bindings {
      var ref: EventHotKeyRef?
      let hkID = EventHotKeyID(signature: OSType(0x5352_4D43), id: id)
      if RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr {
        hotKeyRefs.append(ref)
      }
    }
  }
}

// MARK: - Entry Point

let args = Set(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
let paths = RecorderPaths.fromEnvironment(env)
let headlessTest = args.contains("--headless-test") || env["SR_HEADLESS_TEST"] == "1"
let directHelper = headlessTest || env["SR_DIRECT_HELPER"] == "1"
let syntheticOverride = args.contains("--synthetic") || env["SR_SYNTHETIC"] == "1"

let lockFD = open(paths.hostLockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
if args.contains("--quit") {
  if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    AtomicFile.writeWhole(path: paths.requestPath("quit.request"), text: "quit")
    let deadline = Date().addingTimeInterval(4.5)
    while Date() < deadline {
      if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
        _ = flock(lockFD, LOCK_UN)
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }
  if lockFD >= 0 { close(lockFD) }
  exit(0)
}

if !headlessTest && !args.contains("--background") && !args.contains("--updated") {
  AtomicFile.writeWhole(path: paths.requestPath("open.request"), text: "open")
}

if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
  // Another ScreenReplayMac instance is already running for this REPLAY_ROOT; open.request (if any) wakes its viewer.
  close(lockFD)
  exit(0)
}

let coordinator = HostCoordinator(
  paths: paths,
  headlessTest: headlessTest,
  directHelper: directHelper,
  syntheticOverride: syntheticOverride
)
coordinator.start()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigQ = DispatchQueue(label: "dev.pengx17.screenreplay.host.sig")
let sInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQ)
let sTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: sigQ)
let stopClean: () -> Void = {
  coordinator.shutdown()
  exit(0)
}
sInt.setEventHandler(handler: stopClean)
sTerm.setEventHandler(handler: stopClean)
sInt.resume()
sTerm.resume()

if headlessTest {
  RunLoop.main.run()
} else {
  let app = NSApplication.shared
  _ = app.setActivationPolicy(.accessory)
  app.run()
}
