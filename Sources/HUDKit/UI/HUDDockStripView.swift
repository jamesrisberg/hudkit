import AppKit
import SwiftUI

/// The state dot on the screen-edge side of a dock item.
public enum HUDDockIndicator: String, Equatable, Sendable {
    case none
    /// The app is running (label colour).
    case running
    /// Something of it is on screen: a panel, a drawer (accent colour).
    case visible
}

/// One item of a dock strip.
public struct HUDDockItem: Equatable {
    public var id: String
    /// Accessibility label, and the native tooltip of an item without a `label`.
    public var title: String
    /// The name in the glass pill that shows beside the strip while the pointer rests on the
    /// item (`HUDDockStripView` labels); nil shows none (and the native `title` tooltip).
    public var label: String?
    public var content: HUDDockTile.Content
    /// A count in a badge at the icon's top-right; nil or 0 shows none.
    public var badge: Int?
    public var indicator: HUDDockIndicator
    /// Drawn at reduced opacity (e.g. a folder that no longer exists).
    public var dimmed: Bool
    /// A soft wash behind the icon.
    public var highlighted: Bool
    /// File drags are accepted (subject to `HUDDockStripDelegate.dockStrip(_:validateDrop:on:)`).
    public var acceptsDrop: Bool

    /// Where an item's hover label comes from.
    public enum Label: Equatable {
        /// The title's first segment (up to a ":", " — ", " – " or " - "; `titleLabel`).
        case title
        case text(String)
        case none
    }

    public init(id: String, title: String, content: HUDDockTile.Content, badge: Int? = nil,
                indicator: HUDDockIndicator = .none, dimmed: Bool = false, highlighted: Bool = false,
                acceptsDrop: Bool = false, label: Label = .title) {
        self.id = id
        self.title = title
        switch label {
        case .title: self.label = Self.titleLabel(title)
        case .text(let text): self.label = text
        case .none: self.label = nil
        }
        self.content = content
        self.badge = badge
        self.indicator = indicator
        self.dimmed = dimmed
        self.highlighted = highlighted
        self.acceptsDrop = acceptsDrop
    }

    /// A title's first segment: "Trash: drop files here" → "Trash", "Sift — Downloads" →
    /// "Sift". nil when that is empty.
    public static func titleLabel(_ title: String) -> String? {
        var head = Substring(title)
        for separator in [":", " — ", " – ", " - "] {
            if let r = head.range(of: separator) { head = head[..<r.lowerBound] }
        }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// What a dock strip tells its owner. Everything has a default, so implement what you use.
@MainActor
public protocol HUDDockStripDelegate: AnyObject {
    /// An item was clicked (mouse up inside it).
    func dockStrip(_ strip: HUDDockStripView, didClick item: HUDDockItem, tile: HUDDockTile)
    /// Right click on an item. The default pops up `dockStrip(_:menuFor:)`.
    func dockStrip(_ strip: HUDDockStripView, didRightClick item: HUDDockItem, tile: HUDDockTile, event: NSEvent)
    /// The context menu for an item, or for the strip's background (`item` nil).
    func dockStrip(_ strip: HUDDockStripView, menuFor item: HUDDockItem?) -> NSMenu?
    /// Whether `urls` may drop on an item that `acceptsDrop` (default: yes).
    func dockStrip(_ strip: HUDDockStripView, validateDrop urls: [URL], on item: HUDDockItem) -> Bool
    /// Files dropped on an item. `copy` is true when Option was held.
    func dockStrip(_ strip: HUDDockStripView, didDrop urls: [URL], on item: HUDDockItem, copy: Bool)
    /// A file drag rested on an accepting item for `HUDDockTile.springDelay`.
    func dockStrip(_ strip: HUDDockStripView, springLoad item: HUDDockItem)
    /// A press (on the background or on an item) moved past `HUDDockStripView.dragThreshold`:
    /// the strip is being dragged. Called once per drag; no click follows it, and hover
    /// reports pause until the button comes up.
    func dockStripDidBeginDrag(_ strip: HUDDockStripView)
    /// A drag ended with the pointer at `point` (screen coordinates) on `screen`: `position`
    /// is the nearest of the eight (`HUDDockPosition.nearest` in its visible frame). Only
    /// after `dockStripDidBeginDrag`, and only when the window moved.
    func dockStrip(_ strip: HUDDockStripView, didDragTo position: HUDDockPosition, at point: CGPoint, on screen: NSScreen?)
    /// A drag ended (after `didDragTo` when the window moved). Only after `dockStripDidBeginDrag`.
    func dockStripDidEndDrag(_ strip: HUDDockStripView)
    /// The pointer moved onto an item, or off the items (nil). Not reported while the strip
    /// is dragged; when the drag ends the item under the pointer then is reported.
    func dockStrip(_ strip: HUDDockStripView, didHover item: HUDDockItem?)
}

public extension HUDDockStripDelegate {
    func dockStrip(_ strip: HUDDockStripView, didClick item: HUDDockItem, tile: HUDDockTile) {}
    func dockStrip(_ strip: HUDDockStripView, didRightClick item: HUDDockItem, tile: HUDDockTile, event: NSEvent) {
        guard let menu = dockStrip(strip, menuFor: item) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: tile)
    }
    func dockStrip(_ strip: HUDDockStripView, menuFor item: HUDDockItem?) -> NSMenu? { nil }
    func dockStrip(_ strip: HUDDockStripView, validateDrop urls: [URL], on item: HUDDockItem) -> Bool { true }
    func dockStrip(_ strip: HUDDockStripView, didDrop urls: [URL], on item: HUDDockItem, copy: Bool) {}
    func dockStrip(_ strip: HUDDockStripView, springLoad item: HUDDockItem) {}
    func dockStripDidBeginDrag(_ strip: HUDDockStripView) {}
    func dockStrip(_ strip: HUDDockStripView, didDragTo position: HUDDockPosition, at point: CGPoint, on screen: NSScreen?) {}
    func dockStripDidEndDrag(_ strip: HUDDockStripView) {}
    func dockStrip(_ strip: HUDDockStripView, didHover item: HUDDockItem?) {}
}

/// A dock strip: the MacHUD tool dock's glass slab (Liquid Glass on macOS 26, a
/// behind-window `.popover` blur before it), `HUDDockStyle` corners and hairline border,
/// items as `HUDDockTile`s with the indicator dot on the screen-edge side, dividers between
/// groups, hover magnification, hover labels (a glass pill naming the item under the pointer,
/// outside the strip), and dragging, which reports the snapped `HUDDockPosition` to the
/// delegate. A press anywhere on the strip, an item included, is a click until it moves
/// `dragThreshold`, then a drag of the whole strip, never both. At a corner the slab is an
/// L: the view is masked to the union of its arms.
///
/// Lay it out either with an explicit placement (`apply(items:placement:)`, in this view's
/// coordinates: e.g. `HUDDockStyle.placement(…).local`) or as a straight run filling its
/// bounds (`apply(items:groups:edge:)`), which re-lays out on resize and shrinks the icons
/// when the run is longer than the bounds.
@MainActor
public final class HUDDockStripView: NSView {
    public weak var delegate: HUDDockStripDelegate?
    /// The style the strip was given; a run shrinks a copy of it to fit (`effectiveStyle`).
    public var style: HUDDockStyle {
        didSet {
            guard style != oldValue else { return }
            updateBorder()
            if run != nil { relayoutRun() } else { effectiveStyle = style; place(items: items, placement: placement) }
        }
    }
    /// The style in use: `style`, or its fitted copy for a run that would not fit.
    public private(set) var effectiveStyle: HUDDockStyle
    /// Grow the icon under the pointer.
    public var magnify = true { didSet { tiles.forEach { $0.magnify = magnify } } }

    public private(set) var tiles: [HUDDockTile] = []
    public private(set) var placement = HUDDockPlacement(frame: .zero, segments: [], items: [], itemEdges: [], dividers: [])
    public var items: [HUDDockItem] { tiles.map(\.item) }

    private let backdrop: NSView
    private let overlay = HUDDockOverlayView()
    private let shape = CAShapeLayer()
    private let border = CAShapeLayer()
    private var dividerViews: [NSView] = []
    private var run: (groups: [Int], edge: HUDEdge)?

    public init(frame: NSRect = .zero, style: HUDDockStyle = .standard) {
        self.style = style
        effectiveStyle = style
        backdrop = Self.makeBackdrop(style)
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = shape
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.strip = self
        addSubview(overlay)
        border.fillColor = nil
        layer?.addSublayer(border)
        updateBorder()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// True when the backdrop is Liquid Glass.
    public var usesLiquidGlass: Bool { !(backdrop is NSVisualEffectView) }

    private static func makeBackdrop(_ style: HUDDockStyle) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = HUDDockPassthroughGlass()
            glass.cornerRadius = 0  // the view's mask shapes it
            return glass
        }
        #endif
        let effect = HUDDockPassthroughEffect()
        effect.material = style.fallbackMaterial
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    // MARK: Chrome

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    /// The border colour in the current appearance.
    public var borderColor: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor.white.withAlphaComponent(style.borderAlphaDark)
            : NSColor.black.withAlphaComponent(style.borderAlphaLight)
    }

    private func updateBorder() {
        border.lineWidth = style.borderWidth
        border.strokeColor = borderColor.cgColor
    }

    /// The slab's outline in this view's coordinates.
    public var outline: CGPath { effectiveStyle.outline(placement.segments.isEmpty ? [bounds] : placement.segments) }

    public override func layout() {
        super.layout()
        if run != nil { relayoutRun() } else { applyShape() }
    }

    private func applyShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = outline
        shape.frame = bounds
        shape.path = path
        border.frame = bounds
        border.path = path
        CATransaction.commit()
    }

    /// Clicks in the empty part of an L's bounding box are not the strip's.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard placement.segments.isEmpty || placement.segments.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Items

    /// Shows `items` at `placement` (this view's coordinates; `placement.items` pairs with
    /// `items`). Tiles are reused by id.
    public func apply(items: [HUDDockItem], placement: HUDDockPlacement) {
        run = nil
        effectiveStyle = style
        place(items: items, placement: placement)
    }

    /// Shows `items` as a straight run of `groups` (counts, dividers between) filling this
    /// view's bounds against `edge`, kept laid out as the view resizes.
    public func apply(items: [HUDDockItem], groups: [Int], edge: HUDEdge) {
        run = (groups, edge)
        syncTiles(items)
        relayoutRun()
    }

    private func relayoutRun() {
        guard let run else { return }
        let position = HUDDockPosition(edge: run.edge)
        let s = style.fitted(groups: run.groups, position: position,
                             span: CGSize(width: bounds.width + 0.001, height: bounds.height + 0.001))
        effectiveStyle = s
        var p = s.run(groups: run.groups, in: bounds, edge: run.edge)
        // Centre the run along the strip when it is shorter than the bounds.
        let horizontal = HUDDockAxis(edge: run.edge) == .horizontal
        let slack = ((horizontal ? bounds.width : bounds.height) - s.runLength(groups: run.groups)) / 2
        if slack > 0 {
            let d = horizontal ? CGVector(dx: slack, dy: 0) : CGVector(dx: 0, dy: -slack)
            p.items = p.items.map { $0.offsetBy(dx: d.dx, dy: d.dy) }
            p.dividers = p.dividers.map { $0.offsetBy(dx: d.dx, dy: d.dy) }
        }
        place(items: tiles.map(\.item), placement: p)
    }

    private func syncTiles(_ items: [HUDDockItem]) {
        if tiles.map(\.item.id) == items.map(\.id) {
            for (tile, item) in zip(tiles, items) where tile.item != item { tile.item = item }
            return
        }
        let old = Dictionary(tiles.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = items.map { item -> HUDDockTile in
            if let t = old[item.id] { t.item = item; return t }
            let t = HUDDockTile(item: item, style: effectiveStyle)
            t.strip = self
            return t
        }
        let keep = Set(next.map(ObjectIdentifier.init))
        for t in tiles where !keep.contains(ObjectIdentifier(t)) {
            t.removeFromSuperview()
            t.badgeView.removeFromSuperview()
            if hoveredTile === t { hoveredTile = nil; tileHoverChanged() }
        }
        tiles = next
        for t in tiles {
            if t.superview !== self { addSubview(t, positioned: .below, relativeTo: overlay) }
            if t.badgeView.superview !== self { addSubview(t.badgeView, positioned: .above, relativeTo: overlay) }
        }
    }

    private func place(items: [HUDDockItem], placement p: HUDDockPlacement) {
        syncTiles(items)
        placement = p
        for (i, tile) in tiles.enumerated() {
            guard p.items.indices.contains(i) else { tile.isHidden = true; tile.badgeView.isHidden = true; continue }
            tile.isHidden = false
            tile.style = effectiveStyle
            tile.edge = p.itemEdges[i]
            tile.magnify = magnify
            tile.frame = p.items[i]
            tile.indicatorRect = effectiveStyle.indicatorRect(for: p.items[i], edge: tile.edge)
            tile.resetIcon()
        }
        if let t = hoveredTile, t.isHidden { hoveredTile = nil; tileHoverChanged() } else { updateLabel() }
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews = p.dividers.map { f in
            let line = HUDDockDivider(frame: f)
            line.alpha = effectiveStyle.dividerAlpha
            addSubview(line, positioned: .below, relativeTo: tiles.first ?? overlay)
            return line
        }
        applyShape()
        overlay.needsDisplay = true
    }

    /// Updates just the indicators (e.g. on a timer), keyed by item id.
    public func setIndicators(_ indicators: [String: HUDDockIndicator]) {
        for t in tiles { t.item.indicator = indicators[t.item.id] ?? .none }
        overlay.needsDisplay = true
    }

    public func tile(_ id: String) -> HUDDockTile? { tiles.first { $0.item.id == id } }

    fileprivate func indicatorsChanged() { overlay.needsDisplay = true }

    // MARK: Mouse

    /// How far (points) a press may move and still be a click; past it, the strip is dragged.
    nonisolated public static let dragThreshold: CGFloat = 4

    /// A press on the strip: where it started (screen coordinates), the window's origin then,
    /// the item it began on, and whether it has become a drag.
    private struct Press {
        var start: CGPoint
        var origin: CGPoint
        weak var tile: HUDDockTile?
        var dragging = false
    }
    private var press: Press?

    /// The strip is being dragged (a press moved past `dragThreshold`).
    public var isDragging: Bool { press?.dragging == true }

    /// The background drags the window (below), not AppKit's window-background move, so a
    /// press is a click until it moves and the end of the drag is known exactly.
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        beginPress(event, on: nil)
    }
    public override func mouseDragged(with event: NSEvent) { continuePress(event) }
    public override func mouseUp(with event: NSEvent) { endPress(event) }

    /// The pointer of `event` in screen coordinates.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func beginPress(_ event: NSEvent, on tile: HUDDockTile?) {
        guard let window else { return }
        press = Press(start: screenPoint(event), origin: window.frame.origin, tile: tile)
    }

    func continuePress(_ event: NSEvent) {
        guard var p = press, let window else { return }
        let point = screenPoint(event)
        let d = CGVector(dx: point.x - p.start.x, dy: point.y - p.start.y)
        if !p.dragging {
            guard hypot(d.dx, d.dy) > Self.dragThreshold else { return }
            p.dragging = true
            press = p
            p.tile?.cancelPress()
            dismissLabel()
            delegate?.dockStripDidBeginDrag(self)
        }
        window.setFrameOrigin(CGPoint(x: p.origin.x + d.dx, y: p.origin.y + d.dy))
    }

    /// Ends a press: a click on `tile` when it never became a drag (and the pointer is still
    /// on the tile), otherwise the end of the drag.
    func endPress(_ event: NSEvent) {
        guard let p = press else { return }
        press = nil
        let tile = p.tile
        tile?.cancelPress()
        guard p.dragging else {
            if let tile, tile.bounds.contains(tile.convert(event.locationInWindow, from: nil)) {
                dismissLabel()
                delegate?.dockStrip(self, didClick: tile.item, tile: tile)
            }
            return
        }
        defer {
            delegate?.dockStripDidEndDrag(self)
            // Hover reports resume with whatever is under the pointer now.
            hoveredTile = tiles.first { !$0.isHidden && $0.isHovering }
            tileHoverChanged()
        }
        guard let window, window.frame.origin != p.origin else { return }
        let point = screenPoint(event)
        let snap = Self.snap(point)
        delegate?.dockStrip(self, didDragTo: snap.position, at: point, on: snap.screen)
    }

    /// The position a drag released at `point` snaps to, and the screen it is on.
    public static func snap(_ point: CGPoint, screens: [NSScreen] = NSScreen.screens) -> (position: HUDDockPosition, screen: NSScreen?) {
        let screen = screens.first { $0.frame.contains(point) } ?? screens.first
        return (HUDDockPosition.nearest(to: point, in: screen?.visibleFrame ?? .zero), screen)
    }

    public override func menu(for event: NSEvent) -> NSMenu? { delegate?.dockStrip(self, menuFor: nil) }

    // MARK: Hover and labels

    /// The item under the pointer (as its tracking areas last said).
    public private(set) weak var hoveredTile: HUDDockTile?
    /// The item last reported through `dockStrip(_:didHover:)`.
    private var reportedHover: String?? = .some(nil)

    /// Show items' `label`s beside the strip (on by default).
    public var showsLabels = true { didSet { if !showsLabels { labelState = HUDDockLabelState(); hideLabel(animated: false) } } }
    /// The label machine: which item's label is due or showing.
    public private(set) var labelState = HUDDockLabelState()
    /// The id of the item whose label is on screen.
    public var shownLabel: String? { labelState.shown }
    /// The clock the label delay runs on.
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var labelTimer: Timer?
    private var labelWindow: HUDDockLabelWindow?

    func tileHover(_ tile: HUDDockTile, on: Bool) {
        if on { hoveredTile = tile } else if hoveredTile === tile { hoveredTile = nil }
        tileHoverChanged()
    }

    private func tileHoverChanged() {
        guard !isDragging else { return }
        let id = hoveredTile?.item.id
        if reportedHover != .some(id) {
            reportedHover = .some(id)
            delegate?.dockStrip(self, didHover: hoveredTile?.item)
        }
        updateLabel()
    }

    /// Feeds the hovered item (if it has a label) to the label machine.
    private func updateLabel() {
        guard showsLabels, !isDragging else { return }
        if let t = hoveredTile, t.item.label == nil || t.isHidden {
            run(labelState.exit())
        } else {
            run(labelState.hover(hoveredTile?.item.id, now: now()))
        }
        if let shown = labelState.shown, let t = self.tile(shown), let text = t.item.label {
            labelWindow?.update(text: text)  // a title change while it shows
            if let f = labelFrame(for: t, text: text), labelWindow?.frame != f { labelWindow?.move(to: f) }
        }
    }

    /// Hides the label (a click or a drag) until the pointer moves to another item.
    private func dismissLabel() { run(labelState.dismiss()) }

    private func run(_ actions: [HUDDockLabelState.Action]) {
        for action in actions {
            switch action {
            case .show(let id), .move(let id):
                guard let t = tile(id), let text = t.item.label, let f = labelFrame(for: t, text: text) else { continue }
                let w = labelWindow ?? HUDDockLabelWindow()
                labelWindow = w
                w.level = window?.level ?? .floating
                w.update(text: text)
                if case .show = action { w.show(at: f) } else { w.move(to: f) }
            case .hide:
                hideLabel(animated: true)
            }
        }
        scheduleLabel()
    }

    private func hideLabel(animated: Bool) { labelWindow?.hide(animated: animated) }

    private func scheduleLabel() {
        labelTimer?.invalidate()
        labelTimer = nil
        guard let deadline = labelState.deadline else { return }
        let t = Timer(timeInterval: max(0, deadline - now()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.run(self.labelState.fire(now: self.now()))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        labelTimer = t
    }

    /// Fires a due label now (tests; the timer does this otherwise).
    public func fireLabel(now t: TimeInterval) { run(labelState.fire(now: t)) }

    /// Where `tile`'s label goes on screen, or nil when the strip is not in a window.
    public func labelFrame(for tile: HUDDockTile, text: String) -> CGRect? {
        guard let window else { return nil }
        let arm = placement.segments.first { $0.intersects(tile.frame) } ?? bounds
        let screenRect = { (r: CGRect) in window.convertToScreen(self.convert(r, to: nil)) }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        return Self.labelFrame(size: HUDDockLabelWindow.size(for: text), tile: screenRect(tile.frame),
                               arm: screenRect(arm), edge: tile.edge, visible: visible)
    }

    /// The gap between the strip and its labels.
    nonisolated public static let labelGap: CGFloat = 6

    /// A label of `size` for an item at `tile` on an `arm` of the strip against `edge` (all
    /// screen coordinates): just outside the arm on the side away from the edge (below a
    /// top strip, above a bottom one, right of a left one, left of a right one), centred on
    /// the item, kept inside `visible`.
    public static func labelFrame(size: CGSize, tile: CGRect, arm: CGRect, edge: HUDEdge, visible: CGRect,
                                  gap: CGFloat = labelGap) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: tile.midX - size.width / 2, y: arm.minY - gap - size.height)
        case .bottom: origin = CGPoint(x: tile.midX - size.width / 2, y: arm.maxY + gap)
        case .left: origin = CGPoint(x: arm.maxX + gap, y: tile.midY - size.height / 2)
        case .right: origin = CGPoint(x: arm.minX - gap - size.width, y: tile.midY - size.height / 2)
        }
        if !visible.isInfinite {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return CGRect(origin: origin, size: size).integral
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            labelState = HUDDockLabelState()
            labelTimer?.invalidate()
            hideLabel(animated: false)
        }
    }

    /// The strip hid: no label.
    public override func viewDidHide() {
        super.viewDidHide()
        run(labelState.exit())
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// The pointer left the strip: the label goes at once (between items it waits).
    public override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        run(labelState.exit())
    }

    // MARK: Snapshot

    /// The strip drawn into a bitmap for `--snapshot`s and comparisons. Glass blurs what is
    /// behind the window, which a view cache cannot capture, so the slab is `backdrop` (a dark
    /// stand-in by default) inside the outline, then the dividers, tiles, badges and
    /// indicators, then the border.
    public func snapshot(scale: CGFloat? = nil, backdrop fill: NSColor = NSColor(calibratedWhite: 0.13, alpha: 1)) -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        let k = scale ?? window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * k).rounded()),
                                         pixelsHigh: Int((size.height * k).rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let path = outline
        cg.addPath(path)
        cg.setFillColor(fill.cgColor)
        cg.fillPath()
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        for line in dividerViews {
            NSColor.labelColor.withAlphaComponent(effectiveStyle.dividerAlpha).setFill()
            line.frame.fill()
        }
        for tile in tiles where !tile.isHidden { tile.drawSnapshot(in: cg) }
        overlay.drawIndicators()
        for tile in tiles where !tile.isHidden && !tile.badgeView.isHidden {
            tile.badgeView.drawBadge(in: tile.badgeView.frame)
        }
        cg.restoreGState()
        cg.addPath(path)
        cg.setStrokeColor(borderColor.cgColor)
        cg.setLineWidth(style.borderWidth)
        cg.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes `snapshot()` as a PNG.
    @discardableResult
    public func writeSnapshot(to url: URL, scale: CGFloat? = nil) -> Bool {
        guard let data = snapshot(scale: scale)?.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - Tile

/// One item of a strip: an app icon, a symbol tile or a colour dot; a count badge at the
/// top-right; hover magnification away from the screen edge; dimmed while pressed; a wash
/// when highlighted and an accent wash with a ring while an accepted file drag is over it
/// (opening the item after `springDelay`). Items that take no files show "not allowed".
@MainActor
public final class HUDDockTile: NSView {
    /// What the icon shows.
    public enum Content: Equatable {
        /// The Finder icon of the file or app bundle at this path.
        case file(String)
        case image(NSImage)
        /// A Dock-sized tile (`symbolTile`) with an SF Symbol, white or in `tint`.
        case symbol(String, tint: NSColor? = nil)
        /// A Dock-sized tile with a glowing dot of this colour.
        case dot(NSColor)
        /// A MacHUD family icon tile (`glyphTile`: the dark squircle of `Icons/*.svg`) with an
        /// SF Symbol glowing in `color`, so a strip's own items sit among app icons.
        case glyph(String, color: NSColor)

        public static func == (a: Content, b: Content) -> Bool {
            switch (a, b) {
            case let (.file(x), .file(y)): return x == y
            case let (.image(x), .image(y)): return x === y
            case let (.symbol(x, s), .symbol(y, t)): return x == y && s == t
            case let (.dot(x), .dot(y)): return x == y
            case let (.glyph(x, s), .glyph(y, t)): return x == y && s == t
            default: return false
            }
        }
    }

    public static let springDelay: TimeInterval = 0.4

    public internal(set) var item: HUDDockItem {
        didSet {
            if item.content != oldValue.content { icon.image = Self.image(for: item.content) }
            if item.title != oldValue.title || item.label != oldValue.label { updateToolTip() }
            if item.badge != oldValue.badge { updateBadge() }
            if item.dimmed != oldValue.dimmed || item.highlighted != oldValue.highlighted { updateAlpha(); needsDisplay = true }
            if item.indicator != oldValue.indicator { strip?.indicatorsChanged() }
        }
    }
    public internal(set) var style: HUDDockStyle { didSet { if style.itemSize != oldValue.itemSize { updateBadge() } } }
    /// The screen edge this tile's arm is against.
    public internal(set) var edge: HUDEdge = .bottom
    public internal(set) var magnify = true
    /// The indicator dot, in the strip's coordinates (it lives in the strip's padding).
    public internal(set) var indicatorRect: CGRect = .zero
    /// The badge, a sibling in the strip (it overhangs the tile).
    public let badgeView = HUDDockBadgeView()
    weak var strip: HUDDockStripView?

    private let icon = NSImageView()
    public private(set) var isHovering = false
    public private(set) var isPressed = false { didSet { updateAlpha() } }
    public private(set) var isDropTarget = false { didSet { needsDisplay = true } }
    private var spring: Timer?

    init(item: HUDDockItem, style: HUDDockStyle) {
        self.item = item
        self.style = style
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = Self.image(for: item.content)
        icon.unregisterDraggedTypes()
        addSubview(icon)
        updateToolTip()
        setAccessibilityRole(.button)
        registerForDraggedTypes([.fileURL])
        updateAlpha()
        updateBadge()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The native tooltip is the title, for items without a hover label (which replaces it).
    private func updateToolTip() {
        toolTip = item.label == nil ? item.title : nil
        setAccessibilityLabel(item.title)
    }

    /// The icon's frame now (grown while hovered), in the tile's coordinates.
    public var iconFrame: CGRect { icon.frame }

    private func updateAlpha() {
        icon.alphaValue = (isPressed ? style.pressedAlpha : 1) * (item.dimmed ? 0.45 : 1)
    }

    public static func image(for content: Content) -> NSImage {
        switch content {
        case .file(let path): return NSWorkspace.shared.icon(forFile: path)
        case .image(let image): return image
        case .symbol(let name, let tint): return symbolTile(name, tint: tint)
        case .dot(let color): return dotTile(color)
        case .glyph(let name, let color): return glyphTile(name, color: color)
        }
    }

    /// The tile behind symbol and dot items: the Dock's rounded square in a slate gradient.
    private static func drawTileBackground(_ rect: CGRect) {
        let side = rect.width
        let tile = rect.insetBy(dx: side * 0.09, dy: side * 0.09)
        let path = NSBezierPath(roundedRect: tile, xRadius: side * 0.2, yRadius: side * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.47, alpha: 1),
                   ending: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1))?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    /// A Dock-sized rounded tile with a symbol in white (or `tint`), for items without an
    /// app icon.
    public static func symbolTile(_ symbol: String, tint: NSColor? = nil) -> NSImage {
        let side: CGFloat = 128
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            drawTileBackground(rect)
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.36, weight: .medium)) {
                let tinted = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    (tint ?? .white).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let s = tinted.size
                tinted.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// The MacHUD family icon (see HUDKit's `Icons/README.md`) with an SF Symbol for its
    /// glyph: a dark squircle with a light rim and an accent wash, the glyph in `color` over
    /// a soft glow of it.
    public static func glyphTile(_ symbol: String, color: NSColor) -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            let k = side / 1024
            let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let path = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
            NSGraphicsContext.saveGraphicsState()
            let drop = NSShadow()
            drop.shadowColor = NSColor.black.withAlphaComponent(0.45)
            drop.shadowOffset = NSSize(width: 0, height: -12 * k)
            drop.shadowBlurRadius = 28 * k
            drop.set()
            NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.094, alpha: 1).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(calibratedRed: 0.114, green: 0.133, blue: 0.165, alpha: 1),
                       ending: NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.094, alpha: 1))?.draw(in: path, angle: -90)
            NSGradient(colors: [color.withAlphaComponent(0.10), color.withAlphaComponent(0)])?
                .draw(in: path, relativeCenterPosition: .zero)
            // The rim, as the system draws it round an app icon: a light hairline, brightest
            // at the top.
            NSGraphicsContext.saveGraphicsState()
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 5 * k, dy: 5 * k), cornerWidth: 180 * k, cornerHeight: 180 * k,
                                  transform: nil))
                cg.setLineWidth(10 * k)
                cg.replacePathWithStrokedPath()
                cg.clip()
                NSGradient(starting: NSColor.white.withAlphaComponent(0.34), ending: NSColor.white.withAlphaComponent(0.16))?
                    .draw(in: tile, angle: -90)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.40, weight: .semibold)) {
                let tinted = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    color.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let s = tinted.size
                let at = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = color.withAlphaComponent(0.5)
                glow.shadowBlurRadius = 26 * k
                glow.set()
                tinted.draw(in: at)
                NSGraphicsContext.restoreGraphicsState()
                tinted.draw(in: at)
            }
            return true
        }
    }

    /// A Dock-sized rounded tile with a glowing dot of `color`.
    public static func dotTile(_ color: NSColor) -> NSImage {
        let side: CGFloat = 128
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            drawTileBackground(rect)
            let d = side * 0.26
            let dot = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.8)
            glow.shadowBlurRadius = side * 0.08
            glow.set()
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Back to the resting (or, while hovered, grown) icon; follows a new frame.
    func resetIcon() {
        icon.frame = isHovering && magnify ? style.magnified(bounds, edge: edge) : bounds
        placeBadge(animated: false)
    }

    private func updateBadge() {
        badgeView.style = style
        badgeView.text = item.badge.flatMap { $0 > 0 ? ($0 > 99 ? "99+" : "\($0)") : nil }
        placeBadge(animated: false)
    }

    /// The badge's frame in the strip for an icon frame (tile coordinates): its top-right
    /// just past the icon's top-right corner, like the Dock's.
    private func badgeFrame(forIcon f: CGRect) -> CGRect {
        let size = badgeView.fittingSize
        let r = convert(f, to: superview)
        let over = size.height * 0.2
        return CGRect(x: r.maxX + over - size.width, y: r.maxY + over - size.height, width: size.width, height: size.height)
    }

    private func placeBadge(animated: Bool, icon target: CGRect? = nil) {
        badgeView.isHidden = badgeView.text == nil || isHidden
        guard superview != nil else { return }
        let f = badgeFrame(forIcon: target ?? icon.frame)
        if animated { badgeView.animator().frame = f } else { badgeView.frame = f }
    }

    public override var isHidden: Bool { didSet { badgeView.isHidden = isHidden || badgeView.text == nil } }

    public override func draw(_ dirtyRect: NSRect) {
        drawWash()
    }

    private func drawWash() {
        guard isDropTarget || item.highlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: style.highlightRadius,
                                yRadius: style.highlightRadius)
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            path.fill()
        }
    }

    /// Draws the tile (wash and icon) at its place in the strip, for `HUDDockStripView.snapshot`.
    func drawSnapshot(in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: frame.minX, y: frame.minY)
        drawWash()
        icon.image?.draw(in: icon.frame, from: .zero, operation: .sourceOver, fraction: icon.alphaValue)
        cg.restoreGState()
    }

    // MARK: Mouse

    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { setHovering(true) }
    public override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ on: Bool) {
        guard on != isHovering else { return }
        isHovering = on
        strip?.tileHover(self, on: on)
        guard magnify else { return }
        let target = on ? style.magnified(bounds, edge: edge) : bounds
        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.magnifyDuration
            context.allowsImplicitAnimation = true
            icon.animator().frame = target
            placeBadge(animated: true, icon: target)
        }
    }

    /// A press here is the strip's: a click on this item unless it moves far enough to drag
    /// the strip (`HUDDockStripView.dragThreshold`).
    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        strip?.beginPress(event, on: self)
    }

    public override func mouseDragged(with event: NSEvent) { strip?.continuePress(event) }

    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        strip?.endPress(event)
    }

    func cancelPress() { isPressed = false }

    public override func rightMouseDown(with event: NSEvent) {
        guard let strip else { return }
        strip.delegate?.dockStrip(strip, didRightClick: item, tile: self, event: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    // MARK: File drops

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        let urls = fileURLs(info)
        guard item.acceptsDrop, !urls.isEmpty else { return false }
        guard let strip, let delegate = strip.delegate else { return true }
        return delegate.dockStrip(strip, validateDrop: urls, on: item)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else {
            NSCursor.operationNotAllowed.set()
            return []
        }
        isDropTarget = true
        spring?.invalidate()
        let t = Timer(timeInterval: Self.springDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let strip = self.strip else { return }
                strip.delegate?.dockStrip(strip, springLoad: self.item)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        spring = t
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else {
            NSCursor.operationNotAllowed.set()
            return []
        }
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) { endDrag() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { endDrag() }

    private func endDrag() {
        spring?.invalidate()
        spring = nil
        isDropTarget = false
        NSCursor.arrow.set()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        let ok = accepts(sender)
        endDrag()
        guard ok, let strip else { return false }
        strip.delegate?.dockStrip(strip, didDrop: urls, on: item, copy: NSEvent.modifierFlags.contains(.option))
        return true
    }
}

// MARK: - Badge

/// A count badge: white bold digits on a red capsule, sized from the icon, as the Dock
/// draws them.
@MainActor
public final class HUDDockBadgeView: NSView {
    public var text: String? { didSet { if text != oldValue { needsDisplay = true } } }
    public var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    var style: HUDDockStyle = .standard { didSet { needsDisplay = true } }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var height: CGFloat { (style.itemSize * 0.4).rounded() }
    private var font: NSFont { .systemFont(ofSize: (style.itemSize * 0.27).rounded(), weight: .semibold) }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text ?? "", attributes: [.font: font, .foregroundColor: NSColor.white])
    }

    public override var fittingSize: NSSize {
        guard text != nil else { return .zero }
        let h = height
        return NSSize(width: max(h, (attributed.size().width + h * 0.6).rounded()), height: h)
    }

    public override func draw(_ dirtyRect: NSRect) { drawBadge(in: bounds) }

    func drawBadge(in rect: CGRect) {
        guard text != nil, rect.width > 0 else { return }
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let s = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
    }
}

// MARK: - Pieces

/// Draws the indicator dots, above the glass and beside the tiles.
private final class HUDDockOverlayView: NSView {
    weak var strip: HUDDockStripView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawIndicators() }

    @MainActor func drawIndicators() {
        for t in strip?.tiles ?? [] where !t.isHidden && t.item.indicator != .none {
            let color: NSColor = t.item.indicator == .visible ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.6)
            color.setFill()
            NSBezierPath(ovalIn: t.indicatorRect).fill()
        }
    }
}

/// The thin rule between groups.
private final class HUDDockDivider: NSView {
    var alpha: CGFloat = 0.25
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        bounds.fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class HUDDockPassthroughEffect: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if compiler(>=6.2)
@available(macOS 26, *)
private final class HUDDockPassthroughGlass: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

// MARK: - SwiftUI

/// A `HUDDockStripView` in SwiftUI: a straight run of `items` in `groups` against `edge`,
/// filling the frame it is given. The callbacks stand in for the delegate.
public struct HUDDockStrip: NSViewRepresentable {
    public var items: [HUDDockItem]
    public var groups: [Int]
    public var edge: HUDEdge
    public var style: HUDDockStyle
    public var magnify: Bool
    public var onClick: (HUDDockItem, HUDDockTile) -> Void
    /// Context menu for an item, or the background (nil).
    public var menu: (HUDDockItem?) -> NSMenu?
    public var validateDrop: ([URL], HUDDockItem) -> Bool
    public var onDrop: ([URL], HUDDockItem, _ copy: Bool) -> Void
    public var onDragEnd: (HUDDockPosition, CGPoint, NSScreen?) -> Void
    /// A press became a drag (`HUDDockStripDelegate.dockStripDidBeginDrag`).
    public var onDragBegin: () -> Void

    public init(items: [HUDDockItem], groups: [Int], edge: HUDEdge, style: HUDDockStyle = .standard,
                magnify: Bool = true,
                onClick: @escaping (HUDDockItem, HUDDockTile) -> Void = { _, _ in },
                menu: @escaping (HUDDockItem?) -> NSMenu? = { _ in nil },
                validateDrop: @escaping ([URL], HUDDockItem) -> Bool = { _, _ in true },
                onDrop: @escaping ([URL], HUDDockItem, Bool) -> Void = { _, _, _ in },
                onDragBegin: @escaping () -> Void = {},
                onDragEnd: @escaping (HUDDockPosition, CGPoint, NSScreen?) -> Void = { _, _, _ in }) {
        self.items = items
        self.groups = groups
        self.edge = edge
        self.style = style
        self.magnify = magnify
        self.onClick = onClick
        self.menu = menu
        self.validateDrop = validateDrop
        self.onDrop = onDrop
        self.onDragBegin = onDragBegin
        self.onDragEnd = onDragEnd
    }

    @MainActor
    public final class Coordinator: HUDDockStripDelegate {
        var parent: HUDDockStrip
        init(_ parent: HUDDockStrip) { self.parent = parent }

        public func dockStrip(_ strip: HUDDockStripView, didClick item: HUDDockItem, tile: HUDDockTile) {
            parent.onClick(item, tile)
        }
        public func dockStrip(_ strip: HUDDockStripView, menuFor item: HUDDockItem?) -> NSMenu? { parent.menu(item) }
        public func dockStrip(_ strip: HUDDockStripView, validateDrop urls: [URL], on item: HUDDockItem) -> Bool {
            parent.validateDrop(urls, item)
        }
        public func dockStrip(_ strip: HUDDockStripView, didDrop urls: [URL], on item: HUDDockItem, copy: Bool) {
            parent.onDrop(urls, item, copy)
        }
        public func dockStripDidBeginDrag(_ strip: HUDDockStripView) { parent.onDragBegin() }
        public func dockStrip(_ strip: HUDDockStripView, didDragTo position: HUDDockPosition, at point: CGPoint,
                              on screen: NSScreen?) {
            parent.onDragEnd(position, point, screen)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> HUDDockStripView {
        let view = HUDDockStripView(style: style)
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: HUDDockStripView, context: Context) {
        context.coordinator.parent = self
        view.style = style
        view.magnify = magnify
        view.apply(items: items, groups: groups, edge: edge)
    }
}
