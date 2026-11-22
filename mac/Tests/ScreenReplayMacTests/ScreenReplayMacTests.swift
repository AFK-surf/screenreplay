import Foundation
import XCTest
@testable import ScreenReplayKit

final class ScreenReplayMacTests: XCTestCase {
  private func makeTempDir(_ prefix: String) throws -> String {
    let dir = "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  func testSyntheticRollingRecordingFlushAndInstantSave() throws {
    let root = try makeTempDir("sr-test")
    defer { try? FileManager.default.removeItem(atPath: root) }

    let paths = RecorderPaths(root: root)
    let settingsJSON = """
    {"enabled":true,"fps":60,"codec":"HEVC","quality":"high","systemAudio":true,"lastSeconds":10,"consent":{"version":1,"at":1795335000000}}
    """
    AtomicFile.writeWhole(path: paths.settingsPath, text: settingsJSON)

    let token = "test-secret-token-0123456789abcdef"
    let daemon = HelperDaemon(socketPath: paths.socketPath, token: token, paths: paths, headlessTest: true)
    try daemon.start(autoResumeRecording: false)
    defer { daemon.shutdown() }

    // Unauthorized token must be rejected
    XCTAssertThrowsError(
      try UnixSocketClient.request(socketPath: paths.socketPath, token: "wrong-token", op: "hello")
    )

    // Hello & Status
    let hello = try UnixSocketClient.request(socketPath: paths.socketPath, token: token, op: "hello")
    XCTAssertEqual(hello["ok"] as? Bool, true)

    // Start synthetic 60fps HEVC + 48kHz stereo AAC rolling capture (1.5s segment rotation, zero TCC / zero GUI)
    let startReply = try UnixSocketClient.request(
      socketPath: paths.socketPath,
      token: token,
      op: "record.start",
      fields: [
        "synthetic": true,
        "syntheticWidth": 1280,
        "syntheticHeight": 720,
        "fps": 60,
        "codec": "HEVC",
        "systemAudio": true,
        "segmentSeconds": 1.5,
      ]
    )
    XCTAssertEqual(startReply["ok"] as? Bool, true)

    // Wait ~3.6s so at least 2 segments rotate naturally, then flush active segment & stop
    Thread.sleep(forTimeInterval: 3.6)
    let flushReply = try UnixSocketClient.request(
      socketPath: paths.socketPath,
      token: token,
      op: "record.flush",
      fields: ["minDurationSeconds": 0.2]
    )
    XCTAssertEqual(flushReply["ok"] as? Bool, true)

    let stopReply = try UnixSocketClient.request(socketPath: paths.socketPath, token: token, op: "record.stop")
    XCTAssertEqual(stopReply["ok"] as? Bool, true)

    let store = SegmentStore(folder: paths.defaultBuffer)
    let segs = store.list()
    XCTAssertGreaterThanOrEqual(segs.count, 2, "Expected at least 2 completed segments in \(paths.defaultBuffer)")

    for seg in segs {
      XCTAssertTrue(FileManager.default.fileExists(atPath: seg.path))
      XCTAssertGreaterThan(seg.bytes, 1024)
      XCTAssertGreaterThan(seg.durationMs, 10)
      let stem = (seg.path as NSString).deletingPathExtension
      XCTAssertTrue(FileManager.default.fileExists(atPath: stem + ".json"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: stem + ".input"))
    }

    // Verify synthetic WindowTracker sidecars were written
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appsPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.windowsPath))

    // Probe stream codecs with ffprobe if installed
    let ffprobe = "/opt/homebrew/bin/ffprobe"
    if FileManager.default.isExecutableFile(atPath: ffprobe), let firstSeg = segs.first {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: ffprobe)
      proc.arguments = [
        "-v", "error",
        "-show_entries", "stream=codec_name,codec_type,width,height,sample_rate,channels",
        "-of", "json",
        firstSeg.path,
      ]
      let outPipe = Pipe()
      proc.standardOutput = outPipe
      try proc.run()
      let data = outPipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
      XCTAssertEqual(proc.terminationStatus, 0)
      let probeText = String(data: data, encoding: .utf8) ?? ""
      XCTAssertTrue(probeText.contains("hevc"), "Expected HEVC video stream in ffprobe output: \(probeText)")
      XCTAssertTrue(probeText.contains("aac"), "Expected AAC audio stream in ffprobe output: \(probeText)")
    }

    // Verify lossless Instant Replay ClipJoiner across recorded segments
    let clipOut = (root as NSString).appendingPathComponent("instant-clip.mp4")
    XCTAssertTrue(ClipJoiner.saveLast(segments: segs, duration: 10.0, outputPath: clipOut))
    let clipSize = ((try? FileManager.default.attributesOfItem(atPath: clipOut)[.size]) as? NSNumber)?.int64Value ?? 0
    XCTAssertGreaterThan(clipSize, 2048)
  }

  func testSegmentStoreRetentionPruning() throws {
    let bufDir = try makeTempDir("sr-prune")
    defer { try? FileManager.default.removeItem(atPath: bufDir) }

    let store = SegmentStore(folder: bufDir)
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)
    df.dateFormat = "yyyyMMdd-HHmmss-SSS"

    let now = Date()
    let oldStem = df.string(from: now.addingTimeInterval(-7200)) + "-old1"
    let newStem = df.string(from: now.addingTimeInterval(-10)) + "-new1"

    for stem in [oldStem, newStem] {
      let mp4 = (bufDir as NSString).appendingPathComponent(stem + ".mp4")
      let json = (bufDir as NSString).appendingPathComponent(stem + ".json")
      let inp = (bufDir as NSString).appendingPathComponent(stem + ".input")
      try Data(repeating: 0xAA, count: 4096).write(to: URL(fileURLWithPath: mp4))
      AtomicFile.writeWhole(path: json, text: "{\"durationMs\":5000,\"width\":1280,\"height\":720}")
      try Data(repeating: 1, count: 50).write(to: URL(fileURLWithPath: inp))
    }

    XCTAssertEqual(store.list().count, 2)
    store.prune(before: now.addingTimeInterval(-1800))
    let remaining = store.list()
    XCTAssertEqual(remaining.count, 1)
    XCTAssertTrue(remaining[0].path.contains("new1"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: (bufDir as NSString).appendingPathComponent(oldStem + ".json")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: (bufDir as NSString).appendingPathComponent(oldStem + ".input")))
  }

  func testRefreshProbeStatsMath() {
    // 120Hz ProMotion frame deltas (~8.33 ms)
    let deltas120 = Array(repeating: 8.33, count: 240)
    let stats120 = RefreshProbe.computeStats(deltasMs: deltas120)
    XCTAssertEqual(stats120.sampleCount, 240)
    XCTAssertEqual(stats120.p50Ms, 8.33, accuracy: 0.05)
    XCTAssertGreaterThan(stats120.pctNear120Hz, 99.0)
    XCTAssertEqual(stats120.pctNear60Hz, 0.0)
  }
}
