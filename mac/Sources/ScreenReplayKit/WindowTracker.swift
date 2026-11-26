import AppKit
import CoreGraphics
import Foundation
import ImageIO

public final class WindowTracker: @unchecked Sendable {
  private static let excludedBundleIDs: Set<String> = [
    "dev.pengx17.screenreplay",
    "dev.pengx17.screenreplay.helper",
    "dev.pengx17.screenreplay.viewer",
  ]
  private static let excludedNames: Set<String> = [
    "ScreenReplay",
    "ScreenReplayMac",
    "ScreenReplayViewer",
    "ScreenReplay Helper",
    "ScreenReplayHelper",
    "Window Server",
    "Dock",
    "Control Center",
    "Notification Center",
  ]

  private let paths: RecorderPaths
  private let logger: RecorderLogger?
  private let queue = DispatchQueue(label: "dev.pengx17.screenreplay.windows", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var workspaceObserver: NSObjectProtocol?

  private var active = false
  private var synthetic = false
  private var excludeSelf = true
  private var displayID: CGDirectDisplayID = CGMainDisplayID()

  private var lastAppKey = ""
  private var lastWindowBody = ""
  private var cachedIcons = Set<String>()
  private var lastPruneTime = Date.distantPast

  public init(paths: RecorderPaths, logger: RecorderLogger? = nil) {
    self.paths = paths
    self.logger = logger
  }

  public func start(displayID: CGDirectDisplayID, excludeSelf: Bool, synthetic: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.displayID = displayID == 0 ? CGMainDisplayID() : displayID
      self.excludeSelf = excludeSelf
      self.synthetic = synthetic
      if self.active { return }
      self.active = true
      self.lastWindowBody = ""

      if synthetic {
        self.writeSyntheticSnapshot()
        return
      }

      self.pollNow(force: true)
      let t = DispatchSource.makeTimerSource(queue: self.queue)
      t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
      t.setEventHandler { [weak self] in
        self?.pollNow(force: false)
      }
      t.resume()
      self.timer = t

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.didActivateApplicationNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.queue.async {
            self?.pollNow(force: true)
          }
        }
      }
    }
  }

  public func stop() {
    queue.sync {
      active = false
      timer?.cancel()
      timer = nil
    }
    if let obs = workspaceObserver {
      DispatchQueue.main.async {
        NSWorkspace.shared.notificationCenter.removeObserver(obs)
      }
      workspaceObserver = nil
    }
  }

  public func clear() {
    queue.sync {
      try? FileManager.default.removeItem(atPath: paths.windowsPath)
      lastWindowBody = ""
      lastAppKey = ""
    }
  }

  private func writeSyntheticSnapshot() {
    let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    let appKey = "screenreplaysynthetic"
    if lastAppKey != appKey {
      lastAppKey = appKey
      AtomicFile.appendLine(
        path: paths.appsPath,
        line: "{\"at\":\(nowMs),\"app\":\(AtomicFile.jsonString("ScreenReplaySynthetic"))}"
      )
      try? FileManager.default.createDirectory(atPath: paths.appIconsDir, withIntermediateDirectories: true)
      AtomicFile.writeWhole(
        path: (paths.appIconsDir as NSString).appendingPathComponent("\(appKey).txt"),
        text: "ScreenReplay Synthetic"
      )
    }
    let winLine = "{\"at\":\(nowMs),\"screen\":[0,0,1280,720],\"fg\":1,\"w\":[[1,0,\"ScreenReplaySynthetic\",\"Synthetic Test Window\",80,60,1120,600,0,\"NSWindow\"]]}"
    AtomicFile.appendLine(path: paths.windowsPath, line: winLine)
  }

  private func pollNow(force: Bool) {
    guard active, !synthetic else { return }
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      return
    }

    let bounds = CGDisplayBounds(displayID)
    let mode = CGDisplayCopyDisplayMode(displayID)
    let pixelW = mode?.pixelWidth ?? max(1, Int(bounds.width))
    let scale = bounds.width > 0 ? Double(pixelW) / Double(bounds.width) : 1.0

    let sx = Int((bounds.origin.x * scale).rounded())
    let sy = Int((bounds.origin.y * scale).rounded())
    let sw = max(1, Int((bounds.size.width * scale).rounded()))
    let sh = max(1, Int((bounds.size.height * scale).rounded()))

    let ownPID = getpid()
    var frontWindowID: Int64 = 0
    var frontOwnerPID: pid_t = 0
    var frontOwnerName = ""
    var windowsJSON: [String] = []

    for info in rawList {
      guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
            let winID = (info[kCGWindowNumber as String] as? NSNumber)?.int64Value,
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let rectDict = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: rectDict as CFDictionary)
      else { continue }

      if rect.width < 2 || rect.height < 2 { continue }
      if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }

      let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
      if excludeSelf && (ownerPID == ownPID || Self.excludedNames.contains(ownerName)) {
        continue
      }
      if ownerName == "Window Server" || ownerName == "Dock" {
        continue
      }

      let title = (info[kCGWindowName as String] as? String) ?? ""
      let processKey = Self.sanitizeKey(ownerName)
      if processKey.isEmpty { continue }

      if frontWindowID == 0 {
        frontWindowID = winID
        frontOwnerPID = ownerPID
        frontOwnerName = ownerName
      }

      let wx = Int((rect.origin.x * scale).rounded())
      let wy = Int((rect.origin.y * scale).rounded())
      let ww = max(1, Int((rect.size.width * scale).rounded()))
      let wh = max(1, Int((rect.size.height * scale).rounded()))
      let isZoomed = (ww >= sw && wh >= sh - Int(40.0 * scale)) ? 2 : 0

      let entry = "[\(winID),0,\(AtomicFile.jsonString(processKey)),\(AtomicFile.jsonString(title)),\(wx),\(wy),\(ww),\(wh),\(isZoomed),\"NSWindow\"]"
      windowsJSON.append(entry)
    }

    let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())

    let fgProcessKey = Self.sanitizeKey(frontOwnerName)
    if !fgProcessKey.isEmpty && fgProcessKey != lastAppKey {
      lastAppKey = fgProcessKey
      AtomicFile.appendLine(
        path: paths.appsPath,
        line: "{\"at\":\(nowMs),\"app\":\(AtomicFile.jsonString(fgProcessKey))}"
      )
      if frontOwnerPID > 0 {
        cacheAppIconAndName(pid: frontOwnerPID, key: fgProcessKey, fallbackName: frontOwnerName)
      }
    }

    let body = "\"screen\":[\(sx),\(sy),\(sw),\(sh)],\"fg\":\(frontWindowID),\"w\":[\(windowsJSON.joined(separator: ","))]"
    if force || body != lastWindowBody {
      lastWindowBody = body
      AtomicFile.appendLine(path: paths.windowsPath, line: "{\"at\":\(nowMs),\(body)}")
    }
  }

  private func cacheAppIconAndName(pid: pid_t, key: String, fallbackName: String) {
    let lowerKey = key.lowercased()
    if cachedIcons.contains(lowerKey) { return }
    let pngPath = (paths.appIconsDir as NSString).appendingPathComponent("\(lowerKey).png")
    let txtPath = (paths.appIconsDir as NSString).appendingPathComponent("\(lowerKey).txt")
    if FileManager.default.fileExists(atPath: pngPath) && FileManager.default.fileExists(atPath: txtPath) {
      cachedIcons.insert(lowerKey)
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let app = NSRunningApplication(processIdentifier: pid) else { return }
      if self.excludeSelf, let bid = app.bundleIdentifier, Self.excludedBundleIDs.contains(bid) {
        return
      }
      let displayName = (app.localizedName ?? fallbackName).trimmingCharacters(in: .whitespacesAndNewlines)
      let iconImage = app.icon

      try? FileManager.default.createDirectory(atPath: self.paths.appIconsDir, withIntermediateDirectories: true)
      if !displayName.isEmpty {
        AtomicFile.writeWhole(path: txtPath, text: displayName)
      }
      if let iconImage, let pngData = Self.render32x32PNG(iconImage) {
        AtomicFile.writeWhole(path: pngPath, data: pngData)
      }
      self.queue.async {
        self.cachedIcons.insert(lowerKey)
      }
    }
  }

  public static func render32x32PNG(_ image: NSImage, side: Int = 32) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }

  public static func sanitizeKey(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    var out = ""
    out.reserveCapacity(trimmed.count)
    for ch in trimmed {
      if ch == "/" || ch == "\\" || ch == ":" || ch == "\0" {
        out.append("_")
      } else {
        out.append(ch)
      }
    }
    return out
  }

  public static func isFullscreenAppInFront(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
    let bounds = CGDisplayBounds(displayID)
    guard bounds.width > 0, bounds.height > 0,
          let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }

    let ownPID = getpid()
    for info in rawList {
      guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let rectDict = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: rectDict as CFDictionary)
      else { continue }

      let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
      if ownerName == "Finder" || ownerName == "Dock" || ownerName == "Window Server" { continue }
      if ownerPID == ownPID || excludedNames.contains(ownerName) { return false }

      return rect.minX <= bounds.minX + 1 &&
        rect.minY <= bounds.minY + 1 &&
        rect.width >= bounds.width - 2 &&
        rect.height >= bounds.height - 2
    }
    return false
  }

  public func pruneIfNeeded(keepSeconds: TimeInterval) {
    queue.async { [weak self] in
      guard let self else { return }
      if Date().timeIntervalSince(self.lastPruneTime) < 600 { return }
      self.lastPruneTime = Date()
      Self.trimJSONLinesFile(path: self.paths.windowsPath, minSizeBytes: 4 << 20, keepSeconds: keepSeconds)
      Self.trimJSONLinesFile(path: self.paths.appsPath, minSizeBytes: 256 << 10, keepSeconds: keepSeconds)
      Self.trimJSONLinesFile(path: self.paths.markersPath, minSizeBytes: 256 << 10, keepSeconds: keepSeconds)
    }
  }

  public static func trimJSONLinesFile(path: String, minSizeBytes: Int64, keepSeconds: TimeInterval) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.int64Value,
          size >= minSizeBytes,
          let content = try? String(contentsOfFile: path, encoding: .utf8)
    else { return }

    let cutoffMs = Int64(((Date().timeIntervalSince1970 - keepSeconds) * 1000.0).rounded())
    var kept: [String] = []
    var newestBefore: String?
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    for sub in lines {
      let line = String(sub)
      var at: Int64 = 0
      if line.hasPrefix("{\"at\":"), let comma = line.firstIndex(of: ",") {
        let startIdx = line.index(line.startIndex, offsetBy: 6)
        at = Int64(line[startIdx..<comma]) ?? 0
      }
      if at > 0 && at < cutoffMs {
        newestBefore = line
      } else {
        kept.append(line)
      }
    }
    if let newestBefore {
      kept.insert(newestBefore, at: 0)
    }
    guard kept.count < lines.count else { return }
    AtomicFile.writeWhole(path: path, text: kept.joined(separator: "\n") + "\n")
  }
}
