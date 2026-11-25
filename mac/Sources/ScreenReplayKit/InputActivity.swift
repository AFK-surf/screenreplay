import AppKit
import CoreGraphics
import Foundation
import GameController

/// Monotonic clock in 100-nanosecond ticks (`hns`), matching Windows `Native.NowHns()`.
public enum MonotonicClock {
  public static func nowHns() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 100)
  }
}

/// Exact port of `recording/InputActivity.cs`: counts input intensity in 10 ms slots over a 3-minute ring
/// and produces 1 byte per 100 ms bucket (`0` = idle, `1...255` = active) for `<stem>.input`.
public final class InputActivity: @unchecked Sendable {
  private static let slotHns: Int64 = 100_000      // 10 ms
  private static let slotsCount: Int = 18_000      // 3 minutes
  private static let bucketHns: Int64 = 1_000_000  // 100 ms
  private static let beforeHns: Int64 = 4_500_000  // 450 ms
  private static let afterHns: Int64 = 5_500_000   // 550 ms

  private let lock = NSLock()
  private var stamp = [Int64](repeating: -1, count: slotsCount)
  private var keys = [Int](repeating: 0, count: slotsCount)
  private var clicks = [Int](repeating: 0, count: slotsCount)
  private var wheel = [Int](repeating: 0, count: slotsCount)
  private var axes = [Int](repeating: 0, count: slotsCount)
  private var last: Int64 = 0

  public init() {}

  public var lastHns: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return last
  }

  private func slotIndex(lagMs: Int, nowHns: Int64 = MonotonicClock.nowHns()) -> Int {
    let hns = max(0, nowHns - Int64(lagMs) * 10_000)
    if hns > last {
      last = hns
    }
    let absSlot = hns / Self.slotHns
    let i = Int(((absSlot % Int64(Self.slotsCount)) + Int64(Self.slotsCount)) % Int64(Self.slotsCount))
    if stamp[i] != absSlot {
      keys[i] = 0
      clicks[i] = 0
      wheel[i] = 0
      axes[i] = 0
      stamp[i] = absSlot
    }
    return i
  }

  public func recordKey(lagMs: Int = 0, nowHns: Int64 = MonotonicClock.nowHns()) {
    lock.lock()
    defer { lock.unlock() }
    keys[slotIndex(lagMs: lagMs, nowHns: nowHns)] += 1
  }

  public func recordPresses(_ n: Int, lagMs: Int = 0, nowHns: Int64 = MonotonicClock.nowHns()) {
    guard n > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    keys[slotIndex(lagMs: lagMs, nowHns: nowHns)] += n
  }

  public func recordClick(_ n: Int = 1, lagMs: Int = 0, nowHns: Int64 = MonotonicClock.nowHns()) {
    guard n > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    clicks[slotIndex(lagMs: lagMs, nowHns: nowHns)] += n
  }

  public func recordWheel(delta: Int, lagMs: Int = 0, nowHns: Int64 = MonotonicClock.nowHns()) {
    guard delta != 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    wheel[slotIndex(lagMs: lagMs, nowHns: nowHns)] += abs(delta)
  }

  public func recordAxes(travel: Double, lagMs: Int = 0, nowHns: Int64 = MonotonicClock.nowHns()) {
    let scaled = Int((travel * 1000.0).rounded())
    guard scaled > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    axes[slotIndex(lagMs: lagMs, nowHns: nowHns)] += scaled
  }

  public func read(startHns: Int64, count: Int, nowHns: Int64 = MonotonicClock.nowHns()) -> Data {
    guard count > 0 else { return Data() }
    lock.lock()
    let nowSlot = nowHns / Self.slotHns
    let first = (startHns - Self.beforeHns) / Self.slotHns
    let lastSlot = (startHns + Int64(count) * Self.bucketHns + Self.afterHns) / Self.slotHns
    let n = max(1, Int(lastSlot - first))

    var sk = [Int64](repeating: 0, count: n + 1)
    var sc = [Int64](repeating: 0, count: n + 1)
    var sw = [Int64](repeating: 0, count: n + 1)
    var sa = [Int64](repeating: 0, count: n + 1)

    for j in 0..<n {
      let absSlot = first + Int64(j)
      let i = Int(((absSlot % Int64(Self.slotsCount)) + Int64(Self.slotsCount)) % Int64(Self.slotsCount))
      var k: Int64 = 0, c: Int64 = 0, w: Int64 = 0, a: Int64 = 0
      if absSlot <= nowSlot && stamp[i] == absSlot {
        k = Int64(keys[i])
        c = Int64(clicks[i])
        w = Int64(wheel[i])
        a = Int64(axes[i])
      }
      sk[j + 1] = sk[j] + k
      sc[j + 1] = sc[j] + c
      sw[j + 1] = sw[j] + w
      sa[j + 1] = sa[j] + a
    }
    lock.unlock()

    var bytes = [UInt8](repeating: 0, count: count)
    for b in 0..<count {
      let at = startHns + Int64(b) * Self.bucketHns
      let from = max(0, min(n - 1, Int((at - Self.beforeHns) / Self.slotHns - first)))
      let rawTo = Int((at + Self.afterHns) / Self.slotHns - first)
      let to = min(n, max(from + 1, rawTo))
      let rawUpTo = Int(nowSlot + 1 - first)
      let upTo = min(to, max(from + 1, rawUpTo))
      let seconds = Double(upTo - from) * (Double(Self.slotHns) / 10_000_000.0)
      bytes[b] = Self.intensity(
        keysPerSecond: Double(sk[upTo] - sk[from]) / seconds,
        clicksPerSecond: Double(sc[upTo] - sc[from]) / seconds,
        notchesPerSecond: Double(sw[upTo] - sw[from]) / 120.0 / seconds,
        axesPerSecond: Double(sa[upTo] - sa[from]) / 1000.0 / seconds
      )
    }
    return Data(bytes)
  }

  public static func intensity(
    keysPerSecond: Double,
    clicksPerSecond: Double,
    notchesPerSecond: Double,
    axesPerSecond: Double = 0
  ) -> UInt8 {
    let presses = keysPerSecond + clicksPerSecond + notchesPerSecond * 0.5
    if presses <= 0 && axesPerSecond <= 0 {
      return 0
    }
    let a = min(1.0, log2(1.0 + max(0, presses)) / log2(13.0))
    let b = min(1.0, log2(1.0 + max(0, axesPerSecond) / 0.25) / log2(81.0))
    let any = 1.0 - (1.0 - a) * (1.0 - b)
    let raw = Int((any * 255.0).rounded())
    return UInt8(min(255, max(1, raw)))
  }
}

/// Passive macOS input activity listener for `<stem>.input`:
/// - `GCController` gamepad button presses & stick/trigger travel (requires zero permissions).
/// - Global mouse click & scroll wheel monitor (requires zero TCC permissions).
/// - Keyboard key-down monitor ONLY when `CGPreflightListenEventAccess()` is already granted,
///   so it NEVER triggers an unsolicited Input Monitoring TCC dialog.
/// - Never attaches to desktop events in `synthetic` mode.
public final class InputActivityMonitor: @unchecked Sendable {
  public let activity: InputActivity
  private let lock = NSLock()
  private var running = false
  private var mouseMonitor: Any?
  private var keyMonitor: Any?
  private var connectObserver: NSObjectProtocol?
  private var disconnectObserver: NSObjectProtocol?
  private var controllerAxes: [ObjectIdentifier: (lx: Float, ly: Float, rx: Float, ry: Float, lt: Float, rt: Float, buttons: UInt32)] = [:]

  public init(activity: InputActivity = InputActivity()) {
    self.activity = activity
  }

  public func start(synthetic: Bool) {
    lock.lock()
    if running {
      lock.unlock()
      return
    }
    running = true
    lock.unlock()

    guard !synthetic else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.installMonitorsOnMain()
    }
  }

  public func stop() {
    lock.lock()
    if !running {
      lock.unlock()
      return
    }
    running = false
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let m = self.mouseMonitor { NSEvent.removeMonitor(m); self.mouseMonitor = nil }
      if let k = self.keyMonitor { NSEvent.removeMonitor(k); self.keyMonitor = nil }
      if let c = self.connectObserver { NotificationCenter.default.removeObserver(c); self.connectObserver = nil }
      if let d = self.disconnectObserver { NotificationCenter.default.removeObserver(d); self.disconnectObserver = nil }
      self.controllerAxes.removeAll()
    }
  }

  private func installMonitorsOnMain() {
    lock.lock()
    let stillRunning = running
    lock.unlock()
    guard stillRunning else { return }

    if mouseMonitor == nil {
      mouseMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
      ) { [weak self] event in
        guard let self else { return }
        if event.type == .scrollWheel {
          let dy = Int((abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX)) * (event.hasPreciseScrollingDeltas ? 4.0 : 120.0))
          if dy > 0 { self.activity.recordWheel(delta: dy) }
        } else {
          self.activity.recordClick(1)
        }
      }
    }

    // NEVER request Input Monitoring; only listen to keyDown if the user has already granted it.
    if keyMonitor == nil && CGPreflightListenEventAccess() {
      keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        guard let self, !event.isARepeat else { return }
        self.activity.recordKey()
      }
    }

    for controller in GCController.controllers() {
      attachController(controller)
    }
    connectObserver = NotificationCenter.default.addObserver(
      forName: .GCControllerDidConnect, object: nil, queue: .main
    ) { [weak self] note in
      if let c = note.object as? GCController {
        self?.attachController(c)
      }
    }
    disconnectObserver = NotificationCenter.default.addObserver(
      forName: .GCControllerDidDisconnect, object: nil, queue: .main
    ) { [weak self] note in
      if let c = note.object as? GCController {
        self?.controllerAxes.removeValue(forKey: ObjectIdentifier(c))
      }
    }
  }

  private func attachController(_ controller: GCController) {
    guard let pad = controller.extendedGamepad else { return }
    let id = ObjectIdentifier(controller)
    controllerAxes[id] = (0, 0, 0, 0, 0, 0, 0)
    pad.valueChangedHandler = { [weak self] (gamepad: GCExtendedGamepad, _: GCControllerElement) in
      guard let self else { return }
      let prev = self.controllerAxes[id] ?? (0, 0, 0, 0, 0, 0, 0)
      var btnMask: UInt32 = 0
      let buttons: [GCControllerButtonInput] = [
        gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
        gamepad.leftShoulder, gamepad.rightShoulder,
        gamepad.dpad.up, gamepad.dpad.down, gamepad.dpad.left, gamepad.dpad.right,
      ]
      for (idx, b) in buttons.enumerated() where b.isPressed {
        btnMask |= (1 << idx)
      }
      let newlyPressed = (btnMask & ~prev.buttons).nonzeroBitCount
      if newlyPressed > 0 {
        self.activity.recordPresses(newlyPressed)
      }
      let lx = gamepad.leftThumbstick.xAxis.value
      let ly = gamepad.leftThumbstick.yAxis.value
      let rx = gamepad.rightThumbstick.xAxis.value
      let ry = gamepad.rightThumbstick.yAxis.value
      let lt = gamepad.leftTrigger.value
      let rt = gamepad.rightTrigger.value
      // (summed a term at a time: as one expression, Swift 6.2 gave up type-checking it on CI's runner)
      var sticks: Float = abs(lx - prev.lx)
      sticks += abs(ly - prev.ly)
      sticks += abs(rx - prev.rx)
      sticks += abs(ry - prev.ry)
      var triggers: Float = abs(lt - prev.lt)
      triggers += abs(rt - prev.rt)
      let travel = Double(sticks * 0.5 + triggers)
      if travel >= 0.01 {
        self.activity.recordAxes(travel: travel)
      }
      self.controllerAxes[id] = (lx, ly, rx, ry, lt, rt, btnMask)
    }
  }
}
