import CryptoKit
import Darwin
import Foundation

public struct RecorderPaths: Sendable, Equatable {
  public let root: String
  public let defaultBuffer: String
  public let replayExe: String
  public let rootHash: String
  public let socketPath: String

  public var helperDir: String { (root as NSString).appendingPathComponent("helper") }
  public var installedHelperApp: String { (helperDir as NSString).appendingPathComponent("ScreenReplay Helper.app") }
  public var tokenPath: String { (helperDir as NSString).appendingPathComponent("token") }
  public var helperLockPath: String { (helperDir as NSString).appendingPathComponent("helper.lock") }
  public var hostLockPath: String { (root as NSString).appendingPathComponent("host.lock") }
  public var markersPath: String { (root as NSString).appendingPathComponent("markers.jsonl") }
  public var appsPath: String { (root as NSString).appendingPathComponent("apps.jsonl") }
  public var windowsPath: String { (root as NSString).appendingPathComponent("windows.jsonl") }
  public var statePath: String { (root as NSString).appendingPathComponent("state.json") }
  public var settingsPath: String { (root as NSString).appendingPathComponent("settings.json") }
  public var viewerPath: String { (root as NSString).appendingPathComponent("viewer.json") }
  public var buffersPath: String { (root as NSString).appendingPathComponent("buffers.json") }
  public var savedPath: String { (root as NSString).appendingPathComponent("saved.jsonl") }
  public var notePath: String { (root as NSString).appendingPathComponent("note.json") }
  public var updatePath: String { (root as NSString).appendingPathComponent("update.json") }
  public var appIconsDir: String { (root as NSString).appendingPathComponent("AppIcons") }
  public var thumbsDir: String { (root as NSString).appendingPathComponent("Thumbs") }
  public var logPath: String { (root as NSString).appendingPathComponent("recorder.log") }
  public var oldLogPath: String { (root as NSString).appendingPathComponent("recorder.old.log") }

  public init(root: String, buffer: String? = nil, replayExe: String? = nil, socketPath: String? = nil) {
    let standardizedRoot = (root as NSString).standardizingPath
    self.root = standardizedRoot
    if let buffer, !buffer.isEmpty {
      self.defaultBuffer = (buffer as NSString).standardizingPath
    } else {
      self.defaultBuffer = (standardizedRoot as NSString).appendingPathComponent("Buffer")
    }
    if let replayExe, !replayExe.isEmpty {
      self.replayExe = replayExe
    } else {
      let exeDir = ((Bundle.main.executablePath ?? CommandLine.arguments.first ?? "") as NSString).deletingLastPathComponent
      self.replayExe = (exeDir as NSString).appendingPathComponent("ScreenReplayViewer")
    }
    let digest = SHA256.hash(data: Data(standardizedRoot.lowercased().utf8))
    let hashHex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    self.rootHash = hashHex
    if let socketPath, !socketPath.isEmpty {
      self.socketPath = socketPath
    } else {
      self.socketPath = "/tmp/sr-helper-\(getuid())-\(hashHex).sock"
    }
  }

  public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RecorderPaths {
    let rawRoot: String
    if let sr = env["SR_REPLAY_ROOT"], !sr.isEmpty {
      rawRoot = sr
    } else if let rr = env["REPLAY_ROOT"], !rr.isEmpty {
      rawRoot = rr
    } else {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
        ?? ((NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
      rawRoot = (appSupport as NSString).appendingPathComponent("ScreenReplay")
    }
    try? FileManager.default.createDirectory(atPath: rawRoot, withIntermediateDirectories: true)
    let bufferEnv = env["REPLAY_DIR"]
    let exeEnv = env["REPLAY_WINDOW_EXE"]
    let sockEnv = env["SR_HELPER_SOCKET"]
    return RecorderPaths(
      root: rawRoot,
      buffer: (bufferEnv?.isEmpty == false) ? bufferEnv : nil,
      replayExe: (exeEnv?.isEmpty == false) ? exeEnv : nil,
      socketPath: (sockEnv?.isEmpty == false) ? sockEnv : nil
    )
  }

  public func requestPath(_ name: String) -> String {
    (root as NSString).appendingPathComponent(name)
  }
}

public struct RecorderSettings: Sendable, Equatable {
  public static let consentVersionRequired = 1

  public var enabled: Bool
  public var windowMinutes: Int
  public var maxGB: Int
  public var autostart: Bool
  public var systemAudio: Bool
  public var microphone: Bool
  public var recordCursor: Bool
  public var pauseInFullscreen: Bool
  public var codec: String
  public var maxHeight: Int
  public var frameRate: Int
  public var quality: String
  public var lastSeconds: Int
  public var bufferDir: String
  public var consented: Bool
  public var consentVersion: Int
  public var consentAt: Int64
  public var autoUpdate: Bool
  public var displayID: UInt32
  public var hotkeys: Bool
  public var hotkeyOpen: String
  public var hotkeyMark: String
  public var hotkeySave: String

  public var windowSeconds: TimeInterval { TimeInterval(windowMinutes) * 60.0 }
  public var maxBytes: Int64 { maxGB > 0 ? (Int64(maxGB) << 30) : 0 }

  public init(
    enabled: Bool = false,
    windowMinutes: Int = 120,
    maxGB: Int = 20,
    autostart: Bool = false,
    systemAudio: Bool = true,
    microphone: Bool = false,
    recordCursor: Bool = true,
    pauseInFullscreen: Bool = false,
    codec: String = "HEVC",
    maxHeight: Int = 0,
    frameRate: Int = 60,
    quality: String = "high",
    lastSeconds: Int = 30,
    bufferDir: String = "",
    consented: Bool = false,
    consentVersion: Int = 0,
    consentAt: Int64 = 0,
    autoUpdate: Bool = true,
    displayID: UInt32 = 0,
    hotkeys: Bool = true,
    hotkeyOpen: String = "Ctrl+Alt+R",
    hotkeyMark: String = "Ctrl+Alt+M",
    hotkeySave: String = "Ctrl+Alt+S"
  ) {
    self.enabled = enabled
    self.windowMinutes = min(24 * 60, max(5, windowMinutes))
    self.maxGB = max(0, maxGB)
    self.autostart = autostart
    self.systemAudio = systemAudio
    self.microphone = microphone
    self.recordCursor = recordCursor
    self.pauseInFullscreen = pauseInFullscreen
    self.codec = codec.lowercased() == "h264" ? "H264" : "HEVC"
    self.maxHeight = min(4320, max(0, maxHeight))
    self.frameRate = Self.normalizeFPS(frameRate)
    self.quality = ["low", "medium", "high", "ultra"].contains(quality) ? quality : "high"
    self.lastSeconds = min(600, max(5, lastSeconds))
    self.bufferDir = bufferDir.trimmingCharacters(in: .whitespacesAndNewlines)
    self.consented = consented
    self.consentVersion = consentVersion
    self.consentAt = consentAt
    self.autoUpdate = autoUpdate
    self.displayID = displayID
    self.hotkeys = hotkeys
    self.hotkeyOpen = hotkeyOpen.trimmingCharacters(in: .whitespaces)
    self.hotkeyMark = hotkeyMark.trimmingCharacters(in: .whitespaces)
    self.hotkeySave = hotkeySave.trimmingCharacters(in: .whitespaces)
  }

  public static func normalizeFPS(_ raw: Int) -> Int {
    if raw >= 120 { return 120 }
    if raw >= 90 { return 90 }
    if raw >= 60 { return 60 }
    return 30
  }

  public static func read(from path: String, defaultConsentIfPresent: Bool = false) -> RecorderSettings {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return RecorderSettings()
    }
    return fromJSON(obj, defaultConsentIfPresent: defaultConsentIfPresent)
  }

  public static func fromJSON(_ obj: [String: Any], defaultConsentIfPresent: Bool = false) -> RecorderSettings {
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      if let b = obj[key] as? Bool { return b }
      if let n = obj[key] as? NSNumber { return n.boolValue }
      return fallback
    }
    func number(_ key: String, _ fallback: Int) -> Int {
      if let i = obj[key] as? Int { return i }
      if let n = obj[key] as? NSNumber { return n.intValue }
      return fallback
    }
    func text(_ key: String, _ fallback: String) -> String {
      (obj[key] as? String) ?? fallback
    }

    let sysAudio: Bool
    if obj["systemAudio"] != nil {
      sysAudio = flag("systemAudio", true)
    } else if obj["recordAudio"] != nil {
      sysAudio = flag("recordAudio", true)
    } else {
      sysAudio = true
    }

    let cursor: Bool
    if obj["recordCursor"] != nil {
      cursor = flag("recordCursor", true)
    } else if obj["showsCursor"] != nil {
      cursor = flag("showsCursor", true)
    } else if obj["showCursor"] != nil {
      cursor = flag("showCursor", true)
    } else {
      cursor = true
    }

    var consentVer = 0
    var consentAt: Int64 = 0
    var consented = false
    if let consent = obj["consent"] as? [String: Any] {
      consentVer = (consent["version"] as? NSNumber)?.intValue ?? 0
      consentAt = (consent["at"] as? NSNumber)?.int64Value ?? 0
      consented = consentVer >= consentVersionRequired
    } else if defaultConsentIfPresent && obj["enabled"] != nil {
      consented = true
      consentVer = consentVersionRequired
    }

    let rawFPS = obj["fps"] != nil ? number("fps", 60) : (obj["frameRate"] != nil ? number("frameRate", 60) : 60)
    let rawCodec = text("codec", "HEVC")
    let rawQuality = text("quality", "high")
    let dispID = (obj["displayID"] as? NSNumber)?.uint32Value ?? 0

    return RecorderSettings(
      enabled: flag("enabled", false),
      windowMinutes: number("windowMinutes", 120),
      maxGB: number("maxGB", 20),
      autostart: flag("autostart", false),
      systemAudio: sysAudio,
      microphone: flag("microphone", false),
      recordCursor: cursor,
      pauseInFullscreen: flag("pauseInFullscreen", false),
      codec: rawCodec,
      maxHeight: number("maxHeight", 0),
      frameRate: rawFPS,
      quality: rawQuality,
      lastSeconds: number("lastSeconds", 30),
      bufferDir: text("bufferDir", ""),
      consented: consented,
      consentVersion: consentVer,
      consentAt: consentAt,
      autoUpdate: flag("autoUpdate", true),
      displayID: dispID,
      hotkeys: flag("hotkeys", true),
      hotkeyOpen: text("hotkeyOpen", "Ctrl+Alt+R"),
      hotkeyMark: text("hotkeyMark", "Ctrl+Alt+M"),
      hotkeySave: text("hotkeySave", "Ctrl+Alt+S")
    )
  }

  public static func setEnabled(_ on: Bool, at path: String) {
    var obj: [String: Any] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      obj = parsed
    }
    obj["enabled"] = on
    if let out = try? JSONSerialization.data(withJSONObject: obj, options: []),
       let text = String(data: out, encoding: .utf8)
    {
      AtomicFile.writeWhole(path: path, text: text)
    }
  }
}

public struct ViewerPrefs: Sendable, Equatable {
  public var language: String
  public var hideFromCapture: Bool

  public init(language: String = "system", hideFromCapture: Bool = true) {
    self.language = language
    self.hideFromCapture = hideFromCapture
  }

  public static func read(from path: String) -> ViewerPrefs {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return ViewerPrefs()
    }
    let lang = (obj["language"] as? String) ?? "system"
    let hide: Bool
    if let b = obj["hide_from_capture"] as? Bool {
      hide = b
    } else if let n = obj["hide_from_capture"] as? NSNumber {
      hide = n.boolValue
    } else {
      hide = true
    }
    return ViewerPrefs(language: lang, hideFromCapture: hide)
  }
}

public enum SRStrings {
  public static func isEnglish(viewerPath: String) -> Bool {
    let prefs = ViewerPrefs.read(from: viewerPath)
    switch prefs.language {
    case "en": return true
    case "zh": return false
    default:
      let preferred = Locale.preferredLanguages.first ?? "en"
      return !preferred.lowercased().hasPrefix("zh")
    }
  }

  public static func t(_ zh: String, _ en: String, english: Bool) -> String {
    english ? en : zh
  }

  public static func status(_ code: String, arg: String = "", english: Bool) -> String {
    switch code {
    case "recording":
      return t("后台录制中", "Recording in the background", english: english)
    case "locked":
      return t("已锁屏，暂停中", "Paused while locked", english: english)
    case "paused":
      return t("已暂停，\(arg) 继续", "Paused until \(arg)", english: english)
    case "fullscreen":
      return t("全屏应用在前台，暂停中", "Paused: a full-screen app is in front", english: english)
    case "disabled":
      return t("后台录制已关闭", "Background recording is off", english: english)
    case "diskLow":
      return t("磁盘空间不足，暂停录制", "Paused: the disk is almost full", english: english)
    case "noDisplay":
      return t("找不到主显示器", "No main display found", english: english)
    case "startFailed":
      return t("录制没能开始", "Recording couldn't start", english: english)
    case "noEncoder":
      return t("显卡不支持硬件视频编码，无法录制", "Can't record: no hardware video encoder", english: english)
    case "noPermission":
      return t("需要屏幕录制权限", "Screen Recording permission needed", english: english)
    default:
      return t("启动中…", "Starting…", english: english)
    }
  }

  public static func clipsFolder(english: Bool, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    _ = english
    if let custom = env["REPLAY_OUT"], !custom.isEmpty {
      return custom
    }
    let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path
      ?? (NSHomeDirectory() as NSString).appendingPathComponent("Movies")
    return (movies as NSString).appendingPathComponent("ScreenReplay")
  }
}

public enum Bitrate {
  public static func compute(width: Int, height: Int, frameRate: Int, quality: String, codec: String) -> Int {
    let megapixels = Double(max(2, width)) * Double(max(2, height)) / 1_000_000.0
    let q: Double
    switch quality.lowercased() {
    case "low": q = 0.5
    case "medium": q = 0.75
    case "ultra": q = 1.6
    default: q = 1.0
    }
    let c = codec.caseInsensitiveCompare("HEVC") == .orderedSame || codec.caseInsensitiveCompare("h265") == .orderedSame ? 1.0 : 1.5
    let bps = 3_000_000.0 * pow(megapixels, 0.8) * pow(Double(max(1, frameRate)) / 30.0, 0.6) * q * c
    let clamped = min(150_000_000.0, max(1_000_000.0, bps))
    return Int(clamped.rounded())
  }

  public static func fitDimensions(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
    var w = Double(max(2, width))
    var h = Double(max(2, height))
    if maxHeight > 0 && h > Double(maxHeight) {
      w = w * Double(maxHeight) / h
      h = Double(maxHeight)
    }
    let evenW = max(2, Int(w.rounded()) & ~1)
    let evenH = max(2, Int(h.rounded()) & ~1)
    return (evenW, evenH)
  }
}

public enum AtomicFile {
  public static func writeWhole(path: String, text: String) {
    writeWhole(path: path, data: Data(text.utf8))
  }

  public static func writeWhole(path: String, data: Data, permissions: Int16? = nil) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let part = path + ".part-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    do {
      try data.write(to: URL(fileURLWithPath: part), options: [])
      if let permissions {
        _ = chmod(part, mode_t(permissions))
      }
      if rename(part, path) != 0 {
        try data.write(to: URL(fileURLWithPath: path), options: [])
        if let permissions {
          _ = chmod(path, mode_t(permissions))
        }
        unlink(part)
      }
    } catch {
      try? data.write(to: URL(fileURLWithPath: path), options: [])
      unlink(part)
    }
  }

  public static func appendLine(path: String, line: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let bytes = Data((line + "\n").utf8)
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < raw.count {
        let n = Darwin.write(fd, base + written, raw.count - written)
        if n < 0 {
          if errno == EINTR { continue }
          break
        }
        written += n
      }
    }
  }

  public static func jsonString(_ text: String) -> String {
    var out = "\""
    out.reserveCapacity(text.count + 2)
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x00..<0x20:
        out += String(format: "\\u%04x", scalar.value)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
    return out
  }

  public static func diskFreeBytes(at path: String) -> Int64 {
    var target = path
    while !FileManager.default.fileExists(atPath: target) {
      let parent = (target as NSString).deletingLastPathComponent
      if parent == target || parent.isEmpty { break }
      target = parent
    }
    if let values = try? URL(fileURLWithPath: target).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let avail = values.volumeAvailableCapacityForImportantUsage, avail > 0
    {
      return avail
    }
    var st = statfs()
    if statfs(target, &st) == 0 {
      return Int64(st.f_bavail) * Int64(st.f_bsize)
    }
    return -1
  }
}

public final class RecorderLogger: @unchecked Sendable {
  private let paths: RecorderPaths
  private let lock = NSLock()
  private var writes = 0
  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  public init(paths: RecorderPaths) {
    self.paths = paths
  }

  public func log(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    writes += 1
    if writes % 64 == 1,
       let attrs = try? FileManager.default.attributesOfItem(atPath: paths.logPath),
       let size = (attrs[.size] as? NSNumber)?.int64Value,
       size > 2_000_000
    {
      _ = rename(paths.logPath, paths.oldLogPath)
    }
    let line = "\(formatter.string(from: Date())) \(message)"
    AtomicFile.appendLine(path: paths.logPath, line: line)
  }
}
