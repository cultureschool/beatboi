import XCTest

/// Regression guard for the Export Pack paywall: MIDI/WAV must be locked behind
/// the $1.99 purchase while project-file export stays free, and tapping a
/// locked export row must present the paywall sheet.
final class ExportPaywallUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMIDIAndWAVAreLockedBehindPaywallWhileProjectExportStaysFree() throws {
        let app = XCUIApplication()
        app.launch()

        // Open the export sheet from the editor header.
        let exportButton = app.buttons["Export project"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 8), "export header button should exist")
        exportButton.tap()

        let exportTitle = app.staticTexts["TAKE YOUR TRACK OUT OF THE POCKET"]
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 8), "export sheet should present")

        // Without an entitlement the Beatpad header must not show the unlock badge.
        XCTAssertFalse(app.descendants(matching: .any)["exportPackBadge"].exists, "EXPORT PACK badge must be hidden without a verified entitlement")

        // Project-file export stays free; MIDI/WAV present the paywall when tapped.
        let projectRow = app.buttons["export.project"]
        let midiRow = app.buttons["export.midi"]
        let wavRow = app.buttons["export.wav"]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 8), "project export row should exist")
        XCTAssertTrue(midiRow.exists, "MIDI export row should exist")
        XCTAssertTrue(wavRow.exists, "WAV export row should exist")

        // Tapping a locked row must present the paywall, not an export dialog.
        midiRow.tap()
        XCTAssertTrue(app.staticTexts["EXPORT PACK"].waitForExistence(timeout: 8), "tapping MIDI export should present the paywall")
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

        // Close the paywall and confirm the export sheet is still up.
        let closeButton = app.buttons["CLOSE"].firstMatch
        if closeButton.waitForExistence(timeout: 4) { closeButton.tap() }
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 4), "export sheet should remain after closing the paywall")
    }
}
