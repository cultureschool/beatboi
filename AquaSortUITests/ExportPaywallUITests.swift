import XCTest

/// Regression guard for the Export Pack paywall: WAV audio must be locked behind
/// the $1.99 purchase, and tapping its row must present the paywall sheet.
///
/// The pack used to also cover MIDI and the editor used to hand out a project
/// file. Both rows are gone — WAV audio is the only export the app offers — so
/// this test asserts they stay gone.
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
        XCTAssertFalse(app.descendants(matching: .any)["exportPackBadge"].exists, "EXPORT PACK badge must be hidden without a verified entitlement")

        // WAV audio is the only row left, and it presents the paywall when tapped.
        let wavRow = app.buttons["export.wav"]
        XCTAssertTrue(wavRow.waitForExistence(timeout: 8), "WAV export row should exist")
        XCTAssertFalse(app.buttons["export.midi"].exists, "MIDI export row must no longer be offered")
        XCTAssertFalse(app.buttons["export.project"].exists, "project-file export row must no longer be offered")

        // Tapping the locked row must present the paywall, not an export dialog.
        wavRow.tap()
        XCTAssertTrue(app.staticTexts["EXPORT PACK"].waitForExistence(timeout: 8), "tapping WAV export should present the paywall")
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
    }
}
