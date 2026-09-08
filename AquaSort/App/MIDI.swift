import Foundation
import UniformTypeIdentifiers
import SwiftUI

extension UTType {
    static let bytePocketMIDI = UTType(filenameExtension: "mid") ?? .data
}

struct ByteMIDIDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.bytePocketMIDI, .data] }
    let data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ByteMIDI {
    static func export(project: ByteProject, patterns sourcePatterns: [BytePattern]? = nil) -> Data {
        let ticksPerStep = 120
        let patterns = sourcePatterns ?? project.arrangedPatterns
        let totalSteps = patterns.count * 16
        var tracks: [Data] = [tempoTrack(bpm: project.tempo, ticksPerStep: ticksPerStep)]

        for (channelIndex, _) in ByteChannel.allCases.enumerated() {
            var events = Data()
            var scheduled: [(tick: Int, order: Int, bytes: [UInt8])] = []
            var patternStart = 0
            for pattern in patterns {
                let stepCount = 16
                for localStep in 0..<stepCount {
                    let globalStep = patternStart + localStep
                    let step = localStep
                    guard let note = pattern.steps[channelIndex][step] else { continue }
                    let length = min(stepCount - step, max(1, pattern.noteLengths[channelIndex][step]))
                    let startTick = globalStep * ticksPerStep
                    let endTick = min(totalSteps * ticksPerStep, (globalStep + length) * ticksPerStep)
                    scheduled.append((startTick, 1, [0x90 | UInt8(channelIndex), 0x7F & UInt8(note), 0x64]))
                    scheduled.append((endTick, 0, [0x80 | UInt8(channelIndex), 0x7F & UInt8(note), 0]))
                }
                patternStart += stepCount
            }
            scheduled.sort { lhs, rhs in
                lhs.tick == rhs.tick ? lhs.order < rhs.order : lhs.tick < rhs.tick
            }
            var previousTick = 0
            for event in scheduled {
                appendVariableLength(event.tick - previousTick, to: &events)
                events.append(contentsOf: event.bytes)
                previousTick = event.tick
            }
            appendVariableLength(0, to: &events)
            events.append(contentsOf: [0xFF, 0x2F, 0x00])
            tracks.append(trackChunk(events: events))
        }

        var data = Data("MThd".utf8)
        data.appendBigEndian(UInt32(6))
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(tracks.count))
        data.appendBigEndian(UInt16(ticksPerStep))
        for track in tracks { data.append(track) }
        return data
    }

    static func importIntoProject(_ data: Data, project: ByteProject) -> ByteProject? {
        guard data.count >= 14, String(data: data[0..<4], encoding: .ascii) == "MThd" else { return nil }
        var cursor = 8
        let headerLength = Int(data.readBigEndian(UInt32.self, at: 4))
        guard headerLength >= 6, data.count >= 8 + headerLength else { return nil }
        let trackCount = Int(data.readBigEndian(UInt16.self, at: 10))
        let division = Int(data.readBigEndian(UInt16.self, at: 12))
        guard division > 0 else { return nil }
        cursor = 8 + headerLength

        var imported = ByteProject(name: project.name, tempo: project.tempo, patterns: [BytePattern.empty(name: "IMPORTED 01")])
        var noteBuckets = ByteChannel.allCases.map { _ in Array(repeating: [Int](), count: 16) }
        var parsedTracks = 0
        while parsedTracks < trackCount && cursor + 8 <= data.count {
            guard String(data: data[cursor..<(cursor + 4)], encoding: .ascii) == "MTrk" else { break }
            let length = Int(data.readBigEndian(UInt32.self, at: cursor + 4))
            let start = cursor + 8
            let end = min(data.count, start + length)
            var position = start
            var tick = 0
            var runningStatus: UInt8 = 0
            var channelNote: (Int, Int)?
            while position < end {
                let delta = readVariableLength(data, cursor: &position, limit: end)
                tick += delta
                guard position < end else { break }
                var status = data[position]
                if status < 0x80 { status = runningStatus } else { position += 1 }
                if status == 0xFF {
                    guard position < end else { break }
                    position += 1
                    _ = readVariableLength(data, cursor: &position, limit: end)
                    if position < end { position += 1 }
                    continue
                }
                if status == 0xF0 || status == 0xF7 {
                    let length = readVariableLength(data, cursor: &position, limit: end)
                    position = min(end, position + length)
                    continue
                }
                runningStatus = status
                let kind = status & 0xF0
                guard position < end else { break }
                let valueA = Int(data[position]); position += 1
                if kind == 0x80 || kind == 0x90 {
                    guard position < end else { break }
                    let velocity = Int(data[position]); position += 1
                    if kind == 0x90 && velocity > 0 {
                        channelNote = (valueA, tick)
                    } else if let active = channelNote {
                        let step = min(15, max(0, Int(Double(active.1) / Double(max(1, division)))))
                        let channel = min(3, max(0, parsedTracks - 1))
                        noteBuckets[channel][step].append(active.0)
                        channelNote = nil
                    }
                } else if kind == 0xC0 {
                    continue
                } else {
                    if position < end { position += 1 }
                }
            }
            cursor = end
            parsedTracks += 1
        }

        for channel in 0..<4 {
            for step in 0..<16 where !noteBuckets[channel][step].isEmpty {
                imported.patterns[0].steps[channel][step] = noteBuckets[channel][step][0]
            }
        }
        return imported
    }

    private static func tempoTrack(bpm: Int, ticksPerStep: Int) -> Data {
        let microseconds = UInt32(60_000_000 / max(1, bpm))
        var events = Data()
        appendVariableLength(0, to: &events)
        events.append(contentsOf: [0xFF, 0x51, 0x03])
        events.appendBigEndian24(microseconds)
        appendVariableLength(0, to: &events)
        events.append(contentsOf: [0xFF, 0x2F, 0x00])
        return trackChunk(events: events)
    }

    private static func trackChunk(events: Data) -> Data {
        var data = Data("MTrk".utf8)
        data.appendBigEndian(UInt32(events.count))
        data.append(events)
        return data
    }

    private static func appendVariableLength(_ value: Int, to data: inout Data) {
        var value = max(0, value)
        var buffer = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            buffer.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        data.append(contentsOf: buffer)
    }

    private static func readVariableLength(_ data: Data, cursor: inout Int, limit: Int) -> Int {
        var value = 0
        while cursor < limit {
            let byte = data[cursor]; cursor += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { break }
        }
        return value
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian24(_ value: UInt32) {
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        var value: T = 0
        for index in 0..<size {
            value = (value << 8) | T(self[offset + index])
        }
        return value
    }
}
