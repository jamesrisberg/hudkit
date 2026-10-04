import AppKit
import XCTest
@testable import HUDKit

/// `HUDSoftBackdropView` outside a window: the path it takes with the private pieces there,
/// missing or under Reduce transparency, the mask and tint following the field, and the
/// pieces and the layer tuning on their own.
@MainActor
final class HUDSoftBackdropViewTests: XCTestCase {
    var clock: ManualClock!
    var monitor: HUDEnvironmentMonitor!
    let frame = CGRect(x: 0, y: 0, width: 120, height: 80)

    override func setUp() async throws {
        clock = ManualClock()
        monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
    }

    private func soft(pieces: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing>? = nil,
                      transparency: HUDTransparencySetting = .fixed(reduced: false)) -> HUDSoftBackdropView {
        HUDSoftBackdropView(frame: frame, pieces: pieces ?? HUDSoftBackdropPieces.live, transparency: transparency,
                            environment: monitor, scheduler: clock.scheduler)
    }

    /// Opaque in a centred square half the size, clear around it.
    private func centreField(_ size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.insetBy(dx: rect.width / 4, dy: rect.height / 4).fill()
            return true
        }
    }

    /// The live lookup, with `missing` reported missing and `substitutes` in place of classes.
    private func pieces(missing: String? = nil, substitutes: [String: AnyClass] = [:]) -> Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing> {
        HUDSoftBackdropPieces.resolve { name in
            if name == missing { return nil }
            return substitutes[name] ?? NSClassFromString(name)
        }
    }

    private func missingReason(_ result: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing>) -> String? {
        if case .failure(let missing) = result { return missing.reason }
        return nil
    }

    /// `view` drawn into a bitmap of its size at 1x; alpha at `point` (origin bottom-left).
    private func alpha(drawing view: NSView, at point: CGPoint) throws -> CGFloat {
        let size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.colorAt(x: Int(point.x), y: Int(size.height - 1 - point.y))).alphaComponent
    }

    // MARK: The path

    func testWithThePrivatePiecesTheBlurIsChosen() throws {
        let view = soft()
        view.field = centreField(frame.size)
        XCTAssertEqual(view.path, .blur)
        XCTAssertTrue(view.pathReason.contains("radius 25"), view.pathReason)
        XCTAssertEqual(view.blurRadius, 25, "the family's radius")
        let effect = try XCTUnwrap(view.effectView)
        XCTAssertTrue(effect.tunes)
        XCTAssertTrue(view.subviews == [effect], "no tint unless asked for")
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .active)
        XCTAssertEqual(effect.frame, view.bounds)
        XCTAssertNil(view.hitTest(CGPoint(x: 60, y: 40)))
        XCTAssertNil(effect.hitTest(CGPoint(x: 60, y: 40)))
    }

    func testWithoutAFieldNothingIsDrawn() {
        let view = soft()
        XCTAssertEqual(view.path, .none)
        XCTAssertEqual(view.pathReason, "no field")
        XCTAssertTrue(view.subviews.isEmpty)
        view.tint = .black
        XCTAssertTrue(view.subviews.isEmpty, "a tint needs a field")
        view.field = centreField(frame.size)
        XCTAssertEqual(view.path, .blur)
        XCTAssertEqual(view.subviews.count, 2)
        view.field = nil
        XCTAssertEqual(view.path, .none)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertNil(view.effectView)
        XCTAssertNil(view.tintView)
    }

    func testAMissingPieceTakesTheSystemMaterial() throws {
        for name in ["CABackdropLayer", "CAFilter"] {
            let lookup = pieces(missing: name)
            XCTAssertEqual(missingReason(lookup), "\(name) not found")
            let view = soft(pieces: lookup)
            view.field = centreField(frame.size)
            XCTAssertEqual(view.path, .systemMaterial, name)
            XCTAssertEqual(view.pathReason, "\(name) not found")
            let effect = try XCTUnwrap(view.effectView, "the system's material, through the field")
            XCTAssertFalse(effect.tunes)
            XCTAssertTrue(effect.maskImage === view.stretchedField)
        }
        XCTAssertEqual(missingReason(pieces(substitutes: ["CABackdropLayer": NSObject.self])), "CABackdropLayer is not a CALayer")
    }

    func testAFilterWithoutTheBlurOrItsRadiusTakesTheSystemMaterial() {
        XCTAssertEqual(missingReason(pieces(substitutes: ["CAFilter": NSObject.self])), "+[CAFilter filterWithType:] not found")
        XCTAssertEqual(missingReason(pieces(substitutes: ["CAFilter": FilterWithoutBlur.self])), "CAFilter has no gaussianBlur type")
        XCTAssertEqual(missingReason(pieces(substitutes: ["CAFilter": FilterWithoutKeys.self])), "-[CAFilter inputKeys] not found")
        XCTAssertEqual(missingReason(pieces(substitutes: ["CAFilter": FilterWithoutRadius.self])), "the gaussianBlur filter has no inputRadius")
        let view = soft(pieces: pieces(substitutes: ["CAFilter": FilterWithoutRadius.self]))
        view.field = centreField(frame.size)
        XCTAssertEqual(view.path, .systemMaterial)
        XCTAssertEqual(view.pathReason, "the gaussianBlur filter has no inputRadius")
    }

    func testThePiecesAreFoundAndMakeTheFilter() throws {
        guard case .success(let found) = HUDSoftBackdropPieces.live else {
            return XCTFail("the private pieces resolve on this system: \(missingReason(HUDSoftBackdropPieces.live) ?? "")")
        }
        XCTAssertEqual(NSStringFromClass(found.backdropLayerClass), "CABackdropLayer")
        let filter = try XCTUnwrap(found.makeFilter(12))
        XCTAssertEqual(filter.value(forKey: "type") as? String, "gaussianBlur")
        XCTAssertEqual((filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue, 12)
    }

    func testReduceTransparencyTakesTheSystemMaterialAndBack() throws {
        var reduced = true
        let center = NotificationCenter()
        let view = soft(transparency: HUDTransparencySetting(isReduced: { reduced }, center: center))
        view.field = centreField(frame.size)
        XCTAssertEqual(view.path, .systemMaterial)
        XCTAssertTrue(view.pathReason.contains("Reduce transparency"), view.pathReason)
        let stock = try XCTUnwrap(view.effectView)
        XCTAssertFalse(stock.tunes)
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(view.path, .blur)
        let tuned = try XCTUnwrap(view.effectView)
        XCTAssertTrue(tuned.tunes)
        XCTAssertNil(stock.superview, "a fresh effect view for the other path")
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(view.path, .systemMaterial)
        XCTAssertFalse(try XCTUnwrap(view.effectView).tunes)
        XCTAssertNil(tuned.superview)
    }

    func testARadiusIsTakenAndSaid() {
        let view = soft()
        view.field = centreField(frame.size)
        view.blurRadius = 12.5
        XCTAssertEqual(view.path, .blur)
        XCTAssertTrue(view.pathReason.contains("radius 12.5"), view.pathReason)
        view.blurRadius = -3
        XCTAssertEqual(view.path, .blur)
        XCTAssertTrue(view.pathReason.contains("radius 0 "), "the radius used, not the one asked for: \(view.pathReason)")
    }

    // MARK: The field

    func testTheMaskFollowsTheField() throws {
        let view = soft()
        let small = centreField(CGSize(width: 10, height: 10))
        small.resizingMode = .tile
        view.field = small
        let effect = try XCTUnwrap(view.effectView)
        let mask = try XCTUnwrap(effect.maskImage)
        XCTAssertTrue(mask === view.stretchedField)
        XCTAssertFalse(mask === small, "a copy: the caller's image is left as it is")
        XCTAssertEqual(mask.size, small.size)
        XCTAssertEqual(mask.resizingMode, .stretch, "stretched over the bounds, not tiled")
        XCTAssertEqual(mask.capInsets.left + mask.capInsets.right + mask.capInsets.top + mask.capInsets.bottom, 0)
        XCTAssertEqual(small.resizingMode, .tile)
        // Built once per field: a new size reuses it (AppKit draws it at the new size).
        view.setFrameSize(CGSize(width: 200, height: 150))
        XCTAssertTrue(effect.maskImage === mask)
        XCTAssertEqual(effect.frame, view.bounds)
        // A new field, a new mask.
        let other = centreField(CGSize(width: 20, height: 20))
        view.field = other
        XCTAssertTrue(view.effectView === effect, "the same effect view")
        XCTAssertFalse(effect.maskImage === mask)
        XCTAssertEqual(effect.maskImage?.size, other.size)
    }

    func testTheTintIsDrawnThroughTheField() throws {
        let view = soft()
        view.field = centreField(CGSize(width: 12, height: 8))  // stretched: opaque from 30,20 to 90,60
        view.tint = NSColor.black.withAlphaComponent(0.5)
        let tint = try XCTUnwrap(view.tintView)
        XCTAssertTrue(view.subviews == [try XCTUnwrap(view.effectView), tint], "over the blur")
        XCTAssertEqual(tint.frame, view.bounds)
        XCTAssertNil(tint.hitTest(CGPoint(x: 60, y: 40)))
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 60, y: 40)), 0.5, accuracy: 0.01, "inside the field")
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 10, y: 10)), 0, "outside it")
        view.setFrameSize(CGSize(width: 240, height: 160))
        XCTAssertEqual(tint.frame, view.bounds)
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 120, y: 80)), 0.5, accuracy: 0.01, "the field stretched to the new size")
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 50, y: 30)), 0)
        view.tint = nil
        XCTAssertNil(view.tintView)
        XCTAssertNil(tint.superview)
    }

    // MARK: Tuning a layer tree

    /// A material as AppKit builds it: a backdrop layer with three filters of its own and the
    /// fill, tone and tint layers beside it, in the effect view's layer.
    private func material(backdrop: CALayer) throws -> (root: CALayer, others: [CALayer]) {
        guard case .success(let found) = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces") }
        backdrop.filters = [try XCTUnwrap(found.makeFilter(30)), try XCTUnwrap(found.makeFilter(4))]
        let others = ["fill", "tone", "desktop tint"].map { name -> CALayer in
            let layer = CALayer()
            layer.name = name
            return layer
        }
        let material = CALayer()
        material.sublayers = [backdrop] + others
        let root = CALayer()
        root.addSublayer(material)
        return (root, others)
    }

    func testTheTunerReplacesAppKitsMaterialAndThenFindsItsOwn() throws {
        guard case .success(let found) = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces") }
        let filter = try XCTUnwrap(found.makeFilter(25))
        let backdrop = Backdrop()
        let (root, others) = try material(backdrop: backdrop)
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: Backdrop.self, filter: filter),
                       .applied("filters [gaussianBlur, gaussianBlur]; fill, tone, desktop tint shown"))
        XCTAssertEqual(backdrop.filters?.count, 1)
        XCTAssertTrue((backdrop.filters?.first as AnyObject?) === filter)
        XCTAssertTrue(others.allSatisfy(\.isHidden))
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: Backdrop.self, filter: filter), .ours)
        others[1].isHidden = false
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: Backdrop.self, filter: filter), .applied("tone shown"))
    }

    func testTheTunerWaitsForTheMaterialAndSaysWhenThereIsNoBackdropLayer() throws {
        guard case .success(let found) = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces") }
        let filter = try XCTUnwrap(found.makeFilter(25))
        XCTAssertEqual(HUDSoftBackdropTuner.tune(nil, backdropClass: Backdrop.self, filter: filter), .notBuilt)
        XCTAssertEqual(HUDSoftBackdropTuner.tune(CALayer(), backdropClass: Backdrop.self, filter: filter), .notBuilt)
        let (root, _) = try material(backdrop: CALayer())
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: Backdrop.self, filter: filter),
                       .failed("no \(NSStringFromClass(Backdrop.self)) among the material's layers"))
    }

    func testABlurThatDoesNotStayFails() throws {
        guard case .success(let found) = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces") }
        let filter = try XCTUnwrap(found.makeFilter(25))
        let (root, others) = try material(backdrop: StubbornBackdrop())
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: StubbornBackdrop.self, filter: filter),
                       .failed("the blur did not stay on the backdrop layer (its filters read back [gaussianBlur, gaussianBlur])"))
        XCTAssertTrue(others.allSatisfy { !$0.isHidden }, "AppKit's material is left whole: nothing hidden")
    }

    func testALayerThatWillNotHideFailsAndLeavesTheMaterialWhole() throws {
        guard case .success(let found) = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces") }
        let filter = try XCTUnwrap(found.makeFilter(25))
        let backdrop = Backdrop()
        let (root, others) = try material(backdrop: backdrop)
        let own = backdrop.filters
        let stubborn = AlwaysShown()
        stubborn.name = "tone"
        root.sublayers?.first?.replaceSublayer(others[1], with: stubborn)
        XCTAssertEqual(HUDSoftBackdropTuner.tune(root, backdropClass: Backdrop.self, filter: filter),
                       .failed("the material's tone layer did not stay hidden"))
        XCTAssertEqual(backdrop.filters?.count, own?.count, "AppKit's filters are put back")
        XCTAssertTrue((backdrop.filters?.first as AnyObject?) === (own?.first as AnyObject?))
        XCTAssertFalse(others[0].isHidden, "what was hidden is shown again")
        XCTAssertFalse(others[2].isHidden)
    }
}

/// Stands in for the backdrop layer in hand-built layer trees.
private final class Backdrop: CALayer {}

/// A backdrop layer that keeps its filters whatever is set.
private final class StubbornBackdrop: CALayer {
    private var kept: [Any]?
    override var filters: [Any]? {
        get { kept }
        set { if kept == nil { kept = newValue } }
    }
}

/// Filter classes that lack what the blur needs.
private final class FilterWithoutBlur: NSObject {
    @objc class func filterTypes() -> [String] { ["colorInvert"] }
    @objc class func filterWithType(_ type: String) -> FilterWithoutBlur { FilterWithoutBlur() }
}

private final class FilterWithoutKeys: NSObject {
    @objc class func filterTypes() -> [String] { ["gaussianBlur"] }
    @objc class func filterWithType(_ type: String) -> FilterWithoutKeys { FilterWithoutKeys() }
}

private final class FilterWithoutRadius: NSObject {
    @objc class func filterTypes() -> [String] { ["gaussianBlur"] }
    @objc class func filterWithType(_ type: String) -> FilterWithoutRadius { FilterWithoutRadius() }
    @objc var inputKeys: [String] { ["inputAmount"] }
}

/// A material layer that will not be hidden.
private final class AlwaysShown: CALayer {
    override var isHidden: Bool {
        get { false }
        set {}
    }
}
