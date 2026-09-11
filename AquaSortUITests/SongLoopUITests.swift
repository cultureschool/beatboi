import XCTest

/// Regression guard for the song-mode loop trim: a 3-bar arrangement (bar 2 left
/// intentionally empty) must wrap from bar 3 back to bar 1 — the transport must
/// never keep counting through the 13 trailing empty bars before looping.
final class SongLoopUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThreeBarArrangementWrapsFromBar3BackToBar1() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--song-loop-ui-test"]
        app.launch()

        // Navigate to the Song page.
        let songTab = app.buttons["songPageButton"]
        XCTAssertTrue(songTab.waitForExistence(timeout: 8), "SONG page button should exist")
        songTab.tap()

        // Start song playback.
        let playButton = app.buttons["playStopButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 8), "play button should exist")
        playButton.tap()

        // The readout shows the current bar ("BAR NN"); sample it continuously and
        // track the sequence of bar TRANSITIONS, since each bar lasts several seconds.
        let readout = app.staticTexts["currentBarReadout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "current bar readout should appear once playback starts")

        var lastBar: Int?
        var transitions: [(from: Int, to: Int)] = []
        var seenBars: Set<Int> = []
        let deadline = Date().addingTimeInterval(40)

        while Date() < deadline {
            let digits = readout.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if let bar = digits.first {
                if let previous = lastBar, previous != bar {
                    transitions.append((previous, bar))
                }
                if lastBar != bar {
                    seenBars.insert(bar)
                }
                lastBar = bar
            }
            // Pass as soon as the critical 3 -> 1 wrap is observed.
            if transitions.contains(where: { $0.from == 3 && $0.to == 1 }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(seenBars.contains(1), "should observe bar 1 (transitions: \(transitions))")
        XCTAssertTrue(seenBars.contains(2), "should observe the silent bar 2 (transitions: \(transitions))")
        XCTAssertTrue(seenBars.contains(3), "should observe bar 3 (transitions: \(transitions))")
        XCTAssertTrue(
            transitions.contains(where: { $0.from == 3 && $0.to == 1 }),
            "bar 3 must wrap directly to bar 1, transitions observed: \(transitions)"
        )
        // The old bug: the transport would continue into bar 4 (trailing empty bars).
        XCTAssertFalse(
            transitions.contains(where: { $0.from == 3 && $0.to > 3 }),
            "bar 3 must never advance into a trailing empty bar, transitions: \(transitions)"
        )
    }
}
