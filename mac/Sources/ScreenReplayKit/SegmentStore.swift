import Foundation

public struct Segment: Sendable, Equatable {
  public let path: String
  public let startUtc: Date
  public let endUtc: Date
  public let bytes: Int64
  public let width: Int
  public let height: Int
  public let durationMs: Double
  public let fps: Int

  public var stem: String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
  }

  public init(
    path: String,
    startUtc: Date,
    endUtc: Date,
    bytes: Int64,
    width: Int,
    height: Int,
    durationMs: Double,
    fps: Int = 60
  ) {
    self.path = path
    self.startUtc = startUtc
    self.endUtc = endUtc
    self.bytes = bytes
    self.width = width
    self.height = height
    self.durationMs = durationMs
    self.fps = fps
  }
}

public final class SegmentStore: @unchecked Sendable {
  public static let sidecars = [".json", ".levels", ".input", ".thumbs"]
  public static let tempExtensions = [".mp4.writing", ".recording"]

  public let folder: String
  private let lock = NSLock()
  private var cache: [String: Segment] = [:]

  public init(folder: String) {
    self.folder = (folder as NSString).standardizingPath
  }

  public func list() -> [Segment] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
      return []
    }
    var found: [Segment] = []
    lock.lock()
    var seenPaths = Set<String>()
    for entry in entries {
      guard (entry as NSString).pathExtension.lowercased() == "mp4" else { continue }
      let mp4Path = (folder as NSString).appendingPathComponent(entry)
      seenPaths.insert(mp4Path)
      if let cached = cache[mp4Path] {
        found.append(cached)
      } else if let parsed = Self.readSegment(mp4Path: mp4Path) {
        cache[mp4Path] = parsed
        found.append(parsed)
      }
    }
    for key in Array(cache.keys) where !seenPaths.contains(key) {
      cache.removeValue(forKey: key)
    }
    lock.unlock()

    found.sort { $0.startUtc < $1.startUtc }
    return found
  }

  public static func readSegment(mp4Path: String) -> Segment? {
    let stemPath = (mp4Path as NSString).deletingPathExtension
    let jsonPath = stemPath + ".json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let durationMs = (obj["durationMs"] as? NSNumber)?.doubleValue,
          durationMs > 0
    else {
      return nil
    }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: mp4Path),
          let size = (attrs[.size] as? NSNumber)?.int64Value
    else {
      return nil
    }

    let start: Date
    if let startStr = obj["startUtc"] as? String, let parsed = parseISO8601UTC(startStr) {
      start = parsed
    } else if let fromName = parseStartFromName((mp4Path as NSString).lastPathComponent) {
      start = fromName
    } else {
      return nil
    }

    let w = (obj["width"] as? NSNumber)?.intValue ?? 0
    let h = (obj["height"] as? NSNumber)?.intValue ?? 0
    let fps = (obj["fps"] as? NSNumber)?.intValue ?? 0
    return Segment(
      path: mp4Path,
      startUtc: start,
      endUtc: start.addingTimeInterval(durationMs / 1000.0),
      bytes: size,
      width: w,
      height: h,
      durationMs: durationMs,
      fps: fps
    )
  }

  public static func parseStartFromName(_ name: String) -> Date? {
    guard name.count >= 19 else { return nil }
    let prefix = String(name.prefix(19))
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return f.date(from: prefix)
  }

  public static func formatStem(startUtc: Date, id: String? = nil) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let suffix = id ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    return "\(f.string(from: startUtc))-\(suffix)"
  }

  public static func formatISO8601UTC(_ date: Date) -> String {
    let epochMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    let wholeSec = epochMs / 1000
    let ms = abs(epochMs % 1000)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return String(format: "%@.%03d0000Z", f.string(from: Date(timeIntervalSince1970: TimeInterval(wholeSec))), ms)
  }

  public static func parseISO8601UTC(_ string: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: string) { return d }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: string)
  }

  @discardableResult
  public func prune(before: Date) -> Int {
    var deleted = 0
    for segment in list() {
      if segment.endUtc >= before { continue }
      if deleteSegmentAndSidecars(segment) {
        deleted += 1
      }
    }
    return deleted
  }

  public func pruneToLimits(maxBytes: Int64, keepFreeBytes: Int64 = 10 << 30) -> (deleted: Int, diskTight: Bool) {
    let segments = list()
    guard segments.count > 1 else {
      let free = AtomicFile.diskFreeBytes(at: folder)
      return (0, free >= 0 && free < keepFreeBytes)
    }
    var totalBytes = segments.reduce(Int64(0)) { $0 + $1.bytes }
    var free = AtomicFile.diskFreeBytes(at: folder)
    let initialTight = free >= 0 && free < keepFreeBytes
    var deleted = 0

    for i in 0..<(segments.count - 1) {
      let overMax = maxBytes > 0 && totalBytes > maxBytes
      let lowDisk = free >= 0 && free < keepFreeBytes
      if !overMax && !lowDisk {
        break
      }
      if deleteSegmentAndSidecars(segments[i]) {
        deleted += 1
        totalBytes -= segments[i].bytes
        if free >= 0 {
          free += segments[i].bytes
        }
      }
    }
    let finalTight = initialTight || (free >= 0 && free < keepFreeBytes)
    return (deleted, finalTight)
  }

  public func deleteSegmentAndSidecars(_ segment: Segment) -> Bool {
    do {
      try FileManager.default.removeItem(atPath: segment.path)
    } catch {
      return false
    }
    let stemPath = (segment.path as NSString).deletingPathExtension
    for ext in Self.sidecars {
      try? FileManager.default.removeItem(atPath: stemPath + ext)
    }
    lock.lock()
    cache.removeValue(forKey: segment.path)
    lock.unlock()
    return true
  }

  public func deleteUnfinished() {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
    for entry in entries {
      if Self.tempExtensions.contains(where: { entry.hasSuffix($0) }) {
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(entry))
      }
    }
  }
}
