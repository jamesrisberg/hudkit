import AppKit

/// The look of a dock strip (`HUDDockStripView`): the MacHUD tool dock's chrome, measured
/// from it and shared so every strip in the family (Sift's dock mode, …) is the same object.
///
/// Sizes derive from `itemSize` the way the tool dock scales them (so a strip that shrinks
/// its icons to fit keeps its proportions): 44 pt icons give 10 pt padding, 6 pt spacing and
/// a 64 pt thick strip.
public struct HUDDockStyle: Equatable, Sendable {
    /// Icon (tile) side.
    public var itemSize: CGFloat
    /// Padding around the icons, as a fraction of `itemSize` (rounded): the indicator dot
    /// lives in it.
    public var paddingRatio: CGFloat
    /// Space between neighbouring icons, as a fraction of `itemSize` (rounded).
    public var spacingRatio: CGFloat
    /// Continuous corner radius of the slab (and of each arm of an L).
    public var cornerRadius: CGFloat
    /// Hairline border: width and white/black alpha in dark/light appearance.
    public var borderWidth: CGFloat
    public var borderAlphaDark: CGFloat
    public var borderAlphaLight: CGFloat
    /// How far the icon under the pointer grows (away from the screen edge), and how fast.
    public var magnification: CGFloat
    public var magnifyDuration: TimeInterval
    /// Diameter of the indicator dot on the screen-edge side of an icon.
    public var indicatorSize: CGFloat
    /// Opacity of the divider between groups (label colour).
    public var dividerAlpha: CGFloat
    /// Icon opacity while pressed.
    public var pressedAlpha: CGFloat
    /// Corner radius of the drop-target and highlight wash behind an icon.
    public var highlightRadius: CGFloat
    /// Backdrop before macOS 26 (on 26 it is Liquid Glass).
    public var fallbackMaterial: NSVisualEffectView.Material

    public init(itemSize: CGFloat = 44, paddingRatio: CGFloat = 0.23, spacingRatio: CGFloat = 0.14,
                cornerRadius: CGFloat = 18, borderWidth: CGFloat = 1, borderAlphaDark: CGFloat = 0.18,
                borderAlphaLight: CGFloat = 0.12, magnification: CGFloat = 1.15, magnifyDuration: TimeInterval = 0.12,
                indicatorSize: CGFloat = 4, dividerAlpha: CGFloat = 0.25, pressedAlpha: CGFloat = 0.6,
                highlightRadius: CGFloat = 10, fallbackMaterial: NSVisualEffectView.Material = .popover) {
        self.itemSize = itemSize
        self.paddingRatio = paddingRatio
        self.spacingRatio = spacingRatio
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderAlphaDark = borderAlphaDark
        self.borderAlphaLight = borderAlphaLight
        self.magnification = magnification
        self.magnifyDuration = magnifyDuration
        self.indicatorSize = indicatorSize
        self.dividerAlpha = dividerAlpha
        self.pressedAlpha = pressedAlpha
        self.highlightRadius = highlightRadius
        self.fallbackMaterial = fallbackMaterial
    }

    /// The MacHUD tool dock at its default 44 pt icons: the definition of the look.
    public static let standard = HUDDockStyle()

    /// This style with another icon size (padding, spacing and thickness follow).
    public func withItemSize(_ size: CGFloat) -> HUDDockStyle {
        var s = self
        s.itemSize = size
        return s
    }

    /// Space around the icons: 10 pt for 44 pt icons.
    public var padding: CGFloat { (itemSize * paddingRatio).rounded() }
    /// Between icons: 6 pt for 44 pt icons.
    public var spacing: CGFloat { (itemSize * spacingRatio).rounded() }
    /// Room a divider takes between two groups, on top of the spacing either side of it.
    public var dividerRoom: CGFloat { spacing + 1 }
    /// Across the strip: 64 pt for 44 pt icons.
    public var thickness: CGFloat { itemSize + 2 * padding }
    /// How far a divider stops short of the strip's long sides.
    public var dividerInset: CGFloat { padding * 0.8 }

    // MARK: - One straight run

    /// Length of a straight run of `groups` (item counts), a divider between non-empty groups.
    public func runLength(groups: [Int]) -> CGFloat {
        let counts = groups.filter { $0 > 0 }
        let n = counts.reduce(0, +)
        guard n > 0 else { return thickness }
        let dividers = CGFloat(counts.count - 1)
        return 2 * padding + CGFloat(n) * itemSize + CGFloat(n - 1) * spacing + dividers * (dividerRoom + spacing)
    }

    /// Where each item starts, measured along the run from its start.
    public func itemOffsets(groups: [Int]) -> [CGFloat] {
        var out: [CGFloat] = []
        var along = padding
        var first = true
        for count in groups where count > 0 {
            if !first { along += dividerRoom + spacing }
            first = false
            for _ in 0..<count {
                out.append(along)
                along += itemSize + spacing
            }
        }
        return out
    }

    /// Where each divider's 1 pt line starts, measured along the run from its start.
    public func dividerOffsets(groups: [Int]) -> [CGFloat] {
        var out: [CGFloat] = []
        var along = padding
        let counts = groups.filter { $0 > 0 }
        for (i, count) in counts.enumerated() {
            along += CGFloat(count) * itemSize + CGFloat(count - 1) * spacing
            guard i < counts.count - 1 else { break }
            out.append(along + (dividerRoom + 2 * spacing) / 2 - 0.5)
            along += dividerRoom + 2 * spacing
        }
        return out
    }

    /// The end of an arm a run is measured from.
    public enum RunStart: Sendable { case left, right, top, bottom }

    /// An icon cell `along` points into `arm` from `start`, centred across the arm.
    public func cell(along d: CGFloat, in arm: CGRect, from start: RunStart) -> CGRect {
        let s = itemSize
        switch start {
        case .left: return CGRect(x: arm.minX + d, y: arm.midY - s / 2, width: s, height: s)
        case .right: return CGRect(x: arm.maxX - d - s, y: arm.midY - s / 2, width: s, height: s)
        case .top: return CGRect(x: arm.midX - s / 2, y: arm.maxY - d - s, width: s, height: s)
        case .bottom: return CGRect(x: arm.midX - s / 2, y: arm.minY + d, width: s, height: s)
        }
    }

    /// A 1 pt divider across `arm`, `along` points from `start`.
    public func divider(along c: CGFloat, in arm: CGRect, from start: RunStart) -> CGRect {
        let inset = dividerInset
        switch start {
        case .left: return CGRect(x: arm.minX + c, y: arm.minY + inset, width: 1, height: arm.height - 2 * inset)
        case .right: return CGRect(x: arm.maxX - c - 1, y: arm.minY + inset, width: 1, height: arm.height - 2 * inset)
        case .top: return CGRect(x: arm.minX + inset, y: arm.maxY - c - 1, width: arm.width - 2 * inset, height: 1)
        case .bottom: return CGRect(x: arm.minX + inset, y: arm.minY + c, width: arm.width - 2 * inset, height: 1)
        }
    }

    /// A straight strip filling `arm` against `edge`: `groups` run left to right (top to
    /// bottom on a side), dividers between them. For a strip laid out in its own bounds.
    public func run(groups: [Int], in arm: CGRect, edge: HUDEdge) -> HUDDockPlacement {
        let start: RunStart = HUDDockAxis(edge: edge) == .horizontal ? .left : .top
        let items = itemOffsets(groups: groups).map { cell(along: $0, in: arm, from: start) }
        return HUDDockPlacement(frame: arm, segments: [arm], items: items,
                                itemEdges: Array(repeating: edge, count: items.count),
                                dividers: dividerOffsets(groups: groups).map { divider(along: $0, in: arm, from: start) })
    }

    /// The strip at `position` inside `visible` (less `insets`), in screen coordinates.
    ///
    /// At an edge position it is one row or column of `groups`, centred on that edge. In a
    /// corner it is an L (`HUDDockLayout.lShape`): the first group runs along the vertical
    /// arm starting in the corner, the others along the horizontal arm starting just past
    /// the corner, a divider first. With only one non-empty group the L is just that
    /// group's arm (vertical for the first group).
    public func placement(groups: [Int], position: HUDDockPosition, insets: NSEdgeInsets = NSEdgeInsets(),
                          in visible: CGRect) -> HUDDockPlacement {
        guard position.isCorner else {
            let edge = position.edges[0]
            let arm = HUDDockLayout.frame(for: position, thickness: thickness, length: runLength(groups: groups),
                                          insets: insets, in: visible)
            return run(groups: groups, in: arm, edge: edge)
        }
        let first = groups.first ?? 0
        let rest = Array(groups.dropFirst())
        let restCount = rest.reduce(0, +)
        let hEdge = position.edges[0], vEdge = position.edges[1]
        let vStart: RunStart = hEdge == .top ? .top : .bottom
        let hStart: RunStart = vEdge == .left ? .left : .right
        if first > 0, restCount > 0 {
            // Folded: the first group's first item sits in the corner, the rest run up or
            // down the vertical arm; a divider and the other groups run along the other.
            let across = [1] + rest
            let l = HUDDockLayout.lShape(position: position, thickness: thickness,
                                         verticalLength: runLength(groups: [first]),
                                         horizontalLength: runLength(groups: across), insets: insets, in: visible)
            let vItems = itemOffsets(groups: [first]).map { cell(along: $0, in: l.vertical, from: vStart) }
            let hItems = itemOffsets(groups: across).dropFirst().map { cell(along: $0, in: l.horizontal, from: hStart) }
            let dividers = dividerOffsets(groups: across).map { divider(along: $0, in: l.horizontal, from: hStart) }
            return HUDDockPlacement(frame: l.vertical.union(l.horizontal), segments: [l.vertical, l.horizontal],
                                    items: vItems + hItems,
                                    itemEdges: Array(repeating: vEdge, count: vItems.count)
                                        + Array(repeating: hEdge, count: hItems.count),
                                    dividers: dividers)
        }
        // One group (or none): just its arm, from the corner.
        let vertical = first > 0
        let arm = vertical ? [first] : rest
        let len = runLength(groups: arm)
        let l = HUDDockLayout.lShape(position: position, thickness: thickness,
                                     verticalLength: vertical ? len : thickness,
                                     horizontalLength: vertical ? thickness : len, insets: insets, in: visible)
        let seg = vertical ? l.vertical : l.horizontal
        let start = vertical ? vStart : hStart
        let items = itemOffsets(groups: arm).map { cell(along: $0, in: seg, from: start) }
        return HUDDockPlacement(frame: seg, segments: [seg], items: items,
                                itemEdges: Array(repeating: vertical ? vEdge : hEdge, count: items.count),
                                dividers: dividerOffsets(groups: arm).map { divider(along: $0, in: seg, from: start) })
    }

    /// The arms' lengths (vertical, horizontal) `placement` asks for, before clamping.
    public func armLengths(groups: [Int], position: HUDDockPosition) -> (vertical: CGFloat, horizontal: CGFloat) {
        guard position.isCorner else {
            let l = runLength(groups: groups)
            return HUDDockAxis(edge: position.edges[0]) == .horizontal ? (0, l) : (l, 0)
        }
        let first = groups.first ?? 0
        let rest = Array(groups.dropFirst())
        if first > 0, rest.reduce(0, +) > 0 { return (runLength(groups: [first]), runLength(groups: [1] + rest)) }
        return first > 0 ? (runLength(groups: [first]), 0) : (0, runLength(groups: rest))
    }

    /// This style with the icons shrunk (never grown, 2 pt at a time, down to `minItemSize`)
    /// until every arm of `groups` at `position` fits `span` (the room along each axis).
    public func fitted(groups: [Int], position: HUDDockPosition, span: CGSize, minItemSize: CGFloat = 16) -> HUDDockStyle {
        var s = self
        while s.itemSize > minItemSize {
            let arms = s.armLengths(groups: groups, position: position)
            guard arms.vertical > span.height || arms.horizontal > span.width else { break }
            s.itemSize -= 2
        }
        return s
    }

    // MARK: - Items

    /// The indicator dot's centre for an item: in the padding on the screen-edge side of
    /// its arm, as the Dock draws it.
    public func indicatorCentre(for item: CGRect, edge: HUDEdge) -> CGPoint {
        let d = padding / 2
        switch edge {
        case .bottom: return CGPoint(x: item.midX, y: item.minY - d)
        case .top: return CGPoint(x: item.midX, y: item.maxY + d)
        case .left: return CGPoint(x: item.minX - d, y: item.midY)
        case .right: return CGPoint(x: item.maxX + d, y: item.midY)
        }
    }

    /// The indicator dot's rect for an item.
    public func indicatorRect(for item: CGRect, edge: HUDEdge) -> CGRect {
        let c = indicatorCentre(for: item, edge: edge)
        let d = indicatorSize
        return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }

    /// An item grown by `scale` (default `magnification`) away from its screen edge; its
    /// edge side stays put.
    public func magnified(_ item: CGRect, edge: HUDEdge, scale: CGFloat? = nil) -> CGRect {
        let k = scale ?? magnification
        let w = item.width * k, h = item.height * k
        switch edge {
        case .bottom: return CGRect(x: item.midX - w / 2, y: item.minY, width: w, height: h)
        case .top: return CGRect(x: item.midX - w / 2, y: item.maxY - h, width: w, height: h)
        case .left: return CGRect(x: item.minX, y: item.midY - h / 2, width: w, height: h)
        case .right: return CGRect(x: item.maxX - w, y: item.midY - h / 2, width: w, height: h)
        }
    }

    /// The slab's outline: the union of `segments`, each a rounded rect (a pill, or an L
    /// with a square inner corner).
    public func outline(_ segments: [CGRect]) -> CGPath {
        let pills = segments.map { s -> CGPath in
            let radius = min(cornerRadius, s.width / 2, s.height / 2)
            return CGPath(roundedRect: s, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        guard let first = pills.first else { return CGMutablePath() }
        return pills.dropFirst().reduce(first) { $0.union($1) }
    }
}

/// A strip laid out: its arms, every item, the dividers. Screen or view coordinates.
public struct HUDDockPlacement: Equatable, Sendable {
    /// The arms' bounding box (the window).
    public var frame: CGRect
    /// One arm for an edge position or a one-group corner, two for an L (vertical first).
    public var segments: [CGRect]
    /// Each item's icon, in item order.
    public var items: [CGRect]
    /// The screen edge each item's arm lies against.
    public var itemEdges: [HUDEdge]
    /// 1 pt divider lines.
    public var dividers: [CGRect]

    public init(frame: CGRect, segments: [CGRect], items: [CGRect], itemEdges: [HUDEdge], dividers: [CGRect]) {
        self.frame = frame
        self.segments = segments
        self.items = items
        self.itemEdges = itemEdges
        self.dividers = dividers
    }

    /// An item's hit area: its icon grown across its arm and half the spacing along it, so
    /// the pointer never falls between items.
    public func slot(_ i: Int) -> CGRect? {
        guard items.indices.contains(i), let arm = arm(for: i) else { return nil }
        let b = items[i]
        switch itemEdges[i] {
        case .top, .bottom: return CGRect(x: b.minX - 3, y: arm.minY, width: b.width + 6, height: arm.height)
        case .left, .right: return CGRect(x: arm.minX, y: b.minY - 3, width: arm.width, height: b.height + 6)
        }
    }

    /// The arm an item sits on: an L lists its vertical arm first.
    public func arm(for i: Int) -> CGRect? {
        guard itemEdges.indices.contains(i), !segments.isEmpty else { return nil }
        let vertical = itemEdges[i] == .left || itemEdges[i] == .right
        return segments.count > 1 ? (vertical ? segments[0] : segments[1]) : segments[0]
    }

    public func contains(_ point: CGPoint, slop: CGFloat = 2) -> Bool {
        segments.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// The same placement relative to its own frame (a window's content coordinates).
    public var local: HUDDockPlacement {
        let dx = -frame.minX, dy = -frame.minY
        return HUDDockPlacement(frame: CGRect(origin: .zero, size: frame.size),
                                segments: segments.map { $0.offsetBy(dx: dx, dy: dy) },
                                items: items.map { $0.offsetBy(dx: dx, dy: dy) }, itemEdges: itemEdges,
                                dividers: dividers.map { $0.offsetBy(dx: dx, dy: dy) })
    }
}
