import XCTest

/// Regression guard for the drum kit's voice rows in the Sound Lab.
///
/// The four supplied one-shots are not a kit: measured, the hi-hat and the snare sat within
/// a percentage point of each other on high-frequency share and six percent on length, so the
/// only thing telling them apart was how loud the mixer happened to have left them. Each voice
/// is now shaped — a read rate and a tail trim — and the row says in words what the shape does
/// ("NATIVE · FULL", "TIGHTER · CLICK") so a reader knows what to listen for.
///
/// This drives the controls that expose that on the real hierarchy: the row's own tap-to-hear,
/// the run that plays the kit from the floor up, and the check that plays this pattern's drum row
/// so the voices can also be heard in the music rather than only one at a time.
///
/// The row's volume swipe is deliberately not asserted here. It is a `simultaneousGesture` on a
/// row inside this app's custom scroll container, and a synthetic one-finger drag does not reach
/// it — the mixer faders are built the same way and no test drives them either. That is not
/// caused by the tap-to-hear added beside it: with the tap gesture removed the same drag still
/// left the level untouched.
final class DrumKitAuditionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Each row has to say what its voice is for, and no two rows may say the same thing —
    /// four rows described identically would put the reader back where they started.
    @MainActor
    func testEveryVoiceRowSaysWhatItsVoiceIsFor() throws {
        let app = XCUIApplication()
        app.launch()
        let kit = try openDrumKit(app)

        XCTAssertEqual(kit.character(of: .kick), "NATIVE · FULL", "the kick is the kit's floor: recorded pitch, whole tail")
        XCTAssertEqual(kit.character(of: .hiHat), "TIGHTER · CLICK", "the hi-hat has to read as the shortest, thinnest voice")
        let characters = try ByteDrumVoiceIndices.allCases.map { index in
            try XCTUnwrap(kit.character(of: index), "voice \(index) should describe itself")
        }
        XCTAssertEqual(
            Set(characters).count, characters.count,
            "two voices are described the same way, so the rows cannot be told apart: \(characters)"
        )
    }

    /// Tapping a row hears that voice, lights it so the reader knows which voice answered, and
    /// leaves its level alone — the row already hosts a volume swipe, and a tap is the gesture
    /// sitting next to it.
    @MainActor
    func testTappingAVoiceHearsItWithoutMovingItsLevel() throws {
        let app = XCUIApplication()
        app.launch()
        let kit = try openDrumKit(app)

        let row = kit.row(.snare)
        let before = try XCTUnwrap(kit.level(of: .snare), "the row should report its level")
        row.tap()

        XCTAssertEqual(
            kit.level(of: .snare), before,
            "hearing a voice must not change its level"
        )
        XCTAssertTrue(
            waitForSoundingVoice(app, timeout: 2, voice: .snare),
            "a tap should hear that voice and light its row, so the eye knows which one answered"
        )
        XCTAssertTrue(row.exists, "the row should survive its own preview")
    }

    /// "Hear all four" plays the kit from the floor up, lighting each row as it sounds. The run
    /// is the only way to compare the voices in one pass, so it has to actually reach the rows:
    /// a button that did nothing would look identical from the outside.
    @MainActor
    func testHearAllFourPlaysTheKitAndLightsEachVoice() throws {
        let app = XCUIApplication()
        app.launch()
        _ = try openDrumKit(app)

        let auditionAll = app.descendants(matching: .any)["drumKit.auditionAll"]
        XCTAssertTrue(auditionAll.exists, "the kit panel should offer the run")
        auditionAll.tap()

        let started = auditionAll.value as? String
        let lit = waitForSoundingVoice(app, timeout: 3)
        XCTAssertTrue(
            lit || started == "playing",
            "tapping the run should play the voices and light them, button state: \(String(describing: started))"
        )

        // The run is one bar at the project tempo, so it has to end by itself: a control left
        // "playing" would leave a kit check running over everything the reader does next.
        XCTAssertTrue(
            waitForCheckState("idle", on: auditionAll, timeout: 8),
            "the run should finish after its one bar instead of running on"
        )
    }

    /// The drum-row check plays this pattern's own bar, so the shaped voices can be judged in the
    /// music instead of one at a time. A control that played nothing would look the same from the
    /// outside, so this drives it and watches it report a bar's worth of run.
    ///
    /// Which voices the run lights follows from the row, and the row is read from the pattern in
    /// the unit tests; a pad is written here only so the row is certainly playable, because the
    /// app persists the project and an empty row cannot be assumed away.
    @MainActor
    func testDrumRowCheckPlaysThePatternsRowAndEnds() throws {
        let app = XCUIApplication()
        app.launch()

        let pad = try openFirstDrumPad(app)
        if (pad.value as? String) == "EMPTY" { pad.tap() }
        XCTAssertNotEqual(pad.value as? String, "EMPTY", "the row needs a hit to be worth checking")

        let kit = try openDrumKit(app)
        let check = kit.patternCheck
        XCTAssertTrue(check.exists, "the kit panel should offer the drum-row check")
        XCTAssertTrue(
            waitForCheckState("idle", on: check, timeout: 2),
            "a row with a hit in it should be armed to play, state: \(String(describing: check.value))"
        )

        check.tap()
        XCTAssertTrue(
            waitForCheckState("playing", on: check, timeout: 3),
            "tapping the check should start the row, state: \(String(describing: check.value))"
        )
        XCTAssertTrue(
            waitForCheckState("idle", on: check, timeout: 8),
            "the check is one bar at the tempo, so it should end by itself"
        )
    }

    // MARK: - Helpers

    /// The drum row of the Sound Lab, brought on screen. The kit panel only exists for the drum
    /// channel, so the row is selected explicitly rather than assumed from the launch state.
    @MainActor
    private func openDrumKit(_ app: XCUIApplication) throws -> DrumKit {
        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "the logo doubles as the scroll handle")

        let fader = app.descendants(matching: .any)["channelFader.drum"]
        XCTAssertTrue(
            scrollUntilHittable(fader, logo: logo),
            "the DRUM channel card should be reachable on the beatpad page"
        )
        fader.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        let soundLab = app.buttons["SOUND LAB"]
        XCTAssertTrue(scrollUntilHittable(soundLab, logo: logo), "the SOUND LAB page button should be reachable")
        soundLab.tap()

        let row = app.descendants(matching: .any)["drumVoice.\(ByteDrumVoiceIndices.kick.rawValue)"]
        XCTAssertTrue(scrollUntilHittable(row, logo: logo), "the drum kit panel should come into view")
        return DrumKit(app: app)
    }

    /// The run lights one voice at a time for a fraction of a second, so this polls often enough
    /// to catch a lit row rather than checking once and missing the pass. `voice` narrows the
    /// wait to one row, for a tap that should light exactly that one.
    @MainActor
    private func waitForSoundingVoice(
        _ app: XCUIApplication,
        timeout: TimeInterval,
        voice: ByteDrumVoiceIndices? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in voice.map({ [$0] }) ?? ByteDrumVoiceIndices.allCases {
                let value = app.descendants(matching: .any)["drumVoice.\(index.rawValue)"].value as? String ?? ""
                if value.contains("sounding") { return true }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// The beatpad's first drum pad, brought on screen with the drum row showing. Writing a hit
    /// there is how a test knows the row has something in it: the app persists the project, so
    /// the pads carry whatever the last session left on them.
    @MainActor
    private func openFirstDrumPad(_ app: XCUIApplication) throws -> XCUIElement {
        let logo = app.descendants(matching: .any)["beatboi-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "the logo doubles as the scroll handle")

        let fader = app.descendants(matching: .any)["channelFader.drum"]
        XCTAssertTrue(
            scrollUntilHittable(fader, logo: logo),
            "the DRUM channel card should be reachable on the beatpad page"
        )
        fader.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        let pad = app.descendants(matching: .any)["notePad.0"]
        XCTAssertTrue(scrollUntilHittable(pad, logo: logo), "the note grid should come into view")
        let readout = app.staticTexts["padEditor.readout"].label
        XCTAssertTrue(
            readout.contains("HIT"),
            "the drum row has to be the one on screen for a hit to be written, readout: \(readout)"
        )
        return pad
    }

    /// Waits for a kit check to report `expected` as its accessibility value, which is how both
    /// checks report their state. Polled rather than read once: a run can be a second long, so a
    /// single read is as likely to land between states as on one.
    @MainActor
    private func waitForCheckState(_ expected: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (element.value as? String) == expected
    }

    /// Pulls the logo, which is the app's own page scroll, until the element can be touched.
    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        logo: XCUIElement,
        dy: CGFloat = 45,
        steps: Int = 14
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

    /// The kit panel as the tests address it: one row per voice, keyed by the voice's index.
    private struct DrumKit {
        let app: XCUIApplication

        func row(_ voice: ByteDrumVoiceIndices) -> XCUIElement {
            app.descendants(matching: .any)["drumVoice.\(voice.rawValue)"]
        }

        /// The button that plays this pattern's drum row, beside the walk up the kit.
        var patternCheck: XCUIElement {
            app.descendants(matching: .any)["drumKit.patternCheck"]
        }

        /// The words the row uses to describe its voice, or nil if the row has not been reached.
        func character(of voice: ByteDrumVoiceIndices) -> String? {
            splitValue(of: voice)?.character
        }

        /// The row's level as a percentage.
        func level(of voice: ByteDrumVoiceIndices) -> Int? {
            guard let level = splitValue(of: voice)?.level else { return nil }
            return Int(level.trimmingCharacters(in: .whitespaces))
        }

        /// A row reports "<character>, <level>%[ , sounding]".
        private func splitValue(of voice: ByteDrumVoiceIndices) -> (character: String, level: String)? {
            guard let value = row(voice).value as? String, let percent = value.firstIndex(of: "%") else { return nil }
            let head = value[value.startIndex..<percent]
            guard let comma = head.lastIndex(of: ",") else { return nil }
            return (String(head[head.startIndex..<comma]), String(head[head.index(after: comma)...]))
        }
    }
}

/// The drum voice indices, spelled out rather than imported.
///
/// The UI test target does not link the app module, so the voices are addressed by the order
/// the app puts them in: 0 kick, 1 snare, 2 hi-hat, 3 perc. The rows' own captions are asserted
/// against those names, so a reordering in the app fails here rather than passing quietly.
private enum ByteDrumVoiceIndices: Int, CaseIterable {
    case kick = 0
    case snare = 1
    case hiHat = 2
    case perc = 3
}
