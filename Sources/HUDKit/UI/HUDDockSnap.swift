import AppKit

/// Where a dock strip (the MacHUD dock, or a sibling strip such as Sift's dock mode) sits.
/// The four edge positions are a single row or column centred on that edge; the four corners
/// are an L whose two arms meet in the corner. Raw values are the strings used on the wire and
/// in `docks.json`.
public enum HUDDockPosition: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        case .top, .bottom, .left, .right: return false
        }
    }

    /// The screen edges the strip touches: one for an edge position, two for a corner
    /// (horizontal edge first, then the vertical one: `topLeft` → `[.top, .left]`).
    public var edges: [HUDEdge] {
        switch self {
        case .top: return [.top]
        case .bottom: return [.bottom]
        case .left: return [.left]
        case .right: return [.right]
        case .topLeft: return [.top, .left]
        case .topRight: return [.top, .right]
        case .bottomLeft: return [.bottom, .left]
        case .bottomRight: return [.bottom, .right]
        }
    }

    /// The position for a single edge.
    public init(edge: HUDEdge) {
        switch edge {
        case .top: self = .top
        case .bottom: self = .bottom
        case .left: self = .left
        case .right: self = .right
        }
    }

    /// The corner where `horizontal` (top/bottom) meets `vertical` (left/right); nil for two
    /// edges on the same axis.
    public init?(corner horizontal: HUDEdge, _ vertical: HUDEdge) {
        switch (horizontal, vertical) {
        case (.top, .left), (.left, .top): self = .topLeft
        case (.top, .right), (.right, .top): self = .topRight
        case (.bottom, .left), (.left, .bottom): self = .bottomLeft
        case (.bottom, .right), (.right, .bottom): self = .bottomRight
        default: return nil
        }
    }

    /// Fraction of an edge's length, measured from each end, that belongs to the corner.
    public static let cornerSectorFraction: CGFloat = 0.25

    /// The snap position for a drag at `point` inside `visible` (AppKit coordinates).
    ///
    /// The rectangle is split into four sectors by its diagonals (so the answer does not
    /// depend on the screen's aspect ratio); the sector picks the edge. Within 25% of that
    /// edge's length from either end the position is the corner instead. Points outside
    /// `visible` are clamped onto it first.
    public static func nearest(to point: CGPoint, in visible: CGRect) -> HUDDockPosition {
        guard visible.width > 0, visible.height > 0 else { return .bottom }
        let x = min(max(point.x, visible.minX), visible.maxX)
        let y = min(max(point.y, visible.minY), visible.maxY)
        let fx = (x - visible.minX) / visible.width   // 0 = left, 1 = right
        let fy = (y - visible.minY) / visible.height  // 0 = bottom, 1 = top
        let u = fx * 2 - 1, v = fy * 2 - 1
        let edge: HUDEdge = abs(u) >= abs(v) ? (u < 0 ? .left : .right) : (v < 0 ? .bottom : .top)
        let along = (edge == .top || edge == .bottom) ? fx : fy
        let low = along < cornerSectorFraction, high = along > 1 - cornerSectorFraction
        guard low || high else { return HUDDockPosition(edge: edge) }
        switch edge {
        case .top: return low ? .topLeft : .topRight
        case .bottom: return low ? .bottomLeft : .bottomRight
        case .left: return low ? .bottomLeft : .topLeft
        case .right: return low ? .bottomRight : .topRight
        }
    }
}

/// The axis a strip (or one arm of an L) runs along.
public enum HUDDockAxis: String, Codable, Sendable {
    case horizontal, vertical

    /// The axis a strip on `edge` runs along: top/bottom are horizontal.
    public init(edge: HUDEdge) { self = (edge == .top || edge == .bottom) ? .horizontal : .vertical }
}

/// Where items pack inside an arm. `leading` is the left end of a horizontal arm and the
/// top end of a vertical one (reading order); `trailing` the other end.
public enum HUDDockAlignment: String, Codable, Sendable {
    case leading, center, trailing
}

/// Dock strip geometry. Pure functions; all rects are AppKit screen coordinates (origin
/// bottom-left). `visible` is normally `NSScreen.visibleFrame`.
public enum HUDDockLayout {
    /// The strip's frame. For an edge position: `length` along the edge (centred, clamped to
    /// the space inside `insets`) by `thickness`, flush with the inset edge. For a corner: the
    /// bounding box of the L with both arms `length` long (use `lShape` for the arms).
    public static func frame(for position: HUDDockPosition, thickness: CGFloat, length: CGFloat,
                             insets: NSEdgeInsets = NSEdgeInsets(), in visible: CGRect) -> CGRect {
        let area = inset(visible, insets)
        if position.isCorner {
            let l = lShape(position: position, thickness: thickness, verticalLength: length,
                           horizontalLength: length, insets: insets, in: visible)
            return l.vertical.union(l.horizontal)
        }
        switch position {
        case .top, .bottom:
            let w = min(max(length, 0), area.width), h = min(thickness, area.height)
            let y = position == .top ? area.maxY - h : area.minY
            return CGRect(x: area.midX - w / 2, y: y, width: w, height: h)
        default:
            let h = min(max(length, 0), area.height), w = min(thickness, area.width)
            let x = position == .left ? area.minX : area.maxX - w
            return CGRect(x: x, y: area.midY - h / 2, width: w, height: h)
        }
    }

    /// The two arms of a corner (L) strip. `corner` is the `thickness`-square in the inset
    /// corner; both arms include it (the vertical arm is `verticalLength` tall, the horizontal
    /// one `horizontalLength` wide, each measured from the corner), so the arms intersect in
    /// exactly `corner`. Lengths are clamped to at least `thickness` and at most the inset area.
    /// For an edge position the arm along that edge is the strip and the other arm is `.zero`.
    public static func lShape(position: HUDDockPosition, thickness: CGFloat, verticalLength: CGFloat,
                              horizontalLength: CGFloat, insets: NSEdgeInsets = NSEdgeInsets(),
                              in visible: CGRect) -> (vertical: CGRect, horizontal: CGRect, corner: CGRect) {
        guard position.isCorner else {
            let axis = HUDDockAxis(edge: position.edges[0])
            let strip = frame(for: position, thickness: thickness,
                              length: axis == .horizontal ? horizontalLength : verticalLength,
                              insets: insets, in: visible)
            return axis == .horizontal ? (.zero, strip, .zero) : (strip, .zero, .zero)
        }
        let area = inset(visible, insets)
        let t = max(0, min(thickness, area.width, area.height))
        let vLen = min(max(verticalLength, t), area.height)
        let hLen = min(max(horizontalLength, t), area.width)
        let top = position == .topLeft || position == .topRight
        let left = position == .topLeft || position == .bottomLeft
        let cx = left ? area.minX : area.maxX - t
        let cy = top ? area.maxY - t : area.minY
        let corner = CGRect(x: cx, y: cy, width: t, height: t)
        let vertical = CGRect(x: cx, y: top ? area.maxY - vLen : area.minY, width: t, height: vLen)
        let horizontal = CGRect(x: left ? area.minX : area.maxX - hLen, y: cy, width: hLen, height: t)
        return (vertical, horizontal, corner)
    }

    /// Frames for `count` items of `itemSize` separated by `spacing`, laid out along `arm`
    /// and centred across it. Returned in reading order: left→right for a horizontal arm,
    /// top→bottom for a vertical one. Items that do not fit overflow past the arm's ends
    /// (callers decide whether to grow the arm or scroll).
    public static func itemFrames(count: Int, itemSize: CGSize, spacing: CGFloat, along arm: CGRect,
                                  axis: HUDDockAxis, alignment: HUDDockAlignment = .center) -> [CGRect] {
        guard count > 0 else { return [] }
        let step = (axis == .horizontal ? itemSize.width : itemSize.height) + spacing
        let run = step * CGFloat(count) - spacing
        let span = axis == .horizontal ? arm.width : arm.height
        let offset: CGFloat
        switch alignment {
        case .leading: offset = 0
        case .center: offset = (span - run) / 2
        case .trailing: offset = span - run
        }
        return (0..<count).map { i in
            let d = offset + CGFloat(i) * step
            switch axis {
            case .horizontal:
                return CGRect(x: arm.minX + d, y: arm.midY - itemSize.height / 2,
                              width: itemSize.width, height: itemSize.height)
            case .vertical:
                return CGRect(x: arm.midX - itemSize.width / 2, y: arm.maxY - d - itemSize.height,
                              width: itemSize.width, height: itemSize.height)
            }
        }
    }

    /// The alignment that packs an L arm's items against its corner (so a corner strip grows
    /// outward from the corner). `.center` for edge positions.
    public static func cornerAlignment(for position: HUDDockPosition, axis: HUDDockAxis) -> HUDDockAlignment {
        switch (position, axis) {
        case (.topLeft, _), (.topRight, .vertical), (.bottomLeft, .horizontal): return .leading
        case (.bottomRight, _), (.topRight, .horizontal), (.bottomLeft, .vertical): return .trailing
        default: return .center
        }
    }

    /// Where a panel of `size` goes when it slides out of the dock button at `anchor` on a
    /// strip against `edge`: just past the button on the side away from the edge, centred on
    /// the button along the edge, `gap` points clear, and kept inside `visible`.
    public static func panelFrame(size: CGSize, anchor: CGRect, from edge: HUDEdge, gap: CGFloat = 8,
                                  in visible: CGRect) -> CGRect {
        var f = CGRect(origin: .zero, size: size)
        switch edge {
        case .top: f.origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        case .bottom: f.origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .left: f.origin = CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right: f.origin = CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        return HUDParking.restFrame(for: f, in: visible)
    }

    /// Where a panel of `size` goes when it slides out of the dock button at `anchor` on the
    /// arm against `edge`, never covering any of `dockFrames` (the strip's arms; for a corner
    /// both arms of the L).
    ///
    /// The panel starts `gap` past the far side of the anchor's arm (the dock frame running
    /// along `edge` level with the anchor), centred on the anchor along `edge`. Any other dock frame
    /// it would reach (for a corner, the other arm) bounds it along `edge` on that frame's
    /// open side, `gap` clear: for `topLeft` the panel sits right of the vertical arm and
    /// below the horizontal one, in the crook of the L. The panel is then slid (and, only
    /// if the room is too small, shrunk) to stay inside that room and `visible`.
    public static func panelFrame(size: CGSize, anchor: CGRect, dockFrames: [CGRect], from edge: HUDEdge,
                                  gap: CGFloat = 8, in visible: CGRect) -> CGRect {
        let docks = dockFrames.filter { !$0.isNull && !$0.isEmpty }
        let alongX = edge == .top || edge == .bottom  // the panel's free axis
        // The anchor's own arm: runs along `edge` and is level with the anchor. (A corner's
        // other arm also covers the corner button, but runs across `edge`.)
        func isAnchorArm(_ d: CGRect) -> Bool {
            alongX ? (d.width >= d.height && d.maxX > anchor.minX && d.minX < anchor.maxX)
                   : (d.height >= d.width && d.maxY > anchor.minY && d.minY < anchor.maxY)
        }
        // Across the edge: past the anchor and its arm.
        let level = docks.filter(isAnchorArm)
        var room = visible
        switch edge {
        case .left:
            let x = level.map(\.maxX).reduce(anchor.maxX, max) + gap
            room = CGRect(x: x, y: room.minY, width: room.maxX - x, height: room.height)
        case .right:
            let x = level.map(\.minX).reduce(anchor.minX, min) - gap
            room = CGRect(x: room.minX, y: room.minY, width: x - room.minX, height: room.height)
        case .bottom:
            let y = level.map(\.maxY).reduce(anchor.maxY, max) + gap
            room = CGRect(x: room.minX, y: y, width: room.width, height: room.maxY - y)
        case .top:
            let y = level.map(\.minY).reduce(anchor.minY, min) - gap
            room = CGRect(x: room.minX, y: room.minY, width: room.width, height: y - room.minY)
        }
        // Along the edge: every other arm the room still reaches bounds it on its open side.
        for d in docks where !level.contains(d) && d.insetBy(dx: -gap, dy: -gap).intersects(room) {
            if alongX {
                let lo = min(max(room.minX, d.maxX + gap), room.maxX), hi = max(min(room.maxX, d.minX - gap), room.minX)
                if room.maxX - lo >= hi - room.minX {
                    room = CGRect(x: lo, y: room.minY, width: room.maxX - lo, height: room.height)
                } else {
                    room = CGRect(x: room.minX, y: room.minY, width: hi - room.minX, height: room.height)
                }
            } else {
                let lo = min(max(room.minY, d.maxY + gap), room.maxY), hi = max(min(room.maxY, d.minY - gap), room.minY)
                if room.maxY - lo >= hi - room.minY {
                    room = CGRect(x: room.minX, y: lo, width: room.width, height: room.maxY - lo)
                } else {
                    room = CGRect(x: room.minX, y: room.minY, width: room.width, height: hi - room.minY)
                }
            }
        }
        let w = max(1, min(size.width, room.width)), h = max(1, min(size.height, room.height))
        var origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: anchor.midX - w / 2, y: room.maxY - h)
        case .bottom: origin = CGPoint(x: anchor.midX - w / 2, y: room.minY)
        case .left: origin = CGPoint(x: room.minX, y: anchor.midY - h / 2)
        case .right: origin = CGPoint(x: room.maxX - w, y: anchor.midY - h / 2)
        }
        origin.x = min(max(origin.x, room.minX), room.maxX - w)
        origin.y = min(max(origin.y, room.minY), room.maxY - h)
        return CGRect(origin: origin, size: CGSize(width: w, height: h))
    }

    static func inset(_ r: CGRect, _ i: NSEdgeInsets) -> CGRect {
        CGRect(x: r.minX + i.left, y: r.minY + i.bottom,
               width: max(0, r.width - i.left - i.right), height: max(0, r.height - i.top - i.bottom))
    }
}

public extension HUDDockLayout {
    /// `frame` slid along `edge` (x for top/bottom, y for left/right) so it no longer overlaps
    /// any of `others` (typically the frames other strips published to `HUDDockRegistry`).
    ///
    /// Only frames that overlap `frame` across the edge's axis block it. If `frame` is already
    /// clear it is returned unchanged. Otherwise the nearest clear spot in each direction is
    /// found; the direction whose clear gap is larger wins (equal gaps: the shorter move).
    /// With `visible`, spots must stay inside it; if no clear spot exists, `frame` is returned
    /// unchanged. Without `visible`, both directions are unbounded and the shorter move wins.
    static func avoiding(frame: CGRect, others: [CGRect], along edge: HUDEdge,
                         in visible: CGRect? = nil) -> CGRect {
        let horizontal = HUDDockAxis(edge: edge) == .horizontal
        let eps: CGFloat = 0.001
        let p0 = horizontal ? frame.minX : frame.minY
        let length = horizontal ? frame.width : frame.height
        let crossLo = horizontal ? frame.minY : frame.minX, crossHi = horizontal ? frame.maxY : frame.maxX
        let blockers: [(a: CGFloat, b: CGFloat)] = others.compactMap { o in
            guard !o.isNull, !o.isEmpty else { return nil }
            let oLo = horizontal ? o.minY : o.minX, oHi = horizontal ? o.maxY : o.maxX
            guard min(crossHi, oHi) - max(crossLo, oLo) > eps else { return nil }
            return horizontal ? (o.minX, o.maxX) : (o.minY, o.maxY)
        }
        let lo = visible.map { horizontal ? $0.minX : $0.minY } ?? -.infinity
        let hi = visible.map { horizontal ? $0.maxX : $0.maxY } ?? .infinity
        func isFree(_ p: CGFloat) -> Bool {
            p >= lo - eps && p + length <= hi + eps && blockers.allSatisfy { p + length <= $0.a + eps || p >= $0.b - eps }
        }
        guard !isFree(p0) else { return frame }
        func room(at p: CGFloat) -> CGFloat {
            let start = blockers.map(\.b).filter { $0 <= p + eps }.reduce(lo, max)
            let end = blockers.map(\.a).filter { $0 >= p + length - eps }.reduce(hi, min)
            return end - start
        }
        let candidates = blockers.flatMap { [$0.a - length, $0.b] }.filter(isFree)
        let down = candidates.filter { $0 < p0 }.max()
        let up = candidates.filter { $0 > p0 }.min()
        let chosen: CGFloat?
        switch (down, up) {
        case let (d?, u?):
            let rd = room(at: d), ru = room(at: u)
            if abs(rd - ru) > eps { chosen = rd > ru ? d : u } else { chosen = (p0 - d) <= (u - p0) ? d : u }
        case let (d?, nil): chosen = d
        case let (nil, u?): chosen = u
        case (nil, nil): chosen = nil
        }
        guard let chosen else { return frame }
        var f = frame
        if horizontal { f.origin.x = chosen } else { f.origin.y = chosen }
        return f
    }
}
