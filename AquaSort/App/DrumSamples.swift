import AVFoundation
import Foundation

final class ByteDrumSampleBank: @unchecked Sendable {
    static let shared = ByteDrumSampleBank()
    private let samples: [[[Float]]]

    private init() {
        samples = ByteDrumVoice.allCases.map { voice in
            voice.resourceNames.map { Self.load(name: $0) }
        }
    }

    func sample(voice: ByteDrumVoice, variant: Int) -> [Float] {
        let variants = samples[voice.rawValue]
        return variants[min(1, max(0, variant - 1))]
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
