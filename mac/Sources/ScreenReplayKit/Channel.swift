import Darwin
import Foundation

/// Constant-time string comparison for socket authentication tokens.
public func constantTimeSame(_ a: String, _ b: String) -> Bool {
  let x = Array(a.utf8)
  let y = Array(b.utf8)
  guard x.count == y.count else { return false }
  var differ: UInt8 = 0
  for i in 0..<x.count {
    differ |= x[i] ^ y[i]
  }
  return differ == 0
}

public struct HelperError: Error, CustomStringConvertible, Sendable {
  public let description: String
  public let code: String?

  public init(_ description: String, code: String? = nil) {
    self.description = description
    self.code = code
  }
}

/// Unix domain socket JSON-lines & framed channel (modeled after `StillfailHelper/Channel.swift`).
public final class Channel: @unchecked Sendable {
  public let fd: Int32
  private let lock = NSLock()
  public private(set) var broken = false

  public init(fd: Int32) {
    self.fd = fd
  }

  public func write(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    if broken { return }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.baseAddress else { return }
      var at = 0
      while at < raw.count {
        let n = Darwin.write(fd, base + at, raw.count - at)
        if n < 0 {
          if errno == EINTR { continue }
          broken = true
          return
        }
        at += n
      }
    }
  }

  public func send(_ kind: UInt8, _ payload: Data) {
    var head = Data([kind])
    var n = UInt32(payload.count).bigEndian
    head.append(Data(bytes: &n, count: 4))
    write(head + payload)
  }

  public func sendJSON(_ kind: UInt8, _ value: [String: Any]) {
    send(kind, Channel.json(value))
  }

  public func line(_ value: [String: Any]) {
    write(Channel.json(value) + Data("\n".utf8))
  }

  public static func json(_ value: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
  }

  public func read(_ n: Int) -> Data? {
    if n == 0 { return Data() }
    var data = Data(count: n)
    var at = 0
    while at < n {
      let got = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        Darwin.read(fd, raw.baseAddress! + at, n - at)
      }
      if got < 0 && errno == EINTR { continue }
      if got <= 0 { return nil }
      at += got
    }
    return data
  }

  public func readLine(limit: Int = 1 << 20) -> Data? {
    var line = Data()
    var byte: UInt8 = 0
    while line.count <= limit {
      let got = Darwin.read(fd, &byte, 1)
      if got < 0 && errno == EINTR { continue }
      if got <= 0 { return line.isEmpty ? nil : line }
      if byte == 10 { return line }
      line.append(byte)
    }
    return nil
  }

  public func closeFD() {
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }
}

public enum UnixSocketClient {
  public static func dial(_ socketPath: String, timeoutMs: Int = 5000) throws -> Int32 {
    guard socketPath.utf8CString.count <= 104 else {
      throw HelperError("socket path exceeds 104 bytes: \(socketPath)")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw HelperError("socket() failed: \(String(cString: strerror(errno)))")
    }
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    if timeoutMs > 0 {
      var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
      _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
      bytes.withUnsafeBufferPointer { buf in
        UnsafeMutableRawPointer(ptr).copyMemory(from: buf.baseAddress!, byteCount: buf.count)
      }
    }
    let rc = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else {
      let why = String(cString: strerror(errno))
      close(fd)
      throw HelperError("connect(\(socketPath)) failed: \(why)")
    }
    return fd
  }

  /// Sends a single JSON-line request `{op, token, ...}` and reads its single-line JSON reply.
  public static func request(
    socketPath: String,
    token: String,
    op: String,
    fields: [String: Any] = [:],
    timeoutMs: Int = 10000
  ) throws -> [String: Any] {
    let fd = try dial(socketPath, timeoutMs: timeoutMs)
    defer { close(fd) }
    let channel = Channel(fd: fd)
    var payload = fields
    payload["op"] = op
    payload["token"] = token
    channel.line(payload)
    guard let replyData = channel.readLine(),
          let reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any]
    else {
      throw HelperError("Helper closed connection without valid JSON reply for op=\(op)")
    }
    if let err = reply["error"] as? String {
      throw HelperError(err, code: reply["code"] as? String)
    }
    return reply
  }
}
