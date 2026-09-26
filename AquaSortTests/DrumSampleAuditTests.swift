import XCTest
@testable import AquaSort

/// Both takes behind a drum voice have to be the same instrument.
///
/// This is the fault it guards. SNARE and HI-HAT each shipped a second take that measured as a
/// different drum — a dark tom behind SNARE, a mid drum behind HI-HAT — so the button labelled
/// SAMPLE 2 played something that was not the voice on its row. Nothing in the code could show
/// that: a sample is addressed by number, and a number cannot be wrong the way a name can. So this
/// guard measures the files themselves.
///
/// A drum is identified by the register it sounds in, so the test compares the frequency below
/// which half of each take's energy sits. The two takes of a voice have to agree on that register
/// to within a factor of two, one octave. The takes that were the wrong instrument sat 2.4x and
/// 2.6x apart; the four honest pairs sit 1.2x to 1.5x apart, which is the headroom a re-tune needs.
///
/// What it cannot catch: two different instruments that happen to share a register. A hi-hat
/// behind a snare would pass, because both are bright, broadband hits — telling those apart needs
/// a decay measurement, and the kit's snare and hi-hat are within 6% of each other on length.
final class DrumSampleAuditTests: XCTestCase {

    /// Every take also has to survive the loader the app plays it with. A file that is a valid WAV
    /// but not a format the bank converts from loads as no sample at all, which is silence — and
    /// silence passes a measurement of where a hit's energy sits, so the audit above would not see
    /// it.
    func testEveryTakeLoadsThroughTheAppSampleLoader() {
        for voice in ByteDrumVoice.allCases {
            for variant in 1...2 {
                XCTAssertTrue(
                    ByteDrumSampleBank.shared.hasSample(voice: voice, variant: variant),
                    "\(voice.title) take \(variant) did not load, so that button would play silence"
                )
            }
        }
    }

    /// One octave. Wider than a re-tune ever moves a take, narrower than the difference between
    /// two different drums.
    private let registerLimit = 2.0

    /// Both takes of a voice have to agree on where they live, or one of them is not that voice.
    func testBothTakesOfAVoiceSoundInTheSameRegister() throws {
        for voice in ByteDrumVoice.allCases {
            let files = voice.resourceNames
            XCTAssertEqual(files.count, 2, "\(voice.title) is meant to offer two takes")

            let medians = try files.map { try DrumSampleAudit.medianFrequency(of: $0) }
            let high = max(medians[0], medians[1])
            let low = max(1, min(medians[0], medians[1]))

            XCTAssertLessThanOrEqual(
                high / low, registerLimit,
                """
                \(voice.title)'s two takes sound more than an octave apart, so the SAMPLE buttons \
                offer two instruments: \(files[0]) puts half its energy below \(Int(medians[0])) Hz \
                and \(files[1]) below \(Int(medians[1])) Hz \
                (\(String(format: "%.2fx", high / low))).
                """
            )
        }
    }
}

/// Measures the bundled one-shots the way the audit needs them: read from disk, windowed, and
/// reduced to the one number that says where a hit's energy sits.
private enum DrumSampleAudit {

    enum AuditError: Error, CustomStringConvertible {
        case unexpectedFormat(String)

        var description: String {
            switch self {
            case .unexpectedFormat(let name):
                return "\(name).wav is not the 44.1 kHz mono 24-bit the kit expects"
            }
        }
    }

    /// The frequency below which half of the body of the hit sits.
    ///
    /// The body is the 70 ms after the onset, less its first 5 ms: every drum's attack is
    /// broadband, so counting it would make each one look like a hi-hat, and on a kick the click
    /// would outweigh the whole sample behind it.
    static func medianFrequency(of named: String) throws -> Double {
        let (samples, sampleRate) = try load(named)
        let onset = onset(of: samples, sampleRate: sampleRate)
        let start = min(samples.count, onset + Int(sampleRate * 0.005))
        let length = min(samples.count - start, Int(sampleRate * 0.065))
        guard length > 64 else { return 0 }

        // A 4096-point transform of the windowed body, zero padded. Big enough that the bins are
        // 10 Hz apart, which is finer than the octave the test is comparing.
        let size = 4096
        var real = [Double](repeating: 0, count: size)
        var imaginary = [Double](repeating: 0, count: size)
        for index in 0..<length {
            // Hann window: without it the segment's edges splatter energy across the spectrum and
            // the median stops describing the hit.
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(length - 1))
            real[index] = samples[start + index] * window
        }
        fft(real: &real, imaginary: &imaginary)

        var power = [Double](repeating: 0, count: size / 2)
        for bin in power.indices {
            power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        }
        // DC and its first neighbour are the window's leakage, not the hit.
        power[0] = 0
        power[1] = 0

        let total = power.reduce(0, +)
        guard total > 0 else { return 0 }
        let step = sampleRate / Double(size)
        var running = 0.0
        for bin in power.indices {
            running += power[bin]
            if running >= total / 2 { return Double(bin) * step }
        }
        return 0
    }

    /// The index the hit starts at: the first 2 ms slice carrying a tenth of the sample's peak,
    /// because a one-shot that has not begun yet is silent.
    static func onset(of samples: [Double], sampleRate: Double) -> Int {
        let slice = max(1, Int(sampleRate * 0.002))
        let peak = samples.map(abs).max() ?? 0
        var index = 0
        while index < samples.count {
            let window = samples[index..<min(samples.count, index + slice)]
            if let loudest = window.map(abs).max(), loudest > peak / 10 { return index }
            index += slice
        }
        return 0
    }

    /// Reads one of the bundled one-shots out of the repository.
    ///
    /// The chunk list is walked rather than searched: a four-byte id like `data` can occur inside
    /// a sample, and only the chunk headers say where the samples actually begin.
    static func load(_ named: String) throws -> (samples: [Double], sampleRate: Double) {
        let url = URL(fileURLWithPath: #filePath)      // <repo>/AquaSortTests/<this file>
            .deletingLastPathComponent()               // <repo>/AquaSortTests
            .deletingLastPathComponent()               // <repo>
            .appendingPathComponent("AquaSort/Resources/Drums/\(named).wav")
        let data = try Data(contentsOf: url)

        var sampleRate = 0.0
        var channels = 0
        var bits = 0
        var payload: Range<Int>?
        var cursor = 12   // past "RIFF" + its size + "WAVE"
        while cursor + 8 <= data.count {
            let id = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
            let size = Int(uint32(data, at: cursor + 4))
            let body = cursor + 8
            if id == "fmt ", body + 16 <= data.count {
                channels = Int(uint16(data, at: body + 2))
                sampleRate = Double(uint32(data, at: body + 4))
                bits = Int(uint16(data, at: body + 14))
            } else if id == "data" {
                payload = body..<min(data.count, body + size)
            }
            cursor = body + size + (size % 2)   // chunks are padded to an even length
        }

        guard let payload, channels == 1, bits == 24, sampleRate > 0 else {
            throw AuditError.unexpectedFormat(named)
        }

        var samples = [Double]()
        samples.reserveCapacity(payload.count / 3)
        var index = payload.lowerBound
        while index + 2 < payload.upperBound {
            let raw = Int32(data[index]) | Int32(data[index + 1]) << 8 | Int32(data[index + 2]) << 16
            let signed = (raw & 0x80_0000) != 0 ? raw - 0x100_0000 : raw
            samples.append(Double(signed) / 8_388_608.0)
            index += 3
        }
        return (samples, sampleRate)
    }

    /// In-place iterative radix-2 FFT. The segment is short enough that a hand-written transform
    /// costs less than a dependency: this needs band energies, not a spectrum API.
    private static func fft(real: inout [Double], imaginary: inout [Double]) {
        let count = real.count
        var reversed = 0
        for index in 0..<count {
            if index < reversed {
                real.swapAt(index, reversed)
                imaginary.swapAt(index, reversed)
            }
            var bit = count >> 1
            while bit > 0, reversed & bit != 0 {
                reversed &= ~bit
                bit >>= 1
            }
            reversed |= bit
        }

        var length = 2
        while length <= count {
            let angle = -2.0 * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var start = 0
            while start < count {
                var twiddleReal = 1.0
                var twiddleImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let even = start + offset
                    let odd = even + length / 2
                    let oddReal = real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary
                    let oddImaginary = real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal
                    real[odd] = real[even] - oddReal
                    imaginary[odd] = imaginary[even] - oddImaginary
                    real[even] += oddReal
                    imaginary[even] += oddImaginary

                    let nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                    twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                    twiddleReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
