import AppKit
import ObjectiveC
import QuartzCore

/// A backdrop whose edge fades out instead of ending in a line: a Gaussian blur of what is
/// behind the window, of the family's radius (25) unless `blurRadius` says otherwise, shown
/// through `field`, an alpha image stretched over the bounds. Any shape and any fade is one view
/// in one window (a radial menu's field: opaque in the middle, falling to clear at the rim).
/// `tint`, when set, is drawn over the blur through the same field. It never takes the mouse.
///
/// Put it under the content of a window that is not opaque, and keep `HUDGlassView` out of
/// that window: the glass's blur covers everything its window draws (`HUDWindowBlur`), so it
/// would end in a line where the field's alpha runs out.
///
/// `path` says how it draws and `pathReason` why. Each new path or reason is logged once while
/// the view is in a window (subsystem `xyz.machud.hudkit`, category `softbackdrop`):
/// - `.blur`: an `NSVisualEffectView` (`.hudWindow`, behind the window) masked by the
///   field, whose backdrop layer has one Gaussian blur of `blurRadius` in place of AppKit's
///   filters, with the material's fill, tone and tint layers hidden. The backdrop layer (the
///   private `CABackdropLayer`, found by class name) and the filter (the private `CAFilter`, by
///   type and input key) are looked up at run time and checked before anything is set.
/// - `.systemMaterial`: the same view as AppKit draws it, through the same field: while the user
///   has Reduce transparency on (the system makes the material opaque), where a private piece is
///   missing, or where the blur did not stay on the backdrop layer. A change of the display
///   accessibility settings tries the blur again.
/// - `.none`: no field; nothing is drawn.
///
/// AppKit builds the material's layers when it updates the effect view's layer, in the display
/// pass before a frame is committed, and builds them again with its own filters on an
/// appearance change. The view checks the backdrop layer at the end of each such update, after
/// layout, an appearance change and a move to a window, and once a Space switch, wake or screen
/// change has settled (`HUDEnvironmentMonitor`). Where it finds AppKit's filters or layers it
/// puts the blur back and logs that once per episode (repairs less than `repairEpisodeGap`
/// apart are one episode). So a window shows the blur from its first frame, with nothing for its
/// owner to call before showing it.
///
/// The field is copied once when it is set, to stretch rather than tile; AppKit draws the
/// effect view's mask, and the view its tint, at the bounds' size when that changes.
@MainActor
public final class HUDSoftBackdropView: NSView {
    /// How the view draws.
    public enum Path: String, Sendable {
        /// A Gaussian blur of `blurRadius` of what is behind the window, through the field.
        case blur
        /// The system's own behind-window material, through the field.
        case systemMaterial
        /// Nothing: there is no field.
        case none
    }

    /// The alpha image the backdrop shows through, stretched over the bounds: where it is
    /// opaque the blur shows fully, where it is clear nothing shows. Nil shows nothing.
    public var field: NSImage? {
        didSet { if field !== oldValue { fieldChanged() } }
    }

    /// The blur's radius: the family's, 25, unless set. Below 0 is taken as 0.
    public var blurRadius = CGFloat(HUDWindowBlur.radius) {
        didSet { if blurRadius != oldValue { radiusChanged() } }
    }

    /// A colour drawn over the blur through the field; a dynamic colour follows the appearance.
    /// Nil, the default, draws none.
    public var tint: NSColor? {
        didSet { if tint != oldValue { update() } }
    }

    /// How the view draws now.
    public private(set) var path: Path = .none
    /// Why it draws that way, for diagnostics.
    public private(set) var pathReason = "no field"

    /// Repairs less than this far apart are one episode, logged once.
    static let repairEpisodeGap: TimeInterval = 2

    /// The effect view, below the tint.
    private(set) var effectView: HUDSoftBackdropEffectView?
    /// Draws `tint` through the field.
    private(set) var tintView: HUDSoftBackdropTint?
    /// `field`, stretched over the bounds when drawn (no cap insets, `.stretch`).
    private(set) var stretchedField: NSImage?
    /// Called with each line after it is logged (tests).
    var onLog: ((String) -> Void)?

    private let pieces: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing>
    private let transparency: HUDTransparencySetting
    private let environment: HUDEnvironmentMonitor
    private let scheduler: HUDScheduler
    /// The blur filter of `blurRadius`; nil without the pieces.
    private var filter: NSObject?
    /// The blur has been on this effect view's backdrop layer: AppKit's filters found after
    /// that are a repair.
    private var effectTuned = false
    /// Why the blur was given up on this view: it did not stay, or two looks found no backdrop layer.
    private var failure: String?
    /// A look the turn after one that found the material built with no backdrop layer in it.
    private var secondLook: HUDScheduledWork?
    private var settled: HUDEnvironmentMonitor.Observation?
    /// The current repair episode; nil between episodes.
    private var episode: HUDScheduledWork?
    private var logged: (path: Path, reason: String)?

    public override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, pieces: HUDSoftBackdropPieces.live, transparency: .system,
                  environment: .shared, scheduler: .main)
    }

    /// The private pieces, the Reduce transparency setting, the settled signal and the clock
    /// are injected (tests).
    init(frame: NSRect, pieces: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing>,
         transparency: HUDTransparencySetting, environment: HUDEnvironmentMonitor, scheduler: HUDScheduler) {
        self.pieces = pieces
        self.transparency = transparency
        self.environment = environment
        self.scheduler = scheduler
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        pieces = HUDSoftBackdropPieces.live
        transparency = .system
        environment = .shared
        scheduler = .main
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        filter = makeFilter()
        // Selector-based, so the center lets go of the view when it is deallocated.
        transparency.center.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged),
                                        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        update()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Path

    /// The radius the blur is made with: `blurRadius`, not below 0.
    private var radiusUsed: CGFloat { max(0, blurRadius) }

    private func makeFilter() -> NSObject? {
        guard case .success(let pieces) = pieces else { return nil }
        return pieces.makeFilter(radiusUsed)
    }

    private func choosePath() -> (Path, String) {
        guard field != nil else { return (.none, "no field") }
        if transparency.isReduced() {
            return (.systemMaterial, "Reduce transparency is on; the system makes its material opaque")
        }
        switch pieces {
        case .failure(let missing):
            return (.systemMaterial, missing.reason)
        case .success:
            if let failure { return (.systemMaterial, failure) }
            guard filter != nil else {
                return (.systemMaterial, "no Gaussian blur filter of radius \(Self.format(radiusUsed)) could be made")
            }
            return (.blur, "one Gaussian blur of radius \(Self.format(radiusUsed)) on the material's backdrop layer")
        }
    }

    /// Puts the views in place for the path the state calls for.
    private func update() {
        let (next, reason) = choosePath()
        if next == .none {
            effectView?.removeFromSuperview()
            effectView = nil
            tintView?.removeFromSuperview()
            tintView = nil
        } else {
            let tunes = next == .blur
            if effectView?.tunes != tunes {
                effectView?.removeFromSuperview()
                let effect = HUDSoftBackdropEffectView(frame: bounds, tunes: tunes)
                effect.autoresizingMask = [.width, .height]
                effect.onLayerUpdate = { [weak self, weak effect] in
                    guard let self, let effect, effect === self.effectView else { return }
                    self.check("AppKit's layer update")
                }
                addSubview(effect, positioned: .below, relativeTo: nil)
                effectView = effect
                effectTuned = false
            }
            if effectView?.maskImage !== stretchedField { effectView?.maskImage = stretchedField }
            if let tint {
                let view = tintView ?? HUDSoftBackdropTint(frame: bounds)
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                view.field = stretchedField
                view.color = tint
                if view.superview !== self { addSubview(view, positioned: .above, relativeTo: effectView) }
                tintView = view
            } else {
                tintView?.removeFromSuperview()
                tintView = nil
            }
        }
        path = next
        pathReason = reason
        logPathIfNew()
        check("a change of the backdrop")
    }

    private func fieldChanged() {
        stretchedField = field.map(Self.stretched)
        // A new mask may have AppKit build the material again: the blur put back then is no repair.
        effectTuned = false
        update()
    }

    private func radiusChanged() {
        filter = makeFilter()
        effectTuned = false
        update()
    }

    /// A display accessibility setting changed (Reduce transparency among them): the path
    /// follows, and the blur is tried again where it had been given up.
    @objc private func accessibilityDisplayOptionsChanged(_ note: Notification) {
        failure = nil
        update()
    }

    /// `field` as a copy that stretches over any size rather than tiling.
    private static func stretched(_ field: NSImage) -> NSImage {
        let copy = (field.copy() as? NSImage) ?? field
        copy.capInsets = NSEdgeInsetsZero
        copy.resizingMode = .stretch
        return copy
    }

    private static func format(_ radius: CGFloat) -> String {
        radius == radius.rounded() ? String(Int(radius)) : String(format: "%.1f", radius)
    }

    // MARK: Keeping the blur

    /// Looks at the effect view's backdrop layer and puts the blur back where AppKit's own
    /// filters or layers are found. Cheap when nothing changed. A material with no backdrop layer
    /// in it is looked at once more on the next turn before the blur is given up.
    private func check(_ trigger: String, isSecondLook: Bool = false) {
        guard path == .blur, failure == nil, let effect = effectView, effect.tunes, let filter,
              case .success(let pieces) = pieces else { return }
        // The setting may have changed before its notification arrived; leave the material to
        // AppKit and follow the setting on the next turn.
        guard !transparency.isReduced() else {
            _ = scheduler.after(0) { [weak self] in self?.update() }
            return
        }
        switch HUDSoftBackdropTuner.tune(effect.layer, backdropClass: pieces.backdropLayerClass, filter: filter) {
        case .notBuilt:
            break
        case .ours:
            endSecondLook()
            effectTuned = true
        case .applied(let found):
            endSecondLook()
            if effectTuned { repaired(found, at: trigger) }
            effectTuned = true
        case .noBackdropLayer(let why):
            if isSecondLook {
                giveUp(why)
            } else if secondLook == nil {
                secondLook = scheduler.after(0) { [weak self] in
                    self?.secondLook = nil
                    self?.check("a second look for the backdrop layer", isSecondLook: true)
                }
            }
        case .failed(let why):
            giveUp(why)
        }
    }

    private func endSecondLook() {
        secondLook?.cancel()
        secondLook = nil
    }

    /// The blur is given up on this view: the system's material takes over on the next turn,
    /// not from inside AppKit's layer update.
    private func giveUp(_ why: String) {
        failure = why
        endSecondLook()
        _ = scheduler.after(0) { [weak self] in self?.update() }
    }

    private func repaired(_ found: String, at trigger: String) {
        let first = episode == nil
        episode?.cancel()
        episode = scheduler.after(Self.repairEpisodeGap) { [weak self] in self?.episode = nil }
        guard first else { return }
        log("\(logName): AppKit had put its own material back (\(found)), found at \(trigger); the blur is on again "
            + "(repairs less than \(Self.format(Self.repairEpisodeGap)) s apart are logged once)")
    }

    // MARK: Log

    private var logName: String {
        let number = window.map { " in window \($0.windowNumber)" } ?? ""
        return "soft backdrop \(identifier?.rawValue ?? "(no identifier)")\(number), \(Int(bounds.width))x\(Int(bounds.height)) pt"
    }

    private func logPathIfNew() {
        guard window != nil, logged?.path != path || logged?.reason != pathReason else { return }
        logged = (path, pathReason)
        log("\(logName): \(path.rawValue): \(pathReason)")
    }

    private func log(_ message: String) {
        HUDLog.softBackdrop.notice("\(message, privacy: .public)")
        onLog?(message)
    }

    // MARK: AppKit

    public override func layout() {
        super.layout()
        check("layout")
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        check("an appearance change")
        _ = scheduler.after(0) { [weak self] in self?.check("the turn after an appearance change") }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // AppKit builds the material again in another window: the blur put on it then is no repair.
        if newWindow !== window { effectTuned = false }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            settled = nil
            return
        }
        if settled == nil {
            settled = environment.observeSettled { [weak self] change in self?.check("the settled signal after \(change)") }
        }
        logPathIfNew()
        check("a move to a window")
        _ = scheduler.after(0) { [weak self] in self?.check("the turn after a move to a window") }
    }
}

/// The effect view inside a soft backdrop: AppKit's `.hudWindow` material behind the window,
/// never taking the mouse. It calls `onLayerUpdate` after each update of its layer, which is
/// where AppKit builds and rebuilds the material's layers.
final class HUDSoftBackdropEffectView: NSVisualEffectView {
    /// Whether the backdrop puts its blur on this view's material.
    let tunes: Bool
    var onLayerUpdate: (@MainActor () -> Void)?

    init(frame: NSRect, tunes: Bool) {
        self.tunes = tunes
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        super.updateLayer()
        onLayerUpdate?()
    }
}

/// The tint of a soft backdrop: `color` where the field is, times the field's alpha, the field
/// stretched over the bounds as the effect view's mask is. Drawn again when the field, the
/// colour, the size or the appearance changes.
final class HUDSoftBackdropTint: NSView {
    var field: NSImage? { didSet { if field !== oldValue { needsDisplay = true } } }
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let field else { return }
        color.setFill()
        bounds.fill()
        field.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
    }
}

/// Puts one filter of ours on a material's backdrop layer in place of AppKit's, hides the
/// material's other layers (fill, tone, tint), and says what it found. Where either does not
/// hold, it leaves the material as AppKit had it.
enum HUDSoftBackdropTuner {
    enum Outcome: Equatable {
        /// The material's layers are not there: the view has not been on screen yet, or AppKit
        /// took them down to build them again.
        case notBuilt
        /// The backdrop layer has only our filter and the other layers are hidden.
        case ours
        /// AppKit's own was found (what) and replaced.
        case applied(String)
        /// The material is built but no backdrop layer was found in it (why).
        case noBackdropLayer(String)
        /// The blur cannot be put on this material (why).
        case failed(String)
    }

    /// `root` is the effect view's layer.
    static func tune(_ root: CALayer?, backdropClass: AnyClass, filter: NSObject) -> Outcome {
        guard let root, !(root.sublayers ?? []).isEmpty else { return .notBuilt }
        guard let backdrop = find(backdropClass, under: root), let material = backdrop.superlayer else {
            return .noBackdropLayer("no \(NSStringFromClass(backdropClass)) among the material's layers")
        }
        let others = (material.sublayers ?? []).filter { $0 !== backdrop }
        let appKits = backdrop.filters
        var found: [String] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The filter first, and the other layers hidden only once it has held: a failure leaves
        // AppKit's material as it was.
        let replaced = !hasOnly(filter, backdrop)
        if replaced {
            found.append("filters [\(filterNames(backdrop))]")
            backdrop.filters = [filter]
            guard hasOnly(filter, backdrop) else {
                let readBack = filterNames(backdrop)
                backdrop.filters = appKits
                return .failed("the blur did not stay on the backdrop layer (its filters read back [\(readBack)])")
            }
        }
        let shown = others.filter { !$0.isHidden }
        shown.forEach { $0.isHidden = true }
        if let stuck = shown.first(where: { !$0.isHidden }) {
            shown.forEach { $0.isHidden = false }
            if replaced { backdrop.filters = appKits }
            return .failed("the material's \(layerName(stuck)) layer did not stay hidden")
        }
        if !shown.isEmpty { found.append(shown.map(layerName).joined(separator: ", ") + " shown") }
        return found.isEmpty ? .ours : .applied(found.joined(separator: "; "))
    }

    private static func layerName(_ layer: CALayer) -> String {
        layer.name ?? NSStringFromClass(type(of: layer))
    }

    private static func find(_ cls: AnyClass, under layer: CALayer) -> CALayer? {
        if layer.isKind(of: cls) { return layer }
        for sub in layer.sublayers ?? [] {
            if let found = find(cls, under: sub) { return found }
        }
        return nil
    }

    private static func hasOnly(_ filter: NSObject, _ layer: CALayer) -> Bool {
        guard let filters = layer.filters, filters.count == 1 else { return false }
        return (filters[0] as AnyObject) === filter
    }

    /// Each filter's `type` where it has one, else its class.
    private static func filterNames(_ layer: CALayer) -> String {
        let type = NSSelectorFromString("type")
        return (layer.filters ?? []).map { filter -> String in
            guard let object = filter as? NSObject else { return String(describing: Swift.type(of: filter)) }
            if object.responds(to: type), let name = object.value(forKey: "type") as? String { return name }
            return NSStringFromClass(Swift.type(of: object))
        }.joined(separator: ", ")
    }
}

/// The private pieces the soft backdrop's blur needs, found by name at run time and checked
/// before use: the backdrop layer class AppKit's material samples what is behind the window
/// with (`CABackdropLayer`), and the Gaussian blur filter (`CAFilter` of type `gaussianBlur`
/// with an `inputRadius`).
struct HUDSoftBackdropPieces {
    /// Why a piece is missing.
    struct Missing: Error, Equatable {
        let reason: String
    }

    let backdropLayerClass: AnyClass
    /// A new Gaussian blur filter of this radius.
    let makeFilter: @MainActor (CGFloat) -> NSObject?

    @MainActor static let live = resolve()

    /// `classNamed` finds an Objective-C class by name (`NSClassFromString`).
    @MainActor
    static func resolve(classNamed: (String) -> AnyClass? = NSClassFromString) -> Result<Self, Missing> {
        func missing(_ reason: String) -> Result<Self, Missing> { .failure(Missing(reason: reason)) }
        guard let backdrop = classNamed("CABackdropLayer") else { return missing("CABackdropLayer not found") }
        guard backdrop is CALayer.Type else { return missing("CABackdropLayer is not a CALayer") }
        guard let filterClass = classNamed("CAFilter") as? NSObject.Type else { return missing("CAFilter not found") }
        let withType = NSSelectorFromString("filterWithType:"), types = NSSelectorFromString("filterTypes")
        guard class_getClassMethod(filterClass, withType) != nil else { return missing("+[CAFilter filterWithType:] not found") }
        guard class_getClassMethod(filterClass, types) != nil,
              let listed = filterClass.perform(types)?.takeUnretainedValue() as? [String] else {
            return missing("+[CAFilter filterTypes] not found")
        }
        guard listed.contains("gaussianBlur") else { return missing("CAFilter has no gaussianBlur type") }
        let newFilter = { filterClass.perform(withType, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject }
        guard let sample = newFilter() else { return missing("+[CAFilter filterWithType:] gave no gaussianBlur filter") }
        guard sample.responds(to: NSSelectorFromString("inputKeys")), let keys = sample.value(forKey: "inputKeys") as? [String] else {
            return missing("-[CAFilter inputKeys] not found")
        }
        guard keys.contains("inputRadius") else { return missing("the gaussianBlur filter has no inputRadius") }
        let normalizesEdges = keys.contains("inputNormalizeEdges")
        return .success(HUDSoftBackdropPieces(backdropLayerClass: backdrop) { radius in
            guard let filter = newFilter() else { return nil }
            filter.setValue(radius, forKey: "inputRadius")
            if normalizesEdges { filter.setValue(true, forKey: "inputNormalizeEdges") }
            return filter
        })
    }
}
