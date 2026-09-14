import AVFoundation
import Foundation

final class ByteDrumSampleBank: @unchecked Sendable {
    static let shared = ByteDrumSampleBank()

    /// How many points a voice's outline is drawn from. Fixed at load, because a row redraws on
    /// every step of a volume drag and scanning a sample inside a view body is not something to
    /// do there.
    static let envelopePoints = 44

    private let samples: [[[Float]]]
    /// One outline per voice per variant, in the same order as `samples`.
    private let envelopes: [[[Double]]]
    /// The longest shaped hit in the kit at each variant index. Every row is drawn against this
    /// one scale, so a click reads as a stub beside a full tail instead of four pictures that
    /// each fill their own box.
    private let longestFrameCounts: [Int]

    private init() {
        let loaded = ByteDrumVoice.allCases.map { voice in
            voice.resourceNames.map { Self.load(name: $0) }
        }
        let outlines = ByteDrumVoice.allCases.enumerated().map { index, voice in
            loaded[index].map { voice.envelope(of: $0, points: Self.envelopePoints) }
        }
        let variantCount = loaded.map(\.count).max() ?? 0
        let longest = (0..<variantCount).map { variant in
            ByteDrumVoice.allCases
                .map { voice -> Int in
                    guard loaded[voice.rawValue].indices.contains(variant) else { return 0 }
                    return voice.outputFrameCount(sampleCount: loaded[voice.rawValue][variant].count)
                }
                .max() ?? 1
        }

        samples = loaded
        envelopes = outlines
        longestFrameCounts = longest
    }

    func sample(voice: ByteDrumVoice, variant: Int) -> [Float] {
        let variants = samples[voice.rawValue]
        return variants[min(1, max(0, variant - 1))]
    }

    /// The voice's outline at a variant, in the 0-1 scale a row draws it in.
    func envelope(voice: ByteDrumVoice, variant: Int) -> [Double] {
        let variants = envelopes[voice.rawValue]
        guard !variants.isEmpty else { return [] }
        return variants[min(variants.count - 1, max(0, variant - 1))]
    }

    /// The frames the voice's shaped hit lasts at a variant — the length its picture is drawn at.
    func outputFrameCount(voice: ByteDrumVoice, variant: Int) -> Int {
        voice.outputFrameCount(sampleCount: sample(voice: voice, variant: variant).count)
    }

    /// The longest shaped hit in the kit at a variant, which every row's drawn width is scaled to.
    func longestOutputFrameCount(variant: Int) -> Int {
        guard longestFrameCounts.indices.contains(variant - 1) else { return 1 }
        return max(1, longestFrameCounts[variant - 1])
    }

    func hasSample(voice: ByteDrumVoice, variant: Int) -> Bool {
        !sample(voice: voice, variant: variant).isEmpty
    }

    private static func load(name: String) -> [Float] {
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Drums")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        guard let url, let file = try? AVAudioFile(forReading: url) else { return [] }

        let sourceFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            return []
        }

        let capacity = AVAudioFrameCount(max(1, file.length))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var didSupply = false
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if didSupply {
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input)
                didSupply = true
                inputStatus.pointee = .haveData
                return input
            } catch {
                inputStatus.pointee = .endOfStream
                return nil
            }
        }

        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
