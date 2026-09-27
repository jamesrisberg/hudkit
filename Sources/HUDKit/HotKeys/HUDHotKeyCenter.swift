import AppKit
import Carbon

/// A global hotkey: a key name (see `HUDHotKeyCenter.keyCode(for:)`) plus modifier names
/// (`command`/`cmd`, `option`/`alt`, `control`/`ctrl`, `shift`). Codable as `{"key", "modifiers"}`.
public struct HUDHotKey: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// e.g. `⌃⌥SPACE`.
    public var display: String {
        let m = modifiers.map { mod -> String in
            switch mod.lowercased() {
            case "command", "cmd": return "⌘"
            case "option", "alt": return "⌥"
            case "control", "ctrl": return "⌃"
            case "shift": return "⇧"
            default: return mod
            }
        }.joined()
        return m + key.uppercased()
    }
}

/// Global hotkeys via Carbon, with press *and* release callbacks (needed for hold-to-show UI
/// like a radial menu). Callbacks arrive on the main thread.
public final class HUDHotKeyCenter {
    public static let shared = HUDHotKeyCenter()

    private struct Registration {
        let id: UInt32
        let hotKey: HUDHotKey
        let onPress: () -> Void
        let onRelease: (() -> Void)?
        var ref: EventHotKeyRef?
    }

    private static let signature: OSType = 0x4855_444B // "HUDK"
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let center = Unmanaged<HUDHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == HUDHotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            center.dispatch(id: hk.id, released: kind == UInt32(kEventHotKeyReleased))
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func dispatch(id: UInt32, released: Bool) {
        guard let reg = registrations[id] else { return }
        if released { reg.onRelease?() } else { reg.onPress() }
    }

    /// Returns a registration id, or nil if the key name is unknown or the OS refused
    /// (typically because another app owns the combination).
    @discardableResult
    public func register(_ hotKey: HUDHotKey, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> UInt32? {
        guard let code = Self.keyCode(for: hotKey.key) else {
            NSLog("HUDKit: unknown hotkey key '%@'", hotKey.key)
            return nil
        }
        let mods = Self.carbonModifiers(hotKey.modifiers)
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, mods, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("HUDKit: RegisterEventHotKey failed for %@ (%d)", hotKey.display, status)
            return nil
        }
        registrations[id] = Registration(id: id, hotKey: hotKey, onPress: onPress, onRelease: onRelease, ref: ref)
        return id
    }

    public func unregister(_ id: UInt32) {
        guard let reg = registrations.removeValue(forKey: id), let ref = reg.ref else { return }
        UnregisterEventHotKey(ref)
    }

    public func unregisterAll() {
        for id in Array(registrations.keys) { unregister(id) }
    }

    /// Currently registered hotkeys by id.
    public var registered: [UInt32: HUDHotKey] { registrations.mapValues(\.hotKey) }

    public static func carbonModifiers(_ names: [String]) -> UInt32 {
        var m: UInt32 = 0
        for n in names {
            switch n.lowercased() {
            case "command", "cmd": m |= UInt32(cmdKey)
            case "option", "alt": m |= UInt32(optionKey)
            case "control", "ctrl": m |= UInt32(controlKey)
            case "shift": m |= UInt32(shiftKey)
            default: break
            }
        }
        return m
    }

    /// US-layout virtual key codes for key names (letters, digits, named keys, punctuation, F1-F12).
    public static func keyCode(for name: String) -> UInt32? {
        keyCodes[name.lowercased()].map { UInt32($0) }
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_Return, "escape": kVK_Escape,
        "delete": kVK_Delete, "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
}
