import AppKit
import XCTest
@testable import HUDKit

/// `HUDBackdropView`: the window server's blur under a tint drawn in the backdrop's shape, or
/// the classic `NSVisualEffectView` cut to that shape.
@MainActor
final class HUDBackdropViewTests: XCTestCase {
    struct Call: Equatable {
        let window: Int
        let radius: Int
    }

    var calls: [Call] = []
    var clock: ManualClock!
    var blur: HUDWindowBlur!
    var unavailable: HUDWindowBlur!
    let frame = CGRect(x: 0, y: 0, width: 120, height: 80)

    override func setUp() async throws {
        calls = []
        clock = ManualClock()
        blur = HUDWindowBlur(setter: { [unowned self] window, radius in calls.append(Call(window: window, radius: radius)) },
                             scheduler: clock.scheduler, transparency: .fixed(reduced: false))
        unavailable = HUDWindowBlur(setter: nil, scheduler: clock.scheduler, transparency: .fixed(reduced: false))
    }

    private func backdrop(_ shape: HUDBackdropView.Shape, material: HUDGlassView.Material = .windowBlur,
                          blur: HUDWindowBlur? = nil) -> HUDBackdropView {
        HUDBackdropView(frame: frame, material: material, shape: shape, windowBlur: blur ?? self.blur)
    }

    private let black20 = NSColor.black.withAlphaComponent(0.2)
    private let white20 = NSColor.white.withAlphaComponent(0.2)

    private func assertColor(_ cg: CGColor?, _ expected: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let cg, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB),
              let want = expected.usingColorSpace(.sRGB) else { return XCTFail("no colour", file: file, line: line) }
        XCTAssertEqual(color.redComponent, want.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(color.greenComponent, want.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(color.blueComponent, want.blueComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, want.alphaComponent, accuracy: 0.01, file: file, line: line)
    }

    /// The view drawn into a bitmap of its size at 1x, alpha at `point` (origin bottom-left).
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

    /// A ring-like mask: opaque in a centred square half the size, clear around it.
    private func centreMask(_ size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.insetBy(dx: rect.width / 4, dy: rect.height / 4).fill()
            return true
        }
    }

    func testARoundedBackdropIsATintedRoundedRect() {
        let view = backdrop(.rounded(20))
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(view.material, .windowBlur)
        XCTAssertTrue(view.subviews.isEmpty, "no visual-effect view")
        XCTAssertEqual(view.layer?.cornerRadius, 20)
        XCTAssertEqual(view.layer?.cornerCurve, .continuous)
        assertColor(view.layer?.backgroundColor, black20)
        XCTAssertNil(view.layer?.mask)
    }

    func testTheTintFollowsTheAppearance() {
        let view = backdrop(.rounded(20))
        view.appearance = NSAppearance(named: .aqua)
        assertColor(view.layer?.backgroundColor, white20)
        view.appearance = NSAppearance(named: .darkAqua)
        assertColor(view.layer?.backgroundColor, black20)
        let path = CGPath(rect: frame.insetBy(dx: 10, dy: 10), transform: nil)
        let shaped = backdrop(.path(path))
        shaped.appearance = NSAppearance(named: .aqua)
        assertColor(shaped.tintLayer.fillColor, white20)
    }

    func testAPathBackdropIsTheTintInThatPath() {
        let path = CGPath(roundedRect: frame.insetBy(dx: 10, dy: 10), cornerWidth: 8, cornerHeight: 8, transform: nil)
        let view = backdrop(.path(path))
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertNil(view.layer?.backgroundColor, "only inside the path")
        XCTAssertTrue(view.tintLayer.superlayer === view.layer)
        XCTAssertEqual(view.tintLayer.path, path)
        assertColor(view.tintLayer.fillColor, black20)
        XCTAssertNil(view.layer?.mask)
        // Back to a rounded rect: the path's tint goes.
        view.shape = .rounded(12)
        XCTAssertNil(view.tintLayer.superlayer)
        assertColor(view.layer?.backgroundColor, black20)
    }

    func testAMaskBackdropIsTheTintInTheMasksOpaquePart() throws {
        let view = backdrop(.mask(centreMask(frame.size)))
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertNil(view.layer?.backgroundColor)
        let tint = try XCTUnwrap(view.subviews.first, "the tint is drawn by a subview")
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertEqual(tint.frame, view.bounds)
        XCTAssertNil(tint.hitTest(CGPoint(x: 60, y: 40)))
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 60, y: 40)), 0.2, accuracy: 0.01, "tinted inside the mask")
        XCTAssertEqual(try alpha(drawing: tint, at: CGPoint(x: 5, y: 5)), 0, "clear outside it")
        view.shape = .rounded(6)
        XCTAssertTrue(view.subviews.isEmpty)
    }

    func testTheClassicBlurIsAVisualEffectViewInTheShape() throws {
        for (material, windowBlur) in [(HUDGlassView.Material.visualEffect, blur!), (.windowBlur, unavailable!)] {
            let view = backdrop(.rounded(20), material: material, blur: windowBlur)
            XCTAssertEqual(view.material, .visualEffect)
            let effect = try XCTUnwrap(view.effectView)
            XCTAssertTrue(view.subviews == [effect])
            XCTAssertEqual(effect.material, .hudWindow)
            XCTAssertEqual(effect.blendingMode, .behindWindow)
            XCTAssertEqual(effect.state, .active)
            XCTAssertEqual(effect.frame, view.bounds)
            XCTAssertNil(view.layer?.backgroundColor, "no tint over the classic blur")
            XCTAssertEqual(view.layer?.cornerRadius, 20)
            XCTAssertEqual(view.layer?.masksToBounds, true)
            XCTAssertNil(effect.hitTest(CGPoint(x: 10, y: 10)))
            let mask = centreMask(frame.size)
            view.shape = .mask(mask)
            XCTAssertTrue(effect.maskImage === mask)
            XCTAssertEqual(view.layer?.masksToBounds, false)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: 60, height: 80), transform: nil)
            view.shape = .path(path)
            let cut = try XCTUnwrap(effect.maskImage)
            XCTAssertEqual(cut.size, view.bounds.size)
        }
    }

    func testTheWindowIsBlurredWhileTheBackdropIsInIt() {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 120, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = backdrop(.rounded(20))
        window.contentView?.addSubview(view)
        XCTAssertEqual(calls, [Call(window: window.windowNumber, radius: 25)])
        view.removeFromSuperview()
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: window.windowNumber, radius: 0))
        // The classic blur leaves the window alone.
        calls = []
        let classic = backdrop(.rounded(20), material: .visualEffect)
        window.contentView?.addSubview(classic)
        classic.removeFromSuperview()
        clock.advance(by: 1)
        XCTAssertEqual(calls, [])
    }

    func testAWindowGoingAwayWithItsBackdropInItIsLetGo() {
        weak var gone: NSWindow?
        autoreleasepool {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 120, height: 80),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = backdrop(.rounded(20))
            gone = window
        }
        // The window deallocates with the backdrop still in it; the backdrop leaves it during
        // the window's deallocation.
        XCTAssertNil(gone, "the window went away")
        clock.advance(by: 1)
        XCTAssertFalse(calls.contains { $0.radius == 0 }, "nothing to clear on a window that is gone")
    }

    func testReduceTransparencyTakesTheClassicBlurAndBack() throws {
        var reduced = false
        let center = NotificationCenter()
        let setting = HUDTransparencySetting(isReduced: { reduced }, center: center)
        let blur = HUDWindowBlur(setter: { [unowned self] window, radius in calls.append(Call(window: window, radius: radius)) },
                                 scheduler: clock.scheduler, transparency: setting)
        let window = self.window()
        defer { window.close() }
        let view = backdrop(.rounded(20), blur: blur)
        view.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.addSubview(view)
        XCTAssertEqual(view.material, .windowBlur)
        XCTAssertEqual(calls, [Call(window: window.windowNumber, radius: 25)])
        // The user turns on Reduce transparency: the classic blur, which the system makes
        // opaque, and the window's blur is cleared.
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(view.material, .visualEffect)
        let effect = try XCTUnwrap(view.effectView)
        XCTAssertTrue(view.subviews == [effect])
        XCTAssertNil(view.layer?.backgroundColor, "no tint")
        XCTAssertEqual(view.layer?.cornerRadius, 20)
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: window.windowNumber, radius: 0))
        // And off again.
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(view.material, .windowBlur)
        XCTAssertNil(view.effectView)
        XCTAssertTrue(view.subviews.isEmpty)
        assertColor(view.layer?.backgroundColor, black20)
        XCTAssertEqual(calls.last, Call(window: window.windowNumber, radius: 25))
        // Made while it is on: the classic blur from the start. Asked for: classic either way.
        reduced = true
        XCTAssertEqual(backdrop(.rounded(20), blur: blur).material, .visualEffect)
        let classic = backdrop(.rounded(20), material: .visualEffect, blur: blur)
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(classic.material, .visualEffect)
    }

    func testTheTintFollowsItsWindowsAppearance() {
        let window = self.window()
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let view = backdrop(.rounded(20))
        window.contentView?.addSubview(view)
        assertColor(view.layer?.backgroundColor, white20)
        window.appearance = NSAppearance(named: .darkAqua)
        assertColor(view.layer?.backgroundColor, black20)
    }

    func testAViewMovingBetweenWindowsMovesTheBlur() {
        let a = window(), b = window()
        defer { a.close(); b.close() }
        let view = backdrop(.rounded(20))
        a.contentView?.addSubview(view)
        b.contentView?.addSubview(view)
        XCTAssertEqual(calls, [Call(window: a.windowNumber, radius: 25), Call(window: b.windowNumber, radius: 25)])
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: a.windowNumber, radius: 0), "the window it left, a turn later")
        XCTAssertFalse(calls.contains(Call(window: b.windowNumber, radius: 0)))
    }

    /// A window that is never ordered in, inside the main screen's visible frame.
    private func window() -> NSWindow {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 120, height: 80),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    func testTheBackdropTakesNoMouse() {
        let view = backdrop(.rounded(20))
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
    }
}
