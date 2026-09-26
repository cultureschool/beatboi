import XCTest

/// Regression guard for how the 16 note pads read a touch.
///
/// A pad used to host three gestures at once — a tap, a HIGH-PRIORITY long press
/// and a simultaneous drag. The long press won that arbitration, and it is a bad
/// winner: it reports success the moment its duration elapses, while the finger is
/// still down. So pressing a pad that already held a note for longer than half a
/// second and then dragging did two things wrong at once — it armed link mode, and
/// the pitch drag never ran at all. A drag on an existing note therefore often did
/// nothing to the note while silently changing what the next tap anywhere would
/// do, which is why building a melody felt unreliable and slow: whether your drag
/// worked came down to how long you happened to hesitate first.
///
/// Restoring that long press on top of the current gesture is enough to make
/// `testHoldThenDragPitchesWithoutArmingLink` fail — the drag stops changing the
/// note — so the defect is pinned by behaviour rather than by shape.
///
/// These tests drive the same gestures through the real view hierarchy and assert
/// the corrected reading of each one.
final class NotePadGestureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Press and hold on a note, then drag upward. The pitch must change, no link
    /// may be armed, and the very next tap on another pad must still toggle that
    /// pad — which is precisely what broke when the hold armed link mode.
    @MainActor
    func testHoldThenDragPitchesWithoutArmingLink() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let first = editor.pad(2)
        let second = editor.pad(6)
        clear(second)
        let seeded = try seedNote(on: first)

        // Hold, then drag up. 0.6s is past the 0.45s hold that arms a link, so on
        // the old code this gesture armed one and left it armed.
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -58))
        start.press(forDuration: 0.6, thenDragTo: end)

        XCTAssertNotEqual(
            first.value as? String, seeded,
            "dragging upward must change the note, not arm a link"
        )
        XCTAssertFalse(
            editor.readout.contains("LINK ARMED"),
            "a hold that ends in a drag must not arm a link, readout: \(editor.readout)"
        )

        // The decisive assertion. With a link armed, this tap would set a note
        // LENGTH on the first pad and leave the second one empty.
        second.tap()
        XCTAssertNotEqual(
            second.value as? String, "EMPTY",
            "the next tap after a drag must toggle a pad, not link to the dragged one"
        )
    }

    /// Hold still, then lift. That is the link gesture now, and it must still work
    /// — and it must not be confused with a tap, which would delete the note.
    @MainActor
    func testHoldAndReleaseArmsTheLinkAndKeepsTheNote() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let first = editor.pad(2)
        let second = editor.pad(6)
        clear(second)
        let seeded = try seedNote(on: first)

        first.press(forDuration: 0.7)

        XCTAssertEqual(
            first.value as? String, seeded,
            "holding and releasing must not toggle the note off"
        )
        XCTAssertTrue(
            editor.readout.contains("LINK ARMED"),
            "hold-and-release should arm the link, readout: \(editor.readout)"
        )

        // Arming means the next tap sets the note's end, so it extends the first
        // pad rather than adding a note to the second.
        second.tap()
        XCTAssertEqual(
            second.value as? String, "EMPTY",
            "a tap after an armed link should end the note, not place a new one"
        )
    }

    /// One sideways drag across four pads paints all four, and a single undo takes
    /// the whole run back — the point of sweeping being one gesture and one step.
    @MainActor
    func testSidewaysDragPaintsARunInOneUndoStep() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let run = (0...3).map { editor.pad($0) }
        for pad in run { clear(pad) }

        // Sweep right across the first row. The slow velocity keeps the events dense,
        // so the finger genuinely passes over each pad instead of teleporting between
        // the two endpoints.
        let start = run[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = run[3].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        let painted = run.map { $0.value as? String }
        XCTAssertTrue(
            painted.allSatisfy { $0 != "EMPTY" },
            "a sideways sweep should paint every pad it crosses, got: \(painted)"
        )

        // Undo lives in the header, above the grid, so scroll back up to reach it.
        let logo = app.descendants(matching: .any)["beatboi-logo"]
        let undo = app.buttons["Undo"]
        XCTAssertTrue(
            scrollUntilHittable(undo, logo: logo, dy: -45),
            "the undo control should be reachable from the pad grid"
        )
        undo.tap()

        // Reaching Undo scrolled the page back to the top, where `LazyVGrid` has
        // released the grid's cells — so the pads have to be brought back on screen
        // before they can be read again.
        XCTAssertTrue(
            scrollUntilHittable(run[0], logo: logo),
            "the note grid should come back into view after using undo"
        )
        let afterUndo = run.map { $0.value as? String }
        XCTAssertTrue(
            afterUndo.allSatisfy { $0 == "EMPTY" },
            "ONE undo must take back the whole run, got: \(afterUndo)"
        )
    }

    /// Tapping the pad that armed the link cancels the mode and leaves that pad's note alone.
    /// The tap is the natural way out of a mode, so it must not mean "delete this note" — and
    /// the mode has to be gone afterwards, or the next tap on another pad would extend a note
    /// instead of placing one.
    @MainActor
    func testTappingTheArmedPadCancelsTheLinkAndKeepsTheNote() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let armed = editor.pad(2)
        let other = editor.pad(10)
        clear(other)
        let seeded = try seedNote(on: armed)

        armed.press(forDuration: 0.7)
        XCTAssertTrue(
            editor.readout.contains("LINK ARMED"),
            "setup: holding a filled pad should arm a link, readout: \(editor.readout)"
        )

        armed.tap()

        XCTAssertEqual(
            armed.value as? String, seeded,
            "tapping the armed pad means cancel, so its note must survive"
        )
        XCTAssertFalse(
            editor.readout.contains("LINK ARMED"),
            "tapping the armed pad should disarm the link, readout: \(editor.readout)"
        )

        other.tap()
        XCTAssertNotEqual(
            other.value as? String, "EMPTY",
            "a cancelled link must not swallow the next tap"
        )
    }

    /// A tap on a pad *before* the armed one cannot complete a link, so it cancels the mode and
    /// then does what a tap always does. Leaving the mode armed there was the trap: the tap
    /// looked harmless, and the tap *after* it silently set a note length instead of a note.
    @MainActor
    func testTappingAnEarlierPadCancelsTheLinkAndStillToggles() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let armed = editor.pad(6)
        let earlier = editor.pad(1)
        let later = editor.pad(10)
        clear(earlier)
        clear(later)
        let seeded = try seedNote(on: armed)

        armed.press(forDuration: 0.7)
        XCTAssertTrue(
            editor.readout.contains("LINK ARMED"),
            "setup: holding a filled pad should arm a link, readout: \(editor.readout)"
        )

        earlier.tap()

        XCTAssertNotEqual(
            earlier.value as? String, "EMPTY",
            "a tap on an earlier pad is still a tap, so it should place a note"
        )
        XCTAssertEqual(armed.value as? String, seeded, "the armed note must be left as it was")
        XCTAssertFalse(
            editor.readout.contains("LINK ARMED"),
            "a tap that cannot complete the link should cancel it, readout: \(editor.readout)"
        )

        later.tap()
        XCTAssertNotEqual(
            later.value as? String, "EMPTY",
            "the cancelled mode must not turn the next tap into a note-length edit"
        )
    }

    /// A drag on the drum row picks a voice and the hit has to survive the lift that ends the
    /// drag. The voice pick is applied live and is deliberately not latched, so the release
    /// used to fall through and toggle the pad — deleting the very hit the drag had just
    /// voiced. Picking a snare therefore looked exactly like erasing the pad.
    @MainActor
    func testDrumVoiceDragKeepsTheHitItPicked() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openDrumPadGrid(app)

        let pad = editor.pad(3)
        clear(pad)

        // Straight up is the snare in the row's drag layout.
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = start.withOffset(CGVector(dx: 0, dy: -60))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        XCTAssertEqual(
            pad.value as? String, "SNARE",
            "the drag should leave the voice it picked on the pad"
        )
    }

    /// A plain tap still toggles, twice over, and never arms a link.
    @MainActor
    func testTapTogglesBothWaysWithoutArmingLink() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openMelodicPadGrid(app)

        let pad = editor.pad(4)
        clear(pad)

        pad.tap()
        XCTAssertNotEqual(pad.value as? String, "EMPTY", "a tap should place a note")
        XCTAssertFalse(editor.readout.contains("LINK ARMED"), "a tap must not arm a link")

        pad.tap()
        XCTAssertEqual(pad.value as? String, "EMPTY", "a second tap should clear the note")
        XCTAssertFalse(editor.readout.contains("LINK ARMED"), "clearing must not arm a link")
    }

    /// The dice on the drum row is the drum shuffle, and the one thing it may never do is leave a
    /// bar the ear cannot find its way around: the snare has to land on the backbeat — beats 2 and
    /// 4, or beat 3 alone for a half-time loop.
    ///
    /// It reads the pads rather than the store, because the report was that the button did nothing
    /// on screen, and a test that asked the store instead would have agreed with itself. It also
    /// names the feel in its toast, so the user can tell which of the two they just rolled.
    @MainActor
    func testDrumDiceWritesABeatWithItsSnareOnTheBackbeat() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = try openDrumPadGrid(app)

        let dice = app.buttons["Shuffle drum beat"]
        XCTAssertTrue(
            dice.waitForExistence(timeout: 5),
            "the drum row's dice should say what it does to the drum row"
        )
        dice.tap()

        let announced = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "DRUM BEAT"))
        XCTAssertTrue(
            announced.firstMatch.waitForExistence(timeout: 2),
            "the shuffle should name the feel it just built"
        )

        let voices = (0..<16).map { editor.pad($0).value as? String ?? "MISSING" }
        let snares = voices.enumerated().filter { $0.element == "SNARE" }.map(\.offset)
        XCTAssertTrue(
            snares == [4, 12] || snares == [8],
            "the shuffle wrote its snare to \(snares); a beat needs beats 2 and 4, or beat 3 half time"
        )
        XCTAssertEqual(
            voices[0], "KICK",
            "a shuffled beat still lands on the downbeat, pads read \(voices)"
        )
    }

    // MARK: - Helpers

    /// The pad grid edits whichever channel is selected, and a fresh launch selects
    /// the DRUM row, where the link gesture is deliberately unavailable. Select a
    /// melodic channel and bring the grid on screen.
    @MainActor
    private func openMelodicPadGrid(_ app: XCUIApplication) throws -> PadGrid {
        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "the logo doubles as the scroll handle")

        let fader = app.descendants(matching: .any)["channelFader.pulseA"]
        XCTAssertTrue(
            scrollUntilHittable(fader, logo: logo),
            "the PULSE A channel card should be reachable on the beatpad page"
        )
        // Tap the card's left half: the M and S buttons sit on its right, and a
        // synthesized tap on the container can resolve to one of those instead of
        // to the card's own tap gesture.
        fader.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        let pad = app.descendants(matching: .any)["notePad.2"]
        XCTAssertTrue(
            scrollUntilHittable(pad, logo: logo),
            "the note grid should come into view on the beatpad page"
        )
        let readout = app.staticTexts["padEditor.readout"].label
        XCTAssertFalse(
            readout.contains("KICK"),
            "selecting a melodic channel should switch the grid off the drum row, readout: \(readout)"
        )
        return PadGrid(app: app)
    }

    /// The drum row's grid, brought on screen. Its gestures differ from a melodic row's — the
    /// drum pads pick a voice instead of a pitch and cannot be linked — so the drum row is
    /// selected explicitly rather than assumed from the launch state.
    @MainActor
    private func openDrumPadGrid(_ app: XCUIApplication) throws -> PadGrid {
        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "the logo doubles as the scroll handle")

        let fader = app.descendants(matching: .any)["channelFader.drum"]
        XCTAssertTrue(
            scrollUntilHittable(fader, logo: logo),
            "the DRUM channel card should be reachable on the beatpad page"
        )
        fader.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        let pad = app.descendants(matching: .any)["notePad.3"]
        XCTAssertTrue(
            scrollUntilHittable(pad, logo: logo),
            "the note grid should come into view on the beatpad page"
        )
        let readout = app.staticTexts["padEditor.readout"].label
        XCTAssertTrue(
            readout.contains("HIT"),
            "the drum row should be showing its own hint, readout: \(readout)"
        )
        return PadGrid(app: app)
    }

    /// Normalises a pad to empty.
    ///
    /// The app persists the project, so a pad keeps whatever a previous test case —
    /// or a previous run of the suite — left on it. Assuming a pristine library
    /// makes these tests pass or fail on the order they happen to run in, so every
    /// pad a test touches is normalised first instead.
    @MainActor
    private func clear(_ pad: XCUIElement) {
        if (pad.value as? String) != "EMPTY" { pad.tap() }
        XCTAssertEqual(pad.value as? String, "EMPTY", "this test needs the pad to start empty")
    }

    /// Clears a pad, places a note on it, and returns the note name so the caller
    /// can assert that a later gesture changed it.
    @MainActor
    private func seedNote(on pad: XCUIElement) throws -> String {
        clear(pad)
        pad.tap()
        return try XCTUnwrap(pad.value as? String)
    }

    /// Pulls the logo, which is the app's own page scroll, until the element can be
    /// touched. A negative `dy` scrolls back up. The slow velocity keeps every event
    /// under the flick threshold, so the page tracks the finger and the element does
    /// not sail past.
    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        logo: XCUIElement,
        dy: CGFloat = 45,
        steps: Int = 8
    ) -> Bool {
        for _ in 0..<steps {
            if element.exists && element.isHittable { return true }
            let start = logo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let end = start.withOffset(CGVector(dx: 0, dy: dy))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.exists && element.isHittable
    }

    /// The pad grid as the tests address it: pads keyed by step index, plus the
    /// hint line that doubles as the live readout.
    private struct PadGrid {
        let app: XCUIApplication

        func pad(_ index: Int) -> XCUIElement {
            app.descendants(matching: .any)["notePad.\(index)"]
        }

        /// The hint text is replaced by the live value while a drag scrubs — "PITCH C4",
        /// "VOICE SNARE", "PAINTING 3 STEPS" — so this reads "LINK ARMED ..." only when a
        /// link is genuinely armed.
        var readout: String {
            app.staticTexts["padEditor.readout"].label
        }
    }
}
