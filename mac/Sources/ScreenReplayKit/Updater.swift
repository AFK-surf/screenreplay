import AppKit
import CryptoKit
import Foundation
import Security

public final class Updater: @unchecked Sendable {
  public static let appVersion: String = {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return isPlainVersion(v) ? v : "0.1.27"
  }()

  /// The Team ID of "Developer ID Application: AFK AI, Inc. (D9AAN3VJK8)", what scripts/sign-mac.sh signs with.
  static let team = "D9AAN3VJK8"
  static let zipName = "ScreenReplay-mac.zip"

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
  private var askedByUser = false
  private var downloadedFile = ""
  private var readyAt = Date.distantPast
  private var readyNoted = false
  private var progressWatch: NSKeyValueObservation?

  public var isReplayShown: () -> Bool = { false }
  public var beforeQuit: () -> Void = {}
  public var notify: (String, String) -> Void = { _, _ in }

  public init(paths: RecorderPaths, logger: RecorderLogger? = nil, headlessTest: Bool = false) {
    self.paths = paths
    self.logger = logger
    self.installKind = headlessTest ? 0 : Self.detectInstallKind()
    readPersistedChecked()
    writeState()
    if CommandLine.arguments.contains("--updated") {
      logger?.log("update: now \(Self.appVersion)")
    }
  }

  static func testMode(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    !(env["REPLAY_TEST_UPDATE"] ?? "").isEmpty
  }

  static func updateNowTest(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    testMode(env) && !(env["REPLAY_TEST_UPDATE_NOW"] ?? "").isEmpty
  }

  public static func detectInstallKind() -> Int {
    let bundlePath = Bundle.main.bundlePath
    guard bundlePath.hasSuffix(".app") else { return 0 }
    if testMode() { return 1 }
    let inApplications = bundlePath.hasPrefix("/Applications/") ||
      bundlePath.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/")
    return inApplications && selfSignedByUs() ? 1 : 0
  }

  static func signerRequirement() -> SecRequirement? {
    let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
      + "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
    var req: SecRequirement?
    return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess ? req : nil
  }

  static func selfSignedByUs() -> Bool {
    var me: SecCode?
    guard let req = signerRequirement(), SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
    return SecCodeCheckValidity(me, [], req) == errSecSuccess
  }

  static func signedByUs(_ path: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    let anySigner = testMode(env) && !(env["REPLAY_TEST_ANY_SIGNER"] ?? "").isEmpty
    let req = anySigner ? nil : signerRequirement()
    if !anySigner && req == nil { return false }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
      return false
    }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
  }

  public static func downloadBase(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let testFlag = env["REPLAY_TEST_UPDATE"], !testFlag.isEmpty,
       let custom = env["REPLAY_UPDATE_URL"], !custom.isEmpty
    {
      return custom.hasSuffix("/") ? custom : (custom + "/")
    }
    return "https://screenreplay.pages.dev/dl/"
  }

  public static func idleSeconds() -> Double {
    let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    return s.isFinite && s >= 0 ? s : 0
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
        lock.lock()
        let st = state
        let hand = byHand
        lock.unlock()
        if st == "ready" {
          installNow()
        } else if st == "found" && !hand {
          lock.lock()
          askedByUser = true
          lock.unlock()
          download()
        } else if st == "fetching" {
          lock.lock()
          askedByUser = true
          lock.unlock()
        } else if !headlessTest, let url = URL(string: "https://screenreplay.pages.dev") {
          NSWorkspace.shared.open(url)
        }
        return
      }
    }

    lock.lock()
    let readyAsked = state == "ready" && askedByUser && !busy
    lock.unlock()
    if readyAsked {
      installNow()
      return
    }

    let nowTest = Self.updateNowTest()
    guard !headlessTest, installKind == 1, autoUpdateEnabled || nowTest, startedOverMinuteAgo || nowTest else { return }
    lock.lock()
    let isBusy = busy
    let checked = lastCheckedEpoch
    let tried = lastTried
    let st = state
    let hand = byHand
    lock.unlock()
    guard !isBusy else { return }
    if st == "ready" {
      tryInstallWhenIdle()
      return
    }
    if st == "found" && !hand {
      lock.lock()
      askedByUser = false
      lock.unlock()
      download()
      return
    }
    if st == "installing" { return }

    let nowEpoch = Int64(Date().timeIntervalSince1970)
    let due = nowTest
      ? tried == Date.distantPast
      : (nowEpoch - checked >= 86_400 || checked > nowEpoch + 60) && Date().timeIntervalSince(tried) >= 3600
    if due {
      checkNow(userAsked: false)
    }
  }

  public func checkNow(userAsked: Bool = true) {
    lock.lock()
    if busy || state == "ready" || state == "installing" {
      lock.unlock()
      return
    }
    busy = true
    askedByUser = userAsked
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
        self.busy = false
        self.lock.unlock()
        self.logger?.log("update: \(Self.appVersion) is up to date")
        self.writeState()
        return
      }

      let sha = ((obj["mac_sha256"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let sig = ((obj["mac_signature"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let signedOK = Self.isPlainSHA256(sha) && Self.verifyReleaseSignature(
        version: ver, sha256Hex: sha, signatureHex: sig, publicKeyRawOverride: Self.testReleaseKey())

      self.lock.lock()
      self.lastCheckedEpoch = nowEpoch
      self.foundVersion = ver
      self.foundSha = sha
      self.byHand = self.installKind != 1 || !signedOK
      self.state = "found"
      self.percent = -1
      self.busy = false
      let hand = self.byHand
      self.lock.unlock()
      self.logger?.log("update: found \(ver) (signed=\(signedOK), installKind=\(self.installKind), userAsked=\(userAsked))")
      self.writeState()
      if !userAsked && !hand {
        self.download()
      }
    }.resume()
  }

  static func testReleaseKey() -> Data? {
    let env = ProcessInfo.processInfo.environment
    guard testMode(env), let hex = env["REPLAY_TEST_RELEASE_KEY"], !hex.isEmpty else { return nil }
    return Data(hexString: hex)
  }

  private func updatesDir() -> String {
    let dir = (paths.root as NSString).appendingPathComponent("updates")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  private func download() {
    lock.lock()
    if busy || foundVersion.isEmpty || byHand {
      lock.unlock()
      return
    }
    busy = true
    let ver = foundVersion
    let want = foundSha
    state = "fetching"
    percent = -1
    errorCode = ""
    lock.unlock()
    writeState()

    let urlString = Self.downloadBase() + "v\(ver)/\(Self.zipName)"
    guard let url = URL(string: urlString), Self.isURLAllowed(url) else {
      fail("bad_url")
      return
    }
    logger?.log("update: downloading \(urlString)")
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    req.setValue("ScreenReplay/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
    let dest = (updatesDir() as NSString).appendingPathComponent(Self.zipName)
    let task = URLSession.shared.downloadTask(with: req) { [weak self] tmp, response, error in
      guard let self else { return }
      self.lock.lock()
      self.progressWatch = nil
      self.lock.unlock()
      if let error {
        self.logger?.log("update: download failed: \(error.localizedDescription)")
        self.fail("download_network")
        return
      }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, let tmp else {
        self.fail("download_http")
        return
      }
      let got = Self.sha256(ofFile: tmp.path) ?? ""
      guard got == want else {
        self.logger?.log("update: checksum mismatch for \(ver) (got \(got), expected \(want))")
        self.fail("checksum")
        return
      }
      try? FileManager.default.removeItem(atPath: dest)
      do {
        try FileManager.default.moveItem(atPath: tmp.path, toPath: dest)
      } catch {
        self.fail("download_network")
        return
      }
      self.lock.lock()
      self.downloadedFile = dest
      self.readyAt = Date()
      self.readyNoted = false
      self.state = "ready"
      self.percent = 100
      self.busy = false
      self.lock.unlock()
      // (installed from poll, on the host's queue, where the replay window and the helper are)
      self.logger?.log("update: \(ver) verified and ready at \(dest)")
      self.writeState()
    }
    let watch = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
      guard let self else { return }
      let pct = Int(p.fractionCompleted * 100)
      self.lock.lock()
      let changed = self.state == "fetching" && pct != self.percent
      if changed { self.percent = pct }
      self.lock.unlock()
      if changed { self.writeState() }
    }
    lock.lock()
    progressWatch = watch
    lock.unlock()
    task.resume()
  }

  private func tryInstallWhenIdle() {
    lock.lock()
    let st = state
    let ver = foundVersion
    let since = readyAt
    let noted = readyNoted
    lock.unlock()
    guard st == "ready" else { return }
    if !isReplayShown() && (Self.updateNowTest() || Self.idleSeconds() >= 120) {
      installNow()
      return
    }
    if !noted && Date().timeIntervalSince(since) >= 86_400 {
      lock.lock()
      readyNoted = true
      lock.unlock()
      notify("ScreenReplay \(ver)", "空闲时将自动更新，也可在「设置 › 关于」中立即重启更新。")
    }
  }

  private func installNow() {
    lock.lock()
    if busy || state != "ready" {
      lock.unlock()
      return
    }
    busy = true
    let zip = downloadedFile
    let want = foundSha
    let ver = foundVersion
    state = "installing"
    errorCode = ""
    lock.unlock()
    writeState()

    let fm = FileManager.default
    let app = Bundle.main.bundlePath
    guard Self.sha256(ofFile: zip) == want else {
      try? fm.removeItem(atPath: zip)
      logger?.log("update: \(ver) is not the file signed")
      fail("checksum")
      return
    }
    // (opened next to the app installed: the same volume, so each move below is a rename)
    let staging = ((app as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".ScreenReplay-update")
    let fresh = (staging as NSString).appendingPathComponent("ScreenReplay.app")
    let old = (staging as NSString).appendingPathComponent("ScreenReplay-old.app")
    try? fm.removeItem(atPath: staging)
    guard (try? fm.createDirectory(atPath: staging, withIntermediateDirectories: false)) != nil,
          Self.run("/usr/bin/ditto", ["-x", "-k", zip, staging]) == 0, fm.fileExists(atPath: fresh)
    else {
      try? fm.removeItem(atPath: staging)
      logger?.log("update: could not open \(zip) next to \(app)")
      fail("install_failed")
      return
    }
    let idNow = Bundle.main.bundleIdentifier
    let idFresh = Bundle(path: fresh)?.bundleIdentifier
    guard Self.signedByUs(fresh), idFresh != nil, idNow == nil || idNow == idFresh else {
      try? fm.removeItem(atPath: staging)
      try? fm.removeItem(atPath: zip)
      logger?.log("update: \(ver)'s app is not signed by \(Self.team)")
      fail("checksum")
      return
    }
    logger?.log("update: installing \(ver)")
    beforeQuit()
    guard rename(app, old) == 0 else {
      try? fm.removeItem(atPath: staging)
      logger?.log("update: could not move \(app) aside")
      relaunch(app: app, staging: nil)
      return
    }
    guard rename(fresh, app) == 0 else {
      _ = rename(old, app)
      try? fm.removeItem(atPath: staging)
      logger?.log("update: could not put \(ver) in place")
      relaunch(app: app, staging: nil)
      return
    }
    try? fm.removeItem(atPath: zip)
    relaunch(app: app, staging: staging)
  }

  /// The app at `app` started once this run has ended (before, it would find this run's lock and end), with --updated;
  /// then this run ends.
  private func relaunch(app: String, staging: String?) -> Never {
    let test = Self.testMode()
    let start = test
      ? "exec \"$2/Contents/MacOS/ScreenReplay\" --updated"
      : "/usr/bin/open -n \"$2\" --args --updated"
    let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; [ -n \"$3\" ] && rm -rf \"$3\"; " + start
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "screenreplay-update", String(getpid()), app, staging ?? ""]
    try? p.run()
    exit(0)
  }

  static func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }

  static func sha256(ofFile path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while true {
      let chunk = autoreleasepool { (try? h.read(upToCount: 1 << 20)) ?? Data() }
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
