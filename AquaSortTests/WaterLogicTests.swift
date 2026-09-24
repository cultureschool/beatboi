import XCTest
import SwiftUI
import UIKit
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

    func testChangingKeyTransposesMelodyInsteadOfRatchetingItDownward() {
        let suite = "BeatboiVoicingTransposeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.updateVoicing(key: 0, mode: .major)

        let phrase = [60, 64, 67, 69] // C E G A
        for (step, note) in phrase.enumerated() {
            store.setNote(channel: .pulseA, step: step, note: note)
        }

        store.updateVoicing(key: 2) // D major transposes the phrase up a whole tone
        XCTAssertEqual((0..<phrase.count).map { store.project.patterns[0].steps[0][$0] }, [62, 66, 69, 71])

        // Returning to C restores the phrase exactly. The old nearest-note snapping moved
        // notes a semitone lower on every change and could never recover.
        store.updateVoicing(key: 0)
        XCTAssertEqual((0..<phrase.count).map { store.project.patterns[0].steps[0][$0] }, phrase)

        // Cycling keys repeatedly stays stable in both directions.
        for _ in 0..<8 {
            store.updateVoicing(key: 7) // G
            store.updateVoicing(key: 0)
        }
        XCTAssertEqual((0..<phrase.count).map { store.project.patterns[0].steps[0][$0] }, phrase)
        defaults.removePersistentDomain(forName: suite)
    }

    func testKeyChangeTakesTheShortestIntervalAndKeepsNotesInRegister() {
        let suite = "BeatboiVoicingRegisterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        store.updateVoicing(key: 0, mode: .chromatic)

        store.setNote(channel: .wave, step: 0, note: 36)
        store.setNote(channel: .wave, step: 1, note: 24) // bottom edge of the register

        store.updateVoicing(key: 11) // C to B moves down a semitone rather than up eleven
        XCTAssertEqual(store.project.patterns[0].steps[2][0], 35)
        XCTAssertEqual(store.project.patterns[0].steps[2][1], 24) // held at the register edge

        store.updateVoicing(key: 0)
        XCTAssertEqual(store.project.patterns[0].steps[2][0], 36)
        defaults.removePersistentDomain(forName: suite)
    }

    func testModeChangeStillSnapsMelodicRowsWithoutTouchingDrums() {
        let suite = "BeatboiVoicingModeSnapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.updateVoicing(key: 0, mode: .chromatic)
        store.setNote(channel: .pulseA, step: 0, note: 63) // out of C major
        store.setNote(channel: .drum, step: 0, note: ByteDrumVoice.snare.baseNote)

        store.updateVoicing(mode: .major)
        XCTAssertEqual(store.project.patterns[0].steps[0][0]!, ByteScaleMode.major.quantize(63, key: 0))
        XCTAssertEqual(store.project.patterns[0].steps[3][0], ByteDrumVoice.snare.baseNote)
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

    /// First launch now opens a blank project on the drum channel: one empty pattern,
    /// no notes, no demo groove. The starter remains as the demo document for tests.
    func testFirstLaunchOpensBlankProjectOnDrumChannel() {
        let suite = "BeatboiFirstLaunchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.project.name, "FIRST BEAT")
        XCTAssertEqual(store.project.patterns.count, 1)
        XCTAssertEqual(store.project.patterns[0].steps.flatMap { $0 }.compactMap { $0 }.count, 0)
        XCTAssertEqual(store.selectedChannel, .drum)
        defaults.removePersistentDomain(forName: suite)
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

    /// The WAV writer appends its PCM payload in bulk chunks for speed, which must
    /// not change a single byte of the file. Rebuild the same file with a naive
    /// per-sample little-endian loop and require the two to be identical, so the
    /// encoder can keep being optimized without silently altering exports.
    func testWAVPayloadMatchesNaiveReferenceEncoding() {
        let project = ByteProject.starter
        let samples = ByteRenderer.render(project: project, sampleRate: 8_000)
        let optimized = ByteRenderer.wavData(project: project, sampleRate: 8_000)

        var reference = Data()
        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { reference.append(contentsOf: $0) }
        }

        let channels: UInt16 = 2
        let bits: UInt16 = 16
        let bytesPerSample = Int(bits / 8)
        let dataSize = UInt32(samples.count * bytesPerSample)
        reference.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(36 + dataSize)
        reference.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(channels)
        appendLittleEndian(UInt32(8_000))
        appendLittleEndian(UInt32(8_000 * Int(channels) * bytesPerSample))
        appendLittleEndian(UInt16(Int(channels) * bytesPerSample))
        appendLittleEndian(bits)
        reference.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataSize)
        for sample in samples {
            appendLittleEndian(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }

        XCTAssertEqual(optimized.count, reference.count)
        XCTAssertEqual(optimized, reference)
    }

    func testMIDIHasHeaderAndFiveTracks() {
        let data = ByteMIDI.export(project: ByteProject.starter)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "MThd")
        XCTAssertEqual(data.readBigEndianForTests(UInt16.self, at: 10), 5)
        XCTAssertEqual(String(data: data[14..<18], encoding: .ascii), "MTrk")
    }

    /// A step is a sixteenth note, so two hits four steps apart must sit exactly four
    /// sixteenths apart in the exported ticks. The export used to declare the division as
    /// though a step were a whole quarter note, which made every file play four times slow in
    /// a DAW while still round-tripping correctly through this app's own importer.
    func testMIDITicksPerStepMatchesHeaderDivision() {
        guard let drumRow = ByteChannel.allCases.firstIndex(of: .drum) else {
            return XCTFail("expected a drum channel")
        }
        var project = ByteProject(name: "TIMING", tempo: 120, patterns: [BytePattern.empty(name: "PATTERN 01")])
        project.patterns[0].steps[drumRow][0] = ByteDrumVoice.note(voice: .kick)
        project.patterns[0].steps[drumRow][4] = ByteDrumVoice.note(voice: .kick)
        project.patterns[0].noteLengths[drumRow][0] = 1
        project.patterns[0].noteLengths[drumRow][4] = 1

        let data = ByteMIDI.export(project: project)

        let division = Int(data.readBigEndianForTests(UInt16.self, at: 12))
        XCTAssertGreaterThan(division, 0, "division must be tick-based, not SMPTE")
        XCTAssertEqual(division % 4, 0, "the division must split evenly into sixteenth notes")
        let ticksPerStep = division / 4

        // Track 0 is the tempo track, then one track per channel in allCases order.
        let onsets = noteOnTicks(inTrackAt: trackOffset(drumRow + 1, in: data), of: data)
        XCTAssertEqual(onsets.count, 2, "both drum hits should export")
        XCTAssertEqual(onsets[0], 0, "the first hit lands on the downbeat")
        XCTAssertEqual(onsets[1], ticksPerStep * 4, "four steps must span four sixteenth notes")

        // The importer reads the same file at the same step positions.
        let imported = ByteMIDI.importIntoProject(data, project: project)
        XCTAssertNotNil(imported?.patterns[0].steps[drumRow][0])
        XCTAssertNotNil(imported?.patterns[0].steps[drumRow][4])
    }

    /// Byte offset of the nth `MTrk` chunk in an exported file; 0 is the tempo track.
    private func trackOffset(_ index: Int, in data: Data) -> Int {
        var offset = 14  // "MThd" + length + 6 bytes of header
        for _ in 0..<index {
            offset += 8 + Int(data.readBigEndianForTests(UInt32.self, at: offset + 4))
        }
        return offset
    }

    /// Absolute ticks of every note-on in one track.
    private func noteOnTicks(inTrackAt offset: Int, of data: Data) -> [Int] {
        let end = min(data.count, offset + 8 + Int(data.readBigEndianForTests(UInt32.self, at: offset + 4)))
        var position = offset + 8
        var tick = 0
        var runningStatus: UInt8 = 0
        var onsets: [Int] = []

        while position < end {
            var delta = 0
            while position < end {
                let byte = data[position]
                position += 1
                delta = (delta << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            tick += delta
            guard position < end else { break }

            var status = data[position]
            if status < 0x80 { status = runningStatus } else { position += 1 }
            if status == 0xFF {
                position += 1                                  // meta event type
                var metaLength = 0
                while position < end {
                    let byte = data[position]
                    position += 1
                    metaLength = (metaLength << 7) | Int(byte & 0x7F)
                    if byte & 0x80 == 0 { break }
                }
                position = min(end, position + metaLength)
                continue
            }
            runningStatus = status

            let kind = status & 0xF0
            switch kind {
            case 0x80, 0x90:
                guard position + 1 < end else { return onsets }
                let velocity = data[position + 1]
                position += 2
                if kind == 0x90, velocity > 0 { onsets.append(tick) }
            case 0xC0, 0xD0:
                position += 1
            default:
                position += 2
            }
        }
        return onsets
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

    func testDrumVoiceNamesMatchTheirSamplesAndGestureDirections() {
        XCTAssertEqual(ByteDrumVoice.label(for: 42), "HI-HAT")
        XCTAssertEqual(ByteDrumVoice.label(for: 49), "PERC")
        XCTAssertEqual(ByteDrumVoice.hiHat.title, "HI-HAT")
        XCTAssertEqual(ByteDrumVoice.perc.title, "PERC")
        XCTAssertEqual(ByteDrumVoice.hiHat.resourceNames, ["hihat1", "hihat2"])
        XCTAssertEqual(ByteDrumVoice.perc.resourceNames, ["perc2", "perc1"])
        // A swipe has to point at the voice it is named after.
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: -1, vertical: 0).title, "HI-HAT")
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 1, vertical: 0).title, "PERC")
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 0, vertical: -1).title, "SNARE")
        XCTAssertEqual(ByteDrumVoice.voice(horizontal: 0, vertical: 1).title, "KICK")
    }

    /// A drum pad is painted the colour of the voice it holds. Renaming a voice is how the
    /// pads once ended up labelled HI-HAT and drawn in the perc colour, so each voice is pinned
    /// here to the palette entry that shares its name rather than to whatever table the view
    /// happens to build.
    func testDrumPadColorsFollowTheVoiceNames() {
        let expected: [ByteDrumVoice: Color] = [
            .kick: .drumKick,
            .snare: .drumSnare,
            .hiHat: .drumHiHat,
            .perc: .drumPerc,
        ]
        for voice in ByteDrumVoice.allCases {
            guard let named = expected[voice] else {
                return XCTFail("\(voice.title) has no palette colour sharing its name")
            }
            XCTAssertEqual(
                resampled(voice.padColor),
                resampled(named),
                "\(voice.title) pads must use the palette colour named after them"
            )
        }
        XCTAssertEqual(
            Set(ByteDrumVoice.allCases.map { resampled($0.padColor) }).count,
            ByteDrumVoice.allCases.count,
            "two voices sharing a colour would make the pads unreadable"
        )
    }

    /// A colour as four quantized sRGB channels. Comparing the channels rather than the
    /// `Color` values keeps the failure legible and survives SwiftUI resolving an equivalent
    /// colour through a different internal representation.
    private func resampled(_ color: Color) -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { Int(($0 * 1000).rounded()) }
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
        // Slot cycling clamps at the ends of the current bank ([P1, P2]):
        // one step back from P2 lands on P1.
        store.cycleSongSlot(at: 1, delta: -1)
        XCTAssertEqual(store.songSlot(at: 1).patternID, store.project.patterns[0].id)
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
        // Blank first launch: exactly one empty pattern in the bank.
        XCTAssertEqual(store.project.patterns.count, 1)
        let firstID = store.project.patterns[0].id
        store.addPattern()
        let deletedID = store.currentPatternID
        XCTAssertTrue(store.assignSongPattern(at: 3, patternID: deletedID))
        XCTAssertTrue(store.deletePattern(deletedID))
        XCTAssertFalse(store.project.patterns.contains(where: { $0.id == deletedID }))
        XCTAssertFalse(store.project.arrangement.contains(deletedID))
        XCTAssertNil(store.songSlot(at: 3).patternID)
        XCTAssertTrue(store.project.patterns.contains(where: { $0.id == store.currentPatternID }))
        // Deleting the added pattern leaves the single original — the final
        // remaining pattern is protected from deletion.
        XCTAssertEqual(store.project.patterns.count, 1)
        XCTAssertFalse(store.deletePattern(firstID))
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

        // Blank first launch: PATTERN 01 already exists, so addPattern yields PATTERN 02.
        XCTAssertEqual(store.project.patterns.count, 2)
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

        // Blank first launch: PATTERN 01 exists, so the duplicate lands at index 1.
        XCTAssertEqual(store.project.patterns.count, 2)
        XCTAssertNotEqual(store.currentPatternID, sourceID)
        XCTAssertEqual(store.project.patterns[1].steps, source.steps)
        XCTAssertEqual(store.project.patterns[1].noteLengths, source.noteLengths)
        XCTAssertEqual(store.project.patterns[1].steps.count, 4)
        XCTAssertEqual(store.project.patterns[1].steps.allSatisfy { $0.count == 16 }, true)

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

    /// One unreadable project used to fail the whole library decode, and the next save then
    /// overwrote every project with a blank one. The readable projects must survive it.
    func testUnreadableProjectIsSkippedWithoutLosingTheRest() throws {
        let suite = "BeatboiLenientLoadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        var payload = try JSONEncoder.bytePocketEncoder.encode([keeper])
        payload.removeLast()  // drop the closing bracket so another entry can be appended
        payload.append(contentsOf: Data(#",{"id":"not-a-uuid","name":42}"#.utf8))
        payload.append(contentsOf: Data("]".utf8))
        defaults.set(payload, forKey: "bytePocket.projects")

        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.projects.count, 1, "the readable project must survive")
        XCTAssertEqual(store.projects[0].name, "KEEPER")
        XCTAssertEqual(store.libraryRecovery?.droppedProjects, 1)
        XCTAssertEqual(store.libraryRecovery?.usedBackup, false)
        // The payload holding the unreadable entry is preserved, not thrown away.
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.unreadable"))
    }

    /// The primary payload is mirrored into a rolling backup once it reads back cleanly, and an
    /// unreadable primary falls back to it instead of starting the user over from silence.
    func testUnreadableLibraryFallsBackToTheRollingBackup() {
        let suite = "BeatboiRollingBackupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        XCTAssertEqual(first.projects[0].name, "KEEPER")

        // A second launch mirrors the payload it just read into the backup.
        _ = GameStore(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.backup"))

        // Now the primary is unusable, the way a torn write would leave it.
        let corrupt = Data("{ not json".utf8)
        defaults.set(corrupt, forKey: "bytePocket.projects")
        let recovered = GameStore(defaults: defaults)

        XCTAssertEqual(recovered.projects.count, 1)
        XCTAssertEqual(recovered.projects[0].name, "KEEPER")
        XCTAssertEqual(recovered.libraryRecovery?.usedBackup, true)
        // The corrupt bytes are still preserved...
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), corrupt)
        // ...and the primary has already been healed from the backup.
        XCTAssertNotEqual(defaults.data(forKey: "bytePocket.projects"), corrupt)
    }

    /// Recovering from the backup must leave the primary readable again. Otherwise the next
    /// launch repeats the recovery, and the user is told their library was restored every single
    /// time they open the app — a scare that never resolves.
    func testRecoveryHealsThePrimarySoLaterLaunchesLoadCleanly() {
        let suite = "BeatboiPrimaryHealingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        _ = GameStore(defaults: defaults)   // mirror a clean read into the backup
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.backup"))

        let corrupt = Data("\u{0}\u{1}torn write".utf8)
        defaults.set(corrupt, forKey: "bytePocket.projects")
        let recovered = GameStore(defaults: defaults)
        XCTAssertEqual(recovered.libraryRecovery?.usedBackup, true, "precondition: this launch must actually recover")

        // The next launch must be a normal one, not a second recovery.
        let secondLaunch = GameStore(defaults: defaults)
        XCTAssertEqual(secondLaunch.projects.map(\.name), ["KEEPER"])
        XCTAssertNil(secondLaunch.libraryRecovery, "a healed primary must load without reporting recovery")

        // Prove the healing lives in the primary itself, not in the backup we keep reading from:
        // remove the backup and the library must still load cleanly.
        defaults.removeObject(forKey: "bytePocket.projects.backup")
        let withoutBackup = GameStore(defaults: defaults)
        XCTAssertEqual(withoutBackup.projects.map(\.name), ["KEEPER"])
        XCTAssertNil(withoutBackup.libraryRecovery, "the primary itself must now be readable")
        // Healing is a relocation: the torn bytes stay quarantined rather than vanishing.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), corrupt)
    }

    /// Healing applies only to a library rebuilt from the backup. A payload that was partly
    /// readable is left byte-for-byte intact, because its unreadable entries are the very bytes a
    /// future build might be able to recover.
    func testPartlyReadablePrimaryIsNotRewrittenToLookClean() throws {
        let suite = "BeatboiNoRewriteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let good = try JSONSerialization.jsonObject(with: try JSONEncoder.bytePocketEncoder.encode(keeper)) as? [String: Any]
        let payload = try JSONSerialization.data(withJSONObject: [good as Any, ["id": "nope"]])
        defaults.set(payload, forKey: "bytePocket.projects")

        let store = GameStore(defaults: defaults)
        XCTAssertEqual(store.libraryRecovery?.droppedProjects, 1)
        XCTAssertEqual(store.libraryRecovery?.usedBackup, false, "a partly readable primary must not be treated as a backup recovery")
        // The unreadable entry is still in the stored payload, untouched.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects"), payload)
        // And it was quarantined, so the bytes survive either way.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), payload)
    }

    /// A project deleted in an earlier session is still in the rolling backup, which is rotated at
    /// launch — so the backup is snapshotted before the rotation and offered back in the cart.
    /// Otherwise preserved work would only ever be reachable by reading the raw defaults plist.
    func testProjectDeletedInAnEarlierSessionIsOfferedBackFromTheBackup() {
        let suite = "BeatboiPreservedBackupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        first.newProject()                       // cart: [NEW QUEST 02, KEEPER]
        XCTAssertEqual(first.projects.count, 2)

        // The next launch mirrors the two-project library into the rolling backup.
        let second = GameStore(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.backup"))

        // Then the user deletes one project; the backup still holds a copy of it.
        second.deleteProject(second.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertEqual(second.projects.map(\.name), ["KEEPER"])
        // This exercises the backup as the only way back, which is what an install that deleted
        // the project before the deleted-project payload existed looks like. With that payload
        // present the same project is offered through the delete path instead.
        defaults.removeObject(forKey: "bytePocket.projects.deleted")

        let third = GameStore(defaults: defaults)
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER"], "the live cart must not change")
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["NEW QUEST 02"])
        XCTAssertEqual(third.recoveryCandidates.map(\.source), [.backup])
        XCTAssertTrue(third.hasRecoverableProjects)

        let recovered = third.recoveryCandidates[0]
        XCTAssertTrue(third.restoreRecoveredProject(recovered))
        XCTAssertEqual(Set(third.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertEqual(third.project.name, "NEW QUEST 02", "a restored project becomes the selection")
        XCTAssertTrue(third.recoveryCandidates.isEmpty, "a restored project is no longer offered")
        XCTAssertFalse(third.restoreRecoveredProject(recovered), "restoring a project already in the cart is refused")

        // Restoring writes the cart, so the next launch is an ordinary one.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty)
    }

    /// Projects kept in the quarantine payload are offered back too, which is the difference
    /// between bytes being preserved and bytes being reachable.
    func testQuarantinedProjectsAreOfferedBackAndSurviveRestoring() throws {
        let suite = "BeatboiQuarantineRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let orphan = ByteProject(name: "ORPHAN", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let quarantined = try JSONEncoder.bytePocketEncoder.encode([orphan])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([keeper]), forKey: "bytePocket.projects")
        defaults.set(quarantined, forKey: "bytePocket.projects.unreadable")

        let store = GameStore(defaults: defaults)
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"])
        XCTAssertEqual(store.recoveryCandidates.map(\.project.name), ["ORPHAN"])
        XCTAssertEqual(store.recoveryCandidates.map(\.source), [.quarantine])

        XCTAssertTrue(store.restoreRecoveredProject(store.recoveryCandidates[0]))
        XCTAssertEqual(Set(store.projects.map(\.name)), ["KEEPER", "ORPHAN"])
        // Restoring is additive: the preserved bytes stay put rather than being consumed.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), quarantined)

        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["KEEPER", "ORPHAN"])
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty)
    }

    /// Preserved bytes that cannot be decoded are reported rather than silently dropped, and they
    /// are not offered as restorable projects the app could not actually produce.
    func testPreservedBytesThatCannotBeDecodedAreReportedNotOffered() throws {
        let suite = "BeatboiPreservedUnreadableTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let encoded = try JSONEncoder.bytePocketEncoder.encode([keeper])
        let keeperObject = try XCTUnwrap((JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])?.first)
        defaults.set(encoded, forKey: "bytePocket.projects")
        defaults.set(try JSONSerialization.data(withJSONObject: [keeperObject, ["id": "nope"]]), forKey: "bytePocket.projects.unreadable")

        let store = GameStore(defaults: defaults)
        XCTAssertTrue(store.recoveryCandidates.isEmpty, "the preserved KEEPER matches the cart exactly, so nothing is offered")
        XCTAssertEqual(store.preservedLibrary.unreadableEntries, 1)
        XCTAssertTrue(store.hasRecoverableProjects, "bytes that could not be read must still be surfaced")

        // A payload that cannot be read at all counts as a whole preserved copy, not as an entry.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(encoded, forKey: "bytePocket.projects")
        defaults.set(Data("not json at all".utf8), forKey: "bytePocket.projects.unreadable")
        let garbage = GameStore(defaults: defaults)
        XCTAssertEqual(garbage.preservedLibrary.unreadableCopies, 1)
        XCTAssertEqual(garbage.preservedLibrary.unreadableEntries, 0)
        XCTAssertTrue(garbage.hasRecoverableProjects)
    }

    /// The rolling backup also holds each project as it stood before the last session's edits. That
    /// copy is offered back as an earlier version, and restoring it must keep both: the older copy
    /// arrives as a project of its own instead of replacing the newer one in the cart.
    func testEarlierVersionOfAProjectInTheCartRestoresAsASeparateCopy() {
        let suite = "BeatboiEarlierVersionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        let originalTempo = first.project.tempo

        // The next launch mirrors the project as it stood into the rolling backup, and the edit
        // after that is what makes the preserved copy an older version.
        let second = GameStore(defaults: defaults)
        let keeperID = second.project.id
        let editedTempo = originalTempo + 30
        second.updateTempo(editedTempo)
        XCTAssertEqual(second.project.tempo, editedTempo, "precondition: the edit must not be clamped away")

        let third = GameStore(defaults: defaults)
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER"], "the live cart must not gain anything yet")
        XCTAssertEqual(third.recoveryCandidates.count, 1)
        let candidate = third.recoveryCandidates[0]
        XCTAssertEqual(candidate.kind, .earlierVersion)
        XCTAssertEqual(candidate.id, keeperID, "the copy is recognised by the id it shares with the cart")
        XCTAssertEqual(candidate.project.tempo, originalTempo, "the candidate holds the older content")
        XCTAssertTrue(third.missingRecoverableProjects.isEmpty, "nothing was lost, so the launch is not interrupted")

        XCTAssertTrue(third.restoreRecoveredProject(candidate))
        XCTAssertEqual(third.projects.count, 2, "restoring an earlier version keeps both copies")
        XCTAssertEqual(third.project.name, "KEEPER COPY")
        XCTAssertEqual(third.project.tempo, originalTempo, "the copy arrives with the content it was preserved with")
        XCTAssertNotEqual(third.project.id, keeperID, "the copy gets its own identity")
        XCTAssertEqual(
            third.projects.first { $0.id == keeperID }?.tempo, editedTempo,
            "the newer version already in the cart is untouched"
        )
        XCTAssertTrue(third.recoveryCandidates.isEmpty, "a copy is not offered twice")
        XCTAssertFalse(third.restoreRecoveredProject(candidate), "the same copy cannot be restored twice")

        // Both copies persist, and neither reads as a preserved duplicate of the other.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.projects.count, 2)
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty)
    }

    /// Two projects in the cart must never read the same, so a restored copy takes a name that is
    /// still free.
    func testRestoredCopyTakesANameThatIsStillFree() {
        let suite = "BeatboiCopyNameTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        first.newProject()
        first.renameProject("KEEPER COPY")     // the obvious name for the copy is already taken

        let second = GameStore(defaults: defaults)
        second.selectProject(second.projects.first { $0.name == "KEEPER" }!)
        second.updateTempo(200)

        let third = GameStore(defaults: defaults)
        // "KEEPER COPY" is untouched since the last launch, so only the edited KEEPER is offered.
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["KEEPER"])
        XCTAssertTrue(third.restoreRecoveredProject(third.recoveryCandidates[0]))

        XCTAssertEqual(Set(third.projects.map(\.name)), ["KEEPER", "KEEPER COPY", "KEEPER COPY 2"])
    }

    /// Restoring used to clear the undo history the way selecting a project does, so a restore made
    /// by accident could only be cleaned up by hand. It is now a step on the stack like any other.
    func testRestoringAPreservedProjectIsUndoable() throws {
        let suite = "BeatboiUndoRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")

        // The lost project is planted as a preserved payload rather than produced by deleting one,
        // so this stays a test of restoring a *preserved* project. A deleted project is offered by
        // the delete path instead, which its own tests cover.
        let lost = ByteProject(name: "LOST TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([lost]), forKey: "bytePocket.projects.unreadable")

        let third = GameStore(defaults: defaults)
        let originalTempo = third.project.tempo
        let editedTempo = originalTempo + 20
        third.updateTempo(editedTempo)
        XCTAssertTrue(third.canUndo, "precondition: the ordinary edit is undoable")

        let candidate = third.recoveryCandidates[0]
        XCTAssertEqual(candidate.project.name, "LOST TAKE", "precondition: the lost project is the row")
        XCTAssertTrue(third.restoreRecoveredProject(candidate))
        XCTAssertEqual(Set(third.projects.map(\.name)), ["KEEPER", "LOST TAKE"])
        XCTAssertEqual(third.project.name, "LOST TAKE", "a restored project becomes the selection")
        XCTAssertFalse(third.offersRecovery(candidate), "the restored project stops being a missing one")

        third.undo()
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER"], "undo must take the restored project back out")
        XCTAssertEqual(third.project.name, "KEEPER", "undo must put the selection back where it was")
        XCTAssertEqual(third.project.tempo, editedTempo, "undoing a restore must not undo the edit beneath it")
        XCTAssertTrue(third.offersRecovery(candidate), "the preserved row comes back")

        // The restore went on top of the existing stack rather than clearing it.
        third.undo()
        XCTAssertEqual(third.project.tempo, originalTempo, "the edit underneath is still undoable")
        third.redo()
        third.redo()
        XCTAssertEqual(Set(third.projects.map(\.name)), ["KEEPER", "LOST TAKE"], "redo must put the restore back")
        XCTAssertFalse(third.offersRecovery(candidate), "the restored row is consumed again")
    }

    /// NEW PROJECT adds a project, so it is a membership change like a restore and is taken back the
    /// same way: the project leaves the cart and the previous selection returns.
    func testCreatingANewProjectIsUndoable() {
        let suite = "BeatboiUndoNewProjectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        let keeperID = store.project.id

        store.newProject()
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.project.name, "NEW QUEST 02", "a new project becomes the selection")

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "undo must take the new project back out")
        XCTAssertEqual(store.project.id, keeperID, "undo must put the selection back where it was")
        // The new-project step sat on top of the rename rather than clearing it.
        XCTAssertTrue(store.canUndo, "the edit underneath is still undoable")

        store.redo()
        XCTAssertEqual(store.projects.count, 2, "redo must put the new project back")
        XCTAssertEqual(store.project.name, "NEW QUEST 02")
    }

    /// Importing adds a project when the file is new to the cart and replaces one when it is not.
    /// Both are membership changes, and undo has to reverse each in the matching way.
    func testImportingAProjectIsUndoable() {
        let suite = "BeatboiUndoImportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        let keeperID = store.project.id

        let incoming = ByteProject(name: "IMPORTED", patterns: [BytePattern.empty(name: "PATTERN 01")])
        store.importProject(incoming)
        XCTAssertEqual(store.projects.map(\.name), ["IMPORTED", "KEEPER"])
        XCTAssertEqual(store.project.name, "IMPORTED", "an imported project becomes the selection")

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "undo must take an imported project back out")
        XCTAssertEqual(store.project.id, keeperID, "undo must put the selection back")
        XCTAssertTrue(store.canUndo, "the rename underneath is still undoable")

        store.redo()
        XCTAssertEqual(store.projects.map(\.name), ["IMPORTED", "KEEPER"])

        // Reopening a file already in the cart replaces that project, so undo has to bring the
        // replaced content back — not merely drop a project, which would silently lose the edit.
        var reopened = incoming
        reopened.tempo = incoming.tempo + 40
        XCTAssertEqual(reopened.id, incoming.id, "precondition: the file keeps its own identity")
        store.importProject(reopened)
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.projects.first { $0.id == incoming.id }?.tempo, incoming.tempo + 40)

        store.undo()
        XCTAssertEqual(store.projects.count, 2, "a replace must not change the size of the cart")
        XCTAssertEqual(
            store.projects.first { $0.id == incoming.id }?.tempo, incoming.tempo,
            "undo must restore the content the import replaced"
        )
    }

    /// Undoing a copy has to free the preserved row again as well as remove the copy, which is
    /// exactly what the consumed bookkeeping would otherwise keep hidden.
    func testRestoringAnEarlierVersionCopyIsUndoable() {
        let suite = "BeatboiUndoCopyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        let originalTempo = first.project.tempo

        let second = GameStore(defaults: defaults)
        second.updateTempo(originalTempo + 30)

        let third = GameStore(defaults: defaults)
        XCTAssertEqual(third.recoveryCandidates.count, 1, "precondition: the earlier version is offered")

        XCTAssertTrue(third.restoreRecoveredProject(third.recoveryCandidates[0]))
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER COPY", "KEEPER"])
        XCTAssertTrue(third.recoveryCandidates.isEmpty, "a restored copy is consumed")

        third.undo()
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER"], "undo must remove the copy")
        XCTAssertEqual(third.projects[0].tempo, originalTempo + 30, "the project in the cart is untouched")
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["KEEPER"], "the earlier version is offered again")

        third.redo()
        XCTAssertEqual(third.projects.map(\.name), ["KEEPER COPY", "KEEPER"], "redo must put the copy back")
        XCTAssertTrue(third.recoveryCandidates.isEmpty)
    }

    /// Deleting a project used to wipe the undo history and lean on a single "restore last deleted"
    /// slot, which made it the one action in the cart with no reliable way back.
    func testDeletingAProjectIsUndoable() {
        let suite = "BeatboiUndoDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        XCTAssertEqual(store.projects.map(\.name), ["NEW QUEST 02", "KEEPER"])
        let doomedID = store.project.id

        store.deleteProject(store.project)
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "the deleted project leaves the cart")
        XCTAssertEqual(store.project.name, "KEEPER", "the remaining project becomes the selection")
        XCTAssertTrue(store.canRestoreDeletedProject)

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["NEW QUEST 02", "KEEPER"], "undo must put the project back")
        XCTAssertEqual(store.project.id, doomedID, "undo must put the selection back where it was")
        XCTAssertFalse(store.canRestoreDeletedProject, "nothing is pending a restore once the project is back")

        store.redo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "redo must delete it again")
        XCTAssertTrue(store.canRestoreDeletedProject, "redo must fill the slot again")
    }

    /// The rollback used to be one slot, so deleting twice in a row left the first project with no
    /// way back. Each deletion is now its own step, and they unwind in order.
    func testRepeatedDeletionsCanAllBeUndone() {
        let suite = "BeatboiUndoRepeatedDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("FIRST")
        store.newProject()
        store.renameProject("SECOND")
        store.newProject()
        store.renameProject("THIRD")
        XCTAssertEqual(store.projects.map(\.name), ["THIRD", "SECOND", "FIRST"])

        store.deleteProject(store.projects.first { $0.name == "SECOND" }!)
        store.deleteProject(store.projects.first { $0.name == "FIRST" }!)
        XCTAssertEqual(store.projects.map(\.name), ["THIRD"])

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["THIRD", "FIRST"], "the later deletion comes back first")
        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["THIRD", "SECOND", "FIRST"], "then the earlier one")
    }

    /// The single slot is why an undoable restore could not simply be bolted on: restoring cleared
    /// it, so taking the restore back would have left the project in neither the cart nor the slot —
    /// gone for good. The slot travels in the snapshot so undo puts both back.
    func testRestoringADeletedProjectIsUndoableWithoutLosingTheSlot() {
        let suite = "BeatboiUndoRestoreDeletedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.deleteProject(store.projects.first { $0.name == "NEW QUEST 02" }!)
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"])

        store.restoreDeletedProject()
        XCTAssertEqual(Set(store.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertFalse(store.canRestoreDeletedProject, "restoring consumes the slot")

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "undo must take the restored project back out")
        XCTAssertTrue(store.canRestoreDeletedProject, "the slot has to come back, or the project is gone for good")

        // The affordance still works after being taken back.
        store.restoreDeletedProject()
        XCTAssertEqual(Set(store.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
    }

    /// A deletion used to live only in memory, so quitting the app threw away the only copy of a
    /// project the user had removed. The stack is written to disk now, and this is the contract:
    /// the deletion is still offered after a relaunch, and restoring it puts it back.
    func testDeletedProjectSurvivesRelaunchAndCanBeRestored() {
        let suite = "BeatboiDeletedPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        XCTAssertEqual(store.projects.map(\.name), ["NEW QUEST 02", "KEEPER"])
        store.deleteProject(store.projects.first { $0.name == "NEW QUEST 02" }!)
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"])
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.deleted"), "the deletion must land on disk")

        // A fresh store against the same defaults stands in for the next launch of the app.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.projects.map(\.name), ["KEEPER"], "the live cart must not change")
        XCTAssertTrue(relaunch.canRestoreDeletedProject, "a persisted deletion is still offered")

        relaunch.restoreDeletedProject()
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertEqual(relaunch.project.name, "NEW QUEST 02", "a restored project becomes the selection")
        XCTAssertFalse(relaunch.canRestoreDeletedProject, "restoring empties the stack")
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "an empty stack clears the payload")

        // Restoring wrote the cart, so this launch is an ordinary one.
        let third = GameStore(defaults: defaults)
        XCTAssertEqual(Set(third.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertFalse(third.canRestoreDeletedProject)
    }

    /// The stack keeps every deletion, so a session that removes several projects can still bring
    /// them back after a relaunch, newest first.
    func testDeletedProjectsStackAcrossLaunches() {
        let suite = "BeatboiDeletedStackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("FIRST")
        store.newProject()
        store.renameProject("SECOND")
        store.newProject()
        store.renameProject("THIRD")
        XCTAssertEqual(store.projects.map(\.name), ["THIRD", "SECOND", "FIRST"])

        store.deleteProject(store.projects.first { $0.name == "SECOND" }!)
        store.deleteProject(store.projects.first { $0.name == "FIRST" }!)
        XCTAssertEqual(store.projects.map(\.name), ["THIRD"])

        let relaunch = GameStore(defaults: defaults)
        XCTAssertTrue(relaunch.canRestoreDeletedProject)
        XCTAssertEqual(relaunch.projects.map(\.name), ["THIRD"])

        relaunch.restoreDeletedProject()
        XCTAssertEqual(relaunch.projects.map(\.name), ["FIRST", "THIRD"], "the later deletion comes back first")
        XCTAssertTrue(relaunch.canRestoreDeletedProject, "the earlier deletion is still pending")

        relaunch.restoreDeletedProject()
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["FIRST", "SECOND", "THIRD"])
        XCTAssertFalse(relaunch.canRestoreDeletedProject)

        // Both restores wrote their progress, so a third launch still has nothing pending.
        let third = GameStore(defaults: defaults)
        XCTAssertFalse(third.canRestoreDeletedProject)
    }

    /// A deleted project is also still inside the rolling backup for one generation, so without
    /// suppression the cart would list it twice: once as "last launch" and once as deleted.
    func testDeletedProjectIsNotOfferedTwiceAfterRelaunch() {
        let suite = "BeatboiDeletedNoDuplicateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        _ = GameStore(defaults: defaults)   // mirror the two-project library into the backup
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.backup"), "precondition: the backup holds the deleted project")

        let relaunch = GameStore(defaults: defaults)
        XCTAssertTrue(relaunch.canRestoreDeletedProject, "the deleted project is offered")
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), ["NEW QUEST 02"])
        XCTAssertEqual(
            relaunch.recoveryCandidates.map(\.source), [.deleted],
            "one row, under the deleted label, not also as a preserved copy"
        )

        // The backup still covers work that was not deleted; only the deleted copy is suppressed.
        relaunch.restoreDeletedProject()
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
    }

    /// The cart has one recovery list now, and a deleted project is a row in it. It carries the
    /// DELETED label rather than being reached through a separate affordance.
    func testDeletedProjectsAppearInTheRecoveryListUnderTheirOwnLabel() throws {
        let suite = "BeatboiDeletedInRecoveryListTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)

        // Plant a preserved copy the cart has lost, so one launch holds both kinds of row.
        let orphan = ByteProject(name: "ORPHAN", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([orphan]), forKey: "bytePocket.projects.unreadable")

        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), ["NEW QUEST 02", "ORPHAN"], "deletions lead the list")
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.source), [.deleted, .quarantine])

        // A deletion is the user's own doing, so it does not interrupt the launch the way a lost
        // project does.
        XCTAssertEqual(relaunch.missingRecoverableProjects.map(\.project.name), ["ORPHAN"])

        // Restoring the deleted row consumes its stack entry, so the row goes and the preserved
        // copy is left alone.
        let deletedRow = relaunch.recoveryCandidates.first { $0.source == .deleted }!
        XCTAssertTrue(relaunch.restoreRecoveredProject(deletedRow))
        XCTAssertEqual(Set(relaunch.projects.map(\.name)), ["KEEPER", "NEW QUEST 02"])
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), ["ORPHAN"])

        relaunch.undo()
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), ["NEW QUEST 02", "ORPHAN"], "undo puts the row back")
    }

    /// A project can be in both the rolling backup and the delete stack at once — deleting it this
    /// session does not remove it from the payload the launch already read. The list must still
    /// show it once, under the stronger label.
    func testDeletedProjectSupersedesAPreservedCopyOfTheSameProject() {
        let suite = "BeatboiDeletedSupersedesPreservedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        first.newProject()
        _ = GameStore(defaults: defaults)          // rotates the library into the backup
        let third = GameStore(defaults: defaults)  // reads that backup, so it is preserved here
        XCTAssertTrue(third.recoveryCandidates.isEmpty, "precondition: the preserved backup mirrors the cart")

        third.deleteProject(third.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["NEW QUEST 02"])
        XCTAssertEqual(third.recoveryCandidates.map(\.source), [.deleted], "one row, under the deleted label")

        // The deleted row is what puts the section on screen, and it is what the one discard
        // control clears, so the cart is not offering a control over work it would not touch.
        XCTAssertTrue(third.hasRecoverableProjects)
    }

    /// Undo has to move the persisted payload as well as the in-memory stack, or a relaunch would
    /// resurrect a deletion the user just took back.
    func testUndoingADeleteClearsThePersistedDeletion() {
        let suite = "BeatboiDeletedUndoPersistTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.deleted"))

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["NEW QUEST 02", "KEEPER"])
        XCTAssertFalse(store.canRestoreDeletedProject)
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "undo must take the entry off disk too")
        let afterUndo = GameStore(defaults: defaults)
        XCTAssertFalse(afterUndo.canRestoreDeletedProject, "a taken-back deletion must not come back on relaunch")

        // Redo puts it back on disk, so the two directions stay symmetric.
        store.redo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"])
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.deleted"))
        XCTAssertTrue(GameStore(defaults: defaults).canRestoreDeletedProject)
    }

    /// A deleted payload that cannot be decoded must not stop the cart from loading, and its bytes
    /// are kept rather than abandoned.
    func testUnreadableDeletedPayloadIsIgnoredAndItsBytesPreserved() throws {
        let suite = "BeatboiDeletedCorruptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([keeper]), forKey: "bytePocket.projects")
        let garbage = Data("not a deleted payload".utf8)
        defaults.set(garbage, forKey: "bytePocket.projects.deleted")

        let store = GameStore(defaults: defaults)
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "a bad deleted payload must not affect the cart")
        XCTAssertFalse(store.canRestoreDeletedProject)
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), garbage, "the bytes are kept")
    }

    /// A normal launch must offer nothing. The rolling backup mirrors the live cart, and the
    /// recovery surface would be permanent noise if it mistook that mirror for recoverable work.
    func testCleanLaunchOffersNothingToRecover() {
        let suite = "BeatboiNoRecoveryNoiseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")

        let second = GameStore(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.backup"), "precondition: a backup exists")
        XCTAssertTrue(second.recoveryCandidates.isEmpty)
        XCTAssertFalse(second.hasRecoverableProjects)
        XCTAssertNil(second.libraryRecovery)

        // The third launch is the case that actually compares: the backup is now a mirror of the
        // cart, and a mirror must not be offered as an earlier version of every project.
        let third = GameStore(defaults: defaults)
        XCTAssertTrue(third.recoveryCandidates.isEmpty, "a backup that mirrors the cart is not earlier work")
        XCTAssertFalse(third.hasRecoverableProjects)
    }

    /// Discarding the recoverable copies is durable — they must not come back on the next launch —
    /// and it must not take the rolling safety net down with them.
    func testDiscardingRecoverableProjectsIsDurableAndKeepsTheRollingBackup() throws {
        let suite = "BeatboiDiscardPreservedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        // A preserved copy the cart has lost, which is a row the one discard control clears.
        let orphan = ByteProject(name: "ORPHAN", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([orphan]), forKey: "bytePocket.projects.unreadable")
        let third = GameStore(defaults: defaults)
        XCTAssertFalse(third.recoveryCandidates.isEmpty, "precondition: there is something to discard")
        XCTAssertTrue(third.hasRecoverableProjects, "there is something to discard")

        third.discardRecoverableProjects()
        XCTAssertTrue(third.recoveryCandidates.isEmpty)
        XCTAssertFalse(third.hasRecoverableProjects, "nothing recoverable is left")
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.unreadable"))
        // The safety net now mirrors the live cart instead of being left empty.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.backup"), defaults.data(forKey: "bytePocket.projects"))

        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.projects.map(\.name), ["KEEPER"])
        XCTAssertFalse(relaunch.hasRecoverableProjects, "a discarded copy must not come back on the next launch")

        // Discarding the old copies did not discard the protection for the current cart.
        defaults.set(Data("{ not json".utf8), forKey: "bytePocket.projects")
        let afterCorruption = GameStore(defaults: defaults)
        XCTAssertEqual(afterCorruption.projects.map(\.name), ["KEEPER"])
        XCTAssertEqual(afterCorruption.libraryRecovery?.usedBackup, true)
    }

    /// The cart has one recovery list, so the one discard control clears all of it: a deletion is
    /// dropped along with the preserved payloads rather than outliving the control that sits over
    /// it. This is the destructive side of the unification, so it is pinned in both the live store
    /// and on the next launch.
    func testDiscardingRecoverableProjectsAlsoClearsDeletedProjects() {
        let suite = "BeatboiDiscardClearsDeletedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertEqual(store.recoveryCandidates.map(\.source), [.deleted], "precondition: the deletion is offered")

        store.discardRecoverableProjects()
        XCTAssertFalse(store.canRestoreDeletedProject, "discarding clears the delete stack too")
        XCTAssertTrue(store.recoveryCandidates.isEmpty)
        XCTAssertFalse(store.hasRecoverableProjects)
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "the deleted payload goes with it")
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "the live cart is untouched")

        // A discarded deletion must not come back as a row on the next launch.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertFalse(relaunch.canRestoreDeletedProject)
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty)
        XCTAssertEqual(relaunch.projects.map(\.name), ["KEEPER"])
    }

    /// Discarding clears the delete stack, but the undo history holds snapshots taken *before* the
    /// purge, and those still carry the deleted project. Without dropping the history a leftover
    /// step can put back exactly what the user confirmed discarding, so the purge also clears it.
    func testUndoAfterDiscardingCannotResurrectADeletedProject() {
        let suite = "BeatboiDiscardUndoTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertTrue(store.canRestoreDeletedProject, "precondition: the deletion is still recoverable")

        store.discardRecoverableProjects()
        XCTAssertFalse(store.canRestoreDeletedProject)

        store.undo()
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"], "undo must not put back what was discarded")
        XCTAssertFalse(store.canRestoreDeletedProject, "the deleted row must not come back either")
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "and nothing may land back on disk")
        XCTAssertFalse(GameStore(defaults: defaults).canRestoreDeletedProject)
    }

    /// A single row can be cleared without erasing the payload it came from, and it stays cleared
    /// on the next launch instead of coming back with the bytes.
    func testDismissingOnePreservedRowLeavesTheOthersAndSurvivesRelaunch() throws {
        let suite = "BeatboiDismissRowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        let alpha = ByteProject(name: "ALPHA", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let beta = ByteProject(name: "BETA", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let payload = try JSONEncoder.bytePocketEncoder.encode([alpha, beta])
        defaults.set(payload, forKey: "bytePocket.projects.unreadable")

        let second = GameStore(defaults: defaults)
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["ALPHA", "BETA"], "precondition")

        let alphaRow = second.recoveryCandidates.first { $0.project.name == "ALPHA" }!
        XCTAssertTrue(second.dismissRecoverableProject(alphaRow))
        XCTAssertFalse(second.dismissRecoverableProject(alphaRow), "the same row cannot be dismissed twice")
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["BETA"], "only the dismissed row goes")
        XCTAssertTrue(second.hasRecoverableProjects, "the section stays while a row is left")
        // Removing a row is not erasing it: the payload the row came from is never rewritten.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), payload)
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.dismissed"), "the dismissal is on disk")

        let third = GameStore(defaults: defaults)
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["BETA"], "a dismissed row stays gone")

        // Clearing the last row takes the section with it.
        XCTAssertTrue(third.dismissRecoverableProject(third.recoveryCandidates[0]))
        XCTAssertTrue(third.recoveryCandidates.isEmpty)
        XCTAssertFalse(third.hasRecoverableProjects, "the section goes when the last row does")
        // Clearing rows is not the bulk discard: the bytes are still there, just not offered.
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), payload)
    }

    /// Clearing a deleted row has to remember the id, not just drop the stack entry: the project is
    /// still inside the rolling backup for a generation, so without the id the row would reappear on
    /// the next launch wearing a "last launch" label.
    func testDismissingADeletedRowDoesNotReappearAsAPreservedCopy() {
        let suite = "BeatboiDismissDeletedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        first.newProject()
        _ = GameStore(defaults: defaults)          // rotates the library into the backup
        let third = GameStore(defaults: defaults)  // reads that backup, so the project is preserved here
        third.deleteProject(third.projects.first { $0.name.hasPrefix("NEW QUEST") }!)
        XCTAssertEqual(third.recoveryCandidates.map(\.source), [.deleted], "precondition")

        XCTAssertTrue(third.dismissRecoverableProject(third.recoveryCandidates[0]))
        XCTAssertTrue(third.recoveryCandidates.isEmpty)
        XCTAssertFalse(third.hasRecoverableProjects)
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "the stack entry is gone")

        let relaunch = GameStore(defaults: defaults)
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty, "the backup must not offer it back")
        XCTAssertFalse(relaunch.canRestoreDeletedProject)
    }

    /// Clearing a deletion is only durable because the id is written to disk, which is the record
    /// that stops the rolling backup offering the project again under a different label. This pins
    /// that record directly and by content, so the chain does not rest on the UI fixture, which now
    /// plants its own dismissal rather than earning one by clearing a row.
    func testClearingDeletionsRecordsEachDismissedIDOnDisk() throws {
        let suite = "BeatboiDismissRecordsIDTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("KEEPER")
        store.newProject()
        store.renameProject("NEW QUEST 02")
        store.newProject()
        store.renameProject("NEW QUEST 03")
        XCTAssertEqual(store.projects.map(\.name), ["NEW QUEST 03", "NEW QUEST 02", "KEEPER"])

        // Rotate the three-project library into the rolling backup, then delete two of them, so the
        // backup holds both projects the clearing below is meant to keep from coming back.
        _ = GameStore(defaults: defaults)
        let third = GameStore(defaults: defaults)
        third.deleteProject(third.projects.first { $0.name == "NEW QUEST 02" }!)
        third.deleteProject(third.projects.first { $0.name == "NEW QUEST 03" }!)
        XCTAssertEqual(third.recoveryCandidates.map(\.project.name), ["NEW QUEST 03", "NEW QUEST 02"], "newest first")

        let firstCleared = third.recoveryCandidates[0]
        XCTAssertTrue(third.dismissRecoverableProject(firstCleared))
        let secondCleared = third.recoveryCandidates[0]
        XCTAssertNotEqual(secondCleared.id, firstCleared.id, "clearing one row leaves the other")
        XCTAssertTrue(third.dismissRecoverableProject(secondCleared))

        let recorded = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects.dismissed"))
        XCTAssertEqual(
            try JSONDecoder.bytePocketDecoder.decode([UUID].self, from: recorded),
            [secondCleared.id, firstCleared.id],
            "each cleared deletion is recorded, most recently cleared first"
        )
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.deleted"), "the stack entry goes with it")

        // The record is what the next launch reads, and the backup holds both projects.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertTrue(relaunch.recoveryCandidates.isEmpty, "neither cleared project may come back from the backup")
        XCTAssertEqual(relaunch.projects.map(\.name), ["KEEPER"], "the cart is untouched")
    }

    /// Pins both recovery bounds and says what each one costs to exceed, because they fail in
    /// opposite directions: ageing out a deletion destroys the only remaining copy of that project,
    /// while ageing out a dismissal loses nothing and merely offers the row again. Every other
    /// fixture is built from these constants, so without this a change to either would quietly
    /// retune the tests that exist to pin it.
    func testRecoveryBoundsArePinned() {
        XCTAssertEqual(GameStore.deletedProjectsLimit, 20, "how many deletions can still be taken back")
        XCTAssertEqual(GameStore.dismissedRecoverableLimit, 50, "how many cleared rows stay cleared")
    }

    /// The remembered ids are bounded, so a cart that keeps clearing rows eventually forgets the
    /// oldest dismissal and the project it was hiding is offered again. That is the deliberate cost
    /// of not letting the payload grow without limit, so it is pinned rather than left implicit —
    /// including the part where the forgotten project comes back, which is easy to read as a bug.
    func testDismissedIDRecordIsBoundedAndForgetsTheOldestClear() throws {
        let suite = "BeatboiDismissCapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldest = ByteProject(name: "OLD TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let newest = ByteProject(name: "NEW TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([keeper]), forKey: "bytePocket.projects")
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([oldest, newest]), forKey: "bytePocket.projects.unreadable")

        // A full record with the project we want aged out at the oldest end: the list is written
        // most-recently-cleared first, so the last entry is the one the bound drops. The fixture is
        // built from the bound itself rather than a copied number, so this test keeps testing
        // whatever the bound is; `testRecoveryBoundsArePinned` is what makes changing it deliberate.
        let bound = GameStore.dismissedRecoverableLimit
        let fillers = (0..<(bound - 1)).map { _ in UUID() }
        defaults.set(
            try JSONEncoder.bytePocketEncoder.encode(fillers + [oldest.id]),
            forKey: "bytePocket.projects.dismissed"
        )

        let store = GameStore(defaults: defaults)
        XCTAssertEqual(store.recoveryCandidates.map(\.project.name), ["NEW TAKE"], "the planted dismissal hides the oldest")

        XCTAssertTrue(store.dismissRecoverableProject(store.recoveryCandidates[0]))

        let recorded = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects.dismissed"))
        let ids = try JSONDecoder.bytePocketDecoder.decode([UUID].self, from: recorded)
        XCTAssertEqual(ids.count, bound, "the record stays at its bound")
        XCTAssertEqual(ids.first, newest.id, "the newest clear leads")
        XCTAssertEqual(ids.filter { $0 == newest.id }.count, 1, "and is recorded once")
        XCTAssertFalse(ids.contains(oldest.id), "the oldest clear ages out")

        // The aged-out project is offered again — the cost of the bound, stated rather than hidden.
        XCTAssertEqual(store.recoveryCandidates.map(\.project.name), ["OLD TAKE"])

        // And the record is what the next launch reads, so the same swap persists.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), ["OLD TAKE"])
    }

    /// A minimal view of a stored payload, so this test can assert what is actually on disk without
    /// reaching into the store's private envelope type.
    private struct StoredPayload: Decodable {
        struct Entry: Decodable {
            let name: String
        }

        let projects: [Entry]
    }

    /// The envelope a stored library is meant to be, written as a plain `Encodable` so a test can
    /// reproduce it without reaching into the store's private type.
    private struct ReferenceEnvelope: Encodable {
        let schemaVersion: Int
        let projects: [ByteProject]
    }

    /// Re-serializes JSON with its members in sorted order, so two encodings can be compared for
    /// the value they carry rather than for the order they happen to write it in.
    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The library as storage can actually represent it. Dates are stored with second precision, so
    /// a live project and its reloaded self are equal only after both have been through the
    /// encoder — comparing a live project to a decoded one directly would fail on sub-second
    /// `modifiedAt`, which is a property of the date format rather than of what was written.
    private func storedForm(_ projects: [ByteProject]) throws -> [ByteProject] {
        let data = try JSONEncoder.bytePocketStorageEncoder.encode(projects)
        return try JSONDecoder.bytePocketDecoder.decode([ByteProject].self, from: data)
    }

    /// The stored library is assembled by splicing each project's own cached JSON into a
    /// hand-written container, so an edit does not re-encode every project the user owns. This
    /// pins that container to the envelope it replaced: same members, projects written inline, and
    /// the same value on the way out.
    func testSplicedLibraryPayloadEncodesTheSameValueAsTheEnvelope() throws {
        let suite = "BeatboiSpliceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("FIRST")
        store.newProject()
        store.renameProject("SECOND")
        // Edit *after* the projects have been saved once, so the save under test has to re-encode
        // one project while reusing the other straight from the cache — which is the splice.
        store.setPatchValue(channel: .pulseA, parameter: .tone, value: 2)
        store.setNote(channel: .pulseA, step: 0, note: 64)

        XCTAssertEqual(store.projects.map(\.name), ["SECOND", "FIRST"], "the newest project leads the cart")

        let stored = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "projects"], "the container keeps the envelope's members")
        XCTAssertEqual((object["projects"] as? [Any])?.count, store.projects.count)

        // The projects are written inline, not wrapped in the per-entry container that makes a
        // single unreadable entry survivable — reading is lenient, writing is not.
        let entries = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["name"] as? String, "SECOND")
        XCTAssertNil(entries.first?["project"], "a project must not gain a wrapper just because it was spliced")

        // And it carries exactly the value the reference envelope would, member order aside, which
        // is what makes this a re-encoding of the same format rather than a second one.
        let version = try XCTUnwrap(object["schemaVersion"] as? Int)
        let reference = try JSONEncoder.bytePocketStorageEncoder.encode(
            ReferenceEnvelope(schemaVersion: version, projects: store.projects)
        )
        XCTAssertEqual(try canonicalJSON(stored), try canonicalJSON(reference))

        // A relaunch reads it back as the live library, so the splice is loadable, not merely equal.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.projects, try storedForm(store.projects))
        XCTAssertEqual(relaunch.projects.map(\.name), ["SECOND", "FIRST"])
    }

    /// The cache exists to skip work, so the risk it carries is skipping work it should have done.
    /// A project that changed since it was cached must be re-encoded, not served from the copy on
    /// file, or an edit would be silently lost the next time the library is written.
    func testAnEditAfterACachedSaveStillReachesTheStoredPayload() throws {
        let suite = "BeatboiStaleCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        store.renameProject("BEFORE")
        // Saving the name above warmed the cache with that name's encoding; this edit has to
        // invalidate it.
        store.renameProject("AFTER")
        store.setNote(channel: .pulseA, step: 3, note: 67)

        let stored = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects"))
        let payload = try JSONDecoder.bytePocketDecoder.decode(StoredPayload.self, from: stored)
        XCTAssertEqual(payload.projects.map(\.name), ["AFTER"], "an edit must not be served from the cache")

        // The whole project round-trips, not just the field that was edited. If the cache had
        // served the pre-rename bytes, the name would read "BEFORE" here while the note survived —
        // which is exactly the shape of the failure this guards against.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.projects, try storedForm(store.projects))
        XCTAssertEqual(relaunch.projects.map(\.name), ["AFTER"])
        XCTAssertEqual(
            relaunch.projects.first?.patterns.first?.steps.first?[3],
            67,
            "the edit made after the first save must be on disk"
        )
    }

    /// The delete stack has a bound of its own, and passing it is the one cap in the recovery layer
    /// that destroys something: each entry is a whole project and the stack is the only copy once the
    /// rolling backup has rotated past. So the oldest deletion ages out — its bytes leave the payload
    /// rather than merely stopping being offered — while the newer ones stay restorable.
    func testDeletingPastTheBoundAgesOutTheOldestRecoveryCopy() throws {
        let suite = "BeatboiDeletedBoundTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let bound = GameStore.deletedProjectsLimit
        let store = GameStore(defaults: defaults)
        store.renameProject("KEEP")

        // One more project than the bound, so the final deletion is the one that pushes a copy out.
        var deletedNames: [String] = []
        for index in 1...(bound + 1) {
            store.newProject()
            let name = "TAKE \(index)"
            store.renameProject(name)
            deletedNames.append(name)
        }
        XCTAssertEqual(store.projects.count, bound + 2, "precondition: enough projects to delete past the bound")

        // Oldest deleted first, so the copy that ages out is the first one removed.
        for name in deletedNames {
            store.deleteProject(store.projects.first { $0.name == name }!)
        }

        let survivingNames = stride(from: bound + 1, through: 2, by: -1).map { "TAKE \($0)" }
        XCTAssertEqual(store.recoveryCandidates.map(\.project.name), survivingNames, "the newer deletions survive, newest first")
        XCTAssertEqual(store.recoveryCandidates.count, bound, "the stack stops at its bound")
        XCTAssertEqual(store.recoveryCandidates.map(\.source), Array(repeating: .deleted, count: bound))
        XCTAssertFalse(
            store.recoveryCandidates.contains { $0.project.name == deletedNames[0] },
            "the oldest deletion ages out"
        )
        XCTAssertEqual(store.projects.map(\.name), ["KEEP"], "only the kept project is left in the cart")

        // Aged out means gone from the payload, not merely hidden: this is the one cap that eats bytes.
        let payload = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects.deleted"))
        let stored = try JSONDecoder.bytePocketDecoder.decode(StoredPayload.self, from: payload)
        XCTAssertEqual(stored.projects.count, bound)
        XCTAssertFalse(stored.projects.contains { $0.name == deletedNames[0] }, "its bytes went with it")

        // A relaunch agrees — no backup was rotated to hold the aged-out copy, so nothing offers it.
        let relaunch = GameStore(defaults: defaults)
        XCTAssertEqual(relaunch.recoveryCandidates.map(\.project.name), survivingNames)
        XCTAssertFalse(relaunch.recoveryCandidates.contains { $0.project.name == deletedNames[0] })

        // And the trimmed stack is still usable: the newest surviving deletion comes back.
        relaunch.restoreDeletedProject()
        XCTAssertEqual(relaunch.projects.map(\.name), ["TAKE \(bound + 1)", "KEEP"])
    }

#if DEBUG
    /// The diagnostics dump is what a written-up report gets read from, so its facts are pinned here
    /// rather than left to whoever reads it next. It is built only in debug builds, which is what the
    /// test targets build, so this is gated the same way it is.
    func testRecoveryDiagnosticsReportDescribesTheRecoveryState() throws {
        let suite = "BeatboiDiagnosticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)
        let quiet = store.recoveryDiagnosticsReport()

        // A pasted report has to identify itself, so the build and OS lead it. Both values are read
        // from the runtime here too, which is what pins which bundle keys the dump reads.
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let header = quiet.split(separator: "\n").map(String.init)
        XCTAssertEqual(header.first, "RECOVERY DIAGNOSTICS")
        XCTAssertEqual(header.dropFirst().first, "app: \(version) (build \(build))")
        XCTAssertEqual(header.dropFirst(2).first, "os: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        XCTAssertFalse(version.isEmpty, "precondition: the bundle declares a version")
        XCTAssertFalse(build.isEmpty, "precondition: the bundle declares a build")

        XCTAssertTrue(quiet.contains("deleted stack: 0 of \(GameStore.deletedProjectsLimit)"))
        XCTAssertTrue(quiet.contains("dismissed ids: 0 of \(GameStore.dismissedRecoverableLimit)"))
        XCTAssertTrue(quiet.contains("dismissed: absent"), "an absent payload is named, not omitted")
        XCTAssertTrue(quiet.contains("recoverable rows: 0 (missing 0, earlier version 0)"))
        XCTAssertTrue(quiet.contains("last load: clean"))

        // A deleted project shows up as a row, as stack depth, and as a payload that is now present.
        store.renameProject("KEEPER")
        store.newProject()
        store.renameProject("NEW QUEST 02")
        store.deleteProject(store.projects.first { $0.name.hasPrefix("NEW QUEST") }!)

        let deleted = store.recoveryDiagnosticsReport()
        XCTAssertTrue(deleted.contains("deleted stack: 1 of \(GameStore.deletedProjectsLimit)"))
        XCTAssertTrue(deleted.contains("recoverable rows: 1 (missing 1, earlier version 0)"))
        XCTAssertTrue(deleted.contains("from deleted: 1"))
        XCTAssertTrue(deleted.contains("NEW QUEST 02 [deleted, missing]"), "the report names what can be brought back")
        XCTAssertFalse(deleted.contains("deleted: absent"), "and carries the payload size once the stack has an entry")

        // Clearing that row moves it from the stack to the dismissed record.
        XCTAssertTrue(store.dismissRecoverableProject(store.recoveryCandidates[0]))
        let cleared = store.recoveryDiagnosticsReport()
        XCTAssertTrue(cleared.contains("deleted stack: 0 of \(GameStore.deletedProjectsLimit)"))
        XCTAssertTrue(cleared.contains("dismissed ids: 1 of \(GameStore.dismissedRecoverableLimit)"))
        XCTAssertTrue(cleared.contains("recoverable rows: 0 (missing 0, earlier version 0)"))

        // A payload that cannot be read at all is the case a report most needs to show, and its size
        // is all the dump reports — never an attempt to print what could not be decoded.
        let garbage = Data("not a library".utf8)
        defaults.set(garbage, forKey: "bytePocket.projects.unreadable")
        let damaged = GameStore(defaults: defaults).recoveryDiagnosticsReport()
        XCTAssertTrue(damaged.contains("quarantine: \(garbage.count) bytes"))
        XCTAssertTrue(damaged.contains("unreadable copies: 1"))
        XCTAssertTrue(damaged.contains("unreadable entries: 0"))
    }
#endif

    /// Clearing a row is an ordinary undoable step, so removing the wrong one is a tap away from
    /// coming back — and the dismissal has to travel back off disk too.
    func testDismissingARowIsUndoable() throws {
        let suite = "BeatboiDismissUndoTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        let alpha = ByteProject(name: "ALPHA", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let beta = ByteProject(name: "BETA", patterns: [BytePattern.empty(name: "PATTERN 01")])
        defaults.set(try JSONEncoder.bytePocketEncoder.encode([alpha, beta]), forKey: "bytePocket.projects.unreadable")

        let second = GameStore(defaults: defaults)
        let alphaRow = second.recoveryCandidates.first { $0.project.name == "ALPHA" }!
        second.dismissRecoverableProject(alphaRow)
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["BETA"])
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.dismissed"))

        second.undo()
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["ALPHA", "BETA"], "undo brings the row back")
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.dismissed"), "and takes it off disk")
        XCTAssertEqual(GameStore(defaults: defaults).recoveryCandidates.map(\.project.name), ["ALPHA", "BETA"])

        second.redo()
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["BETA"])
        XCTAssertNotNil(defaults.data(forKey: "bytePocket.projects.dismissed"))
        XCTAssertEqual(GameStore(defaults: defaults).recoveryCandidates.map(\.project.name), ["BETA"])
    }

    /// The bulk discard erases everything, so it also forgets the individual dismissals: otherwise
    /// a later payload holding the same project would stay hidden by a rule about a copy that no
    /// longer exists.
    func testDiscardingRecoverableProjectsForgetsIndividualDismissals() throws {
        let suite = "BeatboiDiscardForgetsDismissalsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = GameStore(defaults: defaults)
        first.renameProject("KEEPER")
        let orphan = ByteProject(name: "ORPHAN", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let payload = try JSONEncoder.bytePocketEncoder.encode([orphan])
        defaults.set(payload, forKey: "bytePocket.projects.unreadable")

        let second = GameStore(defaults: defaults)
        XCTAssertEqual(second.recoveryCandidates.map(\.project.name), ["ORPHAN"], "precondition")
        second.dismissRecoverableProject(second.recoveryCandidates[0])
        XCTAssertTrue(second.recoveryCandidates.isEmpty)

        second.discardRecoverableProjects()
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.dismissed"), "discarding clears the dismissals")

        // A later payload holding the same project is offered again rather than hidden forever.
        defaults.set(payload, forKey: "bytePocket.projects.unreadable")
        XCTAssertEqual(GameStore(defaults: defaults).recoveryCandidates.map(\.project.name), ["ORPHAN"])
    }

    /// A genuinely empty store still opens on the blank first-launch project, reported as a
    /// normal start rather than a recovery.
    func testMissingLibraryStillOpensBlank() {
        let suite = "BeatboiBlankStartTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects[0].patterns.count, 1)
        XCTAssertNil(store.libraryRecovery)
        XCTAssertNil(defaults.data(forKey: "bytePocket.projects.unreadable"))
    }

    /// Version 1 stored a bare `[ByteProject]` array. Reading it is the migration: the payload
    /// still loads, and the next save writes the versioned envelope, so the format change is an
    /// explicit step instead of something a future reader has to infer from missing fields.
    func testVersion1BareArrayLibraryMigratesToTheVersionedEnvelope() throws {
        let suite = "BeatboiSchemaMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keeper = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let legacyPayload = try JSONEncoder.bytePocketEncoder.encode([keeper])
        // A version 1 payload really is a bare array, so it cannot be mistaken for an envelope.
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: legacyPayload) as? [[String: Any]])
        defaults.set(legacyPayload, forKey: "bytePocket.projects")

        let store = GameStore(defaults: defaults)
        // Reading legacy data is not a degraded read: everything decoded, so nothing is reported.
        XCTAssertEqual(store.projects.map(\.name), ["KEEPER"])
        XCTAssertNil(store.libraryRecovery)
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects"), legacyPayload, "loading must not rewrite the v1 payload")

        // The first edit writes the current shape.
        store.renameProject("RENAMED")
        let saved = try XCTUnwrap(defaults.data(forKey: "bytePocket.projects"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let version = try XCTUnwrap(object["schemaVersion"] as? Int, "the saved payload must declare its schema version")
        XCTAssertGreaterThan(version, 1, "a migrated payload must not read as the bare-array version")
        let entries = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["name"] as? String, "RENAMED", "migration must carry the project across, not drop it")
        // The migrated project is stamped with the shape this build writes.
        XCTAssertEqual(entries.first?["schemaVersion"] as? Int, ByteProject.currentSchemaVersion)
    }

    /// A payload written by a newer build must be identified as such rather than absorbed by the
    /// per-field decoding defaults, which would silently drop whatever that build added.
    func testLibraryFromANewerBuildIsDetectedAndItsBytesPreserved() throws {
        let suite = "BeatboiNewerLibraryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let good = ByteProject(name: "FUTURE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let projectData = try JSONEncoder.bytePocketEncoder.encode(good)
        let projectObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: projectData) as? [String: Any])
        let futurePayload = try JSONSerialization.data(withJSONObject: ["schemaVersion": 999, "projects": [projectObject]])
        defaults.set(futurePayload, forKey: "bytePocket.projects")

        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.projects.map(\.name), ["FUTURE"], "the project is still read as far as this build understands it")
        XCTAssertEqual(store.libraryRecovery?.newerFormatFound, true, "a newer container version must be reported")
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), futurePayload, "the original bytes must be preserved")
    }

    /// The same detection applies one level down, to the project shape itself, so a future field
    /// added to `ByteProject` is flagged even when the container version still matches.
    func testProjectFromANewerBuildIsDetected() throws {
        let suite = "BeatboiNewerProjectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let good = ByteProject(name: "FUTURE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let projectData = try JSONEncoder.bytePocketEncoder.encode(good)
        var projectObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: projectData) as? [String: Any])
        projectObject["schemaVersion"] = 999
        let futurePayload = try JSONSerialization.data(withJSONObject: [projectObject])
        defaults.set(futurePayload, forKey: "bytePocket.projects")

        let store = GameStore(defaults: defaults)

        XCTAssertEqual(store.projects.map(\.name), ["FUTURE"])
        XCTAssertEqual(store.libraryRecovery?.newerFormatFound, true)
        XCTAssertEqual(defaults.data(forKey: "bytePocket.projects.unreadable"), futurePayload)
    }

    /// Absence of the field is what every pre-versioning file looks like, so it must decode as the
    /// legacy version specifically — not as whatever this build happens to write. The two are the
    /// same number today, which is exactly why pinning the distinction now matters.
    func testAbsentSchemaVersionReadsAsLegacyAndWrittenAsCurrent() throws {
        let project = ByteProject(name: "LEGACY", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let encoded = try JSONEncoder.bytePocketEncoder.encode(project)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, ByteProject.currentSchemaVersion, "a fresh project must be stamped with the current shape")

        object.removeValue(forKey: "schemaVersion")
        let legacy = try JSONDecoder.bytePocketDecoder.decode(
            ByteProject.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.schemaVersion, ByteProject.legacySchemaVersion)
        XCTAssertLessThanOrEqual(ByteProject.legacySchemaVersion, ByteProject.currentSchemaVersion)
    }

    /// Corrupt the stored library every way we can think of. Every case must hold two lines:
    /// loading never rewrites or discards what is on disk, and any project that is still
    /// readable survives into the library. The first case is a control proving this harness can
    /// produce a valid project, so the unreadable cases cannot pass for the wrong reason.
    func testCorruptStoredLibrariesNeverWipeOrLoseData() throws {
        let suite = "BeatboiCorruptLibraryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let good = ByteProject(name: "KEEPER", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let goodPayload = try JSONEncoder.bytePocketEncoder.encode([good])
        let goodObject = try XCTUnwrap((JSONSerialization.jsonObject(with: goodPayload) as? [[String: Any]])?.first)

        func payload(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = goodObject
            change(&object)
            return try JSONSerialization.data(withJSONObject: [object])
        }
        func array(_ objects: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: objects)
        }

        let cases: [(name: String, payload: Data, keepsProject: Bool)] = [
            ("unmodified object (control)", try array([goodObject]), true),
            ("truncated payload", Data(goodPayload.prefix(goodPayload.count / 2)), false),
            ("empty payload", Data(), false),
            ("not json at all", Data("this is not json".utf8), false),
            ("json object instead of array", Data(#"{"id":"x"}"#.utf8), false),
            ("array of numbers", Data("[1,2,3]".utf8), false),
            ("array of empty objects", Data("[{}]".utf8), false),
            ("array containing null", Data("[null]".utf8), false),
            ("missing id", try payload { $0.removeValue(forKey: "id") }, false),
            ("missing name", try payload { $0.removeValue(forKey: "name") }, false),
            ("missing tempo", try payload { $0.removeValue(forKey: "tempo") }, false),
            ("missing patterns", try payload { $0.removeValue(forKey: "patterns") }, false),
            ("missing createdAt", try payload { $0.removeValue(forKey: "createdAt") }, false),
            ("missing modifiedAt", try payload { $0.removeValue(forKey: "modifiedAt") }, false),
            ("bogus id", try payload { $0["id"] = "not-a-uuid" }, false),
            ("tempo wrong type", try payload { $0["tempo"] = "fast" }, false),
            ("name wrong type", try payload { $0["name"] = 42 }, false),
            ("patterns wrong type", try payload { $0["patterns"] = 5 }, false),
            ("effect values wrong type", try payload { $0["effects"] = "loud" }, false),
            ("good then bad", try array([goodObject, ["id": "nope"]]), true),
            ("bad then good", try array([["id": "nope"], goodObject]), true),
            ("three bad then good", try array([["id": "a"], ["id": "b"], ["id": "c"], goodObject]), true),
        ]

        for testCase in cases {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(testCase.payload, forKey: "bytePocket.projects")
            let context = "\(testCase.name): "

            let store = GameStore(defaults: defaults)

            // Loading must never rewrite what is on disk. Rewriting it is the wipe.
            XCTAssertEqual(
                defaults.data(forKey: "bytePocket.projects"), testCase.payload,
                context + "the stored payload was rewritten by loading"
            )

            if testCase.keepsProject {
                XCTAssertTrue(store.projects.contains { $0.name == "KEEPER" }, context + "a readable project was lost")
            } else {
                XCTAssertNotNil(store.libraryRecovery, context + "an unreadable library was reported as a normal start")
            }

            // The original bytes are preserved exactly when the read was degraded, and a clean
            // read must not quarantine anything.
            let quarantined = defaults.data(forKey: "bytePocket.projects.unreadable")
            if store.libraryRecovery == nil {
                XCTAssertNil(quarantined, context + "a clean load should not quarantine anything")
            } else {
                XCTAssertEqual(quarantined, testCase.payload, context + "the unreadable payload was not preserved")
            }
        }

        // Dropped projects are counted accurately for a mixed payload.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(try array([["id": "nope"], goodObject, ["id": "also-nope"]]), forKey: "bytePocket.projects")
        let mixed = GameStore(defaults: defaults)
        XCTAssertEqual(mixed.projects.count, 1)
        XCTAssertEqual(mixed.libraryRecovery?.droppedProjects, 2)
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
        // Blank project: seed a note so the row actually has something to clear.
        store.toggleStep(channel: .pulseA, step: 3)
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

        // Blank project: activity requires a note, so seed the pulse row at step 0.
        store.toggleStep(channel: .pulseA, step: 0)
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
        // The compact token is the title's first letter, so a channel cannot be labelled one
        // thing and abbreviated as another. PULSE 2 used to abbreviate to "S".
        for channel in ByteChannel.allCases {
            XCTAssertEqual(
                channel.shortTitle,
                String(channel.title.prefix(1)),
                "\(channel.title) must abbreviate from its own name"
            )
        }
    }

    /// The seeded drum kit names its voices the way the model does, and each seed carries the
    /// voice it is named after. The kit once offered a CRASH for what the pads, the mixer and the
    /// samples all call PERC, so a seed named after a voice the app does not have would put a
    /// second name back on the same sound.
    func testDrumSeedKitNamesEveryVoiceTheWayTheModelDoes() {
        let kit = ByteInstrumentPreset.library(for: .drum)
        XCTAssertEqual(
            kit.map(\.name).sorted(),
            ByteDrumVoice.allCases.map(\.title).sorted(),
            "every drum voice needs exactly one seed, under the voice's own title"
        )
        for preset in kit {
            guard ByteDrumVoice.allCases.indices.contains(preset.patch.drumVoice) else {
                return XCTFail("\(preset.name) seeds a drum voice index that does not exist")
            }
            XCTAssertEqual(
                ByteDrumVoice.allCases[preset.patch.drumVoice].title,
                preset.name,
                "the seed named \(preset.name) must set that voice, not another"
            )
        }
    }

    /// The four voices have to be tellable apart by ear, and the bundled one-shots are not a
    /// kit: the kick is the only low voice while three of them are bright, and the snare has no
    /// body of its own. The shape table is what separates them, so it has to separate them on
    /// both axes — no two voices may share a register, and no two may share a length.
    func testDrumVoiceShapesSeparateTheFourVoices() {
        let rates = ByteDrumVoice.allCases.map(\.playbackRate)
        let kept = ByteDrumVoice.allCases.map(\.keptFraction)
        XCTAssertEqual(
            Set(rates).count, ByteDrumVoice.allCases.count,
            "two voices read their sample at the same rate, so they sit in the same register"
        )
        XCTAssertEqual(
            Set(kept).count, ByteDrumVoice.allCases.count,
            "two voices keep the same fraction of their sample, so they last the same time"
        )
        XCTAssertEqual(
            Set(ByteDrumVoice.allCases.map(\.character)).count, ByteDrumVoice.allCases.count,
            "two voices are described the same way, so a reader cannot tell what to listen for"
        )
        for voice in ByteDrumVoice.allCases {
            XCTAssertTrue((0.75...1.6).contains(voice.playbackRate), "\(voice.title) reads at \(voice.playbackRate)×")
            XCTAssertTrue((0.25...1.0).contains(voice.keptFraction), "\(voice.title) keeps \(voice.keptFraction) of its sample")
        }
        // The kick is the kit's floor, so it stays at the pitch it was recorded at with its whole
        // tail; the hi-hat is the fastest and the most cut, which is what stops it reading as a
        // quieter snare.
        XCTAssertEqual(ByteDrumVoice.kick.playbackRate, 1.0)
        XCTAssertEqual(ByteDrumVoice.kick.keptFraction, 1.0)
        XCTAssertEqual(ByteDrumVoice.hiHat.playbackRate, rates.max())
        XCTAssertEqual(ByteDrumVoice.hiHat.keptFraction, kept.min())
    }

    /// Every path that plays a drum reads through one shaper, so the shaper has to behave at
    /// its edges: a rate of one frame per position at native pitch, a voice past its trim silent
    /// rather than playing the rumble the trim was there to remove, and a cut tail that releases
    /// instead of stepping to silence.
    func testDrumVoiceReaderAppliesRateTrimAndRelease() {
        let sample = (0..<1000).map { Float($0) + 1 }
        XCTAssertEqual(ByteDrumVoice.value(of: sample, voice: .kick, at: 0), 1.0, accuracy: 0.0001)
        // A faster voice is further into its sample at the same read position.
        XCTAssertGreaterThan(
            ByteDrumVoice.value(of: sample, voice: .hiHat, at: 100),
            ByteDrumVoice.value(of: sample, voice: .snare, at: 100)
        )
        // The snare is slowed to find the body its own sample lacks, so it reads an earlier
        // frame than its position suggests: 100 × 0.88 = frame 88.
        XCTAssertEqual(ByteDrumVoice.value(of: sample, voice: .snare, at: 100), Double(sample[88]), accuracy: 0.001)
        // Past the trim the voice is silent, whichever sample it was handed.
        let trimmedLength = Double(ByteDrumVoice.hiHat.keptFrameCount(sampleCount: sample.count))
        XCTAssertEqual(ByteDrumVoice.value(of: sample, voice: .hiHat, at: trimmedLength), 0, accuracy: 0.0001)
        // The last kept frame is eased out, so the trim cannot end on a step.
        let lastKeptFrame = (trimmedLength - 1) / ByteDrumVoice.hiHat.playbackRate
        XCTAssertGreaterThan(ByteDrumVoice.value(of: sample, voice: .hiHat, at: lastKeptFrame), 0)
        XCTAssertLessThan(
            ByteDrumVoice.value(of: sample, voice: .hiHat, at: lastKeptFrame),
            Double(sample[ByteDrumVoice.hiHat.keptFrameCount(sampleCount: sample.count) - 1]),
            "the cut tail has to fade, or trimming a sample ends on a click"
        )
        // The kick keeps its whole tail, and an empty sample is silence rather than a crash.
        XCTAssertEqual(ByteDrumVoice.kick.keptFrameCount(sampleCount: 1000), 1000)
        XCTAssertEqual(ByteDrumVoice.kick.keptFrameCount(sampleCount: 0), 0)
        XCTAssertEqual(ByteDrumVoice.value(of: [], voice: .kick, at: 5), 0)
    }

    /// The audition run has to visit every voice exactly once — a kit check that skipped a voice
    /// or played one twice would misrepresent the kit it exists to let you compare — and each
    /// voice's note has to read back as that voice, because the preview plays a note through the
    /// same path the sequence does.
    func testDrumAuditionCoversEveryVoiceAndItsNoteRoundTrips() {
        XCTAssertEqual(
            Set(ByteDrumVoice.auditionOrder), Set(ByteDrumVoice.allCases),
            "every voice needs a place in the run"
        )
        XCTAssertEqual(
            ByteDrumVoice.auditionOrder.count, ByteDrumVoice.allCases.count,
            "a voice played twice would leave another one unheard"
        )
        for voice in ByteDrumVoice.allCases {
            XCTAssertEqual(
                ByteDrumVoice.voice(for: ByteDrumVoice.note(voice: voice)), voice,
                "\(voice.title)'s note must read back as \(voice.title), or it previews the wrong sample"
            )
        }
    }

    /// The run has to be heard in the project's time. One voice per beat puts the four voices on
    /// the four beats of the bar, so the run is countable and shares its pulse with the loop; a
    /// fixed interval plays the same four hits at a tempo the project does not have.
    func testDrumAuditionRunIsOneBarInTimeWithTheTempo() {
        XCTAssertEqual(
            ByteDrumVoice.auditionStepsPerVoice, 4,
            "a voice a beat is what puts the four voices on the bar's four beats"
        )

        for bpm in [60, 90, 120, 132, 174, 240] {
            XCTAssertEqual(
                ByteDrumVoice.auditionInterval(bpm: bpm),
                ByteTransportClock.stepDuration(bpm: bpm) * Double(ByteDrumVoice.auditionStepsPerVoice),
                accuracy: 0.0001,
                "the run must take its spacing from the transport's step at \(bpm) bpm"
            )
        }

        // Four voices at a beat each fill exactly one bar, so the run can be counted back.
        let barAt132 = ByteTransportClock.stepDuration(bpm: 132) * 16
        XCTAssertEqual(
            ByteDrumVoice.auditionInterval(bpm: 132) * Double(ByteDrumVoice.auditionOrder.count),
            barAt132,
            accuracy: 0.0001,
            "the four voices have to be one bar long end to end to land as a countable bar"
        )

        // And the spacing has to follow the tempo, not merely be constant: a run that ignored the
        // tempo would satisfy everything above at one speed and drift at every other.
        XCTAssertNotEqual(
            ByteDrumVoice.auditionInterval(bpm: 120), ByteDrumVoice.auditionInterval(bpm: 90),
            "a slower project has to space the run wider, or the run is not in time with it"
        )
        XCTAssertEqual(
            ByteDrumVoice.auditionInterval(bpm: 120), ByteTransportClock.beatDuration(bpm: 120),
            accuracy: 0.0001,
            "one voice per beat means the interval is the beat itself"
        )
    }

    /// The row's picture has to be the sound it stands for. Each point is the loudest the voice
    /// gets in its slice of the hit, read through the same reader playback and export use, and
    /// scaled to the voice's own peak so a quiet voice's outline is legible rather than flat.
    func testVoiceOutlineIsItsOwnPeaksScaledToItsOwnPeak() {
        // A decaying tone, so an outline that ignored the reader would still look plausible.
        let sample = (0..<20_000).map { Float(exp(-Double($0) / 3_000)) }
        let points = 12

        for voice in ByteDrumVoice.allCases {
            let outline = voice.envelope(of: sample, points: points)
            XCTAssertEqual(outline.count, points)
            XCTAssertEqual(
                outline.max() ?? 0, 1, accuracy: 0.0001,
                "\(voice.title)'s outline has to be scaled to its own loudest point"
            )
            XCTAssertTrue(outline.allSatisfy { (0...1).contains($0) })

            // Every point is a slice of the hit, so over a decaying sample none may rise: a rise
            // would mean the points are not the slices they claim to be.
            for (earlier, later) in zip(outline, outline.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    earlier + 0.0001, later,
                    "\(voice.title)'s outline should follow the decay rather than rise"
                )
            }

            // And the outline covers the hit and no more: past the frames the voice plays, the
            // reader is silent, which is where a trimmed voice's picture has to end.
            let frames = voice.outputFrameCount(sampleCount: sample.count)
            XCTAssertGreaterThan(frames, 0, "\(voice.title) should play something")
            XCTAssertEqual(
                ByteDrumVoice.value(of: sample, voice: voice, at: Double(frames)), 0, accuracy: 0.0001,
                "\(voice.title)'s outline must stop where the voice goes quiet"
            )
        }

        // A hit that is loud the whole way through has to draw full the whole way through. Points
        // that ran past the frames the voice plays would come back as silence instead, splitting
        // the outline into a loud part and a dead one. Not exactly full throughout: the trim's
        // fade reaches into the final point of a voice that is cut short.
        let constant = Array(repeating: Float(1), count: 20_000)
        for voice in ByteDrumVoice.allCases {
            let outline = voice.envelope(of: constant, points: points)
            XCTAssertTrue(
                outline.allSatisfy { $0 > 0.99 },
                "\(voice.title)'s outline should span the frames it plays and no others, it reads \(outline)"
            )
        }

        XCTAssertTrue(
            ByteDrumVoice.kick.envelope(of: [], points: 8).allSatisfy { $0 == 0 },
            "a voice with no sample has no shape to draw"
        )
    }

    /// The drawn width is the voice's length against the longest hit in the kit, so the picture
    /// and the caption have to agree: the voice captioned FULL is the widest, the one captioned
    /// CLICK the narrowest. A row whose picture contradicts its own words is worse than one that
    /// says nothing, because the reader has no way to know which half to believe.
    func testVoiceOutlineWidthsRunInTheOrderTheCaptionsClaim() {
        let captions: [(ByteDrumVoice, String)] = [
            (.kick, "FULL"), (.snare, "LONG"), (.perc, "SHORT"), (.hiHat, "CLICK")
        ]
        var previous = Int.max
        for (voice, word) in captions {
            XCTAssertTrue(
                voice.character.contains(word),
                "\(voice.title) should still be captioned \(word), it says \(voice.character)"
            )
            let frames = voice.outputFrameCount(sampleCount: 44_100)
            XCTAssertLessThan(
                frames, previous,
                "\(voice.title) is captioned \(word), so it has to be drawn narrower than the voice before it"
            )
            previous = frames
        }
    }

    /// The kit check has to play the row the sequence plays, not a stand-in for it: a check that
    /// could disagree with the pattern would send the reader looking for a fault in the kit.
    func testDrumHitsReadTheRowTheSequenceWillPlay() {
        var pattern = BytePattern.empty(name: "ROWS")
        XCTAssertTrue(pattern.drumHits.isEmpty, "an empty row has nothing to check")

        guard let drumRow = ByteChannel.allCases.firstIndex(of: .drum) else {
            return XCTFail("expected a drum channel")
        }
        // Written the way the pad grid writes one, including voices that are not the default for
        // the step they land on.
        pattern.steps[drumRow][2] = ByteDrumVoice.note(voice: .snare)
        pattern.steps[drumRow][9] = ByteDrumVoice.note(voice: .perc)

        XCTAssertEqual(
            pattern.drumHits,
            [ByteDrumHit(step: 2, voice: .snare), ByteDrumHit(step: 9, voice: .perc)],
            "each hit has to keep its own voice, in the order the bar plays them"
        )

        // A hit stored under an alias note still resolves to the voice it is named after.
        pattern.steps[drumRow][12] = 50
        XCTAssertEqual(
            pattern.drumHits.last, ByteDrumHit(step: 12, voice: .perc),
            "the check reads the row through the same note-to-voice table the pads do"
        )
    }

    /// The walk up the kit is a grid of hits like a drum row, one voice per beat, so one runner
    /// plays both — and the walk has to fill the bar that runner walks rather than stopping on
    /// its last voice.
    func testKitWalkIsTheVoicesOneBeatApartOnTheBar() {
        XCTAssertEqual(
            ByteDrumVoice.auditionWalk.map(\.voice), ByteDrumVoice.auditionOrder,
            "the walk is the audition order, on the grid"
        )
        XCTAssertEqual(
            ByteDrumVoice.auditionWalk.map(\.step), [0, 4, 8, 12],
            "four voices a beat apart land on the bar's four beats"
        )
        for (earlier, later) in zip(ByteDrumVoice.auditionWalk, ByteDrumVoice.auditionWalk.dropFirst()) {
            XCTAssertEqual(
                later.step - earlier.step, ByteDrumVoice.auditionStepsPerVoice,
                "the walk has to stay on the beat grid the interval is measured against"
            )
        }
        XCTAssertEqual(
            (ByteDrumVoice.auditionWalk.last?.step ?? 0) + ByteDrumVoice.auditionStepsPerVoice,
            BytePattern.barSteps,
            "the walk has to fill the bar the runner walks, or the run ends off the bar line"
        )
    }

    /// The Export Pack product ID lives in two places that must agree: the app
    /// constant and the checked-in StoreKit config.
    ///
    /// They drifted once already. The app asked for `com.bytepocket.studio.export`
    /// while App Store Connect offered `exportunlock`, so `Product.products(for:)`
    /// came back empty and the pack was unbuyable in TestFlight — while looking
    /// perfectly healthy in Xcode, because the local StoreKit config masks exactly
    /// this class of mistake.
    ///
    /// Both sides now carry the live `exportunlock`, because a product identifier
    /// cannot be renamed once the product exists, so the code is the side that had
    /// to move. This test covers the app-versus-config half; the release script
    /// checks both against live App Store Connect, which is the one side a test
    /// cannot reach.
    func testExportPackProductIDMatchesStoreKitConfig() throws {
        let config = URL(fileURLWithPath: #filePath)   // <repo>/AquaSortTests/WaterLogicTests.swift
            .deletingLastPathComponent()               // <repo>/AquaSortTests
            .deletingLastPathComponent()               // <repo>
            .appendingPathComponent("StoreKitConfig/AquaSort.storekit")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        let offered = (json?["products"] as? [[String: Any]] ?? [])
            .compactMap { $0["productID"] as? String }
        let requested = StoreKitManager().unlockProductID

        XCTAssertFalse(offered.isEmpty, "AquaSort.storekit lists no products")
        XCTAssertTrue(
            offered.contains(requested),
            "the app requests \(requested) but AquaSort.storekit offers \(offered)"
        )
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

    /// A revoked transaction is still "current" for a non-consumable, so the
    /// entitlement rule has to read the revocation date, not merely the presence
    /// of an entry. Without this, a refunded or Family-Sharing-removed Export
    /// Pack would export forever.
    func testRevokedExportPackTransactionDoesNotGrantEntitlement() {
        let live = StoreKitManager.EntitlementEntry(productID: "exportunlock", revocationDate: nil)
        let revoked = StoreKitManager.EntitlementEntry(productID: "exportunlock", revocationDate: Date())
        let unrelated = StoreKitManager.EntitlementEntry(productID: "com.bytepocket.studio.export", revocationDate: nil)

        XCTAssertFalse(StoreKitManager.isOwned(productID: "exportunlock", in: []), "no transactions means no entitlement")
        XCTAssertTrue(StoreKitManager.isOwned(productID: "exportunlock", in: [live]), "an unrevoked purchase grants the pack")
        XCTAssertFalse(StoreKitManager.isOwned(productID: "exportunlock", in: [revoked]), "a revocation must clear the pack")
        XCTAssertFalse(StoreKitManager.isOwned(productID: "exportunlock", in: [unrelated]), "another product must not grant the pack")
        XCTAssertTrue(
            StoreKitManager.isOwned(productID: "exportunlock", in: [revoked, live]),
            "a refund of one purchase must not revoke a later re-purchase"
        )
    }

    // MARK: - Step sweeps

    /// A sweep across several steps has to land as ONE undo step. The grid applies
    /// the run live as the finger moves, so if each step pushed its own history
    /// entry, taking a single drag back would need one undo for every pad it crossed.
    @MainActor
    func testStepSweepPaintsARunAsOneUndoStep() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .pulseA)!
        let before = (1...3).map { store.project.patterns[0].steps[row][$0] }

        store.beginStepSweep(channel: .pulseA, step: 1, painting: true)
        store.extendStepSweep(step: 2)
        store.extendStepSweep(step: 3)
        store.endStepSweep()

        let rootNote = ByteChannel.pulseA.rootNote(for: store.project.key)
        let expected: [Int?] = [rootNote, rootNote, rootNote]
        XCTAssertEqual((1...3).map { store.project.patterns[0].steps[row][$0] }, expected)

        store.undo()

        XCTAssertEqual(
            (1...3).map { store.project.patterns[0].steps[row][$0] }, before,
            "one undo must take back the whole run, not one step of it"
        )
        XCTAssertFalse(store.canUndo, "the sweep was the only edit, so it must leave exactly one step to undo")

        defaults.removePersistentDomain(forName: suite)
    }

    /// Starting a run on a filled step clears it. The sweep's meaning comes from the
    /// pad it began on, which is why the same gesture paints or erases — and why the
    /// grid captures that state at touch-down instead of re-reading it mid-drag.
    @MainActor
    func testStepSweepClearsWhenItStartsOnAFilledStep() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .pulseA)!
        for step in 1...3 { store.toggleStep(channel: .pulseA, step: step) }
        let before = (1...3).map { store.project.patterns[0].steps[row][$0] }
        XCTAssertTrue(before.allSatisfy { $0 != nil }, "setup: the run should start filled")

        store.beginStepSweep(channel: .pulseA, step: 1, painting: false)
        store.extendStepSweep(step: 2)
        store.extendStepSweep(step: 3)
        store.endStepSweep()

        XCTAssertEqual((1...3).map { store.project.patterns[0].steps[row][$0] }, [nil, nil, nil])

        store.undo()

        XCTAssertEqual(
            (1...3).map { store.project.patterns[0].steps[row][$0] }, before,
            "one undo must restore the whole cleared run"
        )

        defaults.removePersistentDomain(forName: suite)
    }

    /// Re-crossing a step must not flip it again, or a finger that wobbles over a pad
    /// boundary would punch a hole in the middle of the run it just painted.
    @MainActor
    func testStepSweepIgnoresAStepItHasAlreadyCrossed() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .pulseA)!

        store.beginStepSweep(channel: .pulseA, step: 1, painting: true)
        store.extendStepSweep(step: 2)
        store.extendStepSweep(step: 1)
        store.extendStepSweep(step: 2)
        store.endStepSweep()

        XCTAssertNotNil(store.project.patterns[0].steps[row][1])
        XCTAssertNotNil(store.project.patterns[0].steps[row][2])
        store.undo()
        XCTAssertFalse(store.canUndo)

        defaults.removePersistentDomain(forName: suite)
    }

    /// A drum run paints the voice it was handed, which is how a sideways drag on an
    /// empty drum row lays down a run of hi-hats instead of a run of kicks.
    @MainActor
    func testDrumSweepPaintsTheSuppliedVoice() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .drum)!

        store.beginStepSweep(
            channel: .drum,
            step: 0,
            painting: true,
            note: ByteDrumVoice.note(voice: .hiHat)
        )
        store.extendStepSweep(step: 1)
        store.endStepSweep()

        let painted = (0...1).map { store.project.patterns[0].steps[row][$0] }
        let expected: [Int?] = [
            ByteDrumVoice.note(voice: .hiHat),
            ByteDrumVoice.note(voice: .hiHat),
        ]
        XCTAssertEqual(painted, expected, "the run must carry the voice, not the default kick")

        defaults.removePersistentDomain(forName: suite)
    }

    /// A melodic run paints the pitch of the pad it started on, so dragging away from a note
    /// repeats *that* note. Painting the channel's root note instead would stamp a melody the
    /// user had just written flat, which is the one thing a sideways drag must not do.
    @MainActor
    func testMelodicSweepPaintsThePitchItStartedOn() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .pulseA)!

        store.setNote(channel: .pulseA, step: 4, note: 67)
        guard let held = store.note(channel: .pulseA, step: 4) else {
            return XCTFail("setup: step 4 should hold the note just written")
        }
        XCTAssertNotEqual(
            held, ByteChannel.pulseA.rootNote(for: store.project.key),
            "the seeded pitch has to differ from the channel root, or this test proves nothing"
        )

        store.beginStepSweep(channel: .pulseA, step: 4, painting: true, note: held)
        store.extendStepSweep(step: 5)
        store.extendStepSweep(step: 6)
        store.endStepSweep()

        XCTAssertEqual(
            (4...6).map { store.project.patterns[0].steps[row][$0] },
            [held, held, held],
            "the run must repeat the pitch it started on, not the root note"
        )

        store.undo()
        XCTAssertEqual(
            [store.project.patterns[0].steps[row][4], store.project.patterns[0].steps[row][5], store.project.patterns[0].steps[row][6]],
            [held, nil, nil],
            "one undo must take back the painted run and leave the pad it started on alone"
        )

        defaults.removePersistentDomain(forName: suite)
    }

    /// A run handed no value — the drag began on an empty pad — still paints something, and
    /// what it paints is the channel's root note.
    @MainActor
    func testMelodicSweepWithoutAValuePaintsTheRootNote() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)
        let row = ByteChannel.allCases.firstIndex(of: .wave)!
        store.clearStep(channel: .wave, step: 9)

        store.beginStepSweep(channel: .wave, step: 9, painting: true)
        store.endStepSweep()

        XCTAssertEqual(
            store.project.patterns[0].steps[row][9],
            ByteChannel.wave.rootNote(for: store.project.key),
            "an empty start leaves the value to the channel's default"
        )

        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Pad auditions

    /// The grid auditions a step through the store's own view of it, so the accessor has to
    /// report the note the step holds and nil when it is empty — an audition of an empty step
    /// would play the previous note and mislead the ear the feature exists to serve.
    @MainActor
    func testStepNoteAccessorReportsTheHeldNoteOrNil() {
        let suite = "BeatboiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GameStore(defaults: defaults)

        store.clearStep(channel: .pulseA, step: 5)
        XCTAssertNil(store.note(channel: .pulseA, step: 5), "an empty step has no note to audition")

        store.setNote(channel: .pulseA, step: 5, note: 67)
        XCTAssertEqual(store.note(channel: .pulseA, step: 5), store.project.mode.quantize(67, key: store.project.key))

        // A drum step stores a voice rather than a pitch, and the audition plays that.
        store.setDrumVoice(step: 2, voice: Int(ByteDrumVoice.snare.rawValue))
        XCTAssertEqual(store.note(channel: .drum, step: 2), ByteDrumVoice.note(voice: .snare))

        XCTAssertNil(store.note(channel: .pulseA, step: 99), "a step outside the loop must not audition")

        defaults.removePersistentDomain(forName: suite)
    }

    /// An audition has to bring the audio unit up, because with the transport stopped nothing
    /// else can make a sound — and it has to let it go again, or the app holds the audio
    /// hardware for the rest of the session.
    @MainActor
    func testAuditionWakesTheAudioUnitAndLetsItSleepAgain() async throws {
        let engine = ByteAudioEngine(auditionIdleSeconds: 0.15)
        XCTAssertFalse(engine.isAudioUnitRunning, "a fresh engine should not be holding the audio hardware")

        engine.audition(channel: .pulseA, note: 64, project: .starter)
        XCTAssertTrue(engine.isAudioUnitRunning, "an audition cannot be heard unless the audio unit is running")

        try await Task.sleep(for: .seconds(0.8))
        XCTAssertFalse(
            engine.isAudioUnitRunning,
            "the audio unit must close again once auditions stop, or it stays powered up indefinitely"
        )
    }

    /// Auditioning while the loop plays must not disturb the transport or shut the audio unit
    /// out from under it — the idle stop is only allowed to close an idle engine.
    @MainActor
    func testAuditionDuringPlaybackLeavesTheTransportAlone() async throws {
        let engine = ByteAudioEngine(auditionIdleSeconds: 0.15)
        engine.play(project: .starter) { _, _ in }
        XCTAssertTrue(engine.playing)

        engine.audition(channel: .pulseA, note: 60, project: .starter)
        try await Task.sleep(for: .seconds(0.8))

        XCTAssertTrue(engine.playing, "a preview must not stop the transport")
        XCTAssertTrue(engine.isAudioUnitRunning, "the idle stop must not close the audio unit while the loop is playing")
        engine.stop()
    }
}

private extension ByteProject {
    var projectEffectsForTests: ByteEffects { effects }
}

private extension GameStore {
    /// Whether the recovery surface is still offering this exact preserved copy.
    func offersRecovery(_ candidate: GameStore.RecoveryCandidate) -> Bool {
        recoveryCandidates.contains { $0.id == candidate.id }
    }
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
