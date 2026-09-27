import AppKit

/// The MacHUD panel window, in one of two behaviours.
///
/// - `.hover` (the default): the recipe hover panels and dock strips use. Borderless,
///   non-activating, floating, on every Space, transparent with a shadow, dark appearance,
///   never hidden on deactivate. `keyable` is false for click-only strips (clicking must never
///   take focus from the app the user is in) and true for panels with text fields. A
///   non-activating panel can take key status without activating its app.
/// - `.windowed`: a windowed HUD app's main window (Sift's browser, MechaHUD's dashboard)
///   behaves like a normal window. Same glass look (borderless, transparent, shadow,
///   draggable by its background), but at `.normal` level, activating its app when clicked,
///   key and main, on the current Space only, in Mission Control and the ⌘` cycle. Other
///   apps' windows can cover it. `showsInDock` (default true) gives the app a Dock tile and a
///   ⌘-Tab entry while such a window is on screen (see `HUDDockPolicy`).
///
/// A window can switch behaviour at runtime with `applyHUDRecipe(behavior:)` (Sift's one
/// window is the windowed browser in full mode and the hover dock strip in compact mode).
/// HUDParking and HUDAnimation only move frames and alpha, so they work for both.
open class HUDPanelWindow: NSPanel {
    public enum Behavior: String, Codable, Sendable {
        case hover, windowed
    }

    /// Set by `applyHUDRecipe`.
    public private(set) var behavior: Behavior = .hover
    /// Hover only: whether the panel takes key status. A windowed window always can.
    open var keyable = false
    /// Windowed only: while this window is on screen the app is a regular app (Dock tile,
    /// ⌘-Tab entry), and goes back to `HUDDockPolicy.hiddenPolicy` when no such window is.
    open var showsInDock = true {
        didSet { HUDDockPolicy.shared.update(self) }
    }

    open override var canBecomeKey: Bool { behavior == .windowed || keyable }
    open override var canBecomeMain: Bool { behavior == .windowed }

    /// HUD panels park off-screen at any edge, including the top. AppKit's default
    /// keeps windows below the menu bar and inside the visible frame, which would
    /// silently undo a park at the top edge, so the recipe does not constrain frames.
    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The hover style mask.
    public static let recipeStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
    /// The windowed style mask: no `.nonactivatingPanel`, so a click activates the app.
    public static let windowedStyleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]

    public static func styleMask(for behavior: Behavior) -> NSWindow.StyleMask {
        behavior == .hover ? recipeStyleMask : windowedStyleMask
    }

    /// The hover recipe's Spaces behaviour: every Space, ignored by Mission Control, over full-screen apps.
    public static let hoverCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    /// The windowed recipe's: the current Space only, shown in Mission Control, in the ⌘` cycle.
    public static let windowedCollectionBehavior: NSWindow.CollectionBehavior = [.managed, .participatesInCycle]

    /// Creates a hover panel with the recipe applied.
    public convenience init(contentRect: CGRect, keyable: Bool = false, level: NSWindow.Level = .floating) {
        self.init(contentRect: contentRect, styleMask: Self.recipeStyleMask, backing: .buffered, defer: false)
        self.keyable = keyable
        applyHUDRecipe(level: level)
    }

    /// Creates a panel with `behavior`'s recipe applied.
    public convenience init(contentRect: CGRect, behavior: Behavior) {
        self.init(contentRect: contentRect, styleMask: Self.styleMask(for: behavior), backing: .buffered, defer: false)
        applyHUDRecipe(behavior: behavior)
    }

    /// Applies the hover recipe to a panel made with a custom initializer.
    public func applyHUDRecipe(level: NSWindow.Level = .floating) {
        applyHUDRecipe(behavior: .hover, level: level)
    }

    /// Applies `behavior`'s recipe (to a panel made with a custom initializer, or to switch a
    /// panel's behaviour). `level` defaults to `.floating` for hover and `.normal` for
    /// windowed. Other style mask bits (`.resizable`) are kept.
    public func applyHUDRecipe(behavior: Behavior, level: NSWindow.Level? = nil) {
        self.behavior = behavior
        switch behavior {
        case .hover:
            styleMask.insert(.nonactivatingPanel)
            collectionBehavior = Self.hoverCollectionBehavior
            animationBehavior = .utilityWindow
        case .windowed:
            styleMask.remove(.nonactivatingPanel)
            collectionBehavior = Self.windowedCollectionBehavior
            animationBehavior = .documentWindow
        }
        setPreventsActivation(behavior == .hover)
        self.level = level ?? (behavior == .hover ? .floating : .normal)
        styleMask.insert(.borderless)
        styleMask.insert(.fullSizeContentView)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        // Every HUD panel can be dragged by its chrome; views that need the drag for
        // themselves (text views, sliders) still win because they handle mouseDown first.
        isMovableByWindowBackground = true
        isMovable = true
        HUDDockPolicy.shared.update(self)
    }

    /// NSPanel reads `.nonactivatingPanel` once, at init: inserting or removing it later
    /// changes the style mask but not whether a click activates the app (verified on macOS
    /// 26). Sift's one window switches between windowed and hover, so the flag is set here
    /// through AppKit's own setter when it exists. Without it a switched window keeps the
    /// activation behaviour it was created with (nothing else breaks).
    private func setPreventsActivation(_ prevents: Bool) {
        let selector = NSSelectorFromString("_setPreventsActivation:")
        guard responds(to: selector), let method = class_getInstanceMethod(NSPanel.self, selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(self, selector, prevents)
    }

    /// Whether a click on the window activates its app (false for hover). Nil where AppKit
    /// does not expose it.
    public var preventsActivation: Bool? {
        responds(to: NSSelectorFromString("_preventsActivation")) ? value(forKey: "_preventsActivation") as? Bool : nil
    }

    /// Brings the window forward for a `panel show` (or the app's own summon). A hover
    /// show (`reason=hover`: the pointer is only passing over MacHUD's dock) orders it in
    /// without taking focus. Anything else (click, summon, no reason) makes it key; a
    /// windowed window also activates the app, and first moves to the current Space if it
    /// is on another one. Returns whether it took focus.
    @discardableResult
    public func activateOnShow(_ transition: HUDPanelTransition = HUDPanelTransition()) -> Bool {
        guard Self.takesFocus(transition) else {
            if !isVisible { orderFrontRegardless() }
            return false
        }
        if behavior == .windowed {
            let onOtherSpace = isVisible && !isOnActiveSpace
            if onOtherSpace {
                // Pull it over rather than switching the user to the Space it was left on.
                collectionBehavior = Self.windowedCollectionBehavior.union(.moveToActiveSpace)
            }
            // macOS 14+ may decline the activation (cooperative activation: the app the user
            // is typing in keeps focus unless the app that took the click yields to us, as
            // MacHUD's dock should). The window still comes to the front, ready for a click.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            orderFrontRegardless()
            if onOtherSpace {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.behavior == .windowed else { return }
                    self.collectionBehavior = Self.windowedCollectionBehavior
                }
            }
        } else if canBecomeKey {
            makeKeyAndOrderFront(nil)
        } else if !isVisible {
            orderFrontRegardless()
        }
        return true
    }

    /// Whether a show for `transition` takes focus: everything but `reason=hover`.
    public nonisolated static func takesFocus(_ transition: HUDPanelTransition) -> Bool {
        transition.reason != .hover
    }

    // Keep the activation policy in step with visibility.
    open override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        HUDDockPolicy.shared.update(self)
    }

    open override func orderFrontRegardless() {
        super.orderFrontRegardless()
        HUDDockPolicy.shared.update(self)
    }

    open override func close() {
        super.close()
        HUDDockPolicy.shared.update(self)
    }
}

/// Gives a menu bar HUD app a Dock tile and a ⌘-Tab entry while one of its windowed
/// panels (`HUDPanelWindow` with `behavior == .windowed` and `showsInDock`) is on screen,
/// and takes them away again when none is: `NSApp.setActivationPolicy(.regular)` while
/// such a window is visible, `hiddenPolicy` (`.accessory`) otherwise. HUDPanelWindow
/// reports its own visibility; apps need do nothing. To opt a window out, set its
/// `showsInDock` to false; to opt the whole app out, set `HUDDockPolicy.shared.isEnabled`
/// to false before showing anything.
@MainActor
public final class HUDDockPolicy {
    public static let shared = HUDDockPolicy()

    public var isEnabled = true
    /// The policy while no windowed panel is showing.
    public var hiddenPolicy: NSApplication.ActivationPolicy = .accessory
    /// Applies a policy; `NSApp.setActivationPolicy` unless replaced (tests).
    public var apply: (NSApplication.ActivationPolicy) -> Void = { policy in
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
    /// The policy last applied, nil before the first change.
    public private(set) var current: NSApplication.ActivationPolicy?

    private var showing = Set<ObjectIdentifier>()

    public init() {}

    /// Windows showing that want a Dock tile.
    public var visibleWindowedCount: Int { showing.count }

    /// Records whether `window` is a visible windowed panel that wants a Dock tile, and
    /// applies the resulting policy on change.
    public func update(_ window: HUDPanelWindow) {
        let key = ObjectIdentifier(window)
        let wants = window.behavior == .windowed && window.showsInDock && window.isVisible
        let changed = wants ? showing.insert(key).inserted : showing.remove(key) != nil
        guard changed, isEnabled else { return }
        let policy: NSApplication.ActivationPolicy = showing.isEmpty ? hiddenPolicy : .regular
        guard policy != current else { return }
        current = policy
        apply(policy)
    }
}
