import Foundation

/// A global shortcut as settings.json keeps it ("Ctrl+Alt+R", "" for none): the names the viewer's shortcut field
/// writes (native/replay_mac.mm rp_hotkey_take), read as Carbon modifiers and a virtual key code.
public struct HotkeySpec: Equatable {
  public let carbonModifiers: UInt32
  public let keyCode: UInt32
  /// The key as an NSMenuItem key equivalent, where it has one.
  public let menuKey: String

  static let codes: [String: UInt32] = [
    "A": 0x00, "B": 0x0B, "C": 0x08, "D": 0x02, "E": 0x0E, "F": 0x03, "G": 0x05, "H": 0x04, "I": 0x22,
    "J": 0x26, "K": 0x28, "L": 0x25, "M": 0x2E, "N": 0x2D, "O": 0x1F, "P": 0x23, "Q": 0x0C, "R": 0x0F,
    "S": 0x01, "T": 0x11, "U": 0x20, "V": 0x09, "W": 0x0D, "X": 0x07, "Y": 0x10, "Z": 0x06, "0": 0x1D,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
    "SPACE": 0x31, "HOME": 0x73, "END": 0x77, "PAGEUP": 0x74, "PAGEDOWN": 0x79, "LEFT": 0x7B, "RIGHT": 0x7C,
    "DOWN": 0x7D, "UP": 0x7E, "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61,
    "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F, "F13": 0x69, "F14": 0x6B,
    "F15": 0x71, "F16": 0x6A, "F17": 0x40, "F18": 0x4F, "F19": 0x50, "F20": 0x5A,
  ]

  public static func parse(_ spec: String) -> HotkeySpec? {
    let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard parts.count >= 2 else { return nil }
    var mods: UInt32 = 0
    for p in parts.dropLast() {
      switch p.lowercased() {
      case "ctrl": mods |= 0x1000  // controlKey
      case "alt": mods |= 0x0800  // optionKey
      case "shift": mods |= 0x0200  // shiftKey
      case "cmd", "win": mods |= 0x0100  // cmdKey
      default: return nil
      }
    }
    guard mods & 0x1900 != 0 else { return nil }
    let name = parts.last!.uppercased()
    guard let code = codes[name] else { return nil }
    return HotkeySpec(carbonModifiers: mods, keyCode: code, menuKey: name.count == 1 ? name.lowercased() : "")
  }
}
