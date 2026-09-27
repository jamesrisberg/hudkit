import AppKit

/// Serializes an app's status menu for the contract's `menu` verb and performs an item for
/// `menu-invoke`, so MacHUD can show a sibling's menu inside its own status menu.
///
/// Item ids are index paths from the root menu (`"3"`, `"5.1"` for the second item of the
/// sixth item's submenu). Hidden and alternate items are left out of the listing but keep
/// their index, so ids stay stable while the menu's structure does. Before listing or
/// performing, the menu (and each submenu) is refreshed the way AppKit does when it opens:
/// the delegate's `menuNeedsUpdate(_:)`, then `update()` for validation, so titles, states and
/// enabled flags are current.
///
/// ```swift
/// router.menuProvider = { [weak self] in self?.statusItem.menu }
/// ```
@MainActor
public enum HUDMenuBridge {
    /// One serialized menu item, as `menu` returns it.
    public struct Item: Equatable, Sendable {
        public enum Kind: String, Sendable { case item, separator, submenu }
        public enum State: String, Sendable { case on, off, mixed }

        public var id: String
        public var title: String
        public var kind: Kind
        public var enabled: Bool
        public var state: State
        /// The key, as AppKit stores it (`"q"`, `"/"`); nil when there is none.
        public var keyEquivalent: String?
        /// `command`, `option`, `control`, `shift` for the key equivalent.
        public var modifiers: [String]
        /// Children of a `submenu`.
        public var items: [Item]?

        public init(id: String, title: String, kind: Kind = .item, enabled: Bool = true, state: State = .off,
                    keyEquivalent: String? = nil, modifiers: [String] = [], items: [Item]? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.enabled = enabled
            self.state = state
            self.keyEquivalent = keyEquivalent
            self.modifiers = modifiers
            self.items = items
        }

        public var json: [String: Any] {
            var d: [String: Any] = ["id": id, "title": title, "kind": kind.rawValue,
                                    "enabled": enabled, "state": state.rawValue]
            if let keyEquivalent {
                d["keyEquivalent"] = keyEquivalent
                d["modifiers"] = modifiers
            }
            if let items { d["items"] = items.map(\.json) }
            return d
        }

        /// Reads the wire form (MacHUD's side). Nil when `id` is missing.
        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String else { return nil }
            self.id = id
            title = json["title"] as? String ?? ""
            kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .item
            enabled = json["enabled"] as? Bool ?? true
            state = (json["state"] as? String).flatMap(State.init(rawValue:)) ?? .off
            keyEquivalent = (json["keyEquivalent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            modifiers = json["modifiers"] as? [String] ?? []
            items = (json["items"] as? [[String: Any]]).map { $0.compactMap(Item.init(json:)) }
        }

        /// A reply's `items` array.
        public static func list(_ raw: Any?) -> [Item] {
            (raw as? [[String: Any]] ?? []).compactMap(Item.init(json:))
        }

        /// `NSEvent.ModifierFlags` for `modifiers`.
        public var modifierFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            for m in modifiers {
                switch m {
                case "command": flags.insert(.command)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                case "shift": flags.insert(.shift)
                default: break
                }
            }
            return flags
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noMenu
        case noSuchItem(String)
        case notAnAction(String)
        case disabled(String)
        /// `menu-invoke title=` did not match: the menu changed since it was listed.
        case changed(String)

        public var description: String {
            switch self {
            case .noMenu: return "no menu"
            case .noSuchItem(let id): return "no menu item \(id)"
            case .notAnAction(let id): return "menu item \(id) is a separator or submenu"
            case .disabled(let id): return "menu item \(id) is disabled"
            case .changed(let id): return "menu item \(id) changed; list the menu again"
            }
        }
    }

    /// Runs what AppKit runs before showing `menu`: the delegate's `menuNeedsUpdate(_:)` then
    /// item validation. Recurses into submenus when `deep`.
    public static func refresh(_ menu: NSMenu, deep: Bool = false) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        guard deep else { return }
        for item in menu.items { if let sub = item.submenu { refresh(sub, deep: true) } }
    }

    /// The menu as `menu` returns it, refreshed first.
    public static func serialize(_ menu: NSMenu) -> [Item] {
        refresh(menu)
        return items(of: menu, prefix: "")
    }

    private static func items(of menu: NSMenu, prefix: String) -> [Item] {
        var out: [Item] = []
        for (index, item) in menu.items.enumerated() where !item.isHidden && !item.isAlternate {
            let id = prefix + String(index)
            if item.isSeparatorItem {
                out.append(Item(id: id, title: "", kind: .separator, enabled: false))
                continue
            }
            var entry = Item(id: id, title: item.title, enabled: item.isEnabled, state: state(item.state))
            if !item.keyEquivalent.isEmpty {
                entry.keyEquivalent = item.keyEquivalent
                entry.modifiers = modifiers(item.keyEquivalentModifierMask)
            }
            if let sub = item.submenu {
                refresh(sub)
                entry.kind = .submenu
                entry.items = items(of: sub, prefix: id + ".")
            }
            out.append(entry)
        }
        return out
    }

    static func state(_ s: NSControl.StateValue) -> Item.State {
        switch s {
        case .on: return .on
        case .mixed: return .mixed
        default: return .off
        }
    }

    static func modifiers(_ mask: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if mask.contains(.control) { out.append("control") }
        if mask.contains(.option) { out.append("option") }
        if mask.contains(.shift) { out.append("shift") }
        if mask.contains(.command) { out.append("command") }
        return out
    }

    /// The menu item at `id` (refreshing each menu on the way down), or nil.
    public static func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        var current = menu
        refresh(current)
        for (depth, index) in parts.enumerated() {
            guard let index, current.items.indices.contains(index) else { return nil }
            let item = current.items[index]
            if depth == parts.count - 1 { return item }
            guard let sub = item.submenu else { return nil }
            refresh(sub)
            current = sub
        }
        return nil
    }

    /// Checks that `id` names an enabled action item (with `title`, when given) and returns
    /// it, without performing it.
    public static func resolve(_ id: String, title: String? = nil, in menu: NSMenu) throws -> NSMenuItem {
        guard let item = item(id, in: menu) else { throw Failure.noSuchItem(id) }
        if let title, item.title != title { throw Failure.changed(id) }
        guard !item.isSeparatorItem, item.submenu == nil else { throw Failure.notAnAction(id) }
        guard item.isEnabled else { throw Failure.disabled(id) }
        return item
    }

    /// Performs the item as if the user had chosen it: its action goes to its target, or up
    /// the responder chain when it has none.
    public static func perform(_ item: NSMenuItem) {
        if let menu = item.menu, let index = Optional(menu.index(of: item)), index >= 0 {
            menu.performActionForItem(at: index)
        } else if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// `resolve` then `perform`, synchronously.
    public static func invoke(_ id: String, title: String? = nil, in menu: NSMenu) throws {
        perform(try resolve(id, title: title, in: menu))
    }
}
