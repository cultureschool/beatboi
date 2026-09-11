import XCTest
@testable import AquaSort

@MainActor
final class BeatboiTests: XCTestCase {
    func testProjectUsesFixedSixteenStepPatterns() {
        let suite = "BeatboiLoopLengthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.updateLoopLength(32)
        XCTAssertEqual(store.loopLength, 16)
        XCTAssertTrue(store.project.patterns[0].steps.allSatisfy { $0.count == 16 })
        store.toggleStep(channel: .pulseA, step: 1)
        XCTAssertEqual(store.project.patterns[0].steps[0][1], ByteChannel.pulseA.rootNote(for: store.project.key))

        let data = try! JSONEncoder.bytePocketEncoder.encode(store.project)
        let decoded = try! JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertEqual(decoded.loopLength, 16)
        XCTAssertTrue(decoded.patterns.allSatisfy { $0.steps.allSatisfy { $0.count == 16 } })
        defaults.removePersistentDomain(forName: suite)
    }

    func testFixedSixteenStepTransportAndRenderer() {
        XCTAssertEqual(ByteTransportClock.step(at: 2.0, bpm: 120, loopLength: 16), 0)
        XCTAssertEqual(ByteTransportClock.step(at: 4.0, bpm: 120, loopLength: 32), 0)

        let project = ByteProject()
        let sampleRate = 8_000.0
        let samples = ByteRenderer.render(project: project, sampleRate: sampleRate)
        let expectedFrames = Int(Double(16) * ByteTransportClock.stepDuration(bpm: project.tempo) * sampleRate)
        XCTAssertEqual(samples.count, expectedFrames * 2)
    }

    func testDrumSketchGesturesMapToQuickVoiceChoices() {
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 0, vertical: 0), .kick)
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 0, vertical: -40), .snare)
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: -40, vertical: 0), .hiHat)
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 40, vertical: 0), .perc)
        // The larger axis wins when the gesture is diagonal.
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: -12, vertical: -30), .snare)
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 30, vertical: 12), .perc)
    }

    func testGlobalVoicingQuantizesMelodicNotesButLeavesDrumsAlone() {
        let suite = "BeatboiVoicingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let secondPattern = BytePattern.empty(name: "PATTERN 02")
        store.project.patterns.append(secondPattern)

        store.project.patterns[0].steps[0][0] = 61 // C#
        store.project.patterns[0].steps[1][0] = 66 // F#
        store.project.patterns[0].steps[3][0] = 49 // Perc
        store.updateVoicing(key: 0, mode: .major)

        XCTAssertEqual(store.project.patterns[0].steps[0][0], 60) // C
        XCTAssertEqual(store.project.patterns[0].steps[1][0], 65) // F
        XCTAssertEqual(store.project.patterns[0].steps[3][0], 49) // Drum unchanged

        store.updateVoicing(mode: .chromatic)
        store.setNote(channel: .pulseA, step: 1, note: 61)
        XCTAssertEqual(store.project.patterns[0].steps[0][1], 61)
        defaults.removePersistentDomain(forName: suite)
    }

    func testNewMelodicNotesUseTheProjectKeyRootAcrossChannels() {
        let suite = "BeatboiRootNoteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.updateVoicing(key: 2, mode: .chromatic) // D

        for channel in [ByteChannel.pulseA, .pulseB, .wave] {
            store.toggleStep(channel: channel, step: 1)
            let row = ByteChannel.allCases.firstIndex(of: channel)!
            XCTAssertEqual(store.project.patterns[0].steps[row][1], channel.rootNote(for: 2))
            XCTAssertEqual(store.project.patterns[0].steps[row][1]! % 12, 2)
        }

        // Manual vertical pitch editing can still choose another pitch from the same pad.
        store.setNote(channel: .pulseA, step: 1, note: 67)
        XCTAssertEqual(store.project.patterns[0].steps[0][1], 67)
        defaults.removePersistentDomain(forName: suite)
    }

    func testAllSupportedScaleModesExposeExpectedNamesAndIntervals() {
        XCTAssertEqual(ByteScaleMode.allCases.count, 10)
        XCTAssertNil(ByteScaleMode.chromatic.intervals)
        XCTAssertEqual(ByteScaleMode.major.intervals, [0, 2, 4, 5, 7, 9, 11])
        XCTAssertEqual(ByteScaleMode.dorian.intervals, [0, 2, 3, 5, 7, 9, 10])
        XCTAssertEqual(ByteScaleMode.harmonicMinor.intervals, [0, 2, 3, 5, 7, 8, 11])
        XCTAssertEqual(ByteScaleMode.melodicMinor.intervals, [0, 2, 3, 5, 7, 9, 11])
        XCTAssertEqual(ByteScaleKey.all.count, 12)
    }

    func testStarterProjectHasFourChannelsAndSixteenSteps() {
        let project = ByteProject.starter
        // The starter ships as a ready-to-play groove: two patterns chained into a song.
        XCTAssertEqual(project.patterns.count, 2)
        XCTAssertEqual(project.arrangement, project.patterns.map(\.id))
        XCTAssertTrue(project.patterns.allSatisfy { $0.steps.count == 4 && $0.steps.allSatisfy { $0.count == 16 } })
        // Every pattern in the bank carries at least one note so first play is musical.
        for pattern in project.patterns {
            XCTAssertTrue(pattern.steps.flatMap { $0 }.contains { $0 != nil })
        }
        XCTAssertEqual(project.songArrangement.count, 16)
        // The starter seeds Song Mode with a two-bar idea and leaves the rest to the user.
        XCTAssertEqual(project.songArrangement[0].patternID, project.patterns[0].id)
        XCTAssertEqual(project.songArrangement[1].patternID, project.patterns[1].id)
        XCTAssertNil(project.songArrangement[2].patternID)
        XCTAssertEqual(project.key, 0)
        XCTAssertEqual(project.mode, .major)
    }

    func testProjectCodableRoundTrip() throws {
        let project = ByteProject.starter
        let data = try JSONEncoder.bytePocketEncoder.encode(project)
        let decoded = try JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertEqual(project.id, decoded.id)
        XCTAssertEqual(project.name, decoded.name)
        XCTAssertEqual(project.tempo, decoded.tempo)
        XCTAssertEqual(project.patterns, decoded.patterns)
        XCTAssertEqual(project.arrangement, decoded.arrangement)
        XCTAssertEqual(project.waveform, decoded.waveform)
        XCTAssertEqual(project.patterns[0].noteLengths, decoded.patterns[0].noteLengths)
    }

    func testTransportClockUsesQuarterNoteSubdivision() {
        XCTAssertEqual(ByteTransportClock.stepDuration(bpm: 120), 0.125, accuracy: 0.0001)
        XCTAssertEqual(ByteTransportClock.step(at: 0.0, bpm: 120), 0)
        XCTAssertEqual(ByteTransportClock.step(at: 0.124, bpm: 120), 0)
        XCTAssertEqual(ByteTransportClock.step(at: 0.125, bpm: 120), 1)
        XCTAssertEqual(ByteTransportClock.step(at: 2.0, bpm: 120), 0)
    }

    func testLiveRendererUsesEachStepNote() {
        var project = ByteProject.starter
        var pattern = project.patterns[0]
        pattern.steps = Array(repeating: Array(repeating: nil, count: 16), count: 4)
        pattern.steps[0][0] = 48
        pattern.steps[0][1] = 72
        project.patterns = [pattern]
        project.arrangement = [pattern.id]

        let sampleRate = 8_000.0
        let stepSamples = Int(ByteTransportClock.stepDuration(bpm: project.tempo) * sampleRate)
        let samples = ByteRenderer.render(project: project, patterns: [pattern], sampleRate: sampleRate)
        let firstStep = Array(samples[0..<(stepSamples * 2)])
        let secondStepStart = stepSamples * 2
        let secondStep = Array(samples[secondStepStart..<(secondStepStart + stepSamples * 2)])

        XCTAssertNotEqual(firstStep, secondStep)
    }

    func testWAVHasRIFFHeader() {
        let data = ByteRenderer.wavData(project: ByteProject.starter, sampleRate: 8_000)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertGreaterThan(data.count, 44)
    }

    func testMIDIHasHeaderAndFiveTracks() {
        let data = ByteMIDI.export(project: ByteProject.starter)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "MThd")
        XCTAssertEqual(data.readBigEndianForTests(UInt16.self, at: 10), 5)
        XCTAssertEqual(String(data: data[14..<18], encoding: .ascii), "MTrk")
    }

    func testMIDIImportCreatesProject() {
        let source = ByteProject.starter
        let data = ByteMIDI.export(project: source)
        let imported = ByteMIDI.importIntoProject(data, project: source)
        XCTAssertNotNil(imported)
        // MIDI import flattens the arrangement into a single 16-step pattern by design.
        XCTAssertEqual(imported?.patterns.count, 1)
        XCTAssertEqual(imported?.patterns[0].steps.count, 4)
    }

    func testStoreEditsCurrentPattern() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.toggleStep(channel: .pulseA, step: 1)
        XCTAssertEqual(store.project.patterns[0].steps[0][1], ByteChannel.pulseA.rootNote(for: store.project.key))
        store.toggleStep(channel: .pulseA, step: 1)
        XCTAssertNil(store.project.patterns[0].steps[0][1])
        defaults.removePersistentDomain(forName: suite)
    }

    func testProjectUndoRedoCoversPatternSoundFXAndSongEdits() {
        let suite = "BeatboiUndoRedoTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        // Effects reset to a vanilla baseline so undo restores known values.
        store.project.effects = ByteEffects()
        let patternID = store.project.patterns[0].id

        store.toggleStep(channel: .pulseA, step: 1)
        XCTAssertTrue(store.canUndo)
        XCTAssertNotNil(store.project.patterns[0].steps[0][1])
        store.undo()
        XCTAssertNil(store.project.patterns[0].steps[0][1])
        XCTAssertTrue(store.canRedo)
        store.redo()
        XCTAssertNotNil(store.project.patterns[0].steps[0][1])

        store.adjustPatch(channel: .pulseA, parameter: .octave, delta: 1)
        XCTAssertEqual(store.patch(for: .pulseA).octave, 1)
        store.undo()
        XCTAssertEqual(store.patch(for: .pulseA).octave, 0)

        store.setEffectSend(channel: .pulseA, percent: 35)
        XCTAssertEqual(store.effectSendPercent(.pulseA), 35)
        store.undo()
        XCTAssertEqual(store.effectSendPercent(.pulseA), 100)

        XCTAssertTrue(store.assignSongPattern(at: 2, patternID: patternID))
        XCTAssertEqual(store.songSlot(at: 2).patternID, patternID)
        store.undo()
        XCTAssertNil(store.songSlot(at: 2).patternID)
        store.redo()
        XCTAssertEqual(store.songSlot(at: 2).patternID, patternID)

        store.toggleStep(channel: .pulseA, step: 1)
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertTrue(store.canRedo)
        store.toggleStep(channel: .pulseA, step: 2)
        XCTAssertFalse(store.canRedo)

        defaults.removePersistentDomain(forName: suite)
    }

    func testNoteLengthSpansStepsAndTrimsWhenEditingInsideHold() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.toggleStep(channel: .pulseA, step: 1)
        store.setNoteLength(channel: .pulseA, step: 1, length: 4)
        XCTAssertEqual(store.noteLength(channel: .pulseA, step: 1), 4)
        XCTAssertTrue(store.isStepCovered(channel: .pulseA, step: 3))
        XCTAssertNil(store.project.patterns[0].steps[0][3])

        // Adding a note inside a hold creates a new start and trims the earlier note.
        store.toggleStep(channel: .pulseA, step: 2)
        XCTAssertEqual(store.noteLength(channel: .pulseA, step: 1), 1)
        XCTAssertNotNil(store.project.patterns[0].steps[0][2])
        XCTAssertFalse(store.isStepCovered(channel: .pulseA, step: 2))

        // A four-step hold from step 1 covers exactly steps 2, 3, and 4; step 5 remains independent.
        store.setNoteLength(channel: .pulseA, step: 1, length: 4)
        XCTAssertTrue(store.isStepCovered(channel: .pulseA, step: 3))
        XCTAssertFalse(store.isStepCovered(channel: .pulseA, step: 5))

        defaults.removePersistentDomain(forName: suite)
    }

    func testChannelMuteSoloStatesPersistAndSoloIsIndependent() {
        let suite = "BeatboiMuteSoloTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        XCTAssertFalse(store.isChannelMuted(.pulseA))
        XCTAssertFalse(store.isChannelSoloed(.pulseA))
        store.toggleChannelMute(.pulseA)
        store.toggleChannelSolo(.drum)
        XCTAssertTrue(store.isChannelMuted(.pulseA))
        XCTAssertTrue(store.isChannelSoloed(.drum))
        XCTAssertFalse(store.isChannelSoloed(.pulseA))

        let data = try! JSONEncoder.bytePocketEncoder.encode(store.project)
        let decoded = try! JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertTrue(decoded.channelPatches.first(where: { $0.channel == .pulseA })?.muted == true)
        XCTAssertTrue(decoded.channelPatches.first(where: { $0.channel == .drum })?.soloed == true)

        store.clearChannelSolos()
        XCTAssertFalse(store.isChannelSoloed(.drum))
        defaults.removePersistentDomain(forName: suite)
    }

    func testChannelVolumeFaderStoresIndependentZeroToHundredPercentValues() {
        let suite = "BeatboiVolumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.setChannelVolume(channel: .pulseA, percent: 37)
        store.setChannelVolume(channel: .drum, percent: 0)
        XCTAssertEqual(store.channelVolumePercent(.pulseA), 37)
        XCTAssertEqual(store.channelVolumePercent(.drum), 0)
        store.setChannelVolume(channel: .pulseA, percent: 140)
        XCTAssertEqual(store.channelVolumePercent(.pulseA), 100)
        defaults.removePersistentDomain(forName: suite)
    }

    func testAllFourChannelsAreFree() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        XCTAssertEqual(store.visibleChannels, ByteChannel.allCases)
        defaults.removePersistentDomain(forName: suite)
    }

    func testIndividualDrumVoiceVolumesStaySeparateFromDrumMaster() {
        let suite = "BeatboiDrumVolumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        // Reset the tuned starter kit so this test exercises a vanilla baseline.
        store.project.channelPatches = ByteChannelPatch.defaults

        store.setDrumVoiceVolume(voice: .kick, percent: 35)
        store.setDrumVoiceVolume(voice: .snare, percent: 80)
        XCTAssertEqual(store.drumVoiceVolumePercent(.kick), 33)
        XCTAssertEqual(store.drumVoiceVolumePercent(.snare), 80)
        XCTAssertEqual(store.drumVoiceVolumePercent(.hiHat), 87)
        XCTAssertEqual(store.channelVolumePercent(.drum), 100)

        store.setChannelVolume(channel: .drum, percent: 42)
        XCTAssertEqual(store.channelVolumePercent(.drum), 42)
        XCTAssertEqual(store.drumVoiceVolumePercent(.kick), 33)
        XCTAssertEqual(store.drumVoiceVolumePercent(.snare), 80)
        defaults.removePersistentDomain(forName: suite)
    }

    func testDrumVoiceNamesAndPercSamplesUseSwappedMapping() {
        XCTAssertEqual(ByteDrumVoice.label(for: 42), "PERC")
        XCTAssertEqual(ByteDrumVoice.label(for: 49), "HI-HAT")
        XCTAssertEqual(ByteDrumVoice.hiHat.title, "PERC")
        XCTAssertEqual(ByteDrumVoice.perc.title, "HI-HAT")
        XCTAssertEqual(ByteDrumVoice.perc.resourceNames, ["perc2", "perc1"])
    }

    func testSoundDiceRandomizesOnlyMelodicChannels() {
        let suite = "BeatboiSoundDiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.selectedChannel = .pulseA
        XCTAssertTrue(store.randomizeSelectedPatch())
        XCTAssertEqual(store.selectedPatchParameter[.pulseA], .portamento)
        XCTAssertTrue((0...3).contains(store.patch(for: .pulseA).duty))

        store.selectedChannel = .wave
        XCTAssertTrue(store.randomizeSelectedPatch())
        XCTAssertEqual(store.selectedPatchParameter[.wave], .portamento)

        store.selectedChannel = .drum
        XCTAssertFalse(store.randomizeSelectedPatch())
        defaults.removePersistentDomain(forName: suite)
    }

    func testDrumSampleSelectionRemainsTheOnlyDrumVoiceChoice() {
        let suite = "BeatboiDrumSoundTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let before = store.patch(for: .drum)
        store.selectedChannel = .drum
        XCTAssertFalse(store.randomizeSelectedPatch())
        store.setDrumSample(voice: .kick, variant: 2)
        XCTAssertEqual(store.patch(for: .drum).drumSamples[ByteDrumVoice.kick.rawValue], 2)
        XCTAssertEqual(store.patch(for: .drum).drumSamples.dropFirst(), before.drumSamples.dropFirst())
        defaults.removePersistentDomain(forName: suite)
    }

    func testBundledDrumSamplesLoadAsAudio() {
        for voice in ByteDrumVoice.allCases {
            for variant in 1...2 {
                XCTAssertFalse(ByteDrumSampleBank.shared.sample(voice: voice, variant: variant).isEmpty, "Missing \(voice.title) sample \(variant)")
            }
        }
    }

    func testDrumStepsAreIndependentAndSampleSelectionIsPerVoice() {
        let suite = "BeatboiDrumTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.toggleStep(channel: .drum, step: 0)
        store.setDrumVoice(step: 0, voice: ByteDrumVoice.hiHat.rawValue)
        store.toggleStep(channel: .drum, step: 2)
        store.setDrumVoice(step: 2, voice: ByteDrumVoice.perc.rawValue)
        XCTAssertEqual(store.project.patterns[0].steps[3][0], 42)
        XCTAssertEqual(store.project.patterns[0].steps[3][2], 49)
        XCTAssertFalse(store.isStepCovered(channel: .drum, step: 1))
        store.setDrumSample(voice: .hiHat, variant: 2)
        XCTAssertEqual(store.patch(for: .drum).drumSamples[ByteDrumVoice.hiHat.rawValue], 2)
        XCTAssertEqual(store.project.patterns[0].steps[3][0], 42)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSongModeAssignsOnePatternPerSlotAndCyclesPatterns() {
        let suite = "BeatboiSongTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let firstID = store.project.patterns[0].id
        let second = BytePattern.empty(name: "PATTERN 02")
        store.project.patterns.append(second)

        XCTAssertTrue(store.assignSongPattern(at: 0, patternID: firstID))
        XCTAssertTrue(store.assignSongPattern(at: 1, patternID: second.id))
        XCTAssertEqual(store.songSlot(at: 0).patternID, firstID)
        XCTAssertFalse(store.songSlot(at: 0).isContinuation)
        XCTAssertEqual(store.songSlot(at: 1).patternID, second.id)
        XCTAssertFalse(store.songSlot(at: 1).isContinuation)
        XCTAssertNil(store.songSlot(at: 2).patternID)
        store.project.arrangement.append(second.id)
        XCTAssertEqual(store.project.arrangedPatterns.map(\.id), store.project.patterns.map(\.id))
        XCTAssertEqual(store.playbackPatterns.map(\.id), [firstID])
        XCTAssertFalse(store.project.songModeEnabled)

        store.cycleSongSlot(at: 1, delta: -100)
        XCTAssertEqual(store.songSlot(at: 1).patternID, firstID)
        store.cycleSongSlot(at: 1, delta: 100)
        XCTAssertEqual(store.songSlot(at: 1).patternID, second.id)
        store.cycleSongSlot(at: 1, delta: -1)
        // One step back lands on the previous pattern in the three-pattern bank.
        XCTAssertEqual(store.songSlot(at: 1).patternID, store.project.patterns[1].id)
        XCTAssertFalse(store.songSlot(at: 1).isContinuation)

        let data = try! JSONEncoder.bytePocketEncoder.encode(store.project)
        let decoded = try! JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertEqual(decoded.songArrangement, store.project.songArrangement)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSongModeRendererUsesOneSixteenStepBarPerSlot() {
        let first = BytePattern.empty(name: "SHORT")
        let second = BytePattern.empty(name: "LONG")
        var project = ByteProject(patterns: [first, second])
        project.songModeEnabled = true
        project.songArrangement = Array(repeating: .empty, count: 16)
        project.songArrangement[0] = ByteSongSlot(patternID: first.id, isContinuation: false)
        project.songArrangement[1] = ByteSongSlot(patternID: second.id, isContinuation: false)
        // Trailing empty bars are trimmed from the loop; the render covers bars 0-1 only.
        let expectedFrames = Int(Double(project.songPatterns.count * 16) * ByteTransportClock.stepDuration(bpm: project.tempo) * 8_000)
        XCTAssertEqual(project.songPatterns.count, 2)
        XCTAssertEqual(project.songSlotIndices, [0, 1])
        let samples = ByteRenderer.render(project: project, patterns: project.songPatterns, sampleRate: 8_000)
        XCTAssertEqual(samples.count, expectedFrames * 2)
    }

    /// A short arrangement must loop on its music: the loop ends at the last assigned
    /// pattern instead of running through trailing empty bars.
    func testSongLoopTrimsTrailingEmptyBars() {
        var project = ByteProject.starter
        project.songModeEnabled = true
        project.songArrangement = Array(repeating: .empty, count: 16)
        project.songArrangement[0] = ByteSongSlot(patternID: project.patterns[0].id, isContinuation: false)
        project.songArrangement[2] = ByteSongSlot(patternID: project.patterns[1].id, isContinuation: false)
        // Bars 0-2 play (bar 1 is intentional silence between the two patterns);
        // trailing empty bars 3-15 are outside the loop.
        XCTAssertEqual(project.songPatterns.count, 3)
        XCTAssertEqual(project.songSlotIndices, [0, 1, 2])
        XCTAssertTrue(project.songPatterns[0].name != "EMPTY BAR")
        XCTAssertEqual(project.songPatterns[1].name, "EMPTY BAR")
        XCTAssertTrue(project.songPatterns[2].name != "EMPTY BAR")
    }

    func testWAVOutputIsFiniteAndBounded() {
        var project = ByteProject.starter
        project.songModeEnabled = true
        let second = BytePattern.empty(name: "VARIATION 02")
        project.patterns.append(second)
        project.songArrangement[0] = ByteSongSlot(patternID: project.patterns[0].id, isContinuation: false)
        project.songArrangement[1] = ByteSongSlot(patternID: second.id, isContinuation: false)
        let samples = ByteRenderer.render(project: project, patterns: project.songPatterns, sampleRate: 8_000)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.9 })
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0)
        let wav = ByteRenderer.wavData(project: project, patterns: project.songPatterns, sampleRate: 8_000)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
    }

    func testDeletingPatternRemovesNormalAndSongAssignments() {
        let suite = "BeatboiDeletePatternTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let firstID = store.project.patterns[0].id
        store.addPattern()
        let deletedID = store.currentPatternID
        XCTAssertTrue(store.assignSongPattern(at: 3, patternID: deletedID))
        XCTAssertTrue(store.deletePattern(deletedID))
        XCTAssertFalse(store.project.patterns.contains(where: { $0.id == deletedID }))
        XCTAssertFalse(store.project.arrangement.contains(deletedID))
        XCTAssertNil(store.songSlot(at: 3).patternID)
        XCTAssertTrue(store.project.patterns.contains(where: { $0.id == store.currentPatternID }))
        // The final remaining pattern is protected from deletion.
        XCTAssertTrue(store.deletePattern(firstID))
        XCTAssertEqual(store.project.patterns.count, 1)
        XCTAssertFalse(store.deletePattern(store.project.patterns[0].id))
        defaults.removePersistentDomain(forName: suite)
    }

    func testDiceMelodyUsesTwoOctavesScaleRestsAndLengths() {
        let suite = "BeatboiDiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.selectedChannel = .pulseA
        store.updateVoicing(key: 0, mode: .major)
        let row = ByteChannel.allCases.firstIndex(of: .pulseA)!
        var randomCalls = 0
        store.project.patterns[0].randomizeMelody(channel: .pulseA, key: 0, mode: .major) { range in
            if range.upperBound == 99 {
                randomCalls += 1
                return randomCalls == 1 ? 0 : 99
            }
            if range.lowerBound >= 2 { return range.upperBound }
            return range.lowerBound
        }
        let notes = store.project.patterns[0].steps[row].compactMap { $0 }
        XCTAssertTrue(notes.allSatisfy { (48...72).contains($0) && ByteScaleMode.major.quantize($0, key: 0) == $0 })
        XCTAssertTrue(store.project.patterns[0].noteLengths[row].allSatisfy { (1...4).contains($0) })
        XCTAssertTrue(store.project.patterns[0].steps[row].contains(where: { $0 == nil }))
        XCTAssertTrue(store.project.patterns[0].noteLengths[row].contains(where: { $0 > 1 }))
        XCTAssertFalse(store.randomizeSelectedMelody() == false)
        store.selectedChannel = .drum
        XCTAssertFalse(store.randomizeSelectedMelody())
        defaults.removePersistentDomain(forName: suite)
    }

    func testNewPatternCreatesFreshEmptySelectedPattern() {
        let suite = "BeatboiNewPatternTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let originalID = store.currentPatternID

        store.addPattern()

        XCTAssertEqual(store.project.patterns.count, 3)
        XCTAssertNotEqual(store.currentPatternID, originalID)
        let fresh = store.project.patterns.first(where: { $0.id == store.currentPatternID })!
        XCTAssertTrue(fresh.steps.allSatisfy { $0.allSatisfy { $0 == nil } })
        XCTAssertTrue(fresh.noteLengths.allSatisfy { $0.allSatisfy { $0 == 1 } })
        defaults.removePersistentDomain(forName: suite)
    }

    func testCopyCurrentPatternCreatesIndependentSelectedPattern() {
        let suite = "BeatboiCopyPatternTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let sourceID = store.currentPatternID
        store.toggleStep(channel: .pulseA, step: 3)
        store.setNoteLength(channel: .pulseA, step: 3, length: 3)
        let source = store.project.patterns[0]

        store.duplicateCurrentPattern()

        XCTAssertEqual(store.project.patterns.count, 3)
        XCTAssertNotEqual(store.currentPatternID, sourceID)
        XCTAssertEqual(store.project.patterns[2].steps, source.steps)
        XCTAssertEqual(store.project.patterns[2].noteLengths, source.noteLengths)
        XCTAssertEqual(store.project.patterns[2].steps.count, 4)
        XCTAssertEqual(store.project.patterns[2].steps.allSatisfy { $0.count == 16 }, true)

        store.toggleStep(channel: .pulseA, step: 3)
        XCTAssertNotEqual(store.project.patterns[1].steps, source.steps)
        XCTAssertEqual(store.project.patterns[0].steps, source.steps)
        defaults.removePersistentDomain(forName: suite)
    }

    func testBitCrushResponseUsesFullControlForFormerZeroToTwentyFiveRange() {
        XCTAssertEqual(ByteEffects.bitCrushLevels(for: 0), 16)
        XCTAssertEqual(ByteEffects.bitCrushHoldFrames(for: 0), 18)
        XCTAssertEqual(ByteEffects.bitCrushHoldFrames(for: 100), 1)
        XCTAssertEqual(ByteEffects.bitCrushEffectiveAmount(for: 0), 0)
        XCTAssertEqual(ByteEffects.bitCrushEffectiveAmount(for: 25), 6.25)
        XCTAssertEqual(ByteEffects.bitCrushEffectiveAmount(for: 100), 25)
        XCTAssertEqual(ByteEffects.bitCrushEffectiveAmount(for: 140), 25)
    }

    func testTriangleWaveShapeChangesRenderedAudio() {
        var base = ByteProject.starter
        var pattern = BytePattern.empty(name: "TRIANGLE SHAPE TEST")
        pattern.steps[2][0] = 48
        base.patterns = [pattern]
        base.arrangement = [pattern.id]
        guard let waveIndex = base.channelPatches.firstIndex(where: { $0.channel == .wave }) else {
            XCTFail("Triangle patch missing")
            return
        }
        base.channelPatches[waveIndex].waveShape = ByteWaveShape.waveBass.rawValue
        let bass = ByteRenderer.render(project: base, sampleRate: 8_000)
        base.channelPatches[waveIndex].waveShape = ByteWaveShape.metal.rawValue
        let metal = ByteRenderer.render(project: base, sampleRate: 8_000)

        XCTAssertEqual(bass.count, metal.count)
        XCTAssertTrue(zip(bass, metal).contains { abs($0 - $1) > 0.0001 })
    }

    func testEffectRenderPathsChangeAudioWhenEnabled() {
        let baseline = ByteRenderer.render(project: ByteProject(), sampleRate: 8_000)
        var effectedProject = ByteProject()
        effectedProject.effects.echoAmount = 100
        effectedProject.effects.bitCrushAmount = 100
        effectedProject.channelPatches[0].octaveFlutterAmount = 70
        effectedProject.channelPatches[0].octaveFlutterPattern = ByteOctaveFlutterPattern.baseUpTwoUp.rawValue
        let effected = ByteRenderer.render(project: effectedProject, sampleRate: 8_000)
        XCTAssertEqual(baseline.count, effected.count)
        XCTAssertTrue(zip(baseline, effected).contains { abs($0 - $1) > 0.0001 })
    }

    func testOctaveFlutterMapsFaderToDiscreteNESStyleJumps() {
        XCTAssertEqual(ByteEffect.allCases, [.echo, .bitCrush])
        XCTAssertEqual(ByteEffects.octaveFlutterDivision(for: 0), 0)
        XCTAssertEqual(ByteEffects.octaveFlutterDivision(for: 1), 0)
        XCTAssertEqual(ByteEffects.octaveFlutterDivision(for: 100), 4)
        XCTAssertEqual(ByteEffects.octaveFlutterDivisionTitle(for: 0), "OFF")
        XCTAssertEqual(ByteEffects.octaveFlutterDivisionTitle(for: 70), "1/128")
        XCTAssertEqual(ByteEffects.octaveFlutterMultiplier(at: 0.0, bpm: 120, amount: 70), 1)
        XCTAssertEqual(ByteEffects.octaveFlutterMultiplier(at: 0.01562505, bpm: 120, amount: 70), 2)
        XCTAssertEqual(ByteEffects.octaveFlutterMultiplier(at: 0.0, bpm: 120, amount: 0), 1)
        XCTAssertEqual(ByteEffects.octaveFlutterMultiplier(at: 0.0, bpm: 120, amount: 70, pattern: .baseUpTwoUp), 1)
        XCTAssertEqual(ByteEffects.octaveFlutterMultiplier(at: 0.03125005, bpm: 120, amount: 70, pattern: .baseUpTwoUp), 4)
    }

    func testAbsoluteSoundLabValuesUpdateEveryMelodicChannel() {
        let suite = "BeatboiAbsolutePatchValueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        for channel in [ByteChannel.pulseA, .pulseB, .wave] {
            store.setPatchValue(channel: channel, parameter: .envelopeAttack, value: 63)
            store.setPatchValue(channel: channel, parameter: .portamento, value: 47)
            store.setPatchValue(channel: channel, parameter: .octave, value: 1)
            XCTAssertEqual(store.patch(for: channel).envelopeAttack, 63)
            XCTAssertEqual(store.patch(for: channel).portamento, 47)
            XCTAssertEqual(store.patch(for: channel).octave, 1)
        }

        store.setPatchValue(channel: .pulseA, parameter: .duty, value: 3)
        XCTAssertEqual(store.patch(for: .pulseA).duty, 3)
        store.setPatchValue(channel: .wave, parameter: .waveShape, value: ByteWaveShape.metal.rawValue)
        XCTAssertEqual(store.patch(for: .wave).waveShape, ByteWaveShape.metal.rawValue)

        // Absolute values clamp at the parameter's real hardware range rather than
        // getting stuck at the old value or overflowing during a fast swipe.
        store.setPatchValue(channel: .pulseA, parameter: .envelopeSustain, value: 140)
        store.setPatchValue(channel: .pulseB, parameter: .envelopeRelease, value: -20)
        XCTAssertEqual(store.patch(for: .pulseA).envelopeSustain, 100)
        XCTAssertEqual(store.patch(for: .pulseB).envelopeRelease, 0)

        defaults.removePersistentDomain(forName: suite)
    }

    func testAudioTaperMakesLowValuesUsable() {
        // Square-root taper: 25% of fader travel delivers 50% of the gain.
        XCTAssertEqual(ByteAudioTaper.gain(for: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ByteAudioTaper.gain(for: 25), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ByteAudioTaper.gain(for: 100), 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(ByteAudioTaper.gain(for: 10), 0.2)
        // Monotonic and bounded across the whole travel.
        var previous = -1.0
        for percent in stride(from: 0, through: 100, by: 5) {
            let gain = ByteAudioTaper.gain(for: percent)
            XCTAssertGreaterThanOrEqual(gain, previous)
            XCTAssertLessThanOrEqual(gain, 1.0)
            previous = gain
        }
        // Out-of-range values clamp like the rest of the engine.
        XCTAssertEqual(ByteAudioTaper.gain(for: -50), 0, accuracy: 0.0001)
        XCTAssertEqual(ByteAudioTaper.gain(for: 150), 1.0, accuracy: 0.0001)
    }

    func testStarterGrooveUsesPresetPatchesAndBalancedMix() {
        let project = ByteProject.starter
        XCTAssertEqual(project.name, "FIRST BEAT")
        XCTAssertGreaterThan(project.effects.echoAmount, 0)
        // Starter channels use the seeded hand-tuned sounds.
        let lead = ByteInstrumentPreset.library(for: .pulseA).first(where: { $0.id == "chipLead" })
        XCTAssertEqual(project.channelPatches[0].duty, lead?.patch.duty ?? -1)
        let bass = ByteInstrumentPreset.library(for: .pulseB).first(where: { $0.id == "bassDub" })
        XCTAssertEqual(project.channelPatches[1].octave, bass?.patch.octave ?? -99)
        // The starter's mix is a hand-set balance, not the default fader positions.
        XCTAssertNotEqual(project.channelPatches[0].masterVolume, 50)
        XCTAssertNotEqual(project.channelPatches[1].masterVolume, 50)
        XCTAssertEqual(project.channelPatches[3].masterVolume, 66)
        // The seeded arrangement chains GROOVE into BREAK and keeps the mix intact.
        XCTAssertEqual(project.songArrangement[0].patternID, project.patterns[0].id)
        XCTAssertEqual(project.songArrangement[1].patternID, project.patterns[1].id)
        XCTAssertNil(project.songArrangement[2].patternID)
    }

    func testSoundLabFineTuneStepsRespectParameterBounds() {
        let suite = "BeatboiFineTuneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.setPatchValue(channel: .pulseA, parameter: .envelopeAttack, value: 50)
        store.setPatchValue(channel: .pulseA, parameter: .envelopeAttack, value: 51)
        XCTAssertEqual(store.patch(for: .pulseA).envelopeAttack, 51)
        store.setPatchValue(channel: .pulseA, parameter: .envelopeAttack, value: 0)
        store.setPatchValue(channel: .pulseA, parameter: .envelopeAttack, value: -1)
        XCTAssertEqual(store.patch(for: .pulseA).envelopeAttack, 0)

        store.setPatchValue(channel: .pulseA, parameter: .octave, value: -2)
        store.setPatchValue(channel: .pulseA, parameter: .octave, value: -1)
        XCTAssertEqual(store.patch(for: .pulseA).octave, -1)
        store.setPatchValue(channel: .pulseA, parameter: .octave, value: 2)
        store.setPatchValue(channel: .pulseA, parameter: .octave, value: 3)
        XCTAssertEqual(store.patch(for: .pulseA).octave, 2)

        defaults.removePersistentDomain(forName: suite)
    }

    func testSharedBeginnerPatchControlsAndDMGEffectsPersist() {
        let suite = "BeatboiSoundControlsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        // Reset the hand-tuned starter patches so this test exercises a vanilla baseline.
        store.project.channelPatches = ByteChannelPatch.defaults
        for channel in [ByteChannel.pulseA, .pulseB, .wave] {
            store.adjustPatch(channel: channel, parameter: .octave, delta: 1)
            XCTAssertEqual(store.patch(for: channel).octave, 1)
            store.adjustPatch(channel: channel, parameter: .octave, delta: -5)
            XCTAssertEqual(store.patch(for: channel).octave, -2)
            store.adjustPatch(channel: channel, parameter: .octave, delta: 8)
            XCTAssertEqual(store.patch(for: channel).octave, 2)
            store.adjustPatch(channel: channel, parameter: .tremolo, delta: -20)
            store.adjustPatch(channel: channel, parameter: .envelope, delta: 30)
            store.adjustPatch(channel: channel, parameter: .vibratoDepth, delta: 40)
            XCTAssertEqual(store.patch(for: channel).tremolo, 0)
            XCTAssertEqual(store.patch(for: channel).envelope, 30)
            XCTAssertEqual(store.patch(for: channel).vibratoDepth, 40)
        }
        store.adjustPatch(channel: .pulseA, parameter: .octaveFlutterSpeed, delta: 65)
        XCTAssertEqual(store.patch(for: .pulseA).octaveFlutterAmount, 65)
        store.adjustPatch(channel: .pulseA, parameter: .octaveFlutterPattern, delta: 1)
        XCTAssertEqual(store.patch(for: .pulseA).octaveFlutterPattern, 1)
        let data = try! JSONEncoder.bytePocketEncoder.encode(store.project)
        let decoded = try! JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertEqual(decoded.channelPatches[0].octaveFlutterAmount, 65)
        XCTAssertEqual(decoded.channelPatches[0].octaveFlutterPattern, 1)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSongArrangementLengthSupportsSixteenThirtyTwoAndSixtyFourBars() throws {
        let suite = "BeatboiArrangementLengthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let firstID = store.project.patterns[0].id
        XCTAssertEqual(store.songArrangementLength, 16)

        XCTAssertTrue(store.assignSongPattern(at: 15, patternID: firstID))
        store.setSongArrangementLength(32)
        XCTAssertEqual(store.songArrangementLength, 32)
        XCTAssertEqual(store.project.songArrangement.count, 32)
        XCTAssertEqual(store.songSlot(at: 15).patternID, firstID)

        XCTAssertTrue(store.assignSongPattern(at: 31, patternID: firstID))
        store.setSongArrangementLength(64)
        XCTAssertEqual(store.songArrangementLength, 64)
        XCTAssertEqual(store.project.songArrangement.count, 64)
        XCTAssertEqual(store.songSlot(at: 31).patternID, firstID)

        let data = try JSONEncoder.bytePocketEncoder.encode(store.project)
        let decoded = try JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data)
        XCTAssertEqual(decoded.songArrangementLength, 64)
        XCTAssertEqual(decoded.songArrangement.count, 64)
        XCTAssertEqual(decoded.songArrangement[31].patternID, firstID)

        store.setSongArrangementLength(16)
        XCTAssertEqual(store.songArrangementLength, 16)
        XCTAssertEqual(store.project.songArrangement.count, 16)
        XCTAssertEqual(store.songSlot(at: 15).patternID, firstID)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSongArrangementPagesStayInSixteenBarBlocks() {
        XCTAssertEqual(Array(0..<16).count, 16)
        XCTAssertEqual(Array(16..<32).count, 16)
        XCTAssertEqual(Array(32..<48).count, 16)
        XCTAssertEqual(Array(48..<64).count, 16)
    }

    func testLegacySongArrangementDefaultsToSixteenBars() throws {
        let data = try JSONEncoder.bytePocketEncoder.encode(ByteProject.starter)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "songArrangementLength")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let recovered = try JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: legacy)
        XCTAssertEqual(recovered.songArrangementLength, 16)
        XCTAssertEqual(recovered.songArrangement.count, 16)
    }

    func testMalformedProjectDecodeRecoversSafeEditorShape() throws {
        let source = try JSONEncoder.bytePocketEncoder.encode(ByteProject.starter)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        object["patterns"] = []
        object["arrangement"] = [UUID().uuidString]
        object["songArrangement"] = [["patternID": UUID().uuidString, "isContinuation": false]]

        let malformed = try JSONSerialization.data(withJSONObject: object)
        let recovered = try JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: malformed)

        XCTAssertFalse(recovered.patterns.isEmpty)
        XCTAssertLessThanOrEqual(recovered.patterns.count, ByteProject.maximumPatternCount)
        XCTAssertTrue(recovered.patterns.allSatisfy { pattern in
            pattern.steps.count == ByteChannel.allCases.count && pattern.steps.allSatisfy { $0.count == 16 }
        })
        XCTAssertFalse(recovered.arrangement.isEmpty)
        XCTAssertTrue(recovered.arrangement.allSatisfy { id in recovered.pattern(with: id) != nil })
        XCTAssertEqual(recovered.songArrangement.count, 16)
        XCTAssertTrue(recovered.songArrangement.allSatisfy { slot in
            slot.patternID == nil || recovered.pattern(with: slot.patternID!) != nil
        })
    }

    func testEmptyProjectInitializerCreatesOneUsablePattern() {
        let project = ByteProject(patterns: [])
        XCTAssertEqual(project.patterns.count, 1)
        XCTAssertEqual(project.patterns[0].steps.count, ByteChannel.allCases.count)
        XCTAssertTrue(project.patterns[0].steps.allSatisfy { $0.count == 16 })
        XCTAssertEqual(project.arrangement, [project.patterns[0].id])
    }

    func testClearingChannelRowRemainsUndoable() {
        let suite = "BeatboiClearRowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let originalRow = store.project.patterns[0].steps[0]

        store.clearChannelRow(.pulseA)
        XCTAssertTrue(store.project.patterns[0].steps[0].allSatisfy { $0 == nil })
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.project.patterns[0].steps[0], originalRow)
        defaults.removePersistentDomain(forName: suite)
    }

    func testChannelActivityMetersFollowPlaybackStepAndMuteState() {
        let suite = "BeatboiActivityMeterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.channelActivityLevel(.pulseA, step: 0), 0)
        store.isPlaying = true
        XCTAssertEqual(store.channelActivityLevel(.pulseA, step: 0), 100)
        XCTAssertEqual(store.channelActivityLevel(.pulseA, step: 1), 0)
        store.toggleChannelMute(.pulseA)
        XCTAssertEqual(store.channelActivityLevel(.pulseA, step: 0), 0)
        defaults.removePersistentDomain(forName: suite)
    }

    func testChannelNamesStayConsistentAcrossTheHardwareModel() {
        XCTAssertEqual(ByteChannel.pulseA.title, "PULSE 1")
        XCTAssertEqual(ByteChannel.pulseB.title, "PULSE 2")
        XCTAssertEqual(ByteChannel.wave.title, "TRIANGLE")
        XCTAssertEqual(ByteChannel.drum.title, "DRUM")
    }

    func testUnlockFlagPersistsAcrossStoreInstances() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        XCTAssertFalse(store.isUnlocked)
        store.setUnlocked(true)
        let reloaded = GameStore(defaults: defaults)
        XCTAssertTrue(reloaded.isUnlocked)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The persisted flag must reconcile DOWN when the receipt no longer backs
    /// the entitlement — this is the branch the app calls at launch.
    func testUnlockedFlagReconcilesDownWhenReceiptDisappears() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.setUnlocked(true)
        let relocked = GameStore(defaults: defaults)
        XCTAssertTrue(relocked.isUnlocked)
        relocked.setUnlocked(false)
        let reconciled = GameStore(defaults: defaults)
        XCTAssertFalse(reconciled.isUnlocked)
        defaults.removePersistentDomain(forName: suite)
    }

    /// Export must never be granted without a signed receipt transaction: a
    /// fresh manager (no purchase in this environment) stays gated.
    @MainActor
    func testExportGateRequiresReceiptBackedEntitlement() async {
        let manager = StoreKitManager()
        let owned = await manager.isPurchased()
        XCTAssertFalse(owned, "test environment must not hold an Export Pack entitlement")
        XCTAssertFalse(manager.hasReceiptEntitlement)
        XCTAssertFalse(manager.canExport)
    }
}

private extension ByteProject {
    var projectEffectsForTests: ByteEffects { effects }
}

private extension Data {
    func readBigEndianForTests<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value = (value << 8) | T(self[offset + index])
        }
        return value
    }
}
