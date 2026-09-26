import Darwin
import XCTest
@testable import AquaSort

/// A take's length must not decide how much memory writing it costs.
///
/// The WAV export streams, so what it holds is one block of the arrangement — the same few hundred
/// kilobytes whether the song is one bar or sixteen — and this is where that claim is enforced rather
/// than merely intended. Nothing about the audio can tell the difference: an export that built the
/// whole take in memory and one that streams it produce the same bytes, which is exactly why the
/// property needs a test of its own instead of being left to whoever reads the writer next.
///
/// Two takes sixteen times apart are streamed and compared, so what is asserted is the *difference*
/// between them: a writer that accumulated a take would cost more for the longer one, and how much
/// more is the whole question. Only new memory can scale with the take, so the ruler is the
/// allocator's own account of what it is holding for the app, sampled on every block — the process's
/// footprint would count pages instead, and a regression could come out of pages some earlier work
/// had already left free and read as no growth at all. The test action runs in Debug, so a regression
/// here fails the build, rather than waiting to surface as a crash on the longest song a user has.
@MainActor
final class WaveExportMemoryGuardTests: XCTestCase {
    /// The ruler is checked before it is used. Every bound below is a claim about what the allocator
    /// reported, so a guard built on a reader that quietly returned zero would pass all of them by
    /// measuring nothing.
    func testTheRulerSeesALargeAllocation() {
        let before = ExportMemoryProbe.allocatedBytes()
        XCTAssertGreaterThan(before, 0, "the process has to report what it is holding at all")

        // Written to a page at a time, so the memory is real rather than promised by the allocator,
        // and held across both readings so neither can race the deallocation.
        var ballast = [UInt8](repeating: 0, count: 32 * 1024 * 1024)
        for index in stride(from: 0, to: ballast.count, by: 4096) { ballast[index] = 1 }

        let after = ExportMemoryProbe.allocatedBytes()
        XCTAssertGreaterThan(
            after,
            before + 16 * 1024 * 1024,
            "32 MB of held memory has to show up: the guard is blind otherwise"
        )
        withExtendedLifetime(ballast) {}
    }

    /// The guard itself: sixteen times the arrangement, and the same amount of memory held while
    /// writing it.
    ///
    /// The difference between the two readings is what carries the guard, which is what makes it
    /// sharp. Sixteen bars of a take are megabytes; the allowance here is 128 KB, so a writer that
    /// held the longer take rather than a block of it would miss by roughly ten times the allowance
    /// rather than by a hair. The absolute bound underneath it is a backstop for memory that is large
    /// but not proportional — a buffer sized by something other than the song.
    func testAnExportsMemoryDoesNotGrowWithTheLengthOfTheTake() throws {
        // A throwaway take first: the first export in a process pays for one-time work — the drum
        // bank, the effect buffers — and whichever reading contained it would be compared against a
        // reading that did not. Warmed up, the two below differ only in length.
        _ = try ExportMemoryProbe.peakHeldBytes(barCount: 1)

        let shortTake = try ExportMemoryProbe.peakHeldBytes(barCount: ExportMemoryProbe.shortTakeBars)
        let longTake = try ExportMemoryProbe.peakHeldBytes(barCount: ExportMemoryProbe.longTakeBars)

        XCTAssertLessThan(
            longTake,
            ExportMemoryProbe.ceilingBytes,
            "streaming a \(ExportMemoryProbe.longTakeBars)-bar take held \(longTake) bytes, past the \(ExportMemoryProbe.ceilingBytes) a block-at-a-time writer may hold"
        )
        XCTAssertLessThan(
            longTake,
            shortTake + ExportMemoryProbe.growthAllowanceBytes,
            "sixteen times the take held \(longTake - shortTake) bytes more than one bar did, past the \(ExportMemoryProbe.growthAllowanceBytes) allowed: the export's memory is growing with the take rather than staying a block"
        )
    }

    /// What the guard allows has to be far smaller than what it is there to catch, or the allowance
    /// is an escape hatch.
    ///
    /// Pinned against the arithmetic rather than trusted, because both numbers move independently:
    /// if the guard's take ever shrank, the test above would keep passing while measuring nothing
    /// worth measuring.
    func testTheGrowthTheGuardAllowsIsFarSmallerThanAWholeTake() {
        let frames = ExportMemoryProbe.frameCount(barCount: ExportMemoryProbe.longTakeBars)
        // The 16-bit payload is the smaller of the two buffers a whole-take export needs, and it is
        // still several times the allowance — as are the interleaved Floats, by twice as much again.
        let wholeTakePCM = UInt64(frames * 4)
        XCTAssertGreaterThan(
            wholeTakePCM,
            4 * ExportMemoryProbe.growthAllowanceBytes,
            "a whole \(ExportMemoryProbe.longTakeBars)-bar take encodes to only \(wholeTakePCM) bytes, which the allowance does not rule out clearly enough to be worth having"
        )
    }
}

/// The measurements the guard above is built from.
private enum ExportMemoryProbe {
    /// A backstop on what a streamed export may hold, whatever the take's length.
    ///
    /// A constant, and not a share of the take, on purpose: a budget expressed as a fraction of the
    /// song would be satisfied by precisely the bug this exists to catch, because a buffer holding
    /// the whole take is a fraction of the song too. One block of Floats and one of 16-bit samples
    /// come to under half a megabyte, so this is that with room for the writer's own bookkeeping.
    static let ceilingBytes: UInt64 = 2 * 1024 * 1024

    /// How far the long take may exceed a single bar before the difference counts as growth. A
    /// constant as well, for the same reason, and small enough that it cannot quietly turn into a
    /// budget that grows with the song.
    static let growthAllowanceBytes: UInt64 = 128 * 1024

    static let shortTakeBars = 1
    static let longTakeBars = 16
    static let sampleRate = 22_050.0
    /// The app's own ceiling on tempo, so the take's length in frames is anchored to an export a
    /// user could really make rather than to a number invented for the test.
    static let tempo = 240

    /// The bytes the allocator is holding for the process right now.
    ///
    /// This is the ruler rather than the process's footprint, because a footprint counts pages: the
    /// pages a freed buffer leaves behind are still the process's, so a writer that held whole
    /// megabytes could grow the footprint by nothing at all and a regression would read as a pass.
    /// The allocator's own account cannot be fooled that way — a buffer that exists is counted.
    static func allocatedBytes() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return UInt64(stats.size_in_use)
    }

    /// How many frames a take of `barCount` bars renders to, using the same arithmetic the renderer
    /// uses — so a change to either the transport or the bar length shows up here too.
    static func frameCount(barCount: Int) -> Int {
        Int(Double(barCount * 16) * ByteTransportClock.stepDuration(bpm: tempo) * sampleRate)
    }

    /// Streams a take and reports the most the process was holding while its file was written.
    ///
    /// Sampled on every block rather than watched from another thread: the progress callback runs on
    /// the thread doing the writing, so the reading lands exactly where the exporter's own memory is
    /// highest, and nothing else in the process is running to blur it.
    static func peakHeldBytes(barCount: Int) throws -> UInt64 {
        var project = ByteProject.starter
        project.tempo = tempo
        // Every bar the same, so the two takes differ only in length — the thing being measured.
        let patterns = Array(repeating: project.patterns[0], count: barCount)
        let url = ByteWaveFile.url(named: "MEMORY GUARD \(barCount) BARS")
        defer { try? FileManager.default.removeItem(at: url) }

        let peak = HeldBytesPeak(baseline: allocatedBytes())
        try ByteRenderer.streamWave(project: project, patterns: patterns, sampleRate: sampleRate, to: url) { _ in
            peak.sample()
        }
        // Once more after the file is whole: a writer that collected the take and only let go of it
        // at the end would show its high point here rather than at any block boundary.
        peak.sample()
        return peak.bytes
    }

    /// The running maximum, in a reference the render's callback can carry rather than a captured
    /// local — the callback is `@Sendable`, and the render calls it synchronously on the thread that
    /// invoked `streamWave`, so `@unchecked` is honest here in a way it usually is not.
    private final class HeldBytesPeak: @unchecked Sendable {
        private let baseline: UInt64
        private(set) var bytes: UInt64 = 0

        init(baseline: UInt64) {
            self.baseline = baseline
        }

        func sample() {
            let current = allocatedBytes()
            bytes = max(bytes, current > baseline ? current - baseline : 0)
        }
    }
}
