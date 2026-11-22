import AppKit
import CryptoKit
import Foundation

/// ECDSA P-256 release verification and `update.json` state manager matching `recorder/Updater.cs` and `app/about.mbt`.
public final class Updater: @unchecked Sendable {
  public static let appVersion = "0.1.22"

  // ECDSA P-256 public key matching `recorder/Updater.cs` (`ScreenReplay 更新签名私钥（ECDSA P-256）`).
  private static let keyX: [UInt8] = [
    0x56, 0x1b, 0xf9, 0xf1, 0xa6, 0x07, 0xe6, 0x9f, 0x9b, 0x2a, 0x7d, 0x0a, 0x9b, 0x0c, 0xc9, 0x86,
    0x7d, 0xfc, 0xa4, 0xec, 0xe2, 0x7c, 0x05, 0x43, 0x38, 0x7f, 0xc5, 0xc1, 0x3f, 0x78, 0xa7, 0xc8,
  ]
  private static let keyY: [UInt8] = [
    0x77, 0xec, 0x9f, 0x82, 0x82, 0x1b, 0xe5, 0xbf, 0x7e, 0xa9, 0xdb, 0x27, 0x83, 0x50, 0x6c, 0xae,
    0xba, 0x23, 0xdb, 0xf4, 0x59, 0xb9, 0x6f, 0xf8, 0x3a, 0x5c, 0xac, 0xc0, 0x4d, 0x02, 0x0e, 0xbf,
  ]

  private let paths: RecorderPaths
  private let logger: RecorderLogger?
  private let installKind: Int
  private let lock = NSLock()

  private var state = "unasked"
  private var foundVersion = ""
  private var foundSha = ""
  private var byHand = false
  private var percent = -1
  private var errorCode = ""
  private var lastCheckedEpoch: Int64 = 0
  private var lastTried = Date.distantPast
  private var busy = false

  public init(paths: RecorderPaths, logger: RecorderLogger? = nil, headlessTest: Bool = false) {
    self.paths = paths
    self.logger = logger
    self.installKind = headlessTest ? 0 : Self.detectInstallKind()
    readPersistedChecked()
    writeState()
  }

  public static func detectInstallKind() -> Int {
    let bundlePath = Bundle.main.bundlePath
    if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications")) {
      return 1
    }
    return 0
  }

  public static func downloadBase(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let testFlag = env["REPLAY_TEST_UPDATE"], !testFlag.isEmpty,
       let custom = env["REPLAY_UPDATE_URL"], !custom.isEmpty
    {
      return custom.hasSuffix("/") ? custom : (custom + "/")
    }
    return "https://screenreplay.pages.dev/dl/"
  }

  public func poll(autoUpdateEnabled: Bool, startedOverMinuteAgo: Bool, headlessTest: Bool = false) {
    let reqPath = paths.requestPath("update.request")
    if FileManager.default.fileExists(atPath: reqPath) {
      let req = ((try? String(contentsOfFile: reqPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      try? FileManager.default.removeItem(atPath: reqPath)
      if req == "check" {
        checkNow(userAsked: true)
        return
      } else if req == "update" {
        if !headlessTest, let url = URL(string: "https://screenreplay.pages.dev") {
          NSWorkspace.shared.open(url)
        }
        return
      }
    }

    guard !headlessTest, installKind == 1, autoUpdateEnabled, startedOverMinuteAgo else { return }
    let nowEpoch = Int64(Date().timeIntervalSince1970)
    lock.lock()
    let isBusy = busy
    let checked = lastCheckedEpoch
    let tried = lastTried
    lock.unlock()
    guard !isBusy else { return }

    if (nowEpoch - checked >= 86_400 || checked > nowEpoch + 60) && Date().timeIntervalSince(tried) >= 3600 {
      checkNow(userAsked: false)
    }
  }

  public func checkNow(userAsked: Bool = true) {
    lock.lock()
    if busy {
      lock.unlock()
      return
    }
    busy = true
    lastTried = Date()
    state = "checking"
    errorCode = ""
    lock.unlock()
    writeState()

    let urlString = Self.downloadBase() + "latest.json"
    guard let url = URL(string: urlString), Self.isURLAllowed(url) else {
      fail("bad_url")
      return
    }

    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.setValue("ScreenReplay/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
      guard let self else { return }
      defer {
        self.lock.lock()
        self.busy = false
        self.lock.unlock()
      }
      if let error {
        self.logger?.log("update: check failed: \(error.localizedDescription)")
        self.fail("network")
        return
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
        self.fail("http")
        return
      }
      guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        self.fail("bad_manifest")
        return
      }

      let ver = ((obj["version"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard Self.isPlainVersion(ver) else {
        self.fail("bad_manifest")
        return
      }

      let nowEpoch = Int64(Date().timeIntervalSince1970)
      if !Self.isNewer(candidate: ver, current: Self.appVersion) {
        self.lock.lock()
        self.lastCheckedEpoch = nowEpoch
        self.state = "latest"
        self.foundVersion = ""
        self.lock.unlock()
        self.writeState()
        return
      }

      let sha = ((obj["mac_sha256"] as? String) ?? (obj["setup_sha256"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let sig = ((obj["mac_signature"] as? String) ?? (obj["signature"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let signedOK = Self.isPlainSHA256(sha) && Self.verifyReleaseSignature(version: ver, sha256Hex: sha, signatureHex: sig)

      self.lock.lock()
      self.lastCheckedEpoch = nowEpoch
      self.foundVersion = ver
      self.foundSha = sha
      self.byHand = true // macOS opens DMG / release download when user clicks update
      self.state = "found"
      self.percent = -1
      self.lock.unlock()
      self.logger?.log("update: found \(ver) (signed=\(signedOK), userAsked=\(userAsked))")
      self.writeState()
    }.resume()
  }

  private func fail(_ code: String) {
    lock.lock()
    state = "failed"
    errorCode = code
    percent = -1
    busy = false
    lock.unlock()
    writeState()
  }

  private func readPersistedChecked() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.updatePath)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let checked = (obj["checked"] as? NSNumber)?.int64Value
    else { return }
    lastCheckedEpoch = checked
  }

  private func writeState() {
    lock.lock()
    let obj: [String: Any] = [
      "installKind": installKind,
      "state": state,
      "version": foundVersion,
      "byHand": byHand,
      "percent": percent,
      "error": errorCode,
      "checked": lastCheckedEpoch,
    ]
    lock.unlock()
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
      AtomicFile.writeWhole(path: paths.updatePath, data: data)
    }
  }

  // MARK: - Pure Verification Helpers

  public static func isURLAllowed(_ url: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    let scheme = url.scheme?.lowercased()
    if scheme == "https" { return true }
    if let test = env["REPLAY_TEST_UPDATE"], !test.isEmpty, scheme == "http", url.host == "127.0.0.1" {
      return true
    }
    return false
  }

  public static func isPlainVersion(_ v: String) -> Bool {
    let parts = v.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...4).contains(parts.count) else { return false }
    for p in parts {
      guard (1...9).contains(p.count) else { return false }
      for c in p where !("0"..."9").contains(c) {
        return false
      }
    }
    return true
  }

  public static func isPlainSHA256(_ hex: String) -> Bool {
    guard hex.count == 64 else { return false }
    for c in hex.lowercased() {
      if !(("0"..."9").contains(c) || ("a"..."f").contains(c)) { return false }
    }
    return true
  }

  public static func isNewer(candidate: String, current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    let n = max(a.count, b.count)
    for i in 0..<n {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  public static func verifyReleaseSignature(
    version: String,
    sha256Hex: String,
    signatureHex: String,
    publicKeyRawOverride: Data? = nil
  ) -> Bool {
    guard signatureHex.count == 128, let sigBytes = Data(hexString: signatureHex) else { return false }
    let rawPubKey = publicKeyRawOverride ?? Data(keyX + keyY)
    guard let pubKey = try? P256.Signing.PublicKey(rawRepresentation: rawPubKey),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
    else { return false }
    let message = Data("screenreplay-update\n\(version)\n\(sha256Hex.lowercased())\n".utf8)
    return pubKey.isValidSignature(signature, for: message)
  }
}

extension Data {
  init?(hexString: String) {
    let chars = Array(hexString.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(chars.count / 2)
    func nibble(_ b: UInt8) -> UInt8? {
      switch b {
      case 0x30...0x39: return b - 0x30
      case 0x41...0x46: return b - 0x41 + 10
      case 0x61...0x66: return b - 0x61 + 10
      default: return nil
      }
    }
    var i = 0
    while i < chars.count {
      guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
      bytes.append((hi << 4) | lo)
      i += 2
    }
    self = Data(bytes)
  }
}
