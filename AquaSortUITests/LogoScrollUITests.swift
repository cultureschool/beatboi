import XCTest

/// Drives the real beatboi logo drag gesture and verifies the page keeps
/// scrolling across consecutive pulls — the interaction previously broke after
/// the first pull, so this is the regression guard.
final class LogoScrollUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLogoPullScrollSurvivesMultiplePulls() throws {
        let app = XCUIApplication()
        app.launch()

        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 8), "beatboi logo should exist")

        // Settle the layout, then confirm a fresh launch rests at the top. The
        // first scroll-metrics callback can transiently report an offset before
        // the ScrollView clamps, so sample until the reading is stable.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(scrollFraction(logo, expectedMotion: false), 0.0, accuracy: 0.05, "fresh launch should be at the top")

        // Pull 1: drag the logo down — the page should scroll down (scrollbar
        // style: pull down -> page goes down), but not so far that one pull
        // bottoms out the page. The drag starts at the logo's VISUAL center
        // (its frame is top-aligned in a taller brand row), which also
        // regression-guards the touch target: a drag starting on the visible
        // artwork must scroll the page.
        dragLogo(logo, dy: 50)
        let afterPull1 = scrollFraction(logo)
        XCTAssertGreaterThan(afterPull1, 0.05, "first down-pull should scroll the page down")
        XCTAssertLessThan(afterPull1, 0.98, "one pull should not rocket to the very bottom")

        // Pull 2: same direction again — THIS is the case that used to break.
        dragLogo(logo, dy: 50)
        let afterPull2 = scrollFraction(logo)
        XCTAssertGreaterThan(afterPull2, afterPull1 + 0.02, "second down-pull must scroll further (regression guard)")
        XCTAssertLessThan(afterPull2, 0.98, "two pulls should not rocket to the very bottom")

        // Pull 3: reverse direction — dragging up scrolls back up.
        dragLogo(logo, dy: -40)
        let afterPull3 = scrollFraction(logo)
        XCTAssertLessThan(afterPull3, afterPull2 - 0.02, "up-pull should scroll back up")
    }

    /// A slow, deliberate drag must not trigger the flick-to-glide momentum:
    /// the page should track the finger and stop with it.
    @MainActor
    func testSlowLogoDragDoesNotMomentumGlide() throws {
        let app = XCUIApplication()
        app.launch()

        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 8), "beatboi logo should exist")

        dragLogo(logo, dy: 60, velocity: .slow)
        let settled = scrollFraction(logo)
        XCTAssertGreaterThan(settled, 0.03, "a slow pull should still scroll the page")

        // With no momentum, the position must be stable once the seek settles.
        let again = scrollFraction(logo)
        XCTAssertEqual(again, settled, accuracy: 0.02, "a slow pull must not keep gliding after release")
    }

    @MainActor
    private func dragLogo(
        _ logo: XCUIElement,
        dy: CGFloat,
        velocity: XCUIGestureVelocity = .default
    ) {
        // Press on the artwork's visible center inside the brand row: the frame
        // is top-aligned in a 106pt-tall row, so the visible mark's center sits
        // at roughly y = 28 of the row (art height 46 / 2 + 5pt drop-in).
        let start = logo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = start.withOffset(CGVector(dx: 0, dy: dy))
        if velocity == .slow {
            // XCUIGestureVelocity.slow drags deliberately, keeping per-event
            // velocity below the flick threshold.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        } else {
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
        }
        // Let the seek animation settle; momentum glides are awaited by the
        // scroll sampler itself (it waits until the value stops changing).
        Thread.sleep(forTimeInterval: 0.35)
    }

    /// Two-finger scrolling: this XCTest SDK cannot synthesize multi-touch
    /// drags (its press overloads have no touch-count parameter), so the
    /// two-finger pipeline is exercised through the app's DEBUG-only simulator
    /// hook, which feeds the exact callbacks the recognizer invokes. The
    /// recognizer wiring itself (exclusive two-finger claim vs. the native
    /// one-finger pan) must be verified by hand on device.
    @MainActor
    func testTwoFingerDragScrollsPage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-GBTwoFingerTest"]
        app.launch()

        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 8), "beatboi logo should exist")

        // The hook starts 1.2s after launch, drags ~120pt down, then releases
        // with flick velocity that fires the glide. The sampler waits out the
        // full motion (drag + glide) before asserting.
        let afterSwipe = scrollFraction(logo)
        XCTAssertGreaterThan(afterSwipe, 0.05, "two-finger swipe should scroll the page down")
        XCTAssertLessThan(afterSwipe, 0.98, "a two-finger swipe should not rocket to the bottom")
    }

    /// Reads the live scroll fraction from the logo's accessibility value
    /// (0.00 = top of page, 1.00 = bottom). Waits until the value stops
    /// changing, so momentum glides are allowed to finish before the caller
    /// asserts. When motion already stalled before the call, `expectedMotion`
    /// makes the wait fail fast so stall regressions surface immediately.
    @MainActor
    private func scrollFraction(_ logo: XCUIElement, expectedMotion: Bool = true) -> Double {
        let deadline = Date().addingTimeInterval(expectedMotion ? 5 : 3)
        var last = -1.0
        var lastChange = Date()
        while Date() < deadline {
            if let raw = logo.value as? String, let frac = Double(raw) {
                let now = Date()
                if abs(frac - last) >= 0.0001, frac >= 0 {
                    last = frac
                    lastChange = now
                }
                if now.timeIntervalSince(lastChange) > 0.6 {
                    return last
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if expectedMotion {
            XCTFail("scroll position kept moving for 5s after the gesture — momentum never settled")
        }
        return last
    }
}
