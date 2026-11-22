import AppKit
import AVFoundation
import Combine
import PermissionFlow
import ScreenCaptureKit
import SwiftUI

public enum HelperGrant: String, CaseIterable, Identifiable {
  case screenRecording = "capture"
  case microphone = "microphone"
  case inputMonitoring = "inputMonitoring"

  public var id: String { rawValue }

  public var pane: PermissionFlowPane? {
    switch self {
    case .screenRecording: return .screenRecording
    case .microphone, .inputMonitoring: return nil
    }
  }

  public var symbol: String {
    switch self {
    case .screenRecording: return "rectangle.dashed.badge.record"
    case .microphone: return "mic.fill"
    case .inputMonitoring: return "keyboard"
    }
  }
}

@MainActor
public final class HelperPermissions {
  public static let shared = HelperPermissions()

  private var windowController: NSWindowController?
  private let model = HelperPermissionsModel()
  private var flow: PermissionFlowController?
  private weak var daemon: HelperDaemon?
  private let delegate = PermissionsWindowDelegate()
  private var previousApp: NSRunningApplication?
  private var didRequestNativeCapture = false

  public var isShown: Bool { windowController != nil }
  public var asked: [String] { model.asked.map(\.rawValue) }

  private func triggerNativeScreenCaptureRegistration() {
    guard !didRequestNativeCapture else { return }
    didRequestNativeCapture = true
    DispatchQueue.global(qos: .userInitiated).async {
      _ = CGRequestScreenCaptureAccess()
      Task.detached {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      }
    }
  }

  public func show(words: [String: Any], grants: [String], daemon: HelperDaemon) {
    self.daemon = daemon
    let requested = grants.compactMap(HelperGrant.init(rawValue:))
    let effective = requested.isEmpty ? [.screenRecording] : requested
    model.asked = windowController == nil ? effective : model.asked + effective.filter { !model.asked.contains($0) }
    model.words.merge(words.compactMapValues { $0 as? String }) { _, new in new }
    if let panel = words["panel"] as? [String: String] {
      PermissionFlowLocalizer.words = panel
    }

    let flow = self.flow ?? PermissionFlow.makeController(configuration: .init(promptForAccessibilityTrust: false))
    self.flow = flow

    model.onRowsChanged = { [weak daemon] rows in
      flow.guidanceSteps = rows.compactMap { row in row.grant.pane.map { (pane: $0, granted: row.granted) } }
      let captureGranted = rows.first(where: { $0.grant == .screenRecording })?.granted ?? false
      daemon?.notify(["event": "grants", "capture": captureGranted])
      // Immediately close and trigger silent takeover restart as soon as Screen Recording flips from false -> true!
      if captureGranted && daemon?.startedGrants.capture == false {
        Task { @MainActor [weak self] in
          try? await Task.sleep(nanoseconds: 600_000_000)
          self?.windowController?.window?.performClose(nil)
        }
      }
    }

    model.onAuthorize = { [weak self] grant in
      switch grant {
      case .screenRecording:
        self?.windowController?.window?.level = .normal
        self?.triggerNativeScreenCaptureRegistration()
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
          if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
          }
          NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        } else {
          flow.resetDroppedApps()
          flow.authorize(pane: .screenRecording, suggestedAppURLs: [Bundle.main.bundleURL])
        }
      case .microphone:
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(url)
        }
      case .inputMonitoring:
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
          NSWorkspace.shared.open(url)
        }
      }
    }

    model.onAllGranted = { [weak self] in
      self?.windowController?.window?.performClose(nil)
    }

    if let window = windowController?.window {
      model.startPolling()
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }

    previousApp = NSWorkspace.shared.frontmostApplication
    let host = NSHostingController(
      rootView: HelperPermissionsView(
        model: model,
        onClose: { [weak self] in self?.windowController?.window?.performClose(nil) }
      )
    )
    let window = NSWindow(contentViewController: host)
    window.title = model.word("title", "ScreenReplay Permissions")
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.center()
    delegate.onClose = { [weak self] in self?.handleClosed() }
    window.delegate = delegate

    let controller = NSWindowController(window: window)
    windowController = controller
    _ = NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    model.startPolling()

    if effective.contains(.screenRecording) && !Status.captureAllowed() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        self?.triggerNativeScreenCaptureRegistration()
      }
    }
  }

  private func handleClosed() {
    model.stopPolling()
    windowController = nil
    flow?.closePanel(returnToPreviousApp: false)
    previousApp?.activate(options: [.activateIgnoringOtherApps])
    previousApp = nil
    DispatchQueue.main.async { _ = NSApp.setActivationPolicy(.accessory) }
    daemon?.notify(["event": "grants"])
    let daemonRef = daemon
    DispatchQueue.global(qos: .userInitiated).async {
      if daemonRef?.grantedCaptureSinceStart() == true {
        DispatchQueue.main.async {
          daemonRef?.restart(autoResumeRecording: true)
        }
      }
    }
  }
}

private final class PermissionsWindowDelegate: NSObject, NSWindowDelegate {
  var onClose: (() -> Void)?
  func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}

@MainActor
final class HelperPermissionsModel: ObservableObject {
  struct Row: Identifiable, Equatable {
    let grant: HelperGrant
    let granted: Bool
    var id: String { grant.rawValue }
  }

  @Published var rows: [Row] = []
  @Published var words: [String: String] = [:]
  var asked: [HelperGrant] = [] {
    didSet {
      rows = asked.map { g in Row(grant: g, granted: rows.first(where: { $0.grant == g })?.granted ?? false) }
    }
  }

  var onAuthorize: ((HelperGrant) -> Void)?
  var onRowsChanged: (([Row]) -> Void)?
  var onAllGranted: (() -> Void)?

  private var timer: Timer?
  private var pollingInFlight = false
  private var closingTask: Task<Void, Never>?

  func word(_ key: String, _ fallback: String) -> String {
    words[key] ?? fallback
  }

  var allGranted: Bool { !rows.isEmpty && rows.allSatisfy(\.granted) }

  func authorize(_ grant: HelperGrant) {
    onAuthorize?(grant)
  }

  func startPolling() {
    refresh()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func stopPolling() {
    timer?.invalidate()
    timer = nil
    closingTask?.cancel()
    closingTask = nil
  }

  func refresh() {
    guard !pollingInFlight else { return }
    pollingInFlight = true
    DispatchQueue.global(qos: .userInitiated).async {
      let fresh = Status.fresh() ?? Status.now()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pollingInFlight = false
        let next = self.asked.map { grant -> Row in
          let ok = (fresh[grant.rawValue] as? Bool) ?? false
          return Row(grant: grant, granted: ok)
        }
        if next != self.rows {
          self.rows = next
          self.onRowsChanged?(next)
        }
        self.scheduleCloseIfComplete()
      }
    }
  }

  private func scheduleCloseIfComplete() {
    guard allGranted else {
      closingTask?.cancel()
      closingTask = nil
      return
    }
    guard closingTask == nil else { return }
    closingTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard let self, !Task.isCancelled, self.allGranted else { return }
      self.onAllGranted?()
    }
  }
}

struct HelperPermissionsView: View {
  @ObservedObject var model: HelperPermissionsModel
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        .resizable()
        .interpolation(.high)
        .frame(width: 68, height: 68)
        .padding(.top, 8)
      VStack(spacing: 6) {
        Text(model.word("title", "开启 ScreenReplay 屏幕录制权限"))
          .font(.system(size: 19, weight: .bold, design: .rounded))
        Text(model.word("subtitle", "ScreenReplay Helper 负责在后台滚动录制屏幕与系统声音，录像仅保存在本机。"))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 440)
      }
      VStack(spacing: 10) {
        ForEach(model.rows) { row in
          HelperPermissionRowView(row: row, model: model) {
            model.authorize(row.grant)
          }
        }
      }
      if model.allGranted {
        Label(model.word("done", "权限已就绪，正在自动开始后台录制"), systemImage: "checkmark.circle.fill")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.green)
      }
    }
    .onExitCommand(perform: onClose)
    .padding(26)
    .frame(width: 500)
  }
}

private struct HelperPermissionRowView: View {
  let row: HelperPermissionsModel.Row
  @ObservedObject var model: HelperPermissionsModel
  let onAllow: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  private var defaultTitle: String {
    switch row.grant {
    case .screenRecording: return "屏幕与系统音频录制"
    case .microphone: return "麦克风（可选）"
    case .inputMonitoring: return "输入活动统计（可选）"
    }
  }

  private var defaultSubtitle: String {
    switch row.grant {
    case .screenRecording:
      if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
        return "在系统设置点列表左下角「+」，把 Finder 里的 ScreenReplay Helper 拖进弹出框点「打开」"
      }
      return "点「允许」把浮窗卡片拖入系统设置列表（或点「Finder」从 Finder 拖入）"
    case .microphone: return "开启「录制麦克风」时混入语音"
    case .inputMonitoring: return "在时间线上显示按键活跃度热力条（仅计次数，不记键名）"
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: row.grant.symbol)
        .font(.system(size: 21))
        .frame(width: 36, height: 36)
        .opacity(row.granted ? 0.7 : 1.0)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.word(row.grant.rawValue, defaultTitle))
          .font(.system(size: 14, weight: .semibold))
        Text(model.word("\(row.grant.rawValue)Why", defaultSubtitle))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if row.granted {
        Image(systemName: "checkmark")
          .foregroundStyle(.green)
          .font(.system(size: 14, weight: .semibold))
      } else {
        if row.grant == .screenRecording {
          Button("Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
          }
          .buttonStyle(.borderless)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
        }
        Button(model.word("allow", "允许"), action: onAllow)
          .buttonStyle(.borderless)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 7)
          .background(Capsule(style: .continuous).fill(Color.accentColor))
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(colorScheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.94))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08), lineWidth: 1)
    )
  }
}
