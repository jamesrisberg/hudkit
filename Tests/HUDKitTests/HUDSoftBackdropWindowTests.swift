import AppKit
import XCTest
@testable import HUDKit

/// `HUDSoftBackdropView` on screen, through AppKit's real material: the layer tree it leaves
/// behind its first frame, after an appearance change, a resize and a settled signal, its
/// fallback, and what it logs. The windows are ordered in at alpha 0, below normal windows,
/// in a corner of the main screen, so nothing is ever seen.
@MainActor
final class HUDSoftBackdropWindowTests: XCTestCase {
    var clock: ManualClock!
    var monitor: HUDEnvironmentMonitor!
    var windows: [NSWindow] = []
    var logs: [String] = []

    override func setUp() async throws {
        clock = ManualClock()
        monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        logs = []
        guard case .success = HUDSoftBackdropPieces.live else { throw XCTSkip("no private pieces on this system") }
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
    }

    private var repairs: [String] { logs.filter { $0.contains("put its own material back") } }

    /// A window that is never seen: alpha 0, below normal windows, 40 pt square in a corner.
    private func window() -> NSWindow {
        let w = NSPanel(contentRect: liveTestFrame(width: 40, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        w.collectionBehavior = [.stationary, .ignoresCycle]
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        windows.append(w)
        return w
    }

    /// A soft backdrop filling `window`'s content, its field a disc fading to the rim.
    private func soft(in window: NSWindow, pieces: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing>? = nil,
                      transparency: HUDTransparencySetting = .fixed(reduced: false)) -> HUDSoftBackdropView {
        let size = window.contentLayoutRect.size
        let view = HUDSoftBackdropView(frame: CGRect(origin: .zero, size: size), pieces: pieces ?? HUDSoftBackdropPieces.live,
                                       transparency: transparency, environment: monitor, scheduler: clock.scheduler)
        view.onLog = { [unowned self] in logs.append($0) }
        view.field = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [.black, .black, .clear], atLocations: [0, 0.6, 1], colorSpace: .sRGB)
            gradient?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            return true
        }
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return view
    }

    private func waitUntil(limit: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    /// Lets AppKit run a few display passes.
    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The material's layers

    private static func find(_ name: String, under layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if NSStringFromClass(type(of: layer)) == name { return layer }
        for sub in layer.sublayers ?? [] {
            if let found = find(name, under: sub) { return found }
        }
        return nil
    }

    private func backdropLayer(_ effect: NSVisualEffectView?) -> CALayer? {
        Self.find("CABackdropLayer", under: effect?.layer)
    }

    private func filterTypes(_ layer: CALayer?) -> [String] {
        (layer?.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "type") as? String }
    }

    /// The backdrop layer has one Gaussian blur of `radius` and every other material layer is hidden.
    private func isBlurred(_ effect: NSVisualEffectView?, radius: Double = 25) -> Bool {
        guard let backdrop = backdropLayer(effect), let filters = backdrop.filters, filters.count == 1,
              let filter = filters.first as? NSObject, filter.value(forKey: "type") as? String == "gaussianBlur",
              (filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == radius else { return false }
        return (backdrop.superlayer?.sublayers ?? []).allSatisfy { $0 === backdrop || $0.isHidden }
    }

    /// AppKit's own material: its filters on the backdrop layer and its fill shown.
    private func isAppKitsOwn(_ effect: NSVisualEffectView?) -> Bool {
        guard let backdrop = backdropLayer(effect) else { return false }
        let fill = backdrop.superlayer?.sublayers?.first { $0.name == "fill" }
        return filterTypes(backdrop).count > 1 && fill?.isHidden == false
    }

    // MARK: Tests

    func testTheFirstFrameIsAlreadyTheBlur() {
        let w = window()
        let view = soft(in: w)
        XCTAssertNil(backdropLayer(view.effectView), "AppKit builds the material only on screen")
        w.orderFrontRegardless()
        // Every look from outside a display pass sees what that pass committed.
        var sawAppKitsOwn = false
        XCTAssertTrue(waitUntil {
            guard backdropLayer(view.effectView) != nil else { return false }
            if !isBlurred(view.effectView) { sawAppKitsOwn = true }
            return true
        }, "AppKit built the material")
        XCTAssertFalse(sawAppKitsOwn, "the material was never seen with AppKit's filters")
        XCTAssertTrue(isBlurred(view.effectView))
        XCTAssertEqual(view.path, .familyBlur)
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs.first?.contains("familyBlur: one Gaussian blur of radius 25") == true, "\(logs)")
        XCTAssertTrue(repairs.isEmpty, "the first application is no repair")
        // Ordered out and in again: AppKit keeps the layers, and the blur on them.
        w.orderOut(nil)
        w.orderFrontRegardless()
        spin()
        XCTAssertTrue(isBlurred(view.effectView))
        XCTAssertTrue(repairs.isEmpty)
    }

    func testTheBlurSurvivesAnAppearanceChangeAndIsLoggedOncePerEpisode() throws {
        let w = window()
        let view = soft(in: w)
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        let first = try XCTUnwrap(backdropLayer(view.effectView))
        w.appearance = NSAppearance(named: .aqua)
        XCTAssertNil(backdropLayer(view.effectView), "AppKit takes the material down to build it again")
        XCTAssertTrue(waitUntil { repairs.count == 1 && isBlurred(view.effectView) }, "\(logs)")
        let second = try XCTUnwrap(backdropLayer(view.effectView))
        XCTAssertFalse(second === first, "a new backdrop layer, blurred again")
        let line = try XCTUnwrap(repairs.first)
        XCTAssertTrue(line.contains("filters [") && line.contains("fill"), "what AppKit had put back: \(line)")
        XCTAssertTrue(line.contains("found at AppKit's layer update"), line)
        // Back within the episode: blurred again, not logged again.
        w.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(waitUntil { backdropLayer(view.effectView).map { $0 !== second } ?? false && isBlurred(view.effectView) })
        spin()
        XCTAssertEqual(repairs.count, 1, "\(logs)")
        // A later episode is logged.
        clock.advance(by: HUDSoftBackdropView.repairEpisodeGap)
        w.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(waitUntil { repairs.count == 2 && isBlurred(view.effectView) }, "\(logs)")
        XCTAssertEqual(view.path, .familyBlur)
    }

    func testTheBlurSurvivesAResizeAndTheMaskFollows() throws {
        let w = window()
        let view = soft(in: w)
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        let effect = try XCTUnwrap(view.effectView)
        let mask = effect.maskImage
        for size in [CGSize(width: 64, height: 48), CGSize(width: 40, height: 40)] {
            w.setContentSize(size)
            spin()
            XCTAssertEqual(view.bounds.size, size)
            XCTAssertEqual(effect.frame, view.bounds)
            XCTAssertTrue(isBlurred(effect), "\(size)")
            let material = try XCTUnwrap(backdropLayer(effect)?.superlayer)
            XCTAssertEqual(material.mask?.frame.size, size, "AppKit's mask covers the new bounds")
        }
        XCTAssertTrue(effect.maskImage === mask, "the field is not built again for a size")
        XCTAssertTrue(view.effectView === effect)
        XCTAssertTrue(repairs.isEmpty, "\(logs)")
    }

    func testTheSettledSignalPutsTheBlurBack() throws {
        let w = window()
        let view = soft(in: w)
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        clock.advance(by: 0)  // the check the turn after the move to the window
        // AppKit putting its own back without rebuilding, as far as the view can tell.
        let backdrop = try XCTUnwrap(backdropLayer(view.effectView))
        backdrop.filters = nil
        backdrop.superlayer?.sublayers?.first { $0.name == "fill" }?.isHidden = false
        XCTAssertFalse(isBlurred(view.effectView))
        monitor.note(.activeSpace)
        clock.advance(by: HUDEnvironmentMonitor.defaultSettleDelay)
        XCTAssertTrue(isBlurred(view.effectView))
        XCTAssertEqual(repairs.count, 1)
        let line = try XCTUnwrap(repairs.first)
        XCTAssertTrue(line.contains("filters []; fill shown"), line)
        XCTAssertTrue(line.contains("the settled signal after activeSpace"), line)
        // Out of the window, the signal is no longer followed.
        view.removeFromSuperview()
        backdrop.filters = nil
        monitor.note(.wake)
        clock.advance(by: HUDEnvironmentMonitor.defaultSettleDelay)
        XCTAssertEqual(backdrop.filters?.count ?? 0, 0)
    }

    func testWhereTheBlurCannotBeAppliedTheSystemMaterialShows() throws {
        // The live lookup with a backdrop layer class AppKit's material does not have.
        let pieces = HUDSoftBackdropPieces.resolve { $0 == "CABackdropLayer" ? NotAppKitsBackdrop.self : NSClassFromString($0) }
        let w = window()
        let view = soft(in: w, pieces: pieces)
        XCTAssertEqual(view.path, .familyBlur, "nothing to tell before AppKit builds the material")
        let first = try XCTUnwrap(view.effectView)
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { backdropLayer(first) != nil })
        clock.advance(by: 0)
        XCTAssertEqual(view.path, .systemMaterial)
        XCTAssertEqual(view.pathReason, "no \(NSStringFromClass(NotAppKitsBackdrop.self)) among the material's layers")
        let stock = try XCTUnwrap(view.effectView)
        XCTAssertFalse(stock === first, "a fresh effect view, as AppKit draws it")
        XCTAssertFalse(stock.tunes)
        XCTAssertTrue(stock.maskImage === view.stretchedField)
        XCTAssertTrue(waitUntil { isAppKitsOwn(stock) })
        XCTAssertEqual(logs.count, 2, "\(logs)")
        XCTAssertTrue(logs.last?.contains("systemMaterial: no ") == true, "\(logs)")
    }

    func testThePathIsLoggedOnceWhenChosen() {
        var reduced = false
        let center = NotificationCenter()
        let w = window()
        let view = soft(in: w, transparency: HUDTransparencySetting(isReduced: { reduced }, center: center))
        view.identifier = NSUserInterfaceItemIdentifier("wheel")
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs.first?.hasPrefix("soft backdrop ") == true, "\(logs)")
        view.tint = NSColor.black.withAlphaComponent(0.45)
        view.blurRadius = 25
        spin()
        XCTAssertEqual(logs.count, 1, "nothing new chosen: \(logs)")
        // Reduce transparency: AppKit's own material, untouched.
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(view.path, .systemMaterial)
        XCTAssertTrue(waitUntil { isAppKitsOwn(view.effectView) })
        spin()
        XCTAssertTrue(isAppKitsOwn(view.effectView), "not tuned while the setting is on")
        // And off again.
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        guard logs.count == 3 else { return XCTFail("three lines: \(logs)") }
        XCTAssertTrue(logs[1].contains("wheel in window \(w.windowNumber)") && logs[1].contains("systemMaterial: Reduce transparency"), logs[1])
        XCTAssertTrue(logs[2].contains("familyBlur"), logs[2])
        XCTAssertTrue(repairs.isEmpty, "\(logs)")
    }

    func testANewRadiusIsPutOnTheBackdropLayer() {
        let w = window()
        let view = soft(in: w)
        w.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isBlurred(view.effectView) })
        view.blurRadius = 10
        XCTAssertTrue(isBlurred(view.effectView, radius: 10), "at once, while the material is built")
        spin()
        XCTAssertTrue(isBlurred(view.effectView, radius: 10))
        XCTAssertTrue(repairs.isEmpty, "\(logs)")
    }
}

/// A backdrop layer class AppKit's material does not use.
private final class NotAppKitsBackdrop: CALayer {}
