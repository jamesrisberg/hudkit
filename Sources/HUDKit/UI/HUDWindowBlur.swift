import AppKit
import Darwin

/// The window server's background blur on a window: the family's backdrop. The server blurs
/// what is behind the window wherever the window draws (a translucent L in a rectangular
/// window blurs only the L), and a window that has it is already blurred when a desktop switch
/// lands, where an `NSVisualEffectView` or Liquid Glass backdrop is opaque for a moment first.
///
/// It is one private call, `CGSSetWindowBackgroundBlurRadius(connection, window, radius)` with
/// `CGSMainConnectionID()`, both resolved at run time with `dlsym` and never linked. Where
/// either is missing `isAvailable` is false, and with Reduce transparency on `isUsable` is
/// false; backdrops then use `NSVisualEffectView` instead, which the system makes opaque under
/// that setting.
///
/// Backdrop views (`HUDBackdropView`) attach to the window they are in. While one is attached
/// the window's radius is `radius`, set at three moments:
/// - on every attach, once the window has a window number. A window made without defer has
///   its number from the start and keeps it through ordering out and in, so this sets the
///   radius before the window first shows.
/// - on every change of the window's occlusion state (posted about 60 ms after an order-in,
///   when the window comes on screen another way, and when it leaves). A deferred window gets
///   its number only when first ordered in, so for it this is the first moment that works.
/// - once more `settleDelay` after each of those.
/// Whether the server keeps a radius set before a window's first order-in, and whether setting
/// it again ever changes anything, is not known: the radius cannot be read back, and the call
/// answers success even for a window number the server does not know. So all three are kept;
/// they are cheap, and the family's look through desktop switches was checked on screen with
/// all three in place.
///
/// After the last backdrop detaches the radius is 0, from the next turn of the run loop unless
/// a backdrop has arrived by then (one replacing another, a style rebuild), so the window is
/// never unblurred in between.
@MainActor
final class HUDWindowBlur {
    /// The blur radius of every HUD backdrop.
    static let radius = 25
    /// How long after an attach or an occlusion change the radius is set once more. Not known
    /// to be needed (the radius cannot be read back to tell); kept because the look was checked
    /// with it in place.
    static let settleDelay: TimeInterval = 0.4

    /// Sets the background blur radius of the window with this window number.
    typealias Setter = @MainActor (_ windowNumber: Int, _ radius: Int) -> Void

    static let shared = HUDWindowBlur(setter: serverSetter(), scheduler: .main, transparency: .system)

    /// The window server's call, or nil when a symbol is missing. `lookup` finds a symbol by
    /// name (`dlsym` over every loaded image).
    static func serverSetter(lookup: (String) -> UnsafeMutableRawPointer? = defaultLookup) -> Setter? {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetRadius = @convention(c) (Int32, UInt32, Int32) -> Int32
        guard let connection = lookup("CGSMainConnectionID"), let set = lookup("CGSSetWindowBackgroundBlurRadius") else {
            return nil
        }
        let mainConnection = unsafeBitCast(connection, to: MainConnection.self)
        let setRadius = unsafeBitCast(set, to: SetRadius.self)
        return { window, radius in
            guard let id = UInt32(exactly: window), id > 0 else { return }
            // The result says nothing useful: the server answers success even for a window
            // number it does not know.
            _ = setRadius(mainConnection(), id, Int32(radius))
        }
    }

    private nonisolated static func defaultLookup(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }

    private let setter: Setter?
    private let scheduler: HUDScheduler
    /// Whether the user asked to reduce transparency, and where that is announced.
    let transparency: HUDTransparencySetting

    /// The window server's call is there.
    var isAvailable: Bool { setter != nil }
    /// Backdrops may use the window server's blur: the call is there and the user has not
    /// asked to reduce transparency.
    var isUsable: Bool { isAvailable && !transparency.isReduced() }

    init(setter: Setter?, scheduler: HUDScheduler, transparency: HUDTransparencySetting) {
        self.setter = setter
        self.scheduler = scheduler
        self.transparency = transparency
    }

    /// A window with backdrops in it.
    private final class Tracked {
        weak var window: NSWindow?
        var views = Set<ObjectIdentifier>()
        var observer: NSObjectProtocol?
        var settle: HUDScheduledWork?
        init(_ window: NSWindow) { self.window = window }
    }

    private var tracked: [ObjectIdentifier: Tracked] = [:]

    /// `view`, a backdrop, is now in `window`: the window is blurred while it is.
    func attach(_ view: NSView, to window: NSWindow) {
        guard isAvailable else { return }
        forgetClosedWindows()
        let key = ObjectIdentifier(window)
        let entry = tracked[key] ?? track(window)
        entry.views.insert(ObjectIdentifier(view))
        apply(entry)
    }

    /// `view` left `window`; the last backdrop to leave clears the blur on the next turn.
    func detach(_ view: NSView, from window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let entry = tracked[key], entry.views.remove(ObjectIdentifier(view)) != nil, entry.views.isEmpty else { return }
        stopTracking(key)
        // A window being deallocated (its weak references already read nil) needs no clearing,
        // and no new weak reference to it may be formed.
        guard entry.window != nil, window.windowNumber > 0 else { return }
        let number = window.windowNumber
        _ = scheduler.after(0) { [weak self] in
            guard let self, self.tracked[key] == nil else { return }
            self.setter?(number, 0)
        }
    }

    private func track(_ window: NSWindow) -> Tracked {
        let key = ObjectIdentifier(window)
        let entry = Tracked(window)
        entry.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.tracked[key] else { return }
                self.apply(entry)
            }
        }
        tracked[key] = entry
        return entry
    }

    private func stopTracking(_ key: ObjectIdentifier) {
        guard let entry = tracked.removeValue(forKey: key) else { return }
        entry.settle?.cancel()
        if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Drops windows that went away with their backdrops still in them.
    private func forgetClosedWindows() {
        for (key, entry) in tracked where entry.window == nil { stopTracking(key) }
    }

    /// Sets the radius now and once more after `settleDelay`.
    private func apply(_ entry: Tracked) {
        guard let window = entry.window else { return }
        set(window, radius: Self.radius)
        entry.settle?.cancel()
        entry.settle = scheduler.after(Self.settleDelay) { [weak self, weak entry] in
            guard let self, let entry, let window = entry.window, !entry.views.isEmpty else { return }
            self.set(window, radius: Self.radius)
        }
    }

    private func set(_ window: NSWindow, radius: Int) {
        guard let setter, window.windowNumber > 0 else { return }
        setter(window.windowNumber, radius)
    }
}

/// The user's Reduce transparency setting (Accessibility > Display), and the notification
/// center that posts `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` when it
/// changes. Tests substitute their own.
struct HUDTransparencySetting {
    var isReduced: @MainActor () -> Bool
    var center: NotificationCenter

    static var system: HUDTransparencySetting {
        HUDTransparencySetting(isReduced: { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
                               center: NSWorkspace.shared.notificationCenter)
    }

    /// A setting that never changes (tests).
    static func fixed(reduced: Bool) -> HUDTransparencySetting {
        HUDTransparencySetting(isReduced: { reduced }, center: NotificationCenter())
    }
}
