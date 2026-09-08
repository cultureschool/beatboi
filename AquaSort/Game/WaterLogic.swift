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
        case .pulseA: return "PULSE"
        case .pulseB: return "SQUARE"
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
}

enum ByteEffect: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case echo
    case bitCrush
    case vibrato
    case widePulse
    case delay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .echo: return "ECHO"
        case .bitCrush: return "BIT CRUSH"
        case .vibrato: return "VIBRATO"
        case .widePulse: return "WIDE PULSE"
        case .delay: return "DELAY"
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
    /// Drum voice used by the Sound Lab selector: 0 kick, 1 snare, 2 hi-hat, 3 crash.
    var drumVoice: Int
    /// Selected supplied sample (1 or 2) for kick, snare, hi-hat, and perc.
    var drumSamples: [Int]
    /// Retained for project compatibility; supplied one-shots no longer expose these controls.
    var drumVolumes: [Int]
    var drumLengths: [Int]

    private enum CodingKeys: String, CodingKey {
        case channel, duty, initialVolume, masterVolume, octave, tremolo, portamento, portamentoTime, envelopeAttack, envelopeDecay, envelopeSustain, envelopeRelease, filter, envelope, vibratoDepth, vibratoCycleLength, vibratoDelay, bendRange, vibratoRate, envelopeIncrease, envelopePace, sweepPace, sweepIncrease, sweepShift
        case waveVolume, waveShape, waveFilter, waveEnvelope, noiseWidth7Bit, noiseClockShift, noiseDivider, panLeft, panRight, lengthCounter, length
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

    static func library(for channel: ByteChannel) -> [ByteInstrumentPreset] {
        switch channel {
        case .pulseA:
            return [
                preset("lead", "LEAD", channel, duty: 1, volume: 15, envelopePace: 0, sweepPace: 0, sweepShift: 0),
                preset("laser", "LASER", channel, duty: 0, volume: 15, envelopePace: 2, sweepPace: 2, sweepIncrease: false, sweepShift: 3),
                preset("jump", "JUMP", channel, duty: 2, volume: 14, envelopePace: 1, sweepPace: 3, sweepIncrease: true, sweepShift: 2),
                preset("arp", "ARPEGGIO", channel, duty: 1, volume: 13, envelopePace: 0, sweepPace: 0, sweepShift: 0),
                preset("bell", "BELL", channel, duty: 3, volume: 12, envelopePace: 3, sweepPace: 1, sweepIncrease: true, sweepShift: 1),
                preset("coin", "COIN", channel, duty: 0, volume: 14, envelopePace: 1, sweepPace: 2, sweepIncrease: true, sweepShift: 2),
                preset("zap", "ZAP", channel, duty: 0, volume: 15, envelopePace: 1, sweepPace: 1, sweepIncrease: false, sweepShift: 5)
            ]
        case .pulseB:
            return [
                preset("bass", "BASS", channel, duty: 2, volume: 15, envelopePace: 0),
                preset("pluck", "PLUCK", channel, duty: 0, volume: 14, envelopePace: 2),
                preset("chord", "CHORD STAB", channel, duty: 1, volume: 12, envelopePace: 3),
                preset("warm", "WARM LEAD", channel, duty: 3, volume: 13, envelopePace: 1),
                preset("sub", "SUB BASS", channel, duty: 2, volume: 15, envelopePace: 0),
                preset("marimba", "MARIMBA", channel, duty: 0, volume: 13, envelopePace: 2),
                preset("wide", "WIDE PULSE", channel, duty: 3, volume: 12, envelopePace: 1)
            ]
        case .wave:
            return [
                wavePreset("waveBass", "WAVE BASS", channel, [8, 10, 12, 14, 15, 14, 12, 10, 8, 6, 4, 2, 1, 2, 4, 6, 8, 10, 12, 14, 15, 14, 12, 10, 8, 6, 4, 2, 1, 2, 4, 6], volume: 0),
                wavePreset("triangle", "TRIANGLE", channel, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0], volume: 0),
                wavePreset("organ", "ORGAN", channel, [8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4, 8, 12, 14, 12, 8, 4, 2, 4], volume: 1),
                wavePreset("metal", "METAL", channel, [8, 15, 2, 13, 1, 12, 3, 14, 0, 15, 4, 11, 2, 13, 1, 14, 8, 0, 13, 2, 15, 3, 12, 1, 14, 4, 11, 2, 15, 0, 13, 3], volume: 1),
                wavePreset("ramp", "RAMP", channel, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], volume: 2),
                wavePreset("pluck", "PLUCK WAVE", channel, [8, 15, 14, 10, 5, 2, 1, 2, 4, 7, 10, 12, 13, 12, 10, 8, 8, 6, 4, 2, 1, 2, 4, 7, 10, 12, 13, 12, 10, 8, 8, 8], volume: 1),
                wavePreset("pulse", "PULSE WAVE", channel, [8, 15, 15, 15, 8, 0, 0, 0, 8, 15, 15, 15, 8, 0, 0, 0, 8, 15, 15, 15, 8, 0, 0, 0, 8, 15, 15, 15, 8, 0, 0, 0], volume: 0)
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

    private static func preset(_ id: String, _ name: String, _ channel: ByteChannel, duty: Int, volume: Int, envelopePace: Int, sweepPace: Int = 0, sweepIncrease: Bool = false, sweepShift: Int = 0) -> ByteInstrumentPreset {
        var patch = ByteChannelPatch(channel: channel)
        patch.duty = duty
        patch.initialVolume = volume
        patch.envelopePace = envelopePace
        patch.sweepPace = sweepPace
        patch.sweepIncrease = sweepIncrease
        patch.sweepShift = sweepShift
        return ByteInstrumentPreset(id: id, name: name, channel: channel, patch: patch, waveform: ByteProject.starter.waveform)
    }

    private static func wavePreset(_ id: String, _ name: String, _ channel: ByteChannel, _ table: [Int], volume: Int) -> ByteInstrumentPreset {
        var patch = ByteChannelPatch(channel: channel)
        patch.waveVolume = volume
        patch.waveShape = ["waveBass": 0, "triangle": 1, "organ": 2, "metal": 3, "ramp": 4][id] ?? 0
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
        return ByteInstrumentPreset(id: id, name: name, channel: channel, patch: patch, waveform: ByteProject.starter.waveform)
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
        case .tone, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoCycleLength, .vibratoDepth, .vibratoDelay, .tremolo, .envelope: return 0...100
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

struct ByteEffects: Codable, Hashable, Sendable {
    // Amounts are percentages so the FX Station can behave like compact hardware knobs.
    // The booleans remain for project-file compatibility with older builds.
    var echo = false
    var echoAmount = 0
    var bitCrush = false
    var bitCrushAmount = 0
    var vibrato = false
    var vibratoAmount = 0
    var widePulse = false
    var widePulseAmount = 0
    /// Per-channel effect sends: Pulse, Square, Triangle, Drum.
    /// 100 preserves the original global-FX behavior for older projects.
    var channelSends = [100, 100, 100, 100]
    /// Retained as a retired legacy field for older project files.
    var delay = 0

    private enum CodingKeys: String, CodingKey {
        case echo, echoAmount, bitCrush, bitCrushAmount, vibrato, vibratoAmount, widePulse, widePulseAmount, channelSends, delay
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
        case .vibrato: return vibratoAmount > 0
        case .widePulse: return widePulseAmount > 0
        case .delay: return delay > 0
        }
    }

    mutating func toggle(_ effect: ByteEffect) {
        switch effect {
        case .echo: echoAmount = echoAmount > 0 ? 0 : 100; echo = echoAmount > 0
        case .bitCrush: bitCrushAmount = bitCrushAmount > 0 ? 0 : 100; bitCrush = bitCrushAmount > 0
        case .vibrato: vibratoAmount = vibratoAmount > 0 ? 0 : 100; vibrato = vibratoAmount > 0
        case .widePulse: widePulseAmount = widePulseAmount > 0 ? 0 : 100; widePulse = widePulseAmount > 0
        case .delay: delay = 0
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
        self.key = min(11, max(0, key))
        self.mode = mode
        var resizedPatterns = Array(patterns.prefix(Self.maximumPatternCount))
        if resizedPatterns.isEmpty {
            resizedPatterns = [BytePattern.empty(name: "PATTERN 01")]
        }
        for index in resizedPatterns.indices { resizedPatterns[index].resize(to: 16) }
        self.patterns = resizedPatterns
        self.arrangement = Self.normalizedArrangement(arrangement ?? resizedPatterns.map(\.id), patterns: resizedPatterns)
        self.songArrangement = Array(repeating: .empty, count: 16)
        if let first = resizedPatterns.first { self.songArrangement[0] = ByteSongSlot(patternID: first.id, isContinuation: false) }
        self.songModeEnabled = false
        self.waveform = Array(waveform.prefix(32)) + Array(repeating: 8, count: max(0, 32 - waveform.count))
        self.channelPatches = channelPatches.count == ByteChannel.allCases.count ? channelPatches : ByteChannelPatch.defaults
        self.effects = effects
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    static let starter = ByteProject()

    var arrangedPatterns: [BytePattern] {
        let lookup = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) })
        let result = arrangement.compactMap { lookup[$0] }
        return result.isEmpty ? patterns : result
    }

    var songPatterns: [BytePattern] {
        let lookup = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) })
        return songArrangement.compactMap { slot in
            guard !slot.isContinuation, let patternID = slot.patternID else { return nil }
            return lookup[patternID]
        }
    }

    var songSlotIndices: [Int] {
        songArrangement.enumerated().compactMap { index, slot in
            slot.isContinuation || slot.patternID == nil ? nil : index
        }
    }

    /// Returns the selected pattern for Beatpad and Sound Lab playback.
    var playbackPatterns: [BytePattern] {
        [patterns.first ?? BytePattern()]
    }

    func pattern(with id: UUID) -> BytePattern? {
        patterns.first(where: { $0.id == id })
    }

    private static func normalizedArrangement(_ arrangement: [UUID], patterns: [BytePattern]) -> [UUID] {
        let validIDs = Set(patterns.map(\.id))
        let filtered = arrangement.filter { validIDs.contains($0) }
        return filtered.isEmpty ? patterns.map(\.id) : filtered
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tempo, loopLength, key, mode, patterns, arrangement, songArrangement, songModeEnabled, waveform, channelPatches, effects, createdAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tempo = try container.decode(Int.self, forKey: .tempo)
        loopLength = 16
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
        let decodedSongArrangement = try container.decodeIfPresent([ByteSongSlot].self, forKey: .songArrangement) ?? Array(repeating: .empty, count: 16)
        songArrangement = decodedSongArrangement.prefix(16).map { slot in
            guard !slot.isContinuation, let patternID = slot.patternID, validPatternIDs.contains(patternID) else { return .empty }
            return ByteSongSlot(patternID: patternID, isContinuation: false)
        }
        if songArrangement.count < 16 { songArrangement.append(contentsOf: Array(repeating: .empty, count: 16 - songArrangement.count)) }
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
