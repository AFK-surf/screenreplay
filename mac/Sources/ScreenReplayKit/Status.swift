import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import Foundation

public enum Status {
  public static func captureAllowed() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  public static func microphoneStatusString() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  public static func microphoneAllowed() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  public static func inputMonitoringAllowed() -> Bool {
    CGPreflightListenEventAccess()
  }

  public static func controlAllowed() -> Bool {
    CGPreflightPostEventAccess() || AXIsProcessTrusted()
  }

  public static func now() -> [String: Any] {
    let online = onlineDisplays()
    let mainID = CGMainDisplayID()
    let mainDisplay = online.first(where: { ($0["id"] as? Int) == Int(mainID) }) ?? display(mainID)
    return [
      "capture": captureAllowed(),
      "microphone": microphoneAllowed(),
      "microphoneStatus": microphoneStatusString(),
      "inputMonitoring": inputMonitoringAllowed(),
      "accessibility": AXIsProcessTrusted(),
      "control": controlAllowed(),
      "responsible": responsible(),
      "displays": online,
      "display": mainDisplay,
      "app": Bundle.main.bundlePath,
      "pid": Int(getpid()),
    ]
  }

  /// Spawns a fresh child process (`<ScreenReplayHelper> status`) so newly granted TCC permissions
  /// are observed immediately even while the running daemon still holds its launch-time TCC snapshot.
  public static func fresh(executablePath: String? = nil) -> [String: Any]? {
    let resolved = executablePath ?? Bundle.main.executablePath ?? CommandLine.arguments.first
    guard let executable = resolved, FileManager.default.isExecutableFile(atPath: executable) else {
      return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["status"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// Queries macOS `responsibility_get_pid_responsible_for_pid` so callers can verify that
  /// `ScreenReplay Helper.app` (not Terminal / launchd / parent host) is its own TCC responsible app.
  public static func responsible() -> [String: Any] {
    typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    var rpid = getpid()
    if let handle = dlopen(nil, RTLD_NOW),
       let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
    {
      rpid = unsafeBitCast(sym, to: ResponsibleFn.self)(getpid())
    }
    var path = executablePath(rpid) ?? ""
    if let range = path.range(of: ".app/Contents/MacOS/") {
      path = String(path[..<range.lowerBound]) + ".app"
    }
    var name = (path as NSString).lastPathComponent
    if name.hasSuffix(".app") {
      name = (Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? String(name.dropLast(4))
    }
    return ["pid": Int(rpid), "path": path, "name": name]
  }

  public static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
      return String(cString: buffer)
    }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size <= 4 { return nil }
    var args = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, 3, &args, &size, nil, 0) != 0 { return nil }
    guard let end = args[4..<size].firstIndex(of: 0) else { return nil }
    return String(decoding: args[4..<end], as: UTF8.self)
  }

  public static func onlineDisplays() -> [[String: Any]] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
      return [display(CGMainDisplayID())]
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
      return [display(CGMainDisplayID())]
    }
    return ids.prefix(Int(count)).map { display($0) }
  }

  public static func display(_ id: CGDirectDisplayID) -> [String: Any] {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    let pixelW = mode?.pixelWidth ?? max(1, Int(bounds.width))
    let pixelH = mode?.pixelHeight ?? max(1, Int(bounds.height))
    var hz = mode?.refreshRate ?? 0.0
    var edrHeadroom = 1.0
    var potentialEdrHeadroom = 1.0
    var wideGamut = false

    // Only inspect NSScreen if NSApp has already been initialized in GUI/daemon mode,
    // so CLI `status` and headless tests never spin up WindowServer AppKit state unnecessarily.
    if NSApp != nil && Thread.isMainThread {
      if let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
      }) {
        if hz <= 0 {
          hz = Double(screen.maximumFramesPerSecond)
        }
        edrHeadroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        potentialEdrHeadroom = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        wideGamut = screen.canRepresent(.p3)
      }
    }
    if hz <= 0 {
      // Built-in Apple Silicon ProMotion panels sometimes report 0 in CGDisplayMode.refreshRate without NSScreen.
      hz = CGDisplayIsBuiltin(id) != 0 ? 120.0 : 60.0
    }
    if !wideGamut {
      let space = CGDisplayCopyColorSpace(id)
      wideGamut = space.isWideGamutRGB
    }

    return [
      "id": Int(id),
      "main": id == CGMainDisplayID(),
      "width": pixelW,
      "height": pixelH,
      "points": [
        "x": bounds.minX,
        "y": bounds.minY,
        "width": bounds.width,
        "height": bounds.height,
      ],
      "refreshRate": hz,
      "edrHeadroom": edrHeadroom,
      "potentialEdrHeadroom": potentialEdrHeadroom,
      "wideGamut": wideGamut,
    ]
  }
}
