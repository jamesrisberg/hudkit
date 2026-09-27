import XCTest
import AppKit
@testable import HUDKit

@MainActor
final class UIComponentTests: XCTestCase {
    func testGlassViewStylesAndLayering() {
        let glass = HUDGlassView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), style: .strip)
        XCTAssertEqual(glass.layer?.cornerRadius, 22)
        XCTAssertEqual(glass.layer?.borderWidth, 0.5)
        XCTAssertEqual(glass.subviews.count, 2, "backdrop + gloss")
        let content = NSView(frame: glass.bounds)
        glass.addSubview(content)
        XCTAssertTrue(glass.subviews.last === content, "content sits above the backdrop")
        XCTAssertTrue(glass.hitTest(CGPoint(x: 10, y: 10)) === content)
        content.removeFromSuperview()
        XCTAssertTrue(glass.hitTest(CGPoint(x: 10, y: 10)) === glass, "backdrop and gloss are click-through")

        if #available(macOS 26, *) { XCTAssertTrue(glass.usesLiquidGlass) } else { XCTAssertFalse(glass.usesLiquidGlass) }
        glass.maskImage = NSImage(size: CGSize(width: 10, height: 10))
        XCTAssertFalse(glass.usesLiquidGlass, "masked glass falls back to NSVisualEffectView")
        glass.style = .plain
        XCTAssertEqual(glass.subviews.count, 1, "no gloss")
        XCTAssertEqual(glass.layer?.cornerRadius, 0)
        let fallback = HUDGlassView(style: HUDGlassView.Style(material: .visualEffect))
        XCTAssertFalse(fallback.usesLiquidGlass)
    }

    func testPanelWindowRecipe() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), keyable: true)
        XCTAssertTrue(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(w.styleMask.contains(.borderless) || w.styleMask.rawValue & NSWindow.StyleMask.titled.rawValue == 0)
        XCTAssertEqual(w.level, .floating)
        XCTAssertTrue(w.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(w.isOpaque)
        XCTAssertFalse(w.hidesOnDeactivate)
        XCTAssertTrue(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
        w.keyable = false
        XCTAssertFalse(w.canBecomeKey)
    }

    func testHoverRecipeUnchanged() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(w.behavior, .hover)
        XCTAssertEqual(w.styleMask, [.borderless, .nonactivatingPanel, .fullSizeContentView])
        XCTAssertEqual(w.level, .floating)
        XCTAssertEqual(w.collectionBehavior, [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary])
        XCTAssertEqual(w.animationBehavior, .utilityWindow)
        XCTAssertFalse(w.canBecomeKey, "click-only by default")
        XCTAssertFalse(w.canBecomeMain)
        XCTAssertTrue(w.isMovableByWindowBackground)
        XCTAssertFalse(w.isReleasedWhenClosed)
        let custom = HUDPanelWindow(contentRect: .zero, styleMask: HUDPanelWindow.recipeStyleMask, backing: .buffered, defer: false)
        custom.applyHUDRecipe(level: .statusBar)
        XCTAssertEqual(custom.level, .statusBar)
        XCTAssertEqual(custom.behavior, .hover)
    }

    func testWindowedRecipe() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), behavior: .windowed)
        XCTAssertEqual(w.behavior, .windowed)
        XCTAssertFalse(w.styleMask.contains(.nonactivatingPanel), "a click activates the app")
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(w.styleMask.contains(.titled))
        XCTAssertEqual(w.level, .normal)
        XCTAssertEqual(w.collectionBehavior, [.managed, .participatesInCycle])
        XCTAssertFalse(w.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(w.animationBehavior, .documentWindow)
        XCTAssertTrue(w.canBecomeKey)
        XCTAssertTrue(w.canBecomeMain)
        XCTAssertFalse(w.hidesOnDeactivate)
        XCTAssertFalse(w.isOpaque)
        XCTAssertTrue(w.hasShadow)
        XCTAssertTrue(w.isMovableByWindowBackground)
        XCTAssertFalse(w.isReleasedWhenClosed)
        XCTAssertTrue(w.showsInDock)
    }

    func testBehaviourSwitchKeepsOtherStyleBits() {
        let w = HUDPanelWindow(contentRect: .zero, styleMask: HUDPanelWindow.recipeStyleMask.union(.resizable),
                               backing: .buffered, defer: false)
        w.keyable = true
        w.applyHUDRecipe(behavior: .windowed)
        XCTAssertTrue(w.styleMask.contains(.resizable))
        XCTAssertFalse(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(w.level, .normal)
        w.applyHUDRecipe(behavior: .hover)
        XCTAssertTrue(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(w.styleMask.contains(.resizable))
        XCTAssertEqual(w.level, .floating)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
        XCTAssertFalse(w.canBecomeMain)
        XCTAssertTrue(w.canBecomeKey, "keyable hover panel")
        if let prevents = w.preventsActivation { XCTAssertTrue(prevents, "back to non-activating") }
        w.applyHUDRecipe(behavior: .windowed, level: .floating)
        if let prevents = w.preventsActivation { XCTAssertFalse(prevents, "switched to activating") }
        XCTAssertEqual(w.level, .floating, "explicit level wins")
    }

    func testTakesFocusByReason() {
        XCTAssertFalse(HUDPanelWindow.takesFocus(HUDPanelTransition(reason: .hover)))
        XCTAssertTrue(HUDPanelWindow.takesFocus(HUDPanelTransition(reason: .click)))
        XCTAssertTrue(HUDPanelWindow.takesFocus(HUDPanelTransition(reason: .summon)))
        XCTAssertTrue(HUDPanelWindow.takesFocus(HUDPanelTransition()))
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), behavior: .windowed)
        XCTAssertFalse(w.activateOnShow(HUDPanelTransition(reason: .hover)))
        XCTAssertTrue(w.isVisible, "a hover show still orders the window in")
        w.orderOut(nil)
    }

    func testDockPolicyFollowsWindowedVisibility() {
        let policy = HUDDockPolicy.shared
        var applied: [NSApplication.ActivationPolicy] = []
        let savedApply = policy.apply
        policy.apply = { applied.append($0) }
        defer { policy.apply = savedApply }

        let hover = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        hover.orderFrontRegardless()
        XCTAssertEqual(applied, [], "hover panels never change the policy")
        hover.orderOut(nil)

        let a = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), behavior: .windowed)
        let b = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), behavior: .windowed)
        a.orderFront(nil)
        XCTAssertEqual(applied, [.regular])
        b.orderFrontRegardless()
        XCTAssertEqual(policy.visibleWindowedCount, 2)
        a.orderOut(nil)
        XCTAssertEqual(applied, [.regular], "still one windowed panel showing")
        b.orderOut(nil)
        XCTAssertEqual(applied, [.regular, .accessory])

        a.showsInDock = false
        a.orderFront(nil)
        XCTAssertEqual(applied, [.regular, .accessory], "opted out")
        a.showsInDock = true
        XCTAssertEqual(applied, [.regular, .accessory, .regular])
        a.applyHUDRecipe(behavior: .hover)
        XCTAssertEqual(applied, [.regular, .accessory, .regular, .accessory], "switching to hover drops the tile")
        a.orderOut(nil)
    }

    func testHotKeyCodesAndDisplay() {
        XCTAssertNotNil(HUDHotKeyCenter.keyCode(for: "space"))
        XCTAssertNotNil(HUDHotKeyCenter.keyCode(for: "F5"))
        XCTAssertNil(HUDHotKeyCenter.keyCode(for: "nope"))
        XCTAssertEqual(HUDHotKey(key: "space", modifiers: ["control", "option"]).display, "⌃⌥SPACE")
        XCTAssertEqual(HUDHotKey(key: "k", modifiers: ["cmd", "shift"]).display, "⌘⇧K")
        XCTAssertEqual(HUDHotKeyCenter.carbonModifiers(["ctrl", "alt"]), HUDHotKeyCenter.carbonModifiers(["control", "option"]))
        let decoded = try? JSONDecoder().decode(HUDHotKey.self, from: Data(#"{"key":"d","modifiers":["control","option"]}"#.utf8))
        XCTAssertEqual(decoded, HUDHotKey(key: "d", modifiers: ["control", "option"]))
    }

    func testPanelWindowIsNotClampedBelowMenuBar() {
        guard let screen = NSScreen.main else { return }
        let w = HUDPanelWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100))
        let above = CGRect(x: 100, y: screen.frame.maxY - 12, width: 200, height: 100)
        w.setFrame(above, display: false)
        XCTAssertEqual(w.frame.origin.y, above.origin.y, accuracy: 0.5, "top-edge parking must not be clamped by AppKit")
    }

    func testFadeInDuringFadeOutKeepsWindowVisible() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        w.orderFrontRegardless()
        let done = expectation(description: "fade settled")
        HUDAnimation.fadeOut(w, duration: 0.05)
        HUDAnimation.fadeIn(w, duration: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(w.isVisible, "a fade-in that interrupts a fade-out must win")
        XCTAssertEqual(w.alphaValue, 1, accuracy: 0.01)
        w.orderOut(nil)
    }

    func testSlideOutUsesLiveFrameAfterSlideInLanded() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let first = CGRect(x: 200, y: 200, width: 100, height: 100)
        let moved = CGRect(x: 500, y: 300, width: 100, height: 100)
        let landed = expectation(description: "landed")
        HUDAnimation.slide(in: w, from: .bottom, to: first, duration: 0.05) { landed.fulfill() }
        wait(for: [landed], timeout: 2)
        w.setFrame(moved, display: false)  // the user dragged it, or MacHUD re-framed it
        let out = expectation(description: "out")
        HUDAnimation.slideOut(w, toward: .bottom, duration: 0.05) { out.fulfill() }
        wait(for: [out], timeout: 2)
        XCTAssertEqual(w.frame.origin, moved.origin, "slideOut must restore the live frame, not the old slide-in rest")
        XCTAssertFalse(w.isVisible)
    }
}

@MainActor
final class StatusIconTests: XCTestCase {
    func testFallsBackToTheSymbolWithoutABundledGlyph() throws {
        let empty = try XCTUnwrap(Bundle(path: FileManager.default.temporaryDirectory.path))
        let image = try XCTUnwrap(HUDStatusIcon.image(fallbackSymbol: "sparkles", accessibilityDescription: "Test", bundle: empty))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Test")
    }

    func testUsesTheBundledGlyph() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HUDStatusIcon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("MenuBarIcon.png"))
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        let image = try XCTUnwrap(HUDStatusIcon.image(fallbackSymbol: "sparkles", accessibilityDescription: nil, bundle: bundle))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    @MainActor
    func testEditMenuInstallsOnceWithStandardKeyEquivalents() {
        _ = NSApplication.shared
        HUDEditMenu.install(appName: "Test")
        let edit = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu
        XCTAssertNotNil(edit)
        let paste = edit?.items.first { $0.title == "Paste" }
        XCTAssertEqual(paste?.keyEquivalent, "v")
        XCTAssertEqual(paste?.keyEquivalentModifierMask, [.command])
        let count = NSApp.mainMenu?.items.count
        HUDEditMenu.install(appName: "Test")
        XCTAssertEqual(NSApp.mainMenu?.items.count, count, "installing twice must not duplicate menus")
    }
}
