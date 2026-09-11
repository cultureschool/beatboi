import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ByteScaleMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case chromatic
    case major
    case dorian
    case phrygian
    case lydian
    case mixolydian
    case aeolian
    case locrian
    case harmonicMinor
    case melodicMinor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chromatic: return "CHROMATIC"
        case .major: return "MAJOR / IONIAN"
        case .dorian: return "DORIAN"
        case .phrygian: return "PHRYGIAN"
        case .lydian: return "LYDIAN"
        case .mixolydian: return "MIXOLYDIAN"
        case .aeolian: return "AEOLIAN / NATURAL MINOR"
        case .locrian: return "LOCRIAN"
        case .harmonicMinor: return "HARMONIC MINOR"
        case .melodicMinor: return "MELODIC MINOR"
        }
    }

    var intervals: [Int]? {
        switch self {
        case .chromatic: return nil
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian: return [0, 1, 3, 5, 7, 8, 10]
        case .lydian: return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .aeolian: return [0, 2, 3, 5, 7, 8, 10]
        case .locrian: return [0, 1, 3, 5, 6, 8, 10]
        case .harmonicMinor: return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor: return [0, 2, 3, 5, 7, 9, 11]
        }
    }

    func quantize(_ note: Int, key: Int) -> Int {
        guard let intervals else { return min(96, max(24, note)) }
        let root = min(11, max(0, key))
        let candidates = (-2...10).flatMap { octave in
            intervals.map { root + octave * 12 + $0 }
        }
        return candidates
            .filter { (24...96).contains($0) }
            .min { lhs, rhs in
                let leftDistance = abs(lhs - note)
                let rightDistance = abs(rhs - note)
                return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
            } ?? min(96, max(24, note))
    }
}

struct ByteScaleKey: Identifiable, Hashable, Sendable {
    let note: Int
    let title: String
    var id: Int { note }

    static let all: [ByteScaleKey] = [
        ByteScaleKey(note: 0, title: "C"), ByteScaleKey(note: 1, title: "C#"),
        ByteScaleKey(note: 2, title: "D"), ByteScaleKey(note: 3, title: "D#"),
        ByteScaleKey(note: 4, title: "E"), ByteScaleKey(note: 5, title: "F"),
        ByteScaleKey(note: 6, title: "F#"), ByteScaleKey(note: 7, title: "G"),
        ByteScaleKey(note: 8, title: "G#"), ByteScaleKey(note: 9, title: "A"),
        ByteScaleKey(note: 10, title: "A#"), ByteScaleKey(note: 11, title: "B")
    ]
}

enum ByteDrumVoice: Int, CaseIterable, Identifiable, Sendable {
    case kick
    case snare
    case hiHat
    case perc

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .kick: return "KICK"
        case .snare: return "SNARE"
        case .hiHat: return "PERC"
        case .perc: return "HI-HAT"
        }
    }

    var baseNote: Int { [36, 38, 42, 49][rawValue] }
    var resourceNames: [String] {
        switch self {
        case .kick: return ["kick1", "kick2"]
        case .snare: return ["snare1", "snare2"]
        case .hiHat: return ["hihat1", "hihat2"]
        case .perc: return ["perc2", "perc1"]
        }
    }

    static func voice(for note: Int) -> ByteDrumVoice {
        switch note {
        case 38, 39: return .snare
        case 42, 43: return .hiHat
        case 49, 50: return .perc
        default: return .kick
        }
    }

    /// Maps a completed hold-drag to the quick drum sketching layout.
    /// Vertical up is Snare, horizontal left is the displayed Perc voice,
    /// horizontal right is the displayed Hi-hat voice,
    /// and a downward/neutral gesture keeps the default Kick.
    static func voice(horizontal: Int, vertical: Int) -> ByteDrumVoice {
        if abs(horizontal) > abs(vertical) {
            return horizontal < 0 ? .hiHat : .perc
        }
        return vertical < 0 ? .snare : .kick
    }

    /// Drum pads store only the voice. Sample variant selection lives in the Drum Sound Lab.
    static func variant(for note: Int) -> Int { 1 }
    static func note(voice: ByteDrumVoice, variant: Int = 1) -> Int { voice.baseNote }
    static func label(for note: Int) -> String { voice(for: note).title }
}

enum ByteChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case pulseA
    case pulseB
    case wave
    case drum

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "noise" ? .drum : (ByteChannel(rawValue: value) ?? .drum)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulseA: return "PULSE 1"
        case .pulseB: return "PULSE 2"
        case .wave: return "TRIANGLE"
        case .drum: return "DRUM"
        }
    }

    var shortTitle: String {
        switch self {
        case .pulseA: return "P"
        case .pulseB: return "S"
        case .wave: return "T"
        case .drum: return "D"
        }
    }

    var systemImage: String {
        switch self {
        case .pulseA, .pulseB: return "waveform.path"
        case .wave: return "triangle"
        case .drum: return "drum.fill"
        }
    }

    var defaultNotes: [Int] {
        switch self {
        case .pulseA: return [60, 64, 67, 72]
        case .pulseB: return [48, 55, 60, 55]
        case .wave: return [36, 36, 43, 36]
        case .drum: return ByteDrumVoice.allCases.map(\.baseNote)
        }
    }

    /// The tap-to-place note for a melodic channel keeps the same root pitch class as
    /// the project's key while preserving each channel's comfortable register.
    func rootNote(for key: Int) -> Int {
        guard self != .drum else { return ByteDrumVoice.kick.baseNote }
        let root = min(11, max(0, key))
        switch self {
        case .pulseA: return 60 + root
        case .pulseB: return 48 + root
        case .wave: return 36 + root
        case .drum: return ByteDrumVoice.kick.baseNote
        }
    }
}

enum ByteEffect: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case echo
    case bitCrush

    var id: String { rawValue }
    var title: String {
        switch self {
        case .echo: return "ECHO"
        case .bitCrush: return "BIT CRUSH"
        }
    }
}

enum ByteOctaveFlutterPattern: Int, CaseIterable, Codable, Identifiable, Sendable {
    case baseUp = 0
    case upBase = 1
    case baseUpTwoUp = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .baseUp: return "BASE / +1"
        case .upBase: return "+1 / BASE"
        case .baseUpTwoUp: return "BASE / +1 / +2 / +1"
        }
    }

    var octaveSteps: [Int] {
        switch self {
        case .baseUp: return [0, 1]
        case .upBase: return [1, 0]
        case .baseUpTwoUp: return [0, 1, 2, 1]
        }
    }
}

enum ByteWaveShape: Int, CaseIterable, Identifiable, Sendable {
    case waveBass
    case triangle
    case organ
    case metal
    case ramp

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .waveBass: return "BASS"
        case .triangle: return "TRIANGLE"
        case .organ: return "ORGAN"
        case .metal: return "METAL"
        case .ramp: return "RAMP"
        }
    }

    var table: [Int] {
        switch self {
        case .waveBass: return [8, 10, 12, 14, 15, 14, 12, 10, 8, 6, 4, 2, 1, 2, 4, 6, 8, 10, 12, 14, 15, 14, 12, 10, 8, 6, 4, 2, 1, 2, 4, 6]
        case .triangle: return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
        case .organ: return [8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4]
        case .metal: return [8, 15, 2, 13, 1, 12, 3, 14, 0, 15, 4, 11, 2, 13, 1, 14, 8, 0, 13, 2, 15, 3, 12, 1, 14, 4, 11, 2, 15, 0, 13, 3]
        case .ramp: return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        }
    }

    static func shape(for id: String) -> ByteWaveShape {
        switch id {
        case "triangle": return .triangle
        case "organ": return .organ
        case "metal": return .metal
        case "ramp": return .ramp
        default: return .waveBass
        }
    }
}

/// Hardware-inspired parameters for one of the four DMG channels.
struct ByteChannelPatch: Codable, Hashable, Sendable {
    let channel: ByteChannel
    var duty: Int
    var initialVolume: Int
    /// Per-channel master fader, independent from the DMG 4-bit envelope volume.
    var masterVolume: Int
    /// Coarse melodic transposition, stored as octaves from -2 through +2.
    var octave: Int
    /// Beginner-friendly amplitude modulation amount retained for old projects.
    var tremolo: Int
    /// Monophonic pitch glide controls. Portamento replaces the former auto-bend UI.
    var portamento: Int
    var portamentoTime: Int
    /// Simple synth envelope controls, expressed as 0–100% drag values.
    var envelopeAttack: Int
    var envelopeDecay: Int
    var envelopeSustain: Int
    var envelopeRelease: Int
    var envelope: Int
    var vibratoDepth: Int
    var vibratoCycleLength: Int
    var vibratoDelay: Int
    var bendRange: Int
    var vibratoRate: Int
    /// Per-channel NES-style octave flutter speed. Zero disables it.
    var octaveFlutterAmount: Int
    /// Per-channel octave path: 0 base/+1, 1 +1/base, 2 base/+1/+2/+1.
    var octaveFlutterPattern: Int
    var envelopeIncrease: Bool
    var envelopePace: Int
    var sweepPace: Int
    var sweepIncrease: Bool
    var sweepShift: Int
    var waveVolume: Int
    /// Fixed wave preset index plus simple tone and decay controls.
    var waveShape: Int
    var waveFilter: Int
    var waveEnvelope: Int
    // Retained privately for old project compatibility; Drum UI exposes voice controls instead.
    var noiseWidth7Bit: Bool
    var noiseClockShift: Int
    var noiseDivider: Int
    var panLeft: Bool
    var panRight: Bool
    var lengthCounter: Bool
    var length: Int
    /// Mixer state is project data so mute/solo survives autosave and export.
    var muted: Bool
    var soloed: Bool
    /// Drum voice used by the Sound Lab selector: 0 kick, 1 snare, 2 hi-hat, 3 crash.
    var drumVoice: Int
    /// Selected supplied sample (1 or 2) for kick, snare, hi-hat, and perc.
    var drumSamples: [Int]
    /// Retained for project compatibility; supplied one-shots no longer expose these controls.
    var drumVolumes: [Int]
    var drumLengths: [Int]

    private enum CodingKeys: String, CodingKey {
        case channel, duty, initialVolume, masterVolume, octave, tremolo, portamento, portamentoTime, envelopeAttack, envelopeDecay, envelopeSustain, envelopeRelease, filter, envelope, vibratoDepth, vibratoCycleLength, vibratoDelay, bendRange, vibratoRate, envelopeIncrease, envelopePace, sweepPace, sweepIncrease, sweepShift
        case waveVolume, waveShape, waveFilter, waveEnvelope, noiseWidth7Bit, noiseClockShift, noiseDivider, panLeft, panRight, lengthCounter, length, muted, soloed, octaveFlutterAmount, octaveFlutterPattern
        case drumVoice, drumSamples, drumVolumes, drumLengths
    }

    init(channel: ByteChannel) {
        self.channel = channel
        self.duty = channel == .pulseA || channel == .pulseB ? 1 : 0
        self.initialVolume = 15
        self.masterVolume = channel == .pulseA || channel == .pulseB ? 50 : 100
        self.octave = 0
        self.tremolo = 0
        self.portamento = 0
        self.portamentoTime = 35
        self.envelopeAttack = 0
        self.envelopeDecay = 25
        self.envelopeSustain = 100
        self.envelopeRelease = 0
        self.envelope = 0
        self.vibratoDepth = 0
        self.vibratoCycleLength = 15
        self.vibratoDelay = 0
        self.bendRange = 2
        self.vibratoRate = 5
        self.octaveFlutterAmount = 0
        self.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
        self.envelopeIncrease = false
        self.envelopePace = 0
        self.sweepPace = channel == .pulseA ? 2 : 0
        self.sweepIncrease = false
        self.sweepShift = channel == .pulseA ? 1 : 0
        self.waveVolume = 0
        self.waveShape = 0
        self.waveFilter = 55
        self.waveEnvelope = 35
        self.noiseWidth7Bit = false
        self.noiseClockShift = 3
        self.noiseDivider = 3
        self.panLeft = true
        self.panRight = true
        self.lengthCounter = channel == .drum
        self.muted = false
        self.soloed = false
        self.length = 63
        self.drumVoice = 0
        self.drumSamples = [1, 1, 1, 1]
        self.drumVolumes = [15, 15, 13, 15]
        self.drumLengths = [18, 26, 8, 48]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try container.decodeIfPresent(ByteChannel.self, forKey: .channel) ?? .drum
        self.init(channel: channel)
        duty = try container.decodeIfPresent(Int.self, forKey: .duty) ?? duty
        initialVolume = try container.decodeIfPresent(Int.self, forKey: .initialVolume) ?? initialVolume
        masterVolume = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .masterVolume) ?? masterVolume))
        octave = min(2, max(-2, try container.decodeIfPresent(Int.self, forKey: .octave) ?? octave))
        tremolo = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .tremolo) ?? (try container.decodeIfPresent(Int.self, forKey: .filter) ?? tremolo)))
        portamento = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .portamento) ?? portamento))
        portamentoTime = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .portamentoTime) ?? portamentoTime))
        envelopeAttack = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .envelopeAttack) ?? envelopeAttack))
        envelopeDecay = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .envelopeDecay) ?? (try container.decodeIfPresent(Int.self, forKey: .envelope) ?? envelopeDecay)))
        envelopeSustain = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .envelopeSustain) ?? envelopeSustain))
        envelopeRelease = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .envelopeRelease) ?? envelopeRelease))
        envelope = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .envelope) ?? envelopeDecay))
        vibratoDepth = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .vibratoDepth) ?? vibratoDepth))
        vibratoCycleLength = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .vibratoCycleLength) ?? vibratoCycleLength))
        vibratoDelay = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .vibratoDelay) ?? vibratoDelay))
        bendRange = min(24, max(0, try container.decodeIfPresent(Int.self, forKey: .bendRange) ?? bendRange))
        vibratoRate = min(12, max(1, try container.decodeIfPresent(Int.self, forKey: .vibratoRate) ?? vibratoRate))
        octaveFlutterAmount = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .octaveFlutterAmount) ?? octaveFlutterAmount))
        octaveFlutterPattern = min(ByteOctaveFlutterPattern.allCases.count - 1, max(0, try container.decodeIfPresent(Int.self, forKey: .octaveFlutterPattern) ?? octaveFlutterPattern))
        envelopeIncrease = try container.decodeIfPresent(Bool.self, forKey: .envelopeIncrease) ?? envelopeIncrease
        envelopePace = try container.decodeIfPresent(Int.self, forKey: .envelopePace) ?? envelopePace
        sweepPace = try container.decodeIfPresent(Int.self, forKey: .sweepPace) ?? sweepPace
        sweepIncrease = try container.decodeIfPresent(Bool.self, forKey: .sweepIncrease) ?? sweepIncrease
        sweepShift = try container.decodeIfPresent(Int.self, forKey: .sweepShift) ?? sweepShift
        waveVolume = try container.decodeIfPresent(Int.self, forKey: .waveVolume) ?? waveVolume
        waveShape = min(ByteWaveShape.allCases.count - 1, max(0, try container.decodeIfPresent(Int.self, forKey: .waveShape) ?? waveShape))
        waveFilter = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .waveFilter) ?? waveFilter))
        waveEnvelope = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .waveEnvelope) ?? waveEnvelope))
        noiseWidth7Bit = try container.decodeIfPresent(Bool.self, forKey: .noiseWidth7Bit) ?? noiseWidth7Bit
        noiseClockShift = try container.decodeIfPresent(Int.self, forKey: .noiseClockShift) ?? noiseClockShift
        noiseDivider = try container.decodeIfPresent(Int.self, forKey: .noiseDivider) ?? noiseDivider
        panLeft = try container.decodeIfPresent(Bool.self, forKey: .panLeft) ?? panLeft
        panRight = try container.decodeIfPresent(Bool.self, forKey: .panRight) ?? panRight
        lengthCounter = try container.decodeIfPresent(Bool.self, forKey: .lengthCounter) ?? lengthCounter
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? muted
        soloed = try container.decodeIfPresent(Bool.self, forKey: .soloed) ?? soloed
        length = try container.decodeIfPresent(Int.self, forKey: .length) ?? length
        drumVoice = min(3, max(0, try container.decodeIfPresent(Int.self, forKey: .drumVoice) ?? drumVoice))
        if let samples = try container.decodeIfPresent([Int].self, forKey: .drumSamples), samples.count == 4 {
            drumSamples = samples.map { min(2, max(1, $0)) }
        }
        if let volumes = try container.decodeIfPresent([Int].self, forKey: .drumVolumes), volumes.count == 4 {
            drumVolumes = volumes.map { min(15, max(0, $0)) }
        }
        if let lengths = try container.decodeIfPresent([Int].self, forKey: .drumLengths), lengths.count == 4 {
            drumLengths = lengths.map { min(63, max(1, $0)) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channel, forKey: .channel)
        try container.encode(duty, forKey: .duty)
        try container.encode(initialVolume, forKey: .initialVolume)
        try container.encode(masterVolume, forKey: .masterVolume)
        try container.encode(octave, forKey: .octave)
        try container.encode(tremolo, forKey: .tremolo)
        try container.encode(portamento, forKey: .portamento)
        try container.encode(portamentoTime, forKey: .portamentoTime)
        try container.encode(envelopeAttack, forKey: .envelopeAttack)
        try container.encode(envelopeDecay, forKey: .envelopeDecay)
        try container.encode(envelopeSustain, forKey: .envelopeSustain)
        try container.encode(envelopeRelease, forKey: .envelopeRelease)
        try container.encode(envelope, forKey: .envelope)
        try container.encode(vibratoDepth, forKey: .vibratoDepth)
        try container.encode(vibratoCycleLength, forKey: .vibratoCycleLength)
        try container.encode(vibratoDelay, forKey: .vibratoDelay)
        try container.encode(bendRange, forKey: .bendRange)
        try container.encode(vibratoRate, forKey: .vibratoRate)
        try container.encode(octaveFlutterAmount, forKey: .octaveFlutterAmount)
        try container.encode(octaveFlutterPattern, forKey: .octaveFlutterPattern)
        try container.encode(envelopeIncrease, forKey: .envelopeIncrease)
        try container.encode(envelopePace, forKey: .envelopePace)
        try container.encode(sweepPace, forKey: .sweepPace)
        try container.encode(sweepIncrease, forKey: .sweepIncrease)
        try container.encode(sweepShift, forKey: .sweepShift)
        try container.encode(waveVolume, forKey: .waveVolume)
        try container.encode(waveShape, forKey: .waveShape)
        try container.encode(waveFilter, forKey: .waveFilter)
        try container.encode(waveEnvelope, forKey: .waveEnvelope)
        try container.encode(noiseWidth7Bit, forKey: .noiseWidth7Bit)
        try container.encode(noiseClockShift, forKey: .noiseClockShift)
        try container.encode(noiseDivider, forKey: .noiseDivider)
        try container.encode(panLeft, forKey: .panLeft)
        try container.encode(panRight, forKey: .panRight)
        try container.encode(lengthCounter, forKey: .lengthCounter)
        try container.encode(muted, forKey: .muted)
        try container.encode(soloed, forKey: .soloed)
        try container.encode(length, forKey: .length)
        try container.encode(drumVoice, forKey: .drumVoice)
        try container.encode(drumSamples, forKey: .drumSamples)
        try container.encode(drumVolumes, forKey: .drumVolumes)
        try container.encode(drumLengths, forKey: .drumLengths)
    }

    static var defaults: [ByteChannelPatch] {
        ByteChannel.allCases.map(ByteChannelPatch.init(channel:))
    }
}

struct ByteInstrumentPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let channel: ByteChannel
    let patch: ByteChannelPatch
    let waveform: [Int]

    /// Shared waveform table for the seeded starter sounds. Kept off
    /// ByteProject.starter so building the library can never recursively trigger
    /// starter init.
    static let defaultWaveform: [Int] = [8, 10, 13, 15, 14, 12, 9, 6, 3, 1, 0, 1, 3, 6, 9, 12, 14, 13, 11, 8, 5, 2, 1, 2, 4, 7, 10, 13, 15, 14, 11, 8]

    /// Hand-tuned starter patches. No longer a user-facing Sound Lab bank — the
    /// presets exist so ByteProject.starter can seed its channels with sounds that
    /// map to parameters the live audio engine actually renders.
    static func library(for channel: ByteChannel) -> [ByteInstrumentPreset] {
        switch channel {
        case .pulseA:
            return [
                tuned("chipLead", "CHIP LEAD", channel) { p in
                    p.duty = 1
                    p.initialVolume = 15
                    p.envelopeDecay = 22
                    p.envelopeSustain = 100
                    p.envelopeRelease = 14
                    p.vibratoDepth = 26
                    p.vibratoCycleLength = 50
                    p.vibratoDelay = 30
                },
                tuned("laser", "LASER", channel) { p in
                    p.duty = 0
                    p.initialVolume = 15
                    p.envelopeAttack = 2
                    p.envelopeDecay = 55
                    p.envelopeSustain = 30
                    p.sweepPace = 2
                    p.sweepShift = 3
                    p.sweepIncrease = false
                },
                tuned("coin", "COIN", channel) { p in
                    p.duty = 0
                    p.initialVolume = 15
                    p.envelopeDecay = 40
                    p.envelopeSustain = 20
                    p.envelopeRelease = 8
                    p.sweepPace = 2
                    p.sweepShift = 4
                    p.sweepIncrease = true
                },
                tuned("zap", "ZAP", channel) { p in
                    p.duty = 0
                    p.initialVolume = 15
                    p.envelopeDecay = 70
                    p.envelopeSustain = 15
                    p.sweepPace = 3
                    p.sweepShift = 5
                    p.sweepIncrease = false
                },
                tuned("bell", "BELL", channel) { p in
                    p.duty = 3
                    p.initialVolume = 15
                    p.envelopeAttack = 18
                    p.envelopeDecay = 15
                    p.envelopeSustain = 95
                    p.envelopeRelease = 60
                    p.vibratoDepth = 12
                    p.vibratoCycleLength = 40
                    p.vibratoDelay = 10
                },
                tuned("arp16", "ARP 16TH", channel) { p in
                    p.duty = 1
                    p.initialVolume = 14
                    p.envelopeDecay = 45
                    p.envelopeSustain = 40
                    p.envelopeRelease = 4
                    p.octaveFlutterAmount = 16
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
                },
                tuned("ghost", "GHOST", channel) { p in
                    p.duty = 2
                    p.initialVolume = 14
                    p.envelopeSustain = 90
                    p.envelopeRelease = 10
                    p.octaveFlutterAmount = 8
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUpTwoUp.rawValue
                    p.vibratoDepth = 18
                    p.vibratoCycleLength = 60
                    p.portamento = 30
                    p.portamentoTime = 45
                    p.bendRange = 4
                },
                tuned("sawChip", "SAW CHIP", channel) { p in
                    p.duty = 2
                    p.initialVolume = 15
                    p.envelopeDecay = 15
                    p.envelopeSustain = 100
                    p.envelopeRelease = 10
                    p.vibratoDepth = 30
                    p.vibratoCycleLength = 40
                    p.vibratoDelay = 20
                    p.tremolo = 12
                },
                tuned("siren", "SIREN", channel) { p in
                    p.duty = 1
                    p.initialVolume = 14
                    p.envelopeAttack = 8
                    p.envelopeSustain = 100
                    p.vibratoDepth = 55
                    p.vibratoCycleLength = 85
                    p.portamento = 55
                    p.portamentoTime = 70
                    p.bendRange = 12
                },
                tuned("tremPulse", "TREM PULSE", channel) { p in
                    p.duty = 1
                    p.initialVolume = 15
                    p.envelopeAttack = 2
                    p.envelopeDecay = 15
                    p.envelopeSustain = 100
                    p.envelopeRelease = 10
                    p.tremolo = 60
                }
            ]
        case .pulseB:
            return [
                tuned("bassDub", "BASS DUB", channel) { p in
                    p.duty = 2
                    p.initialVolume = 15
                    p.octave = -1
                    p.envelopeAttack = 3
                    p.envelopeDecay = 38
                    p.envelopeSustain = 70
                    p.envelopeRelease = 6
                    p.portamento = 35
                    p.portamentoTime = 40
                    p.bendRange = 2
                },
                tuned("subBass", "SUB BASS", channel) { p in
                    p.duty = 2
                    p.initialVolume = 15
                    p.octave = -1
                    p.envelopeAttack = 2
                    p.envelopeDecay = 12
                    p.envelopeSustain = 100
                    p.envelopeRelease = 2
                },
                tuned("pluck", "PLUCK", channel) { p in
                    p.duty = 0
                    p.initialVolume = 14
                    p.envelopeDecay = 65
                    p.envelopeSustain = 25
                    p.envelopeRelease = 6
                    p.portamento = 25
                    p.portamentoTime = 30
                    p.bendRange = 3
                },
                tuned("chordStab", "CHORD STAB", channel) { p in
                    p.duty = 1
                    p.initialVolume = 12
                    p.envelopeAttack = 2
                    p.envelopeDecay = 45
                    p.envelopeSustain = 45
                    p.envelopeRelease = 15
                },
                tuned("marimba", "MARIMBA", channel) { p in
                    p.duty = 0
                    p.initialVolume = 13
                    p.envelopeDecay = 72
                    p.envelopeSustain = 18
                    p.envelopeRelease = 18
                    p.portamento = 30
                    p.portamentoTime = 25
                    p.bendRange = 4
                },
                tuned("warmLead", "WARM LEAD", channel) { p in
                    p.duty = 3
                    p.initialVolume = 13
                    p.envelopeAttack = 6
                    p.envelopeDecay = 18
                    p.envelopeSustain = 100
                    p.envelopeRelease = 16
                    p.vibratoDepth = 22
                    p.vibratoCycleLength = 55
                    p.vibratoDelay = 35
                },
                tuned("squareBass", "SQUARE BASS", channel) { p in
                    p.duty = 1
                    p.initialVolume = 15
                    p.octave = -1
                    p.envelopeAttack = 2
                    p.envelopeDecay = 42
                    p.envelopeSustain = 55
                    p.envelopeRelease = 4
                },
                tuned("vibe", "VIBE", channel) { p in
                    p.duty = 1
                    p.initialVolume = 14
                    p.envelopeDecay = 15
                    p.envelopeSustain = 95
                    p.envelopeRelease = 20
                    p.vibratoDepth = 42
                    p.vibratoCycleLength = 30
                    p.vibratoDelay = 15
                    p.tremolo = 10
                },
                tuned("arpBass", "ARP BASS", channel) { p in
                    p.duty = 2
                    p.initialVolume = 15
                    p.octave = -1
                    p.envelopeAttack = 2
                    p.envelopeDecay = 30
                    p.envelopeSustain = 60
                    p.octaveFlutterAmount = 16
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
                },
                tuned("organPulse", "ORGAN PULSE", channel) { p in
                    p.duty = 3
                    p.initialVolume = 13
                    p.envelopeAttack = 2
                    p.envelopeDecay = 10
                    p.envelopeSustain = 100
                    p.envelopeRelease = 8
                    p.tremolo = 25
                }
            ]
        case .wave:
            return [
                tuned("waveBass", "WAVE BASS", channel) { p in
                    p.waveShape = ByteWaveShape.waveBass.rawValue
                    p.waveVolume = 0
                    p.octave = -1
                    p.envelopeAttack = 2
                    p.envelopeDecay = 15
                    p.envelopeSustain = 100
                },
                tuned("triLead", "TRI LEAD", channel) { p in
                    p.waveShape = ByteWaveShape.triangle.rawValue
                    p.waveVolume = 0
                    p.envelopeDecay = 15
                    p.envelopeSustain = 95
                    p.envelopeRelease = 12
                    p.vibratoDepth = 26
                    p.vibratoCycleLength = 50
                    p.vibratoDelay = 30
                },
                tuned("organ", "ORGAN", channel) { p in
                    p.waveShape = ByteWaveShape.organ.rawValue
                    p.waveVolume = 1
                    p.envelopeAttack = 3
                    p.envelopeDecay = 10
                    p.envelopeSustain = 100
                    p.envelopeRelease = 8
                    p.tremolo = 15
                },
                tuned("metal", "METAL", channel) { p in
                    p.waveShape = ByteWaveShape.metal.rawValue
                    p.waveVolume = 1
                    p.envelopeDecay = 20
                    p.envelopeSustain = 90
                    p.octaveFlutterAmount = 10
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
                },
                tuned("ramp", "RAMP", channel) { p in
                    p.waveShape = ByteWaveShape.ramp.rawValue
                    p.waveVolume = 1
                    p.envelopeSustain = 100
                    p.portamento = 40
                    p.portamentoTime = 50
                    p.bendRange = 6
                    p.vibratoDepth = 12
                    p.vibratoCycleLength = 45
                },
                tuned("wavePluck", "WAVE PLUCK", channel) { p in
                    p.waveShape = ByteWaveShape.triangle.rawValue
                    p.waveVolume = 0
                    p.envelopeDecay = 65
                    p.envelopeSustain = 22
                    p.envelopeRelease = 8
                },
                tuned("arpWave", "ARP WAVE", channel) { p in
                    p.waveShape = ByteWaveShape.waveBass.rawValue
                    p.waveVolume = 0
                    p.envelopeDecay = 30
                    p.envelopeSustain = 50
                    p.octaveFlutterAmount = 18
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
                },
                tuned("bassFlutter", "BASS FLUTTER", channel) { p in
                    p.waveShape = ByteWaveShape.waveBass.rawValue
                    p.waveVolume = 0
                    p.octave = -1
                    p.envelopeAttack = 2
                    p.envelopeDecay = 25
                    p.envelopeSustain = 80
                    p.octaveFlutterAmount = 12
                    p.octaveFlutterPattern = ByteOctaveFlutterPattern.baseUpTwoUp.rawValue
                },
                tuned("triVibe", "TRI VIBE", channel) { p in
                    p.waveShape = ByteWaveShape.triangle.rawValue
                    p.waveVolume = 0
                    p.envelopeSustain = 100
                    p.envelopeRelease = 22
                    p.vibratoDepth = 48
                    p.vibratoCycleLength = 35
                    p.vibratoDelay = 10
                },
                tuned("rampBass", "RAMP BASS", channel) { p in
                    p.waveShape = ByteWaveShape.ramp.rawValue
                    p.waveVolume = 1
                    p.octave = -1
                    p.envelopeSustain = 100
                    p.portamento = 30
                    p.portamentoTime = 45
                    p.bendRange = 3
                }
            ]
        case .drum:
            return [
                drumPreset("kick", "KICK", channel, width7Bit: false, clockShift: 8, divider: 6, volume: 15, length: 18),
                drumPreset("snare", "SNARE", channel, width7Bit: false, clockShift: 5, divider: 3, volume: 15, length: 26),
                drumPreset("hat", "HI-HAT", channel, width7Bit: true, clockShift: 1, divider: 0, volume: 13, length: 8),
                drumPreset("crash", "CRASH", channel, width7Bit: false, clockShift: 3, divider: 1, volume: 15, length: 48)
            ]
        }
    }

    /// Builds a hand-tuned patch. The optional waveform lets wave presets carry the
    /// exact table for their selected fixed shape.
    private static func tuned(_ id: String, _ name: String, _ channel: ByteChannel, waveform: [Int]? = nil, _ tune: (inout ByteChannelPatch) -> Void) -> ByteInstrumentPreset {
        var patch = ByteChannelPatch(channel: channel)
        tune(&patch)
        let table: [Int]
        if let waveform {
            table = waveform
        } else if channel == .wave {
            let shape = ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, patch.waveShape))]
            table = shape.table
        } else {
            table = Self.defaultWaveform
        }
        return ByteInstrumentPreset(id: id, name: name, channel: channel, patch: patch, waveform: table)
    }

    private static func drumPreset(_ id: String, _ name: String, _ channel: ByteChannel, width7Bit: Bool, clockShift: Int, divider: Int, volume: Int, length: Int) -> ByteInstrumentPreset {
        var patch = ByteChannelPatch(channel: channel)
        patch.noiseWidth7Bit = width7Bit
        patch.noiseClockShift = clockShift
        patch.noiseDivider = divider
        patch.initialVolume = volume
        patch.drumVoice = ["kick", "snare", "hat", "crash"].firstIndex(of: id) ?? 0
        patch.drumVolumes[patch.drumVoice] = volume
        patch.drumLengths[patch.drumVoice] = length
        patch.envelopePace = id == "kick" ? 3 : id == "snare" ? 3 : id == "hat" ? 1 : 2
        patch.lengthCounter = true
        patch.length = length
        return ByteInstrumentPreset(id: id, name: name, channel: channel, patch: patch, waveform: Self.defaultWaveform)
    }
}

enum BytePatchParameter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case tone
    case duty
    case envelopeAttack
    case envelopeDecay
    case envelopeSustain
    case envelopeRelease
    case portamento
    case portamentoTime
    case vibratoCycleLength
    case vibratoDepth
    case vibratoDelay
    case octaveFlutterSpeed
    case octaveFlutterPattern
    case bendRange
    case octave
    case tremolo
    case envelope
    case waveShape
    case waveFilter
    case waveEnvelope
    case volume
    case envelopeDirection
    case envelopePace
    case sweepPace
    case sweepDirection
    case sweepShift
    case waveVolume
    case drumSample
    case panLeft
    case panRight
    case lengthCounter
    case length

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tone: return "TONE"
        case .duty: return "DUTY"
        case .envelopeAttack: return "ATTACK"
        case .envelopeDecay: return "DECAY"
        case .envelopeSustain: return "SUSTAIN"
        case .envelopeRelease: return "RELEASE"
        case .portamento: return "PORTAMENTO"
        case .portamentoTime: return "GLIDE TIME"
        case .vibratoCycleLength: return "VIB CYCLE"
        case .vibratoDepth: return "VIB DEPTH"
        case .vibratoDelay: return "VIB DELAY"
        case .octaveFlutterSpeed: return "OCT FLUTTER"
        case .octaveFlutterPattern: return "FLUTTER PATH"
        case .bendRange: return "BEND RANGE"
        case .octave: return "OCTAVE"
        case .tremolo: return "TREMOLO"
        case .envelope: return "ENVELOPE"
        case .waveShape: return "WAVE SHAPE"
        case .waveFilter: return "FILTER"
        case .waveEnvelope: return "ENVELOPE"
        case .volume: return "VOLUME"
        case .envelopeDirection: return "ENV DIR"
        case .envelopePace: return "ENV PACE"
        case .sweepPace: return "SWEEP PACE"
        case .sweepDirection: return "SWEEP DIR"
        case .sweepShift: return "SWEEP STEP"
        case .waveVolume: return "VOLUME SHIFT"
        case .drumSample: return "DRUM SAMPLE"
        case .panLeft: return "PAN LEFT"
        case .panRight: return "PAN RIGHT"
        case .lengthCounter: return "LENGTH GATE"
        case .length: return "LENGTH"
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .tone, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoCycleLength, .vibratoDepth, .vibratoDelay, .octaveFlutterSpeed, .tremolo, .envelope: return 0...100
        case .octaveFlutterPattern: return 0...(ByteOctaveFlutterPattern.allCases.count - 1)
        case .duty: return 0...3
        case .bendRange: return 0...24
        case .octave: return -2...2
        case .waveShape: return 0...(ByteWaveShape.allCases.count - 1)
        case .waveFilter, .waveEnvelope: return 0...100
        case .volume: return 0...15
        case .envelopeDirection, .sweepDirection, .panLeft, .panRight, .lengthCounter: return 0...100
        case .envelopePace, .sweepPace, .sweepShift: return 0...7
        case .waveVolume: return 0...3
        case .drumSample: return 1...2
        case .length: return 0...63
        }
    }
}

/// Musical response curve shared by faders and sends. Perceptual loudness is roughly
/// logarithmic, so a linear 0–100 knob wastes the bottom of its travel. The square-root
/// taper boosts low percentages: 25% of fader travel now delivers 50% of the gain, which
/// keeps quiet settings audible and gives the top of the range fine control.
enum ByteAudioTaper {
    static func gain(for percent: Int) -> Double {
        let clamped = Double(min(100, max(0, percent)))
        return pow(clamped / 100.0, 0.5)
    }
}

struct ByteEffects: Codable, Hashable, Sendable {
    /// Bit Crush is intentionally softened: UI 0–100 maps to the former effective 0–25 range.
    static func bitCrushEffectiveAmount(for amount: Int) -> Double {
        Double(min(100, max(0, amount))) * 0.25
    }

    /// Converts the softened Bit Crush response into a stable quantizer resolution.
    static func bitCrushLevels(for effectiveAmount: Double) -> Double {
        max(1.0, 16.0 - min(25.0, max(0.0, effectiveAmount)) / 100.0 * 14.0)
    }

    /// Holds crushed samples slightly longer as the control rises for audible downsampling.
    static func bitCrushHoldFrames(for amount: Int) -> Int {
        let clamped = min(100, max(0, amount))
        return max(1, 18 - (clamped * 17 / 100))
    }

    /// Legacy FX helper retained for old projects; channel patches now own flutter settings.
    static func octaveFlutterDivision(for amount: Int) -> Int {
        let clamped = min(100, max(0, amount))
        guard clamped > 0 else { return 0 }
        return min(4, (clamped - 1) / 20)
    }

    static func octaveFlutterDivisionTitle(for amount: Int) -> String {
        ["OFF", "1/16", "1/32", "1/64", "1/128", "1/256"][octaveFlutterDivision(for: amount) + (amount > 0 ? 1 : 0)]
    }

    /// Returns a hard, tempo-synced octave arpeggio multiplier.
    static func octaveFlutterMultiplier(
        at time: Double,
        bpm: Int,
        amount: Int,
        pattern: ByteOctaveFlutterPattern = .baseUp
    ) -> Double {
        guard amount > 0 else { return 1.0 }
        let divisionBeats = [0.25, 0.125, 0.0625, 0.03125, 0.015625][octaveFlutterDivision(for: amount)]
        let divisionDuration = 60.0 / Double(max(1, bpm)) * divisionBeats
        let index = Int(max(0, time) / max(0.001, divisionDuration)) % pattern.octaveSteps.count
        return pow(2.0, Double(pattern.octaveSteps[index]))
    }

    // Amounts are percentages so the FX Station can behave like compact hardware knobs.
    // The booleans and retired fields remain for project-file compatibility with older builds.
    var echo = false
    var echoAmount = 0
    var bitCrush = false
    var bitCrushAmount = 0
    var vibrato = false
    var vibratoAmount = 0
    var octaveFlutterPattern = ByteOctaveFlutterPattern.baseUp.rawValue
    // Legacy fields remain Codable so older projects still open, but they are no longer active.
    var widePulse = false
    var widePulseAmount = 0
    /// Per-channel effect sends: Pulse, Square, Triangle, Drum.
    /// 100 preserves the original global-FX behavior for older projects.
    var channelSends = [100, 100, 100, 100]
    /// Retained as a retired legacy field for older project files.
    var delay = 0

    private enum CodingKeys: String, CodingKey {
        case echo, echoAmount, bitCrush, bitCrushAmount, vibrato, vibratoAmount, octaveFlutterPattern, widePulse, widePulseAmount, channelSends, delay
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        echo = try container.decodeIfPresent(Bool.self, forKey: .echo) ?? false
        echoAmount = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .echoAmount) ?? (echo ? 100 : 0)))
        bitCrush = try container.decodeIfPresent(Bool.self, forKey: .bitCrush) ?? false
        bitCrushAmount = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .bitCrushAmount) ?? (bitCrush ? 100 : 0)))
        vibrato = try container.decodeIfPresent(Bool.self, forKey: .vibrato) ?? false
        vibratoAmount = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .vibratoAmount) ?? (vibrato ? 100 : 0)))
        octaveFlutterPattern = min(ByteOctaveFlutterPattern.allCases.count - 1, max(0, try container.decodeIfPresent(Int.self, forKey: .octaveFlutterPattern) ?? ByteOctaveFlutterPattern.baseUp.rawValue))
        widePulse = try container.decodeIfPresent(Bool.self, forKey: .widePulse) ?? false
        widePulseAmount = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .widePulseAmount) ?? (widePulse ? 100 : 0)))
        if let sends = try container.decodeIfPresent([Int].self, forKey: .channelSends), sends.count == ByteChannel.allCases.count {
            channelSends = sends.map { min(100, max(0, $0)) }
        }
        // Delay is a retired legacy field; keep decoding it harmless for old projects.
        _ = try container.decodeIfPresent(Int.self, forKey: .delay)
        delay = 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(echoAmount > 0, forKey: .echo)
        try container.encode(echoAmount, forKey: .echoAmount)
        try container.encode(bitCrushAmount > 0, forKey: .bitCrush)
        try container.encode(bitCrushAmount, forKey: .bitCrushAmount)
        try container.encode(vibratoAmount > 0, forKey: .vibrato)
        try container.encode(vibratoAmount, forKey: .vibratoAmount)
        try container.encode(octaveFlutterPattern, forKey: .octaveFlutterPattern)
        try container.encode(widePulseAmount > 0, forKey: .widePulse)
        try container.encode(widePulseAmount, forKey: .widePulseAmount)
        try container.encode(channelSends.map { min(100, max(0, $0)) }, forKey: .channelSends)
        // Preserve the legacy key without enabling the retired delay implementation.
        try container.encode(0, forKey: .delay)
    }

    func contains(_ effect: ByteEffect) -> Bool {
        switch effect {
        case .echo: return echoAmount > 0
        case .bitCrush: return bitCrushAmount > 0
        }
    }

    mutating func toggle(_ effect: ByteEffect) {
        switch effect {
        case .echo: echoAmount = echoAmount > 0 ? 0 : 100; echo = echoAmount > 0
        case .bitCrush: bitCrushAmount = bitCrushAmount > 0 ? 0 : 100; bitCrush = bitCrushAmount > 0
        }
    }
}

struct BytePattern: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Each pattern can be one or two bars while the project remains backward compatible.
    var loopLength: Int
    var steps: [[Int?]]
    /// Duration, in sixteenth-note steps, for each note start. Covered cells are kept empty.
    var noteLengths: [[Int]]

    init(id: UUID = UUID(), name: String = "PATTERN 01", loopLength: Int? = nil, steps: [[Int?]]? = nil, noteLengths: [[Int]]? = nil) {
        self.id = id
        self.name = name
        self.loopLength = 16
        self.steps = steps ?? BytePattern.starterSteps()
        self.noteLengths = BytePattern.normalizedLengths(noteLengths ?? BytePattern.defaultLengths(), stepCount: 16)
        resize(to: 16)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, loopLength, steps, noteLengths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decode([[Int?]].self, forKey: .steps)
        loopLength = 16
        // Older or hand-edited project files may contain extra rows or cells. Normalize both
        // dimensions here so every downstream editor and renderer can rely on four rows x 16.
        let decodedLengths = try container.decodeIfPresent([[Int]].self, forKey: .noteLengths)
        noteLengths = BytePattern.normalizedLengths(decodedLengths ?? BytePattern.defaultLengths(), stepCount: 16)
        resize(to: 16)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(loopLength, forKey: .loopLength)
        try container.encode(steps, forKey: .steps)
        try container.encode(noteLengths, forKey: .noteLengths)
    }

    static func starterSteps() -> [[Int?]] {
        ByteChannel.allCases.map { channel in
            (0..<16).map { step in
                guard step % 4 == 0 else { return nil }
                return channel.defaultNotes[(step / 4) % channel.defaultNotes.count]
            }
        }
    }

    /// Replaces one melodic row with a compact two-octave idea: scale-safe notes,
    /// rests, and short stepped holds. The injected picker keeps this logic testable.
    mutating func randomizeMelody(
        channel: ByteChannel,
        key: Int,
        mode: ByteScaleMode,
        nextInt: (ClosedRange<Int>) -> Int
    ) {
        guard channel != .drum,
              let row = ByteChannel.allCases.firstIndex(of: channel) else { return }

        // Keep generated ideas in the comfortable C3–C5 register. The key/mode chooses
        // the pitch classes inside that range rather than shifting the whole melody upward.
        let lowerBound = 48
        let upperBound = 72
        let scaleNotes = Array(lowerBound...upperBound).filter { note in
            guard let intervals = mode.intervals else { return true }
            let pitchClass = ((note - key) % 12 + 12) % 12
            return intervals.contains(pitchClass)
        }
        let availableNotes = scaleNotes.isEmpty ? Array(lowerBound...upperBound) : scaleNotes
        steps[row] = Array(repeating: nil, count: 16)
        noteLengths[row] = Array(repeating: 1, count: 16)

        var step = 0
        var previousNoteIndex: Int?
        while step < 16 {
            // Rests leave room for the rhythm to breathe without making the line empty.
            if nextInt(0...99) < 22 {
                step += 1
                continue
            }

            let center = previousNoteIndex ?? availableNotes.count / 2
            let window = min(3, availableNotes.count - 1)
            let minimum = max(0, center - window)
            let maximum = min(availableNotes.count - 1, center + window)
            let noteIndex = nextInt(minimum...maximum)
            let safeIndex = min(availableNotes.count - 1, max(0, noteIndex))
            let note = availableNotes[safeIndex]
            previousNoteIndex = safeIndex

            let remaining = min(4, 16 - step)
            let length: Int
            if remaining < 2 {
                length = 1
            } else {
                length = nextInt(0...99) < 72 ? 1 : min(remaining, max(2, nextInt(2...remaining)))
            }
            steps[row][step] = note
            noteLengths[row][step] = length
            step += length
        }
    }

    static func empty(name: String) -> BytePattern {
        BytePattern(name: name, steps: ByteChannel.allCases.map { _ in Array(repeating: nil, count: 16) })
    }

    static func defaultLengths() -> [[Int]] {
        ByteChannel.allCases.map { _ in Array(repeating: 1, count: 16) }
    }

    private static func normalizedLengths(_ values: [[Int]], stepCount: Int = 16) -> [[Int]] {
        let count = 16
        return ByteChannel.allCases.indices.map { channel in
            (0..<count).map { step in
                let value = values.indices.contains(channel) && values[channel].indices.contains(step) ? values[channel][step] : 1
                return min(count, max(1, value))
            }
        }
    }

    mutating func resize(to stepCount: Int) {
        let count = 16
        loopLength = count
        // Always discard unknown channel rows before filling missing rows. This protects
        // renderers and editors from malformed or legacy data with a different row count.
        steps = Array(steps.prefix(ByteChannel.allCases.count))
        while steps.count < ByteChannel.allCases.count {
            steps.append(Array(repeating: nil, count: count))
        }
        for channel in ByteChannel.allCases.indices {
            if steps[channel].count < count {
                steps[channel].append(contentsOf: Array(repeating: nil, count: count - steps[channel].count))
            } else if steps[channel].count > count {
                steps[channel] = Array(steps[channel].prefix(count))
            }
        }
        noteLengths = BytePattern.normalizedLengths(noteLengths, stepCount: count)
        for channel in ByteChannel.allCases.indices {
            for step in 0..<count {
                noteLengths[channel][step] = min(count - step, max(1, noteLengths[channel][step]))
            }
        }
    }
}

struct ByteSongSlot: Codable, Hashable, Sendable {
    var patternID: UUID?
    var isContinuation: Bool

    static let empty = ByteSongSlot(patternID: nil, isContinuation: false)
}

struct ByteProject: Codable, Hashable, Identifiable, Sendable {
    static let maximumPatternCount = 16
    static let songArrangementLengths = [16, 32, 64]

    var id: UUID
    var name: String
    var tempo: Int
    /// The active sequencer length. Existing projects default to a classic 16-step loop.
    var loopLength: Int
    /// Global melodic voicing. Key is MIDI pitch class: C = 0 through B = 11.
    var key: Int
    var mode: ByteScaleMode
    var patterns: [BytePattern]
    var arrangement: [UUID]
    /// Song Mode slots play in reading order. A continuation slot belongs to the 32-step slot before it.
    var songArrangement: [ByteSongSlot]
    /// Number of bars visible and played by Song Mode. Legacy projects default to 16.
    var songArrangementLength: Int
    /// Song Mode can be enabled independently so older projects keep their pattern-list playback.
    var songModeEnabled: Bool
    /// Exactly 32 four-bit samples, stored as integers from 0 through 15.
    var waveform: [Int]
    var channelPatches: [ByteChannelPatch]
    var effects: ByteEffects
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "UNTITLED QUEST",
        tempo: Int = 132,
        loopLength: Int = 16,
        songArrangementLength: Int = 16,
        key: Int = 0,
        mode: ByteScaleMode = .chromatic,
        patterns: [BytePattern] = [BytePattern()],
        arrangement: [UUID]? = nil,
        waveform: [Int] = [8, 10, 13, 15, 14, 12, 9, 6, 3, 1, 0, 1, 3, 6, 9, 12, 14, 13, 11, 8, 5, 2, 1, 2, 4, 7, 10, 13, 15, 14, 11, 8],
        channelPatches: [ByteChannelPatch] = ByteChannelPatch.defaults,
        effects: ByteEffects = ByteEffects(),
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.tempo = tempo
        self.loopLength = 16
        self.songArrangementLength = Self.normalizedSongArrangementLength(songArrangementLength)
        self.key = min(11, max(0, key))
        self.mode = mode
        var resizedPatterns = Array(patterns.prefix(Self.maximumPatternCount))
        if resizedPatterns.isEmpty {
            resizedPatterns = [BytePattern.empty(name: "PATTERN 01")]
        }
        for index in resizedPatterns.indices { resizedPatterns[index].resize(to: 16) }
        self.patterns = resizedPatterns
        self.arrangement = Self.normalizedArrangement(arrangement ?? resizedPatterns.map(\.id), patterns: resizedPatterns)
        self.songArrangement = Array(repeating: .empty, count: self.songArrangementLength)
        if let first = resizedPatterns.first { self.songArrangement[0] = ByteSongSlot(patternID: first.id, isContinuation: false) }
        self.songModeEnabled = false
        self.waveform = Array(waveform.prefix(32)) + Array(repeating: 8, count: max(0, 32 - waveform.count))
        self.channelPatches = channelPatches.count == ByteChannel.allCases.count ? channelPatches : ByteChannelPatch.defaults
        self.effects = effects
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Default project: a ready-to-play groove in C major. Two patterns seed a two-bar
    /// song with preset patches and a light echo, so the very first play already sounds
    /// like a track instead of an empty grid.
    ///
    /// New installs open `blank` instead; `starter` remains as the demo document used
    /// by tests, previews, and the fallback waveform seed.
    static let starter: ByteProject = {
        let groove = BytePattern(
            name: "GROOVE",
            steps: [
                // PULSE 1 — eighth-note lead motif in C major: E G A C5 A G E D.
                [64, nil, 67, nil, 69, nil, 72, nil, 69, nil, 67, nil, 64, nil, 62, 67],
                // PULSE 2 — quarter-note bass: C G F G.
                [36, nil, nil, nil, 43, nil, nil, nil, 41, nil, nil, nil, 43, nil, nil, nil],
                // TRIANGLE — held root and fifth an octave up.
                [48, nil, nil, nil, nil, nil, nil, nil, 55, nil, nil, nil, nil, nil, nil, nil],
                // DRUM — kick on 0/8, snare on 4/12, offbeat hats.
                [36, nil, 42, nil, 38, nil, 42, nil, 36, nil, 42, nil, 38, nil, 42, nil]
            ],
            noteLengths: [
                [1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1],
                [4, 1, 1, 1, 4, 1, 1, 1, 4, 1, 1, 1, 4, 1, 1, 1],
                [8, 1, 1, 1, 1, 1, 1, 1, 8, 1, 1, 1, 1, 1, 1, 1],
                [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
            ]
        )
        let breakdown = BytePattern(
            name: "BREAK",
            steps: [
                // PULSE 1 — sparse C5 A G E line with a pickup.
                [72, nil, nil, nil, 69, nil, nil, nil, 67, nil, nil, nil, 64, nil, nil, 67],
                // PULSE 2 — longer bass tones.
                [36, nil, nil, nil, nil, nil, 43, nil, nil, nil, nil, nil, 36, nil, nil, nil],
                // TRIANGLE — one sustained root.
                [48, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil],
                // DRUM — four-on-the-floor kick, snare on 2/10, hats on 6/14.
                [36, nil, 38, nil, 36, nil, 42, nil, 36, nil, 38, nil, 36, nil, 42, nil]
            ],
            noteLengths: [
                [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
                [6, 1, 1, 1, 1, 1, 6, 1, 1, 1, 1, 1, 4, 1, 1, 1],
                [16, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
                [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
            ]
        )

        var project = ByteProject(
            name: "FIRST BEAT",
            tempo: 138,
            key: 0,
            mode: .major,
            patterns: [groove, breakdown]
        )
        // Hand-tuned starter sounds (from the seed library) so the groove sounds
        // right immediately.
        var patches = ByteChannelPatch.defaults
        if let lead = ByteInstrumentPreset.library(for: .pulseA).first(where: { $0.id == "chipLead" }) { patches[0] = lead.patch }
        if let bass = ByteInstrumentPreset.library(for: .pulseB).first(where: { $0.id == "bassDub" }) { patches[1] = bass.patch }
        if let triangle = ByteInstrumentPreset.library(for: .wave).first(where: { $0.id == "waveBass" }) { patches[2] = triangle.patch }
        // Balanced quick mix; the square-root taper keeps these settings musical.
        patches[0].masterVolume = 58
        patches[1].masterVolume = 62
        patches[2].masterVolume = 60
        patches[3].masterVolume = 66
        project.channelPatches = patches

        // Light echo on the lead and drums; bass stays mostly dry.
        project.effects.echoAmount = 22
        project.effects.echo = true
        project.effects.channelSends = [52, 30, 42, 68]

        // Seed Song Mode with a two-bar idea: GROOVE then BREAK. The remaining slots
        // stay empty so a new user learns to build the arrangement themselves.
        let a = groove.id
        let b = breakdown.id
        project.arrangement = [a, b]
        project.songArrangement = (0..<16).map { index in
            let patternID: UUID? = index == 0 ? a : (index == 1 ? b : nil)
            return ByteSongSlot(patternID: patternID, isContinuation: false)
        }
        return project
    }()

    /// First-launch project: a truly empty single pattern, so a new user opens onto a
    /// silent drum-pad grid and builds from scratch rather than hearing the demo groove.
    static let blank: ByteProject = {
        var project = ByteProject(name: "FIRST BEAT", patterns: [BytePattern.empty(name: "PATTERN 01")])
        project.channelPatches = ByteChannelPatch.defaults
        return project
    }()

    var arrangedPatterns: [BytePattern] {
        let lookup = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) })
        let result = arrangement.compactMap { lookup[$0] }
        return result.isEmpty ? patterns : result
    }

    /// Returns one playback bar for every arrangement slot through the last assigned
    /// pattern. Empty bars between patterns stay silent rather than compacted away, so
    /// bar numbers hold — but trailing empty slots are excluded, so a short arrangement
    /// loops on its music instead of playing dead air. Silence is structural only when
    /// a later slot carries a pattern again.
    var songPatterns: [BytePattern] {
        let lookup = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) })
        let slots = songArrangement.prefix(songArrangementLength)
        guard let lastAssigned = slots.lastIndex(where: { !$0.isContinuation && $0.patternID != nil && lookup[$0.patternID!] != nil }) else {
            return []
        }
        return slots.prefix(through: lastAssigned).map { slot in
            guard !slot.isContinuation, let patternID = slot.patternID, let pattern = lookup[patternID] else {
                return BytePattern.empty(name: "EMPTY BAR")
            }
            return pattern
        }
    }

    /// Each playback pattern maps directly to its arrangement bar, including structural
    /// silent bars. Mirrors the songPatterns trim so playback always covers real music.
    var songSlotIndices: [Int] {
        Array(0..<songPatterns.count)
    }

    var hasAssignedSongPattern: Bool {
        songArrangement.prefix(songArrangementLength).contains { $0.patternID != nil && !$0.isContinuation }
    }

    /// Returns the selected pattern for Beatpad and Sound Lab playback.
    var playbackPatterns: [BytePattern] {
        [patterns.first ?? BytePattern()]
    }

    func pattern(with id: UUID) -> BytePattern? {
        patterns.first(where: { $0.id == id })
    }

    private static func normalizedSongArrangementLength(_ value: Int) -> Int {
        songArrangementLengths.min(by: { abs($0 - value) < abs($1 - value) }) ?? 16
    }

    private static func normalizedArrangement(_ arrangement: [UUID], patterns: [BytePattern]) -> [UUID] {
        let validIDs = Set(patterns.map(\.id))
        let filtered = arrangement.filter { validIDs.contains($0) }
        return filtered.isEmpty ? patterns.map(\.id) : filtered
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tempo, loopLength, songArrangementLength, key, mode, patterns, arrangement, songArrangement, songModeEnabled, waveform, channelPatches, effects, createdAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tempo = try container.decode(Int.self, forKey: .tempo)
        loopLength = 16
        songArrangementLength = Self.normalizedSongArrangementLength(try container.decodeIfPresent(Int.self, forKey: .songArrangementLength) ?? 16)
        key = min(11, max(0, try container.decodeIfPresent(Int.self, forKey: .key) ?? 0))
        mode = try container.decodeIfPresent(ByteScaleMode.self, forKey: .mode) ?? .chromatic
        patterns = Array(try container.decode([BytePattern].self, forKey: .patterns).prefix(Self.maximumPatternCount))
        if patterns.isEmpty {
            patterns = [BytePattern.empty(name: "PATTERN 01")]
        }
        for index in patterns.indices { patterns[index].resize(to: 16) }
        let decodedArrangement = try container.decodeIfPresent([UUID].self, forKey: .arrangement) ?? []
        arrangement = Self.normalizedArrangement(decodedArrangement, patterns: patterns)
        let validPatternIDs = Set(patterns.map(\.id))
        let decodedSongArrangement = try container.decodeIfPresent([ByteSongSlot].self, forKey: .songArrangement) ?? Array(repeating: .empty, count: songArrangementLength)
        songArrangement = decodedSongArrangement.prefix(songArrangementLength).map { slot in
            guard !slot.isContinuation, let patternID = slot.patternID, validPatternIDs.contains(patternID) else { return .empty }
            return ByteSongSlot(patternID: patternID, isContinuation: false)
        }
        if songArrangement.count < songArrangementLength { songArrangement.append(contentsOf: Array(repeating: .empty, count: songArrangementLength - songArrangement.count)) }
        songModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .songModeEnabled) ?? false

        if let values = try? container.decode([Int].self, forKey: .waveform) {
            waveform = values
        } else if let oldValues = try? container.decode([Double].self, forKey: .waveform) {
            waveform = oldValues.map { min(15, max(0, Int((($0 + 1.0) * 7.5).rounded()))) }
        } else {
            waveform = ByteProject.starter.waveform
        }
        channelPatches = try container.decodeIfPresent([ByteChannelPatch].self, forKey: .channelPatches) ?? ByteChannelPatch.defaults
        effects = try container.decodeIfPresent(ByteEffects.self, forKey: .effects) ?? ByteEffects()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        waveform = Array(waveform.prefix(32)) + Array(repeating: 8, count: max(0, 32 - waveform.count))
        if channelPatches.count != ByteChannel.allCases.count { channelPatches = ByteChannelPatch.defaults }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tempo, forKey: .tempo)
        try container.encode(loopLength, forKey: .loopLength)
        try container.encode(songArrangementLength, forKey: .songArrangementLength)
        try container.encode(key, forKey: .key)
        try container.encode(mode, forKey: .mode)
        try container.encode(patterns, forKey: .patterns)
        try container.encode(arrangement, forKey: .arrangement)
        try container.encode(songArrangement, forKey: .songArrangement)
        try container.encode(songModeEnabled, forKey: .songModeEnabled)
        try container.encode(waveform, forKey: .waveform)
        try container.encode(channelPatches, forKey: .channelPatches)
        try container.encode(effects, forKey: .effects)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

// MARK: - Files

extension UTType {
    static let bytePocketProject = UTType(exportedAs: "com.bytepocket.project")
    static let bytePocketWave = UTType(filenameExtension: "wav") ?? .data
}

struct ByteProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.bytePocketProject, .json] }
    var project: ByteProject

    init(project: ByteProject = .starter) { self.project = project }

    init(configuration: ReadConfiguration) throws {
        project = try JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder.bytePocketEncoder.encode(project))
    }
}

struct ByteWaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.bytePocketWave] }
    let data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension JSONEncoder {
    static var bytePocketEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bytePocketDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
