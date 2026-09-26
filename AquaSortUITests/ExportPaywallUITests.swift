import XCTest

/// Regression guard for the WAV export paywall: WAV audio must be locked behind the
/// $1.99 purchase, and tapping its row must present the paywall sheet.
///
/// The purchase used to also cover MIDI and the editor used to hand out a project
/// file. Both rows are gone — WAV audio is the only export the app offers — so
/// this test asserts they stay gone. It also pins the copy: the store's product is
/// still named Export Pack, and that name has no business reaching the screen.
final class ExportPaywallUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWAVIsTheOnlyExportAndIsLockedBehindPaywall() throws {
        let app = XCUIApplication()
        app.launch()

        // Open the export sheet from the editor header.
        let exportButton = app.buttons["Export WAV"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 8), "export header button should exist")
        exportButton.tap()

        let exportTitle = app.staticTexts["TAKE YOUR TRACK OUT OF THE POCKET"]
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 8), "export sheet should present")

        // Without an entitlement the Beatpad header must not show the unlock badge.
        XCTAssertFalse(app.descendants(matching: .any)["exportPackBadge"].exists, "the unlock badge must be hidden without a verified entitlement")

        // WAV audio is the only row left, and it presents the paywall when tapped.
        let wavRow = app.buttons["export.wav"]
        XCTAssertTrue(wavRow.waitForExistence(timeout: 8), "WAV export row should exist")
        XCTAssertFalse(app.buttons["export.midi"].exists, "MIDI export row must no longer be offered")
        XCTAssertFalse(app.buttons["export.project"].exists, "project-file export row must no longer be offered")

        // Tapping the locked row must present the paywall, not an export dialog.
        wavRow.tap()
        XCTAssertTrue(app.staticTexts["WAV EXPORT"].waitForExistence(timeout: 8), "tapping WAV export should present the paywall")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "PACK")).count > 0,
            "the paywall must name the export, not the store's product"
        )
        let unlockButton = app.buttons["exportPaywall.unlockButton"]
        let unlockAppeared = unlockButton.waitForExistence(timeout: 10)
        if unlockAppeared {
            // When the store product loads we additionally verify the price copy.
            // The sandboxed test runner often can't reach StoreKit, so the loading
            // / retry states are acceptable — gating is what must hold either way.
            XCTAssertTrue(unlockButton.label.contains("1.99"), "paywall button should show the $1.99 price, got: \(unlockButton.label)")
        }
        XCTAssertTrue(app.buttons["exportPaywall.restoreButton"].exists, "paywall must offer restore purchases")
        XCTAssertTrue(
            unlockAppeared
                || app.staticTexts["CONNECTING TO CART…"].exists
                || app.staticTexts["STORE UNAVAILABLE — CHECK YOUR CONNECTION"].exists,
            "paywall should show a purchase, loading, or retry state"
        )

        // The paywall advertises WAV alone.
        XCTAssertFalse(app.staticTexts["MIDI FILE EXPORT"].exists, "paywall must not advertise MIDI export")

        // Close the paywall and confirm the export sheet is still up.
        let closeButton = app.buttons["CLOSE"].firstMatch
        if closeButton.waitForExistence(timeout: 4) { closeButton.tap() }
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 4), "export sheet should remain after closing the paywall")

        // Sharing is the same rendered WAV leaving the app, so it is gated by the same purchase:
        // a free share would be the paywall walking around the back.
        let shareRow = app.buttons["export.share"]
        XCTAssertTrue(shareRow.waitForExistence(timeout: 8), "the share row should be offered")
        shareRow.tap()
        XCTAssertTrue(
            app.staticTexts["WAV EXPORT"].waitForExistence(timeout: 8),
            "tapping share without the unlock should present the paywall, not the activity sheet"
        )
        if closeButton.waitForExistence(timeout: 4) { closeButton.tap() }
    }

    /// The unlocked header badge is a padlock and nothing else — no purchase name to read — and it
    /// is a way into the export sheet rather than a status light.
    ///
    /// The entitlement is seeded through the launch argument, which plants it in the same in-session
    /// floor a signed transaction raises, so this test exercises the real unlocked state instead of
    /// a bypass of it.
    @MainActor
    func testUnlockedPadlockIsWordlessAndOpensTheExportSheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--export-unlocked-ui-test"]
        app.launch()

        let padlock = app.descendants(matching: .any)["exportPackBadge"]
        XCTAssertTrue(padlock.waitForExistence(timeout: 10), "a verified entitlement should show the open padlock")
        XCTAssertEqual(padlock.label, "Export WAV unlocked", "the badge should describe itself to VoiceOver")
        let headerCopy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "EXPORT"))
        XCTAssertEqual(
            headerCopy.count, 0,
            "the unlocked badge is a padlock with no copy beside it, found: \(headerCopy.allElementsBoundByIndex.map(\.label))"
        )

        padlock.tap()

        XCTAssertTrue(
            app.staticTexts["TAKE YOUR TRACK OUT OF THE POCKET"].waitForExistence(timeout: 8),
            "tapping the padlock should open the export sheet"
        )
        XCTAssertTrue(app.buttons["export.wav"].waitForExistence(timeout: 8), "the WAV row should be offered")
        XCTAssertFalse(
            app.buttons["exportPaywall.unlockButton"].exists,
            "an owned purchase must not ask to be bought again"
        )

        // Sharing goes to the system activity sheet rather than the paywall. The sheet belongs to the
        // app's process, so it is the app's own element tree that has to show it.
        let shareRow = app.buttons["export.share"]
        XCTAssertTrue(shareRow.waitForExistence(timeout: 8), "the share row should be offered")
        shareRow.tap()
        XCTAssertTrue(
            app.otherElements["ActivityListView"].waitForExistence(timeout: 25),
            "an owned purchase should open the system share sheet for the rendered WAV"
        )
    }

    /// Saving to Files is the other end of the same take.
    ///
    /// Both handovers read the file the render streamed to disk — the picker is handed that URL and
    /// copies it itself — so this has to open on a real file rather than on bytes held in memory,
    /// which is what the ready row underneath is evidence of: the take is only reported ready once
    /// the streamed file is whole.
    @MainActor
    func testSavingAnUnlockedTakeOpensTheFilesPickerOnTheStreamedFile() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--export-unlocked-ui-test"]
        app.launch()

        let padlock = app.descendants(matching: .any)["exportPackBadge"]
        XCTAssertTrue(padlock.waitForExistence(timeout: 10), "a verified entitlement should show the open padlock")
        padlock.tap()

        let saveRow = app.buttons["export.wav"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 8), "the WAV row should be offered")
        let ready = app.staticTexts["export.ready"]
        XCTAssertFalse(ready.exists, "nothing has been rendered yet, so there is nothing to be ready")

        saveRow.tap()

        // The picker belongs to the system, but it is presented inside this app's process, so the
        // app's own element tree is where it shows up.
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 40), "saving an unlocked take should open the Files picker")
        XCTAssertTrue(app.staticTexts["On My iPhone"].exists, "the picker should open the local storage browser")
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "a finished render should report the take as ready")
        XCTAssertEqual(ready.label, "RENDERED · READY TO EXPORT", "the take can only be ready once the streamed file is whole")

        // Saving out of the pocket is the system's own file copy, and it can only work if the file
        // the render streamed is really there.
        saveButton.tap()
        XCTAssertTrue(waitUntilGone(saveButton, timeout: 20), "saving should close the picker and leave the export sheet behind")
        XCTAssertTrue(app.buttons["export.wav"].waitForExistence(timeout: 8), "the export sheet should still be offered")
    }

    /// Saving a take and then sharing the same one used to synthesize it twice, because the sheet
    /// threw its render away every time it was dismissed. The sheet now reports what the next tap
    /// will cost — ready while the bytes are cached, and no re-render needed once a handover has
    /// reused them — so this reads the answer out of the accessibility tree rather than watching a
    /// stopwatch. A cache that quietly stopped working would still export the right audio; it would
    /// simply do the work twice, which no clock-based assertion can state reliably.
    @MainActor
    func testSecondExportOfAnUnchangedTakeReusesTheRender() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--export-unlocked-ui-test"]
        app.launch()

        let padlock = app.descendants(matching: .any)["exportPackBadge"]
        XCTAssertTrue(padlock.waitForExistence(timeout: 10), "a verified entitlement should show the open padlock")
        padlock.tap()

        let shareRow = app.buttons["export.share"]
        XCTAssertTrue(shareRow.waitForExistence(timeout: 8), "the share row should be offered")
        let ready = app.staticTexts["export.ready"]
        XCTAssertFalse(ready.exists, "nothing has been rendered yet, so there is nothing to be ready")

        // The first handover has to synthesize, and afterwards the sheet says the bytes are here.
        let activityList = app.otherElements["ActivityListView"]
        shareRow.tap()
        XCTAssertTrue(activityList.waitForExistence(timeout: 40), "the first export should open the activity sheet")
        dismissActivitySheet(app, activityList)
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "a finished render should report the take as ready")
        XCTAssertEqual(ready.label, "RENDERED · READY TO EXPORT", "the first handover had to synthesize")

        // The second handover of the same, untouched take must not synthesize again — and it has to
        // say so, which is the assertion a stopwatch could never make.
        shareRow.tap()
        XCTAssertTrue(activityList.waitForExistence(timeout: 40), "the second export should open the activity sheet")
        dismissActivitySheet(app, activityList)
        XCTAssertEqual(
            ready.label,
            "RENDERED EARLIER · NO RE-RENDER NEEDED",
            "an unchanged take must be reused rather than synthesized again"
        )

        // The cache has to outlive the sheet as well. Keeping the bytes in the sheet's own state
        // would pass everything above and then forget the render the moment the user closed it,
        // which is the other half of saving a take and coming back to share it.
        app.navigationBars["EXPORT"].buttons["DONE"].tap()
        XCTAssertTrue(waitUntilGone(ready, timeout: 8), "closing the sheet should take its status row with it")
        padlock.tap()
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "a reopened sheet should still find the rendered take")
        XCTAssertEqual(ready.label, "RENDERED · READY TO EXPORT", "this visit has handed nothing over yet")
    }

    /// Closes Apple's activity sheet so the export screen underneath is reachable again. The control
    /// belongs to the system, so it is found by the labels it ships with, and the gesture fallback
    /// covers the case where those labels ever move.
    @MainActor
    private func dismissActivitySheet(_ app: XCUIApplication, _ activityList: XCUIElement) {
        for label in ["Cancel", "Close"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                if waitUntilGone(activityList, timeout: 6) { return }
            }
        }
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntilGone(activityList, timeout: 6), "the activity sheet should close so the export rows are reachable")
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }
}
