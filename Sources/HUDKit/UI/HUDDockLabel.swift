import AppKit

/// When a dock strip's hover label shows. Pure, so it is unit tested.
///
/// - The pointer resting on a labelled item for `delay` (250 ms) shows its label.
/// - While a label shows, moving to another labelled item moves it there at once (no fade),
///   also across the gap between items (the label waits `grace` there).
/// - Moving to an item without a label, or off the strip (`exit`), hides it; resting between
///   items hides it after `grace`.
/// - A click or a drag (`dismiss`) hides it, and it stays hidden until the pointer moves to
///   another item.
public struct HUDDockLabelState: Equatable, Sendable {
    public static let delay: TimeInterval = 0.25
    public static let grace: TimeInterval = 0.3
    /// Clock readings are floating point.
    static let tolerance: TimeInterval = 1e-6

    public enum Action: Equatable, Sendable {
        /// Fade the label in at this item.
        case show(String)
        /// Move the showing label to this item.
        case move(String)
        case hide
    }

    public var delay: TimeInterval = Self.delay
    public var grace: TimeInterval = Self.grace
    /// The labelled item under the pointer.
    public private(set) var hovered: String?
    /// The item whose label shows.
    public private(set) var shown: String?
    /// When the pointer reached `hovered`, while its label is due.
    public private(set) var since: TimeInterval?
    /// Dismissed by a click or drag: no label until the pointer leaves it.
    public private(set) var suppressed: String?
    /// When the pointer left the shown label's item for the strip between items.
    public private(set) var leftAt: TimeInterval?

    public init() {}

    /// When the timer should `fire`: the due label's show, or the end of the grace.
    public var deadline: TimeInterval? {
        if let since { return since + delay }
        return leftAt.map { $0 + grace }
    }

    /// The pointer is on labelled item `id`, or (nil) on the strip between items.
    public mutating func hover(_ id: String?, now: TimeInterval) -> [Action] {
        guard id != hovered else { return [] }
        hovered = id
        if suppressed != nil, suppressed != id { suppressed = nil }
        since = nil
        guard let id else {
            if shown != nil { leftAt = now }
            return []
        }
        leftAt = nil
        if id == suppressed { return hideShown() }
        if let s = shown {
            shown = id
            return s == id ? [] : [.move(id)]
        }
        since = now
        return []
    }

    /// The pointer left the strip, or is on an item without a label: hide now.
    public mutating func exit() -> [Action] {
        hovered = nil
        suppressed = nil
        since = nil
        return hideShown()
    }

    /// The timer: shows the due label once `delay` has passed, or hides the label after
    /// `grace` between items.
    public mutating func fire(now: TimeInterval) -> [Action] {
        guard let deadline, now >= deadline - Self.tolerance else { return [] }
        if since != nil, let id = hovered {
            since = nil
            shown = id
            return [.show(id)]
        }
        return hideShown()
    }

    private mutating func hideShown() -> [Action] {
        since = nil
        leftAt = nil
        guard shown != nil else { return [] }
        shown = nil
        return [.hide]
    }

    /// A click or a drag: hide, and keep hidden until the pointer moves to another item.
    public mutating func dismiss() -> [Action] {
        suppressed = hovered
        return hideShown()
    }
}

/// The hover label's window: a small glass pill with the item's name, above the strip's
/// window and never taking the mouse.
@MainActor
final class HUDDockLabelWindow: NSPanel {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let padding = CGSize(width: 8, height: 4)
    static let cornerRadius: CGFloat = 6
    static let fadeIn: TimeInterval = 0.1
    static let fadeOut: TimeInterval = 0.08

    private let text = NSTextField(labelWithString: "")
    private var hiding = false

    static func size(for string: String) -> CGSize {
        let s = (string as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + padding.width * 2, height: ceil(s.height) + padding.height * 2)
    }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        var style = HUDGlassView.Style.plain
        style.cornerRadius = Self.cornerRadius
        let glass = HUDGlassView(style: style)
        glass.autoresizingMask = [.width, .height]
        text.font = Self.font
        text.textColor = .labelColor
        text.alignment = .center
        text.lineBreakMode = .byClipping
        text.autoresizingMask = [.width, .height]
        glass.addSubview(text)
        contentView = glass
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(text string: String) {
        guard text.stringValue != string else { return }
        text.stringValue = string
        layoutText()
    }

    private func layoutText() {
        guard let content = contentView else { return }
        let h = ceil(text.intrinsicContentSize.height)
        text.frame = CGRect(x: 0, y: ((content.bounds.height - h) / 2).rounded(), width: content.bounds.width, height: h)
    }

    /// Fades in at `frame`.
    func show(at frame: CGRect) {
        hiding = false
        setFrame(frame, display: true)
        layoutText()
        if !isVisible { alphaValue = 0 }
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            animator().alphaValue = 1
        }
    }

    /// Moves a showing label (no fade).
    func move(to frame: CGRect) {
        setFrame(frame, display: true)
        layoutText()
    }

    func hide(animated: Bool) {
        guard isVisible, !hiding else { return }
        guard animated else { alphaValue = 0; orderOut(nil); return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hiding else { return }
                self.hiding = false
                self.orderOut(nil)
            }
        })
    }
}
