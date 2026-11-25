import AVFoundation
import CoreMedia
import Foundation

public enum ClipJoiner {
  public static func saveLast(segments: [Segment], duration: TimeInterval, outputPath: String) -> Bool {
    guard !segments.isEmpty, duration > 0 else { return false }
    let newest = segments[segments.count - 1]
    let cutoff = newest.endUtc.addingTimeInterval(-duration)

    var parts: [Segment] = []
    for seg in segments.reversed() {
      if seg.endUtc <= cutoff || seg.width != newest.width || seg.height != newest.height {
        break
      }
      parts.insert(seg, at: 0)
    }
    guard !parts.isEmpty else { return false }

    let partialPath = outputPath + ".partial.mp4"
    try? FileManager.default.removeItem(atPath: partialPath)
    let dir = (outputPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let sem = DispatchSemaphore(value: 0)
    var succeeded = false

    Task {
      defer { sem.signal() }
      do {
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
          return
        }
        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for (idx, seg) in parts.enumerated() {
          let asset = AVURLAsset(url: URL(fileURLWithPath: seg.path))
          let assetDuration = try await asset.load(.duration)
          guard assetDuration.isValid && assetDuration > .zero else { continue }

          let videoTracks = try await asset.loadTracks(withMediaType: .video)
          guard let srcVideo = videoTracks.first else { continue }

          var trimStart = CMTime.zero
          if idx == 0 && cutoff > seg.startUtc {
            let skipSec = min(
              max(0.0, cutoff.timeIntervalSince(seg.startUtc)),
              max(0.0, CMTimeGetSeconds(assetDuration) - 0.1)
            )
            trimStart = CMTime(seconds: skipSec, preferredTimescale: 60_000)
          }
          let rangeDuration = CMTimeSubtract(assetDuration, trimStart)
          guard rangeDuration > .zero else { continue }
          let timeRange = CMTimeRange(start: trimStart, duration: rangeDuration)

          try compVideo.insertTimeRange(timeRange, of: srcVideo, at: cursor)

          if let compAudio {
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if let srcAudio = audioTracks.first {
              try? compAudio.insertTimeRange(timeRange, of: srcAudio, at: cursor)
            }
          }
          cursor = CMTimeAdd(cursor, rangeDuration)
        }

        guard cursor > .zero else { return }
        if let compAudio, compAudio.segments.isEmpty {
          composition.removeTrack(compAudio)
        }

        guard let exportSession = AVAssetExportSession(
          asset: composition,
          presetName: AVAssetExportPresetPassthrough
        ) else { return }

        exportSession.outputURL = URL(fileURLWithPath: partialPath)
        exportSession.outputFileType = .mp4
        await exportSession.export()

        if exportSession.status == .completed {
          try? FileManager.default.removeItem(atPath: outputPath)
          try FileManager.default.moveItem(atPath: partialPath, toPath: outputPath)
          succeeded = true
        } else {
          try? FileManager.default.removeItem(atPath: partialPath)
        }
      } catch {
        try? FileManager.default.removeItem(atPath: partialPath)
      }
    }

    _ = sem.wait(timeout: .now() + 30.0)
    return succeeded
  }
}
