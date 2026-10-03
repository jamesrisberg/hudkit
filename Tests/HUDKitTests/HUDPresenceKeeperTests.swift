import XCTest
import AppKit
@testable import HUDKit

/// `HUDPresenceKeeper` with a fake probe and a hand-advanced clock: which windows it tracks,
/// which it repairs on the settled signal, how, which it only reports, and what it logs. The
/// windows are real (small, nearly transparent, ordered out in tearDown); what the keeper
/// reads about them is fake.
@MainActor
final class HUDPresenceKeeperTests: XCTestCase {
    private var clock: ManualClock!
    private var monitor: HUDEnvironmentMonitor!
    private var fake: FakePresenceProbe!
    private var keeper: HUDPresenceKeeper!
    private var findings: [HUDPresenceKeeper.Finding] = []
    private var windows: [NSWindow] = []
    private var frame = CGRect.zero

    override func setUp() {
        clock = ManualClock()
        monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        fake = FakePresenceProbe()
        frame = liveTestFrame()
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        fake.screens = [HUDScreenSnapshot(id: "main", frame: screen, visibleFrame: screen)]
        keeper = HUDPresenceKeeper(environment: monitor, scheduler: clock.scheduler, probe: fake.probe)
        findings = []
        keeper.onFinding = { [unowned self] in self.findings.append($0) }
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// A window of `behavior` kept by the test's keeper, ordered in, with its records cleared.
    private func shown(_ behavior: HUDPanelWindow.Behavior, keyable: Bool = false) -> RecordingPanel {
        let w = RecordingPanel(contentRect: frame, behavior: behavior)
        w.keyable = keyable
        w.showsInDock = false   // a windowed one must not give the test runner a Dock tile
        w.alphaValue = 0.02
        w.presenceKeeper = keeper
        windows.append(w)
        w.orderFrontRegardless()
        w.resetRecords()
        return w
    }

    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    /// Counts `activeSpaceDidSettleNotification`s for `window` (posted synchronously).
    private func settleNotifications(for window: NSWindow) -> () -> Int {
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: HUDPanelWindow.activeSpaceDidSettleNotification,
                                                           object: window, queue: nil) { _ in counter.count += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        return { counter.count }
    }

    /// One settle of the test's monitor: the settle delay, then long enough for every
    /// follow-up and second look it starts.
    private func settle(_ change: HUDEnvironmentMonitor.Change = .activeSpace) {
        monitor.note(change)
        clock.advance(by: 2)
    }

    // MARK: - Tracking

    func testAppsRegisterNothing() {
        let w = HUDPanelWindow(contentRect: frame)
        w.alphaValue = 0.02
        windows.append(w)
        XCTAssertTrue(w.presenceKeeper === HUDPresenceKeeper.shared)
        XCTAssertFalse(HUDPresenceKeeper.shared.isTracking(w))
        w.orderFrontRegardless()
        XCTAssertTrue(HUDPresenceKeeper.shared.isTracking(w), "an ordered-in hover window is kept")
        w.orderOut(nil)
        XCTAssertFalse(HUDPresenceKeeper.shared.isTracking(w))
    }

    func testTracksHoverAndWidgetWindowsWhileOrderedIn() {
        let hover = shown(.hover)
        let widget = shown(.widget)
        let windowed = shown(.windowed)
        XCTAssertEqual(keeper.trackedWindows, [hover, widget], "windowed windows stay on their own Space")

        hover.orderOut(nil)
        XCTAssertEqual(keeper.trackedWindows, [widget], "ordered out")
        hover.orderFront(nil)
        hover.orderFront(nil)
        XCTAssertEqual(keeper.trackedWindows, [widget, hover], "tracked once")
        widget.close()
        XCTAssertEqual(keeper.trackedWindows, [hover], "closed")

        hover.applyHUDRecipe(behavior: .windowed)
        XCTAssertEqual(keeper.trackedWindows, [], "switched to windowed while shown")
        hover.applyHUDRecipe(behavior: .hover)
        XCTAssertEqual(keeper.trackedWindows, [hover], "and back")
        windowed.applyHUDRecipe(behavior: .widget)
        XCTAssertEqual(keeper.trackedWindows, [hover, windowed])
    }

    // MARK: - The settled signal

    func testChecksOnTheSettledSignal() {
        let w = shown(.hover)
        fake.strand(w)
        monitor.note(.activeSpace)
        clock.advance(by: 0.2)
        monitor.note(.wake)
        clock.advance(by: 0.3)
        XCTAssertEqual(findings.count, 0, "not before the burst has been quiet for the settle delay")
        clock.advance(by: 0.06)
        XCTAssertEqual(findings.map(\.change), [[.activeSpace, .wake]], "once, with every change seen")
    }

    func testHealthyWindowsAreNotTouched() {
        let hover = shown(.hover)
        let widget = shown(.widget)
        fake.server[ObjectIdentifier(hover)] = HUDPresenceKeeper.ServerWindow(isOnScreen: true,
                                                                             bounds: frame.offsetBy(dx: 0.6, dy: -0.4))
        XCTAssertEqual(keeper.check(.activeSpace), [])
        XCTAssertEqual(clock.pendingCount, 0, "nothing to look at again (a sub-point difference is rounding)")
        clock.advance(by: 2)
        XCTAssertTrue(hover.untouched, "no Spaces toggle, no re-order, no frame set, no delegate callback")
        XCTAssertTrue(widget.untouched)
        XCTAssertEqual(findings.count, 0, "and nothing logged")
    }

    // MARK: - Off the user's desktop

    func testHoverOffTheDesktopIsReassertedThenMovedIfTheServerStillHasItOffScreen() {
        let w = shown(.hover)
        let settled = settleNotifications(for: w)
        fake.strand(w)
        let found = keeper.check(.activeSpace)
        XCTAssertEqual(found.map(\.kind), [.offDesktop])
        let hover = HUDPanelWindow.hoverCollectionBehavior
        XCTAssertEqual(w.behaviourSets, [hover.subtracting(.canJoinAllSpaces), hover], "re-asserted")
        XCTAssertEqual(w.orderIns, 0, "not re-ordered")
        XCTAssertEqual(w.moves, 0)

        clock.advance(by: HUDPanelWindow.spaceCheckDelay)
        XCTAssertEqual(w.moves, 1, "the window server still has it off screen: moved to the active Space")
        XCTAssertEqual(settled(), 0)
        fake.heal(w)
        clock.advance(by: HUDPanelWindow.spaceCheckDelay)
        XCTAssertEqual(settled(), 1, "the settled onActiveSpace is announced once AppKit has caught up")
        XCTAssertEqual(findings.map(\.kind), [.offDesktop], "the move worked: nothing more to say")
    }

    func testHoverBroughtBackByTheReassertionIsNotMoved() {
        let w = shown(.hover)
        let settled = settleNotifications(for: w)
        fake.strand(w)
        keeper.check(.screensWake)
        fake.heal(w)
        clock.advance(by: 1)
        XCTAssertEqual(w.moves, 0)
        XCTAssertEqual(settled(), 1, "onActiveSpace went from false to true")
    }

    /// A window AppKit calls off the active Space while the window server lists it on screen
    /// (or does not list it at all) gets one attempt and no retry: the user may be looking at
    /// it, and only the window server's word moves a window (ordering out and in would be seen,
    /// and resigns key, collapsing the voice host's expanded conversation).
    func testAWindowTheServerShowsOnScreenGetsOneAttemptAndNoRetry() throws {
        let w = shown(.hover, keyable: true)
        fake.onActiveSpace[ObjectIdentifier(w)] = false
        for _ in 0..<20 { monitor.note(.activeSpace); clock.advance(by: 5) }   // 100 s of desktop switches
        let hover = HUDPanelWindow.hoverCollectionBehavior
        XCTAssertEqual(w.behaviourSets, [hover.subtracting(.canJoinAllSpaces), hover], "one re-assertion, no retry")
        XCTAssertEqual(w.moves, 0)
        XCTAssertEqual(w.orderIns, 0)
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop])
        XCTAssertTrue(findings[1].message.contains("not repaired again until it is seen on the desktop"), findings[1].message)

        fake.heal(w)
        settle()
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop, .back])
        XCTAssertTrue(try XCTUnwrap(findings.last).message.contains("is back on the user's desktop after 1 attempt:"))

        fake.onActiveSpace[ObjectIdentifier(w)] = false
        fake.server[ObjectIdentifier(w)] = .some(nil)
        w.resetRecords()
        for _ in 0..<10 { monitor.note(.activeSpace); clock.advance(by: 5) }
        XCTAssertEqual(w.behaviourSets.count, 2, "unlisted: one attempt, no retry either")
        XCTAssertEqual(w.moves, 0)
    }

    /// A window the window server still has off screen after a repair is tried again on later
    /// settled signals, at most once every 30 s, each time with the same repair (unseen: it is
    /// not on screen). The failure is said once; the retries say nothing.
    func testAWindowStillOffScreenIsTriedAgainEvery30Seconds() throws {
        XCTAssertEqual(HUDPresenceKeeper.defaultRetryInterval, 30)
        let w = shown(.hover)
        fake.strand(w)
        // A desktop switch every 5 s for 100 s. Attempts at 0.35 s, then at the first settle
        // 30 s after each failure: 35.35 s and 70.35 s.
        for _ in 0..<20 { monitor.note(.activeSpace); clock.advance(by: 5) }
        XCTAssertEqual(w.moves, 3, "three attempts, each a re-assertion and then the move")
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop], "one failure line; retries log nothing")
        XCTAssertTrue(findings[1].message.contains("tried again at most every 30 s while the window server has it off screen"),
                      findings[1].message)
    }

    func testAWindowBackOnTheThirdAttemptSaysSoOnce() throws {
        let w = shown(.widget)
        fake.strand(w)
        settle()                     // attempt 1 fails
        clock.advance(by: 30)
        settle()                     // attempt 2 fails
        XCTAssertEqual(w.orderIns, 2)
        clock.advance(by: 30)
        monitor.note(.wake)
        clock.advance(by: HUDEnvironmentMonitor.defaultSettleDelay)
        XCTAssertEqual(w.orderIns, 3, "attempt 3")
        fake.heal(w)                 // and this one takes
        clock.advance(by: 1)
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop, .back])
        let back = try XCTUnwrap(findings.last)
        XCTAssertEqual(back.attempts, 3)
        XCTAssertEqual(back.message,
                       "RecordingPanel #\(w.windowNumber) (widget) is back on the user's desktop after 3 attempts: "
                           + "frame \(HUDLog.format(frame)) isOnActiveSpace=true serverOnScreen=true "
                           + "serverBounds \(HUDLog.format(frame)) after wake")
        settle()
        settle()
        XCTAssertEqual(findings.count, 3, "nothing more")
        XCTAssertEqual(w.orderIns, 3)
    }

    func testOnTheActiveSpaceButNotOnScreenIsRepaired() {
        let w = shown(.hover)
        fake.server[ObjectIdentifier(w)] = HUDPresenceKeeper.ServerWindow(isOnScreen: false, bounds: frame)
        XCTAssertEqual(keeper.check(.wake).count, 1, "AppKit can be wrong; the window server's flag counts")
    }

    func testUnlistedWindowOnTheActiveSpaceIsLeftAlone() {
        let w = shown(.hover)
        fake.server[ObjectIdentifier(w)] = .some(nil)
        XCTAssertEqual(keeper.check(.wake), [], "no evidence from the window server either way")
        XCTAssertTrue(w.untouched)
        fake.onActiveSpace[ObjectIdentifier(w)] = false
        XCTAssertEqual(keeper.check(.wake).count, 1, "AppKit alone says it is away")
    }

    func testWidgetOffTheDesktopIsReassertedAndOrderedInNeverMoved() {
        let w = shown(.widget)
        fake.strand(w)
        XCTAssertEqual(keeper.check(.activeSpace).map(\.behavior), [.widget])
        let widget = HUDPanelWindow.widgetCollectionBehavior
        XCTAssertEqual(w.behaviourSets, [widget.subtracting(.canJoinAllSpaces), widget])
        XCTAssertEqual(w.orderIns, 1, "ordered in, as show(presenting:) does")
        clock.advance(by: 2)
        XCTAssertEqual(w.moves, 0, "no .moveToActiveSpace for widgets")
        XCTAssertFalse(w.behaviourSets.contains { $0.contains(.moveToActiveSpace) })
    }

    func testWidgetOnAFullScreenSpaceIsLeftAlone() {
        let widget = shown(.widget)
        let hover = shown(.hover)
        fake.strand(widget)
        fake.strand(hover)
        fake.windows = [HUDWindowSnapshot(windowID: 77, ownerPID: 4242, layer: 0, bounds: fake.screens[0].frame)]
        let found = keeper.check(.activeSpace)
        XCTAssertEqual(found.map(\.behavior), [.hover], "hover windows join full-screen Spaces; widgets do not")
        XCTAssertTrue(widget.untouched)
        XCTAssertEqual(findings.count, 1, "the widget is not logged either")

        clock.advance(by: 2)
        fake.windows = [HUDWindowSnapshot(windowID: 77, ownerPID: 4242, layer: 0, bounds: fake.screens[0].frame, alpha: 0)]
        XCTAssertEqual(keeper.check(.activeSpace).map(\.behavior), [.widget],
                       "an undrawn screen-sized window is not a full-screen Space")
    }

    /// A full-screen Space the exact-size test does not recognise (Split View's two half-width
    /// windows) keeps a widget off screen however often it is repaired: it is tried at most
    /// every 30 s, unseen, and said once.
    func testAWidgetOnAnUnrecognisedFullScreenSpaceIsRetriedQuietly() throws {
        let w = shown(.widget)
        let half = fake.screens[0].frame.divided(atDistance: fake.screens[0].frame.width / 2, from: .minXEdge)
        fake.windows = [HUDWindowSnapshot(windowID: 1, ownerPID: 10, layer: 0, bounds: half.slice),
                        HUDWindowSnapshot(windowID: 2, ownerPID: 11, layer: 0, bounds: half.remainder)]
        fake.strand(w)
        for change in [HUDEnvironmentMonitor.Change.activeSpace, .wake, .screensWake, .activeSpace, .screenParameters] {
            settle(change)
        }
        XCTAssertEqual(w.orderIns, 1, "one attempt in the first 30 s")
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop], "and one line saying it had no effect")
        clock.advance(by: 25)
        settle()
        XCTAssertEqual(w.orderIns, 2, "tried again 30 s on")
        XCTAssertEqual(findings.count, 2, "without a line")

        fake.heal(w)
        settle()
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop, .back])
        XCTAssertEqual(findings.last?.attempts, 2, "seen on the desktop again, after two attempts")
        fake.strand(w)
        w.resetRecords()
        settle()
        XCTAssertEqual(w.orderIns, 1, "a new episode starts at once")
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop, .back, .offDesktop, .stillOffDesktop])
    }

    func testOrderingOutAndInResetsTheCount() throws {
        let w = shown(.hover)
        fake.strand(w)
        settle()
        clock.advance(by: 31)
        settle()
        XCTAssertEqual(w.moves, 2, "two failed attempts")
        w.orderOut(nil)
        w.orderFrontRegardless()
        settle()
        XCTAssertEqual(w.moves, 3, "tried at once after the order-in, without waiting out the 30 s")
        XCTAssertEqual(findings.map(\.kind), [.offDesktop, .stillOffDesktop, .offDesktop, .stillOffDesktop],
                       "a new episode, said anew")
        clock.advance(by: 31)
        monitor.note(.activeSpace)
        clock.advance(by: HUDEnvironmentMonitor.defaultSettleDelay)
        fake.heal(w)
        clock.advance(by: 1)
        XCTAssertEqual(findings.last?.kind, .back)
        XCTAssertEqual(findings.last?.attempts, 2, "counted from the order-in")
    }

    func testWindowsNotMeantToBeSeenAreLeftAlone() {
        let faded = shown(.hover)
        faded.alphaValue = 0
        let parked = shown(.widget)
        parked.setFrame(fake.screens[0].frame.offsetBy(dx: -10_000, dy: 0), display: false)
        parked.resetRecords()
        fake.strand(faded)
        fake.strand(parked)
        XCTAssertEqual(keeper.check(.activeSpace), [])
        XCTAssertTrue(faded.untouched, "alpha 0: hidden on purpose")
        XCTAssertTrue(parked.untouched, "on no screen")
    }

    func testFindingNamesTheWindowAndWhatWasWrong() throws {
        let w = shown(.hover)
        w.identifier = NSUserInterfaceItemIdentifier("voice-orb")
        fake.strand(w)
        let finding = try XCTUnwrap(keeper.check([.activeSpace, .wake]).first)
        let rect = HUDLog.format(frame)
        XCTAssertEqual(finding.message,
                       "restoring RecordingPanel \"voice-orb\" #\(w.windowNumber) (hover), off the user's desktop: "
                           + "frame \(rect) isOnActiveSpace=false serverOnScreen=false serverBounds \(rect) "
                           + "after activeSpace,wake")
        w.identifier = nil
        w.title = ""
        w.panelID = "main"
        XCTAssertTrue(w.logName.hasPrefix("RecordingPanel \"main\" #"), w.logName)
        w.panelID = nil
        XCTAssertEqual(w.logName, "RecordingPanel #\(w.windowNumber)", "nothing set: class and number")
    }

    // MARK: - Displaced (reported, never repaired)

    func testTransientDisplacementIsNotReported() {
        let w = shown(.hover)
        fake.displace(w, dx: 2090)   // mid-swipe: all-Spaces windows travel with the desktop
        XCTAssertEqual(keeper.check(.activeSpace), [])
        XCTAssertEqual(clock.pendingDelays, [HUDPresenceKeeper.defaultDisplacementRecheckDelay], "looked at again later")
        fake.heal(w)
        clock.advance(by: 1)
        XCTAssertEqual(findings.count, 0)
        XCTAssertTrue(w.untouched)
    }

    /// One window the window server still holds away from its frame, by the same amount 0.5 s
    /// later, beside one that is where it should be: reported once, and nothing is done to it
    /// (a frame set would reach the app's delegate as the user moving the window).
    func testPersistentDisplacementIsReportedAndNotRepaired() throws {
        let w = shown(.hover, keyable: true)
        let healthy = shown(.widget)
        w.makeKeyAndOrderFront(nil)
        let wasKey = w.isKeyWindow
        XCTAssertTrue(wasKey, "precondition: key")
        w.resetRecords()
        fake.displace(w, dx: -2624)
        keeper.check(.activeSpace)
        monitor.note(.activeSpace)
        clock.advance(by: 0.4)   // another settle while the second look is pending
        XCTAssertEqual(findings.count, 0)
        clock.advance(by: 0.2)
        XCTAssertEqual(findings.map(\.kind), [.displaced], "still apart by the same amount 0.5 s later")
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.message,
                       "RecordingPanel #\(w.windowNumber) (hover) is displaced, not repaired: frame \(HUDLog.format(frame)) "
                           + "serverBounds \(HUDLog.format(frame.offsetBy(dx: -2624, dy: 0))) isOnActiveSpace=true "
                           + "serverOnScreen=true after activeSpace")
        clock.advance(by: 2)
        XCTAssertTrue(w.untouched, "no frame set, no delegate callback, no re-order, no Spaces toggle")
        XCTAssertEqual(w.frame, frame)
        XCTAssertTrue(w.isKeyWindow, "key status unchanged")
        XCTAssertTrue(healthy.untouched)
    }

    func testALoneDisplacedWindowIsReported() {
        let w = shown(.widget)
        fake.displace(w, dx: 2300)
        keeper.check(.screenParameters)
        clock.advance(by: 0.5)
        XCTAssertEqual(findings.map(\.kind), [.displaced],
                       "one window on the screen gives no common offset to excuse it")
        XCTAssertTrue(w.untouched)
    }

    /// Every kept window on the screen shifted by the same amount at both readings is a
    /// transition held in place (fingers resting mid-swipe), not a fault.
    func testACommonOffsetOnEveryWindowOfTheScreenIsNotReported() {
        let a = shown(.hover)
        let b = shown(.widget)
        fake.displace(a, dx: 1500)
        fake.displace(b, dx: 1500)
        keeper.check(.activeSpace)
        clock.advance(by: 1)
        XCTAssertEqual(findings.count, 0)

        fake.heal(b)   // b back where it belongs, a still away
        keeper.check(.activeSpace)
        clock.advance(by: 1)
        XCTAssertEqual(findings.map(\.window), [a.logName], "not common to the screen any more")
        XCTAssertTrue(a.untouched)
        XCTAssertTrue(b.untouched)
    }

    /// Still apart, but by a different amount: the window is moving (a transition in flight, or
    /// its app resizing it every frame, as the voice orb does while dictating), not stuck.
    func testMovingDisplacementIsNotReported() {
        let w = shown(.hover)
        fake.displace(w, dx: 2090)
        keeper.check(.activeSpace)
        fake.displace(w, dx: 1200)
        clock.advance(by: 1)
        XCTAssertEqual(findings.count, 0)

        fake.displace(w, dx: 2090)
        keeper.check(.activeSpace)
        w.setFrame(frame.insetBy(dx: -2, dy: -2), display: false)   // the app resizes it
        fake.displace(w, dx: 2090)   // the server lags the new frame by the same offset as before
        clock.advance(by: 1)
        XCTAssertEqual(findings.map(\.kind), [.displaced], "the same displacement from the current frame is stuck")
    }

    func testADisplacementIsReportedOncePerEpisode() {
        let w = shown(.hover)
        fake.displace(w, dx: 900)
        for _ in 0..<4 { settle() }
        XCTAssertEqual(findings.map(\.kind), [.displaced], "said once while it lasts")
        fake.heal(w)
        settle()
        fake.displace(w, dx: 900)
        settle()
        XCTAssertEqual(findings.map(\.kind), [.displaced, .displaced], "seen where it belongs in between: said again")
        XCTAssertTrue(w.untouched)
    }

    func testWindowOrderedOutBeforeTheSecondLookIsLeftAlone() {
        let w = shown(.hover)
        fake.displace(w, dx: 2090)
        keeper.check(.activeSpace)
        w.orderOut(nil)
        w.resetRecords()
        clock.advance(by: 1)
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertTrue(w.untouched)
        XCTAssertEqual(findings.count, 0)
    }
}
