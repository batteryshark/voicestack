import Foundation

/// A global hotkey written as "ctrl+option+space": modifiers (ctrl, option/alt, cmd, shift) and one key. Parsed into
/// Carbon's virtual key code and modifier mask (RegisterEventHotKey), which needs no Accessibility permission.
public struct Hotkey: Equatable, Sendable {
    public let keyCode: UInt32
    /// Carbon modifier mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public let modifiers: UInt32
    /// "⌃⌥Space"
    public let display: String

    /// ⌃⌥⌘Space (macOS uses ⌃⌥Space and ⌃Space to switch input sources).
    public static let defaultSpec = "ctrl+option+cmd+space"
    public static let discardSpec = "ctrl+option+cmd+backspace"
    public static let discardHelp = "Discard unsent speech only; already sent messages stay sent (⌃⌥⌘Backspace)."
    /// Choices offered in Settings.
    public static let presets = ["ctrl+option+cmd+space", "ctrl+option+cmd+return", "ctrl+option+cmd+s", "ctrl+shift+return", "cmd+shift+return"]

    static let keys: [String: (UInt32, String)] = {
        var k: [String: (UInt32, String)] = ["space": (49, "Space"), "return": (36, "Return"), "enter": (36, "Return"), "tab": (48, "Tab"),
                                             "escape": (53, "Esc"), "backspace": (51, "Backspace")]
        let letters: [(String, UInt32)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
                                           ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
                                           ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (l, c) in letters { k[l] = (c, l.uppercased()) }
        let digits: [(String, UInt32)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29)]
        for (d, c) in digits { k[d] = (c, d) }
        return k
    }()

    public static func parse(_ spec: String) -> Hotkey? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let (code, label) = keys[keyName] else { return nil }
        var mask: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "ctrl", "control": mask |= 0x1000
            case "option", "opt", "alt": mask |= 0x0800
            case "cmd", "command": mask |= 0x0100
            case "shift": mask |= 0x0200
            default: return nil
            }
        }
        guard mask != 0 else { return nil } // a bare key would swallow ordinary typing
        var symbols = ""
        if mask & 0x1000 != 0 { symbols += "⌃" }
        if mask & 0x0800 != 0 { symbols += "⌥" }
        if mask & 0x0200 != 0 { symbols += "⇧" }
        if mask & 0x0100 != 0 { symbols += "⌘" }
        return Hotkey(keyCode: code, modifiers: mask, display: symbols + label)
    }
}

/// Injectable registration policy; a failed attempt is reported once per pending-speech interval.
/// Carbon stays in the app layer so this policy is testable without installing global shortcuts.
@MainActor
public final class DiscardShortcutBinding {
    private var attempted = false
    private let register: () -> String?
    private let unregister: () -> Void
    private let reportError: (String) -> Void
    public init(register: @escaping () -> String?, unregister: @escaping () -> Void,
                reportError: @escaping (String) -> Void) {
        self.register = register; self.unregister = unregister; self.reportError = reportError
    }
    public func update(_ status: ConversationController.Status) {
        guard status.discardHotkeyEligible else {
            if attempted { unregister() }
            attempted = false
            return
        }
        guard !attempted else { return }
        attempted = true
        if let error = register() { reportError(error) }
    }
}
