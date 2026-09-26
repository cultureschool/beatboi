import AVFoundation
import Foundation

enum ByteTransportClock {
    /// Seconds per quarter note at this tempo. Everything the app spaces in time is a division
    /// of this, so a preview that wants to be in time with the loop has one number to read.
    static func beatDuration(bpm: Int) -> Double {
        60.0 / Double(max(1, bpm))
    }

    /// A step is a sixteenth note, so four of them make the beat above.
    static func stepDuration(bpm: Int) -> Double {
        beatDuration(bpm: bpm) / 4.0
    }

    static func step(at elapsed: TimeInterval, bpm: Int, loopLength: Int = 16) -> Int {
        Int(max(0, elapsed) / stepDuration(bpm: bpm)) % max(16, loopLength)
    }
}

private struct ByteMixEffects {
    private var history: [Double]
    private var cursor = 0
    private var crushedLeft = 0.0
    private var crushedRight = 0.0

    init(sampleRate: Double) {
        history = Array(repeating: 0.0, count: max(256, Int(sampleRate * 0.25) * 2))
    }

    mutating func process(left: Double, right: Double, effects: ByteEffects, send: Double = 1.0, sampleRate: Double) -> (left: Double, right: Double) {
        guard !history.isEmpty else { return (left, right) }
        let inputLeft = max(-0.9, min(0.9, left)) * send
        let inputRight = max(-0.9, min(0.9, right)) * send
        let amount = min(100, max(0, effects.bitCrushAmount))
        let crushBlend = Double(amount) / 100.0
        let effectiveAmount = ByteEffects.bitCrushEffectiveAmount(for: amount)
        let holdFrames = ByteEffects.bitCrushHoldFrames(for: amount)
        if amount > 0, (cursor / 2) % holdFrames == 0 {
            let levels = ByteEffects.bitCrushLevels(for: effectiveAmount)
            crushedLeft = (inputLeft * levels).rounded() / levels
            crushedRight = (inputRight * levels).rounded() / levels
        }
        let crushedInputLeft = amount > 0 ? inputLeft + (crushedLeft - inputLeft) * crushBlend : inputLeft
        let crushedInputRight = amount > 0 ? inputRight + (crushedRight - inputRight) * crushBlend : inputRight

        let frameCount = history.count / 2
        let echoFrames = min(frameCount - 1, max(1, Int(sampleRate * 0.085)))
        let echoIndex = (cursor - echoFrames * 2 + history.count) % history.count
        let echoMix = Double(min(100, max(0, effects.echoAmount))) / 100.0 * 0.48
        let effectedLeft = crushedInputLeft + history[echoIndex] * echoMix
        let effectedRight = crushedInputRight + history[(echoIndex + 1) % history.count] * echoMix

        // Store the dry send so Echo does not recursively build an uncontrolled feedback loop.
        history[cursor] = inputLeft
        history[(cursor + 1) % history.count] = inputRight
        cursor = (cursor + 2) % history.count
        return (effectedLeft, effectedRight)
    }
}

/// Shared live state read by the realtime audio callback. UI edits replace the project snapshot;
/// the callback keeps its transport position, oscillator phases, and noise register intact.
private final class ByteLiveAudioState: @unchecked Sendable {
    private let dataLock = NSLock()
    private let transportLock = NSLock()
    private var project = ByteProject.starter
    private var patterns = [ByteProject.starter.patterns[0]]
    private var patternIndex = 0
    private var slotIndices: [Int] = []
    private var active = false

    // These values are owned by the audio render callback, except currentStepValue which is also
    // read by the display timer. The tiny lock is only taken when a 16th-note boundary changes.
    private var stepElapsed = 0.0
    private var playbackStep = 0
    private var lastStep = -1
    /// The four sequence channels, plus one slot held back for the pad audition. Giving the
    /// preview a slot of its own is what lets it sound through the same synthesis without
    /// touching any channel's oscillator phase or drum sample position — so auditioning a
    /// pitch while the loop plays cannot make the sequence repeat or stutter.
    private static let auditionSlot = ByteChannel.allCases.count
    private static let voiceSlots = ByteChannel.allCases.count + 1
    /// How long one auditioned note sounds. This carries the patch's whole envelope once,
    /// which is long enough to recognise a pitch and short enough to step to the next one.
    private static let auditionDuration = 0.45
    /// The pulse duty cycles, built once instead of once per rendered frame.
    private static let pulseDuties: [Double] = [0.125, 0.25, 0.50, 0.75]

    // All per-voice state is indexed by voice SLOT, so every array here is sized to
    // `voiceSlots` and no reset may size one back down to the channel count. A half-grown
    // set of these is an index-out-of-range waiting for the first audition.
    private var phases = Array(repeating: 0.0, count: ByteLiveAudioState.voiceSlots)
    private var waveFilterStates = Array(repeating: 0.0, count: ByteLiveAudioState.voiceSlots)
    private var noiseStates: [UInt16] = Array(repeating: 0x7FFF, count: ByteLiveAudioState.voiceSlots)
    private var noiseAccumulators = Array(repeating: 0.0, count: ByteLiveAudioState.voiceSlots)
    /// Fractional, because a voice's shape reads its sample at its own rate rather than one
    /// frame per output frame.
    private var drumSamplePositions = Array(repeating: 0.0, count: ByteLiveAudioState.voiceSlots)
    private var effectsProcessor = ByteMixEffects(sampleRate: 44_100)
    private var currentStepValue = 0
    private var currentSongSlotValue = -1
    /// UI scrubbing submits one command; the realtime callback consumes it at a safe render boundary.
    private var pendingSongSlot: Int?
    /// A pad audition, handed over exactly like `pendingSongSlot`.
    private var pendingAudition: (row: Int, note: Int)?
    // Owned by the render callback.
    private var auditioning = false
    private var auditionRow = 0
    private var auditionNote = 60
    private var auditionElapsed = 0.0

    func begin(project: ByteProject, patterns: [BytePattern], slotIndices: [Int] = [], startSongSlot: Int? = nil) {
        dataLock.lock()
        self.project = project
        self.patterns = patterns
        self.slotIndices = slotIndices
        let startIndex = startSongSlot.flatMap { slotIndices.firstIndex(of: $0) } ?? 0
        self.patternIndex = min(max(0, startIndex), max(0, patterns.count - 1))
        self.pendingSongSlot = nil
        self.active = true
        dataLock.unlock()
        stepElapsed = 0
        playbackStep = 0
        lastStep = -1
        phases = Array(repeating: 0.0, count: Self.voiceSlots)
        waveFilterStates = Array(repeating: 0.0, count: Self.voiceSlots)
        noiseStates = Array(repeating: 0x7FFF, count: Self.voiceSlots)
        noiseAccumulators = Array(repeating: 0.0, count: Self.voiceSlots)
        effectsProcessor = ByteMixEffects(sampleRate: 44_100)
        setCurrentStep(0)
        setCurrentSongSlot(slotIndices.indices.contains(patternIndex) ? slotIndices[patternIndex] : -1)
    }

    func update(project: ByteProject, patterns: [BytePattern], slotIndices: [Int] = [], restartSequence: Bool = false) {
        dataLock.lock()
        self.project = project
        self.patterns = patterns
        self.slotIndices = slotIndices
        if restartSequence { self.patternIndex = 0 }
        dataLock.unlock()
    }

    /// Moves the song transport to the requested arrangement bar. The editor calls this at
    /// a 16-step boundary so scrubbing never cuts a bar in half.
    func seekSongSlot(_ slot: Int) {
        // Do not mutate render-thread state from the gesture callback. The next audio render
        // consumes this request and begins the selected arrangement bar at step 1.
        dataLock.lock()
        if slotIndices.contains(slot) {
            pendingSongSlot = slot
        }
        dataLock.unlock()
    }

    /// Submits one note to be auditioned — played on its own, through the same synthesis as
    /// the sequence, so a melody can be built by ear from the pad grid.
    ///
    /// The project travels with the request because `update` is only called while the
    /// transport is running; without it a preview would be voiced by whatever patch happened
    /// to be published last, which is not the patch the user is looking at.
    func audition(row: Int, note: Int, project: ByteProject) {
        dataLock.lock()
        self.project = project
        pendingAudition = (row: row, note: note)
        dataLock.unlock()
    }

    func end() {
        dataLock.lock()
        active = false
        dataLock.unlock()
    }

    func currentPosition() -> (step: Int, songSlot: Int) {
        transportLock.lock()
        let result = (currentStepValue, currentSongSlotValue)
        transportLock.unlock()
        return result
    }

    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>, sampleRate: Double) {
        dataLock.lock()
        let isActive = active
        let project = self.project
        let patterns = self.patterns
        var resetTransport = false
        if let pendingSongSlot, let index = slotIndices.firstIndex(of: pendingSongSlot), patterns.indices.contains(index) {
            patternIndex = index
            self.pendingSongSlot = nil
            resetTransport = true
        }
        let pattern = patterns.isEmpty ? nil : patterns[min(patternIndex, patterns.count - 1)]
        let auditionRequest = pendingAudition
        if auditionRequest != nil { self.pendingAudition = nil }
        dataLock.unlock()

        // Armed here, on the render thread, so a request that arrives mid-drag replaces the
        // note in flight rather than stacking a second one.
        if let request = auditionRequest {
            auditionRow = min(max(0, request.row), ByteChannel.allCases.count - 1)
            auditionNote = request.note
            auditionElapsed = 0
            auditioning = true
            phases[Self.auditionSlot] = 0.0
            drumSamplePositions[Self.auditionSlot] = 0
        }

        // Only the realtime callback mutates oscillator and step state. This avoids racing
        // the audio thread when the user scrubs repeatedly across the timeline.
        if resetTransport {
            stepElapsed = 0
            playbackStep = 0
            lastStep = -1
            phases = Array(repeating: 0.0, count: Self.voiceSlots)
            drumSamplePositions = Array(repeating: 0, count: Self.voiceSlots)
            setCurrentStep(0)
            setCurrentSongSlot(slotIndices.indices.contains(patternIndex) ? slotIndices[patternIndex] : -1)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return }

        var channelPointers: [UnsafeMutablePointer<Float>?] = []
        for buffer in buffers {
            channelPointers.append(buffer.mData?.assumingMemoryBound(to: Float.self))
        }

        guard isActive, let pattern else {
            for buffer in channelPointers {
                guard let buffer else { continue }
                for frame in 0..<frameCount { buffer[frame] = 0 }
            }
            // With the transport stopped, an audition is the only thing that can make a
            // sound — which is exactly the case the pad grid needs it for.
            renderAudition(
                frameCount: frameCount,
                buffers: buffers,
                channelPointers: channelPointers,
                project: project,
                sampleRate: sampleRate
            )
            return
        }

        for frame in 0..<frameCount {
            let secondsPerStep = ByteTransportClock.stepDuration(bpm: project.tempo)
            // stepElapsed is only the position inside the current step. Keep the step index
            // separately; deriving both from the wrapped elapsed value would play step 01 forever.
            let step = playbackStep
            let normalized = min(1.0, max(0.0, stepElapsed / secondsPerStep))
            if step != lastStep {
                lastStep = step
                // Reset only channels that are starting a new note. A held note keeps its
                // oscillator/noise state across covered cells instead of retriggering.
                for channelIndex in ByteChannel.allCases.indices {
                    let active = noteAt(row: channelIndex, step: step, pattern: pattern)
                    if active?.start == step {
                        phases[channelIndex] = 0.0
                        noiseStates[channelIndex] = 0x7FFF
                        noiseAccumulators[channelIndex] = 0.0
                        drumSamplePositions[channelIndex] = 0
                    }
                }
                setCurrentStep(step)
                setCurrentSongSlot(slotIndices.indices.contains(patternIndex) ? slotIndices[patternIndex] : -1)
            }

            var left = 0.0
            var right = 0.0
            var effectsLeft = 0.0
            var effectsRight = 0.0
            for (channelIndex, channel) in ByteChannel.allCases.enumerated() {
                guard let activeNote = noteAt(row: channelIndex, step: step, pattern: pattern) else { continue }
                let note = activeNote.note
                let noteProgress = Double(step - activeNote.start) + normalized
                let noteNormalized = min(1.0, max(0.0, noteProgress / Double(max(1, activeNote.length))))
                let patch = project.channelPatches.first(where: { $0.channel == channel }) ?? ByteChannelPatch(channel: channel)
                let hasSoloChannel = project.channelPatches.contains(where: { $0.soloed })
                guard !patch.muted, !hasSoloChannel || patch.soloed else { continue }
                let baseFrequency = 440.0 * pow(2.0, Double(note - 69 + patch.octave * 12) / 12.0)
                let sweep = channel == .pulseA ? liveSweep(noteNormalized, patch: patch) : 0.0
                let portamentoAmount = Double(min(100, max(0, patch.portamento))) / 100.0
                let portamentoTime = max(0.01, Double(min(100, max(0, patch.portamentoTime))) / 100.0)
                let portamentoProgress = min(1.0, noteProgress / max(0.01, portamentoTime * 2.0))
                let portamentoSemitones = (1.0 - portamentoProgress) * portamentoAmount * Double(patch.bendRange)
                let vibratoDepth = Double(min(100, max(0, patch.vibratoDepth))) / 100.0
                let vibratoCycle = 0.05 + Double(min(100, max(0, patch.vibratoCycleLength))) / 100.0 * 0.45
                let vibratoDelay = Double(min(100, max(0, patch.vibratoDelay))) / 100.0 * max(0.01, Double(activeNote.length))
                let vibratoTime = Double(step - activeNote.start) + normalized
                let vibrato = vibratoDepth > 0 && vibratoTime >= vibratoDelay
                    ? sin((vibratoTime - vibratoDelay) * secondsPerStep * 2.0 * .pi / vibratoCycle) * vibratoDepth * 0.018
                    : 0.0
                let flutterMultiplier = channel == .drum ? 1.0 : ByteEffects.octaveFlutterMultiplier(
                    at: Double(step) * secondsPerStep + stepElapsed,
                    bpm: project.tempo,
                    amount: patch.octaveFlutterAmount,
                    pattern: ByteOctaveFlutterPattern(rawValue: patch.octaveFlutterPattern) ?? .baseUp
                )
                let frequency = max(1.0, baseFrequency * pow(2.0, portamentoSemitones / 12.0) * flutterMultiplier * (1.0 + vibrato + sweep))
                // Supplied drum one-shots own their duration and level. Do not apply the
                // former synthesized-noise length gate or envelope to them.
                let effectiveLength = channel == .drum ? 63 : patch.length
                let gated = channel == .drum ? false : (patch.lengthCounter && noteNormalized > Double(effectiveLength) / 63.0)
                let envelopeLevel = channel == .drum ? 1.0 : liveEnvelope(normalized: noteNormalized, patch: patch)
                let value: Double

                switch channel {
                case .pulseA, .pulseB:
                    value = livePulse(phase: phases[channelIndex], duty: pulseDuty(patch))
                    phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                case .wave:
                    value = liveWave(phase: phases[channelIndex], shape: patch.waveShape, volume: patch.waveVolume)
                    phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                case .drum:
                    value = liveDrumSample(note: note, patch: patch, channelIndex: channelIndex)
                }

                var shaped = value
                let tremoloAmount = Double(min(100, max(0, patch.tremolo))) / 100.0
                if channel != .drum && tremoloAmount > 0 {
                    let tremolo = 1.0 - tremoloAmount * 0.65 * (0.5 + 0.5 * sin((stepElapsed + Double(step) * secondsPerStep) * 2.0 * .pi * 7.0))
                    shaped *= tremolo
                }
                let mixed = gated ? 0.0 : shaped * channelGain(channel: channel, note: note, patch: patch) * envelopeLevel
                let sendIndex = ByteChannel.allCases.firstIndex(of: channel) ?? 0
                let send = project.effects.channelSends.indices.contains(sendIndex)
                    ? ByteAudioTaper.gain(for: project.effects.channelSends[sendIndex])
                    : 1.0
                if patch.panLeft {
                    left += mixed
                    effectsLeft += mixed * send
                }
                if patch.panRight {
                    right += mixed
                    effectsRight += mixed * send
                }
            }

            let effected = effectsProcessor.process(left: effectsLeft, right: effectsRight, effects: project.effects, sampleRate: sampleRate)
            let dryLeft = left - effectsLeft
            let dryRight = right - effectsRight
            let leftSample = Float(max(-0.9, min(0.9, dryLeft + effected.left)))
            let rightSample = Float(max(-0.9, min(0.9, dryRight + effected.right)))
            if buffers.count == 1 {
                if let buffer = channelPointers[0] {
                    buffer[frame * 2] = leftSample
                    buffer[frame * 2 + 1] = rightSample
                }
            } else {
                if let leftBuffer = channelPointers[0] { leftBuffer[frame] = leftSample }
                if let rightBuffer = channelPointers[1] { rightBuffer[frame] = rightSample }
                if buffers.count > 2 {
                    for index in 2..<buffers.count {
                        if let buffer = channelPointers[index] { buffer[frame] = 0 }
                    }
                }
            }

            stepElapsed += 1.0 / sampleRate
            if stepElapsed >= secondsPerStep {
                stepElapsed -= secondsPerStep
                if playbackStep + 1 >= pattern.steps.first?.count ?? 16 {
                    playbackStep = 0
                    patternIndex = (patternIndex + 1) % max(1, patterns.count)
                    for index in ByteChannel.allCases.indices { phases[index] = 0; drumSamplePositions[index] = 0 }
                } else {
                    playbackStep += 1
                }
            }
        }

        // Mixed on top of the sequence, so scrubbing a pitch while the loop plays is heard
        // immediately instead of waiting for the transport to come back round to the step.
        renderAudition(
            frameCount: frameCount,
            buffers: buffers,
            channelPointers: channelPointers,
            project: project,
            sampleRate: sampleRate
        )
    }

    private func noteAt(row: Int, step: Int, pattern: BytePattern) -> (note: Int, start: Int, length: Int)? {
        guard ByteChannel.allCases.indices.contains(row), pattern.steps.indices.contains(row), (0..<pattern.steps[row].count).contains(step) else { return nil }
        if let note = pattern.steps[row][step] {
            let isDrum = row == (ByteChannel.allCases.firstIndex(of: .drum) ?? -1)
            let length = isDrum ? 1 : min(pattern.steps[row].count - step, max(1, pattern.noteLengths[row][step]))
            return (note, step, length)
        }
        // Drum cells are independent one-shots; an empty beat must not replay the
        // previous drum sample or create a hidden link.
        if row == (ByteChannel.allCases.firstIndex(of: .drum) ?? -1) { return nil }
        for candidate in stride(from: step - 1, through: 0, by: -1) {
            guard pattern.steps[row][candidate] != nil else { continue }
            let length = min(pattern.steps[row].count - candidate, max(1, pattern.noteLengths[row][candidate]))
            if candidate + length > step, let note = pattern.steps[row][candidate] {
                return (note, candidate, length)
            }
            break
        }
        return nil
    }

    private func setCurrentStep(_ step: Int) {
        transportLock.lock()
        currentStepValue = step
        transportLock.unlock()
    }

    private func setCurrentSongSlot(_ slot: Int) {
        transportLock.lock()
        currentSongSlotValue = slot
        transportLock.unlock()
    }


    /// The pulse duty cycle for a patch. Pulled out of the render loop so an audition cannot
    /// drift from the sequence, and so the table is built once rather than once per frame.
    private func pulseDuty(_ patch: ByteChannelPatch) -> Double {
        Self.pulseDuties[min(3, max(0, patch.duty))]
    }

    /// The steady part of a channel's level: its voice weight, the patch volume, and the
    /// master taper. Shared with the audition, so a preview is heard at the level the note
    /// will really play at rather than at some convenient preview volume.
    private func channelGain(channel: ByteChannel, note: Int, patch: ByteChannelPatch) -> Double {
        let drumVolume = channel == .drum && patch.drumVolumes.indices.contains(ByteDrumVoice.voice(for: note).rawValue)
            ? patch.drumVolumes[ByteDrumVoice.voice(for: note).rawValue]
            : 15
        let effectiveVolume = channel == .drum ? drumVolume : patch.initialVolume
        let voiceWeight = channel == .drum ? 0.16 : (channel == .pulseA || channel == .pulseB ? 0.06 : 0.12)
        return voiceWeight * (Double(effectiveVolume) / 15.0) * ByteAudioTaper.gain(for: patch.masterVolume)
    }

    /// Renders one auditioned note, added to whatever the transport is producing.
    ///
    /// It runs the same oscillators, envelope and channel gain as the sequence so a preview
    /// sounds like the note it is previewing, but it reads and writes only its own voice slot
    /// and it deliberately ignores pan: a preview is a reference pitch, not a mix position.
    private func renderAudition(
        frameCount: Int,
        buffers: UnsafeMutableAudioBufferListPointer,
        channelPointers: [UnsafeMutablePointer<Float>?],
        project: ByteProject,
        sampleRate: Double
    ) {
        guard auditioning else { return }
        let channel = ByteChannel.allCases[min(max(0, auditionRow), ByteChannel.allCases.count - 1)]
        let patch = project.channelPatches.first(where: { $0.channel == channel }) ?? ByteChannelPatch(channel: channel)
        // Mute and solo are honoured, so an audition is an honest preview of the mix the
        // sequence will actually produce rather than a private channel that ignores the mixer.
        let hasSoloChannel = project.channelPatches.contains(where: { $0.soloed })
        guard !patch.muted, !hasSoloChannel || patch.soloed else {
            auditioning = false
            return
        }

        let slot = Self.auditionSlot
        let frequency = 440.0 * pow(2.0, Double(auditionNote - 69 + patch.octave * 12) / 12.0)

        for frame in 0..<frameCount {
            let normalized = min(1.0, auditionElapsed / Self.auditionDuration)
            let value: Double
            switch channel {
            case .pulseA, .pulseB:
                value = livePulse(phase: phases[slot], duty: pulseDuty(patch))
                phases[slot] = (phases[slot] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
            case .wave:
                value = liveWave(phase: phases[slot], shape: patch.waveShape, volume: patch.waveVolume)
                phases[slot] = (phases[slot] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
            case .drum:
                value = liveDrumSample(note: auditionNote, patch: patch, channelIndex: slot)
            }
            let envelopeLevel = channel == .drum ? 1.0 : liveEnvelope(normalized: normalized, patch: patch)
            let sample = Float(value * channelGain(channel: channel, note: auditionNote, patch: patch) * envelopeLevel)
            if buffers.count == 1 {
                if let buffer = channelPointers[0] {
                    buffer[frame * 2] += sample
                    buffer[frame * 2 + 1] += sample
                }
            } else {
                if let left = channelPointers[0] { left[frame] += sample }
                if let right = channelPointers[1] { right[frame] += sample }
            }
            auditionElapsed += 1.0 / sampleRate
            if auditionElapsed >= Self.auditionDuration {
                auditioning = false
                break
            }
        }
    }

    private func livePulse(phase: Double, duty: Double) -> Double {
        phase < duty ? 1.0 : -1.0
    }

    private func liveTriangle(phase: Double) -> Double {
        let wrapped = phase.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0.5 ? (wrapped * 4.0 - 1.0) : (3.0 - wrapped * 4.0)
    }

    /// Channel 3 is a 32-sample wavetable. The Sound Lab shape selector chooses the
    /// table, while the hardware-style volume control applies the DMG four-level gain.
    private func liveWave(phase: Double, shape: Int, volume: Int) -> Double {
        let table = ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, shape))].table
        let wrapped = phase - floor(phase)
        let position = wrapped * Double(table.count)
        let lower = Int(position) % table.count
        let upper = (lower + 1) % table.count
        let blend = position - floor(position)
        let sample = Double(table[lower]) + (Double(table[upper]) - Double(table[lower])) * blend
        let gains = [1.0, 0.5, 0.25, 0.0]
        return (sample / 7.5 - 1.0) * gains[min(3, max(0, volume))]
    }

    private func liveSweep(_ normalized: Double, patch: ByteChannelPatch) -> Double {
        guard patch.sweepPace > 0, patch.sweepShift > 0 else { return 0 }
        let clock = max(1.0, Double(patch.sweepPace))
        let stepped = floor(normalized * clock) / clock
        let amount = Double(patch.sweepShift) * 0.012
        return (patch.sweepIncrease ? 1.0 : -1.0) * stepped * amount
    }

    private func liveEnvelope(normalized: Double, patch: ByteChannelPatch) -> Double {
        let attack = Double(min(100, max(0, patch.envelopeAttack))) / 100.0 * 0.25
        let decay = Double(min(100, max(0, patch.envelopeDecay))) / 100.0 * 0.35
        let release = Double(min(100, max(0, patch.envelopeRelease))) / 100.0 * 0.25
        let sustain = Double(min(100, max(0, patch.envelopeSustain))) / 100.0
        if attack > 0, normalized < attack { return normalized / attack }
        let decayStart = attack
        let decayEnd = min(0.9, decayStart + decay)
        if decay > 0, normalized < decayEnd { return 1.0 - (1.0 - sustain) * ((normalized - decayStart) / decay) }
        if release > 0, normalized > 1.0 - release { return sustain * max(0.0, (1.0 - normalized) / release) }
        return sustain
    }

    private func liveDrumSample(note: Int, patch: ByteChannelPatch, channelIndex: Int) -> Double {
        let voice = ByteDrumVoice.voice(for: note)
        let variant = patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1
        let sample = ByteDrumSampleBank.shared.sample(voice: voice, variant: variant)
        let value = ByteDrumVoice.value(of: sample, voice: voice, at: drumSamplePositions[channelIndex])
        drumSamplePositions[channelIndex] += 1
        return value
    }

    private func liveNoiseClockRate(_ patch: ByteChannelPatch) -> Double {
        let dividerTable = [8, 16, 32, 48, 64, 80, 96, 112]
        let dividerValue = dividerTable[min(7, max(0, patch.noiseDivider))]
        return 4_194_304.0 / Double(dividerValue) / pow(2.0, Double(min(15, max(0, patch.noiseClockShift))))
    }
}

@MainActor
final class ByteAudioEngine {
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let liveState = ByteLiveAudioState()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var timer: Timer?
    private var auditionIdleTask: Task<Void, Never>?
    private let auditionIdleSeconds: Double
    private(set) var playing = false

    /// Whether the audio unit is running. Auditions are the only reason it can be running
    /// with the transport stopped, so a test needs to see this to pin that lifecycle.
    var isAudioUnitRunning: Bool { engine.isRunning }

    /// `auditionIdleSeconds` is injectable so a test can watch the audio unit go back to
    /// sleep without waiting out the real window.
    init(auditionIdleSeconds: Double = 5) {
        self.auditionIdleSeconds = auditionIdleSeconds
        let state = liveState
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            state.render(frameCount: Int(frameCount), audioBufferList: audioBufferList, sampleRate: 44_100)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Starts one continuous source. Subsequent update calls never stop or reset this transport.
    func play(project: ByteProject, patterns: [BytePattern]? = nil, useSongArrangement: Bool = false, startSongSlot: Int? = nil, onStep: @escaping (Int, Int) -> Void) {
        stop()
        let playbackPatterns = useSongArrangement ? project.songPatterns : (patterns ?? [project.patterns[0]])
        let slotIndices = useSongArrangement ? project.songSlotIndices : []
        liveState.begin(project: project, patterns: playbackPatterns, slotIndices: slotIndices, startSongSlot: startSongSlot)
        do {
            try engine.start()
            playing = true
            onStep(0, startSongSlot.flatMap { slotIndices.firstIndex(of: $0) }.flatMap { slotIndices[$0] } ?? slotIndices.first ?? -1)
            // Poll transport at 60 Hz: steps are at least ~62 ms apart even at 240 BPM,
            // and the playhead animates between updates, so 120 Hz only doubled lock
            // contention with the audio thread and battery drain in the background.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let position = self.liveState.currentPosition()
                onStep(position.step, position.songSlot)
            }
        } catch {
            stop()
        }
    }

    /// Publishes edits to the realtime source without touching the engine or transport position.
    func update(project: ByteProject, patterns: [BytePattern]? = nil, useSongArrangement: Bool = false, restartSequence: Bool = false) {
        let playbackPatterns = useSongArrangement ? project.songPatterns : (patterns ?? [project.patterns[0]])
        let slotIndices = useSongArrangement ? project.songSlotIndices : []
        liveState.update(project: project, patterns: playbackPatterns, slotIndices: slotIndices, restartSequence: restartSequence)
    }

    func seekSongSlot(_ slot: Int) {
        liveState.seekSongSlot(slot)
    }

    /// Plays one note on its own, for the pad grid's audition.
    ///
    /// An audition is the only thing that can make a sound while the transport is stopped,
    /// so this brings the audio unit up on demand. The unit is then left running for a few
    /// seconds after the last audition and closed again: long enough that a run of pitch
    /// scrubs stays warm and responsive, but not so long that the audio hardware is left
    /// powered up for the rest of the session.
    func audition(channel: ByteChannel, note: Int, project: ByteProject) {
        liveState.audition(row: ByteChannel.allCases.firstIndex(of: channel) ?? 0, note: note, project: project)
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                // A silent preview is better than a crash; the edit itself already landed.
                return
            }
        }
        scheduleAuditionIdleStop()
    }

    private func scheduleAuditionIdleStop() {
        auditionIdleTask?.cancel()
        auditionIdleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.auditionIdleSeconds))
            guard !Task.isCancelled, !self.playing else { return }
            self.engine.stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        auditionIdleTask?.cancel()
        auditionIdleTask = nil
        liveState.end()
        engine.stop()
        playing = false
    }
}

enum ByteRenderer {
    /// The whole take as interleaved stereo Floats.
    ///
    /// Only the tests call this now — the export streams to a file and live playback synthesizes a
    /// buffer at a time — but it is the reference the export paths are measured against, so it stays
    /// the plainest possible statement of what the synth produces.
    static func render(project: ByteProject, patterns sourcePatterns: [BytePattern]? = nil, sampleRate: Double, onProgress: @Sendable (Double) -> Void = { _ in }) -> [Float] {
        let patterns = sourcePatterns ?? project.arrangedPatterns
        let frames = patterns.isEmpty ? 0 : waveFrameCount(project: project, patterns: patterns, sampleRate: sampleRate)
        var output = [Float]()
        output.reserveCapacity(frames * 2)
        forEachWaveBlock(project: project, patterns: patterns, frames: frames, sampleRate: sampleRate, onProgress: onProgress) { block in
            output.append(contentsOf: block)
        }
        return output
#if false
        let totalSteps = patterns.count * 16
        let secondsPerStep = ByteTransportClock.stepDuration(bpm: project.tempo)
        let totalSamples = Int(Double(totalSteps) * secondsPerStep * sampleRate)
        var output = Array(repeating: Float(0), count: totalSamples * 2)

        var globalOffset = 0
        for pattern in patterns {
            let stepCount = 16
            let patternStart = globalOffset
            let patternEnd = patternStart + stepCount
            for globalStep in patternStart..<patternEnd {
                let step = globalStep - patternStart
                let start = Int(Double(globalStep) * secondsPerStep * sampleRate)
                let end = min(totalSamples, start + Int(secondsPerStep * sampleRate))

            for (channelIndex, channel) in ByteChannel.allCases.enumerated() {
                guard let activeNote = noteAt(row: channelIndex, step: step, pattern: pattern) else { continue }
                let note = activeNote.note
                let patch = project.channelPatches.first(where: { $0.channel == channel }) ?? ByteChannelPatch(channel: channel)
                let hasSoloChannel = project.channelPatches.contains(where: { $0.soloed })
                guard !patch.muted, !hasSoloChannel || patch.soloed else { continue }
                let baseFrequency = 440.0 * pow(2.0, Double(note - 69 + patch.octave * 12) / 12.0)
                let baseGain = channel == .drum ? 0.16 : (channel == .pulseA || channel == .pulseB ? 0.06 : 0.12)
                var drumSamplePosition = 0

                for sample in start..<end {
                    let local = sample - start
                    let normalized = Double(local) / Double(max(1, end - start))
                    let noteProgress = Double(step - activeNote.start) + normalized
                    let noteNormalized = min(1.0, max(0.0, noteProgress / Double(max(1, activeNote.length))))
                    let t = Double(sample) / sampleRate
                    let sweep = channel == .pulseA ? dmgSweep(noteNormalized, patch: patch) : 0.0
                    let vibratoDepth = Double(patch.vibratoDepth) / 100.0
                    let vibrato = vibratoDepth > 0
                        ? sin(t * Double(patch.vibratoRate) * 2.0 * .pi) * vibratoDepth * 0.018
                        : 0.0
                    let flutterMultiplier = channel == .drum ? 1.0 : ByteEffects.octaveFlutterMultiplier(
                        at: Double(sampleIndex) / sampleRate,
                        bpm: project.tempo,
                        amount: patch.octaveFlutterAmount,
                        pattern: ByteOctaveFlutterPattern(rawValue: patch.octaveFlutterPattern) ?? .baseUp
                    )
                    let frequency = baseFrequency * flutterMultiplier * (1.0 + vibrato + sweep)
                    // Drum samples are complete one-shots; let their own WAV tails play.
                    let effectiveLength = channel == .drum ? 63 : patch.length
                    let drumVolume = channel == .drum && patch.drumVolumes.indices.contains(ByteDrumVoice.voice(for: note).rawValue)
                    ? patch.drumVolumes[ByteDrumVoice.voice(for: note).rawValue]
                    : 15
                let effectiveVolume = channel == .drum ? drumVolume : patch.initialVolume
                    let gated = channel == .drum ? false : (patch.lengthCounter && noteNormalized > Double(effectiveLength) / 63.0)
                    let envelopeLevel = channel == .drum ? 1.0 : envelope(normalized: noteNormalized, patch: patch)
                    var value: Double

                    switch channel {
                    case .pulseA, .pulseB:
                        let duties = [0.125, 0.25, 0.50, 0.75]
                        let duty = duties[min(3, max(0, patch.duty))]
                        value = pulse(t * frequency, duty: duty)
                    case .wave:
                        let shifts = [1.0, 0.5, 0.25, 0.0]
                        let table = ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, patch.waveShape))].table
                        let rawWave = wave4Bit(phase: t * frequency, table: table) * shifts[min(3, max(0, patch.waveVolume))]
                        let decay = 1.0 - (Double(min(100, max(0, patch.waveEnvelope))) / 100.0) * noteNormalized
                        value = rawWave * max(0.0, decay)
                    case .drum:
                        let voice = ByteDrumVoice.voice(for: note)
                        let variant = patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1
                        let sampleData = ByteDrumSampleBank.shared.sample(voice: voice, variant: variant)
                        value = drumSamplePosition < sampleData.count ? Double(sampleData[drumSamplePosition]) : 0.0
                        drumSamplePosition += 1
                    }

                    if project.effects.bitCrushAmount > 0 {
                        let blend = Double(min(100, max(0, project.effects.bitCrushAmount))) / 100.0
                        let effectiveAmount = ByteEffects.bitCrushEffectiveAmount(for: project.effects.bitCrushAmount)
                        let levels = ByteEffects.bitCrushLevels(for: effectiveAmount)
                        let crushed = (value * levels).rounded() / levels
                        value += (crushed - value) * blend
                    }
                    let masterLevel = ByteAudioTaper.gain(for: patch.masterVolume)
                    let mixed = gated ? 0.0 : Float(value * baseGain * (Double(effectiveVolume) / 15.0) * envelopeLevel * masterLevel)
                    if patch.panLeft { output[sample * 2] += mixed }
                    if patch.panRight { output[sample * 2 + 1] += mixed }
                }
            }
        }
        globalOffset = patternEnd
    }

        // Delay is disabled globally; old echo data must not affect new exports.
        return mixed
#endif
    }

    /// Longest run of frames synthesized in a single call. Large enough that the per-block
    /// bookkeeping costs nothing measurable, small enough that the scratch buffers a blocked export
    /// holds are kilobytes rather than the tens of megabytes the whole take would be.
    private static let waveBlockFrames = 32_768

    /// The synth's mutable state, in a value that outlives a single call so a take can be rendered
    /// a block at a time.
    ///
    /// Live playback walks this same math sample by sample; an export walks it to the end of the
    /// arrangement. Keeping the state — oscillator phases, drum read positions, the delay line —
    /// outside the loop is what lets the WAV writer convert a block and stream it out while the next
    /// one is synthesized, instead of the whole take having to exist as Floats before a single byte
    /// can be written.
    private struct ByteRenderCursor {
        let project: ByteProject
        let patterns: [BytePattern]
        let sampleRate: Double
        let secondsPerStep: Double
        var stepElapsed = 0.0
        var playbackStep = 0
        var patternIndex = 0
        var lastStep = -1
        var phases: [Double]
        var drumSamplePositions: [Double]
        var effectsProcessor: ByteMixEffects

        init(project: ByteProject, patterns: [BytePattern], sampleRate: Double) {
            self.project = project
            self.patterns = patterns
            self.sampleRate = sampleRate
            self.secondsPerStep = ByteTransportClock.stepDuration(bpm: project.tempo)
            self.phases = Array(repeating: 0.0, count: ByteChannel.allCases.count)
            self.drumSamplePositions = Array(repeating: 0.0, count: ByteChannel.allCases.count)
            self.effectsProcessor = ByteMixEffects(sampleRate: sampleRate)
        }

        /// Writes `frames` interleaved stereo frames into `output`, then carries the state on to the
        /// next call.
        ///
        /// Only the route the samples take out of here is new. Where a block boundary falls cannot
        /// change a sample of the take, which is why rendering an arrangement in one call and in a
        /// thousand of them is the same audio.
        mutating func render(into output: UnsafeMutableBufferPointer<Float>, frames: Int) {
            for frame in 0..<frames {
                let pattern = patterns[min(patternIndex, patterns.count - 1)]
                let step = playbackStep
                let normalized = min(1.0, max(0.0, stepElapsed / secondsPerStep))
                if step != lastStep {
                    lastStep = step
                    for channelIndex in ByteChannel.allCases.indices {
                        if let active = noteAt(row: channelIndex, step: step, pattern: pattern), active.start == step {
                            phases[channelIndex] = 0.0
                            drumSamplePositions[channelIndex] = 0
                        }
                    }
                }

                var left = 0.0
                var right = 0.0
                var effectsLeft = 0.0
                var effectsRight = 0.0
                for (channelIndex, channel) in ByteChannel.allCases.enumerated() {
                    guard let activeNote = noteAt(row: channelIndex, step: step, pattern: pattern) else { continue }
                    let note = activeNote.note
                    let noteProgress = Double(step - activeNote.start) + normalized
                    let noteNormalized = min(1.0, max(0.0, noteProgress / Double(max(1, activeNote.length))))
                    let patch = project.channelPatches.first(where: { $0.channel == channel }) ?? ByteChannelPatch(channel: channel)
                    let hasSoloChannel = project.channelPatches.contains(where: { $0.soloed })
                    guard !patch.muted, !hasSoloChannel || patch.soloed else { continue }
                    let baseFrequency = 440.0 * pow(2.0, Double(note - 69 + patch.octave * 12) / 12.0)
                    let sweep = channel == .pulseA ? dmgSweep(noteNormalized, patch: patch) : 0.0
                    let portamentoAmount = Double(min(100, max(0, patch.portamento))) / 100.0
                    let portamentoTime = max(0.01, Double(min(100, max(0, patch.portamentoTime))) / 100.0)
                    let portamentoProgress = min(1.0, noteProgress / max(0.01, portamentoTime * 2.0))
                    let portamentoSemitones = (1.0 - portamentoProgress) * portamentoAmount * Double(patch.bendRange)
                    let vibratoDepth = Double(min(100, max(0, patch.vibratoDepth))) / 100.0
                    let vibratoCycle = 0.05 + Double(min(100, max(0, patch.vibratoCycleLength))) / 100.0 * 0.45
                    let vibratoDelay = Double(min(100, max(0, patch.vibratoDelay))) / 100.0 * max(0.01, Double(activeNote.length))
                    let vibratoTime = Double(step - activeNote.start) + normalized
                    let vibrato = vibratoDepth > 0 && vibratoTime >= vibratoDelay
                        ? sin((vibratoTime - vibratoDelay) * secondsPerStep * 2.0 * .pi / vibratoCycle) * vibratoDepth * 0.018
                        : 0.0
                    let flutterMultiplier = channel == .drum ? 1.0 : ByteEffects.octaveFlutterMultiplier(
                        at: Double(step) * secondsPerStep + stepElapsed,
                        bpm: project.tempo,
                        amount: patch.octaveFlutterAmount,
                        pattern: ByteOctaveFlutterPattern(rawValue: patch.octaveFlutterPattern) ?? .baseUp
                    )
                    let frequency = max(1.0, baseFrequency * pow(2.0, portamentoSemitones / 12.0) * flutterMultiplier * (1.0 + vibrato + sweep))
                    let effectiveLength = channel == .drum ? 63 : patch.length
                    let drumVolume = channel == .drum && patch.drumVolumes.indices.contains(ByteDrumVoice.voice(for: note).rawValue)
                        ? patch.drumVolumes[ByteDrumVoice.voice(for: note).rawValue]
                        : 15
                    let effectiveVolume = channel == .drum ? drumVolume : patch.initialVolume
                    let gated = channel == .drum ? false : (patch.lengthCounter && noteNormalized > Double(effectiveLength) / 63.0)
                    let envelopeLevel = channel == .drum ? 1.0 : envelope(normalized: noteNormalized, patch: patch)
                    let value: Double

                    switch channel {
                    case .pulseA, .pulseB:
                        let duties = [0.125, 0.25, 0.50, 0.75]
                        value = pulse(phases[channelIndex], duty: duties[min(3, max(0, patch.duty))])
                        phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                    case .wave:
                        value = wave(phase: phases[channelIndex], shape: patch.waveShape, volume: patch.waveVolume)
                        phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                    case .drum:
                        let voice = ByteDrumVoice.voice(for: note)
                        let variant = patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1
                        let sampleData = ByteDrumSampleBank.shared.sample(voice: voice, variant: variant)
                        // The same reader live playback uses, so an export carries the same kit.
                        value = ByteDrumVoice.value(of: sampleData, voice: voice, at: drumSamplePositions[channelIndex])
                        drumSamplePositions[channelIndex] += 1
                    }

                    var shaped = value
                    let tremoloAmount = Double(min(100, max(0, patch.tremolo))) / 100.0
                    if channel != .drum && tremoloAmount > 0 {
                        let tremolo = 1.0 - tremoloAmount * 0.65 * (0.5 + 0.5 * sin((stepElapsed + Double(step) * secondsPerStep) * 2.0 * .pi * 7.0))
                        shaped *= tremolo
                    }
                    let masterLevel = ByteAudioTaper.gain(for: patch.masterVolume)
                    let mixed = gated ? 0.0 : shaped * (channel == .drum ? 0.16 : (channel == .pulseA || channel == .pulseB ? 0.06 : 0.12)) * (Double(effectiveVolume) / 15.0) * envelopeLevel * masterLevel
                    let sendIndex = ByteChannel.allCases.firstIndex(of: channel) ?? 0
                    let send = project.effects.channelSends.indices.contains(sendIndex)
                        ? ByteAudioTaper.gain(for: project.effects.channelSends[sendIndex])
                        : 1.0
                    if patch.panLeft {
                        left += mixed
                        effectsLeft += mixed * send
                    }
                    if patch.panRight {
                        right += mixed
                        effectsRight += mixed * send
                    }
                }

                let effected = effectsProcessor.process(left: effectsLeft, right: effectsRight, effects: project.effects, sampleRate: sampleRate)
                let dryLeft = left - effectsLeft
                let dryRight = right - effectsRight
                output[frame * 2] = Float(max(-0.9, min(0.9, dryLeft + effected.left)))
                output[frame * 2 + 1] = Float(max(-0.9, min(0.9, dryRight + effected.right)))

                stepElapsed += 1.0 / sampleRate
                if stepElapsed >= secondsPerStep {
                    stepElapsed -= secondsPerStep
                    if playbackStep + 1 >= 16 {
                        playbackStep = 0
                        patternIndex = (patternIndex + 1) % patterns.count
                        for index in ByteChannel.allCases.indices {
                            phases[index] = 0.0
                            drumSamplePositions[index] = 0
                        }
                    } else {
                        playbackStep += 1
                    }
                }
            }
        }
    }

    /// Renders a whole take a block at a time, handing each block of interleaved stereo samples to
    /// `consume`.
    ///
    /// Every export path runs through this one loop, so a file streamed to disk and a buffer built
    /// in memory cannot drift apart — they differ only in what they do with a block.
    private static func forEachWaveBlock(
        project: ByteProject,
        patterns: [BytePattern],
        frames: Int,
        sampleRate: Double,
        onProgress: @Sendable (Double) -> Void,
        consume: (UnsafeBufferPointer<Float>) throws -> Void
    ) rethrows {
        guard frames > 0 else {
            onProgress(1.0)
            return
        }
        onProgress(0.0)
        var cursor = ByteRenderCursor(project: project, patterns: patterns, sampleRate: sampleRate)
        var block = [Float](repeating: 0, count: waveBlockFrames * 2)
        var rendered = 0
        while rendered < frames {
            let count = min(waveBlockFrames, frames - rendered)
            try block.withUnsafeMutableBufferPointer { buffer in
                let slice = UnsafeMutableBufferPointer(rebasing: buffer[0..<(count * 2)])
                cursor.render(into: slice, frames: count)
                try consume(UnsafeBufferPointer(slice))
            }
            rendered += count
            onProgress(Double(rendered) / Double(frames))
        }
    }

    /// How many frames a take renders to. The arrangement has a fixed length, so this is known
    /// before the first sample is synthesized — which is what lets a streaming writer put the real
    /// sizes in the RIFF header as it opens the file, instead of seeking back to patch them in.
    private static func waveFrameCount(project: ByteProject, patterns: [BytePattern], sampleRate: Double) -> Int {
        Int(Double(patterns.count * 16) * ByteTransportClock.stepDuration(bpm: project.tempo) * sampleRate)
    }

    /// The canonical 44-byte RIFF header for a PCM payload of `dataSize` bytes: stereo, 16-bit.
    private static func waveHeader(dataSize: UInt32, sampleRate: Double) -> Data {
        let channels: UInt16 = 2
        let bits: UInt16 = 16
        let bytesPerSample = Int(bits / 8)
        var header = Data()
        header.reserveCapacity(44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendLittleEndian(36 + dataSize)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(channels)
        header.appendLittleEndian(UInt32(sampleRate))
        header.appendLittleEndian(UInt32(Int(sampleRate) * Int(channels) * bytesPerSample))
        header.appendLittleEndian(UInt16(Int(channels) * bytesPerSample))
        header.appendLittleEndian(bits)
        header.append(contentsOf: Array("data".utf8))
        header.appendLittleEndian(dataSize)
        return header
    }

    /// Clamps one block of floats into the fixed-size 16-bit scratch buffer the caller reuses for
    /// the whole render, which is why nothing here allocates. `FixedWidthInteger` bytes are
    /// little-endian on every platform this app runs on, which is what RIFF wants.
    private static func convertToPCM(_ block: UnsafeBufferPointer<Float>, into pcm: inout [Int16]) {
        for index in block.indices {
            pcm[index] = Int16(max(-1, min(1, block[index])) * Float(Int16.max))
        }
    }

    /// Renders a take straight into a WAV file on disk, a block at a time.
    ///
    /// Nothing here is the size of the song. A long arrangement is tens of megabytes of 16-bit
    /// audio and twice that while it is still Floats, so the old pair of buffers — the render and
    /// the encoded `Data` — peaked far above the size of the file being handed over, and how long a
    /// take could be was a question about the phone's spare memory. The stream holds one block of
    /// each instead.
    ///
    /// The file lands where a handover needs it: the activity sheet is given this URL, and the Files
    /// picker copies this same file, so neither of them holds the audio in memory either.
    @discardableResult
    static func streamWave(project: ByteProject, patterns sourcePatterns: [BytePattern]? = nil, sampleRate: Double = 44_100, to url: URL, onProgress: @Sendable (Double) -> Void = { _ in }) throws -> URL {
        let patterns = sourcePatterns ?? project.arrangedPatterns
        let frames = patterns.isEmpty ? 0 : waveFrameCount(project: project, patterns: patterns, sampleRate: sampleRate)
        // Stereo 16-bit: four bytes per frame.
        let dataSize = UInt32(frames * 4)
        var pcm = [Int16](repeating: 0, count: waveBlockFrames * 2)
        try ByteWaveFile.withStagingFile(at: url) { handle in
            try handle.write(contentsOf: waveHeader(dataSize: dataSize, sampleRate: sampleRate))
            try forEachWaveBlock(project: project, patterns: patterns, frames: frames, sampleRate: sampleRate, onProgress: onProgress) { block in
                convertToPCM(block, into: &pcm)
                try pcm.withUnsafeBytes { raw in
                    try handle.write(contentsOf: Data(bytes: raw.baseAddress!, count: block.count * 2))
                }
            }
        }
        return url
    }

    /// The whole take as WAV bytes in memory.
    ///
    /// The app's export path no longer uses this — it streams to a file — but the reference-encoding
    /// tests do, and sharing one encoder with `streamWave` is what makes the two provably the same
    /// audio rather than merely similar.
    static func wavData(project: ByteProject, patterns sourcePatterns: [BytePattern]? = nil, sampleRate: Double = 44_100, onProgress: @Sendable (Double) -> Void = { _ in }) -> Data {
        let patterns = sourcePatterns ?? project.arrangedPatterns
        let frames = patterns.isEmpty ? 0 : waveFrameCount(project: project, patterns: patterns, sampleRate: sampleRate)
        // Stereo 16-bit: four bytes per frame.
        let dataSize = UInt32(frames * 4)
        var data = waveHeader(dataSize: dataSize, sampleRate: sampleRate)
        var pcm = [Int16](repeating: 0, count: waveBlockFrames * 2)
        // Reserving the payload up front keeps the appends below from repeatedly reallocating as the
        // buffer grows.
        data.reserveCapacity(44 + Int(dataSize))
        forEachWaveBlock(project: project, patterns: patterns, frames: frames, sampleRate: sampleRate, onProgress: onProgress) { block in
            convertToPCM(block, into: &pcm)
            pcm.withUnsafeBytes { data.append(contentsOf: $0.prefix(block.count * 2)) }
        }
        return data
    }

    private static func pulse(_ phase: Double, duty: Double) -> Double {
        phase.truncatingRemainder(dividingBy: 1) < duty ? 1 : -1
    }

    private static func dmgSweep(_ normalized: Double, patch: ByteChannelPatch) -> Double {
        guard patch.sweepPace > 0, patch.sweepShift > 0 else { return 0 }
        let clock = max(1.0, Double(patch.sweepPace))
        let stepped = floor(normalized * clock) / clock
        let amount = Double(patch.sweepShift) * 0.012
        return (patch.sweepIncrease ? 1.0 : -1.0) * stepped * amount
    }

    private static func envelope(normalized: Double, patch: ByteChannelPatch) -> Double {
        let attack = Double(min(100, max(0, patch.envelopeAttack))) / 100.0 * 0.25
        let decay = Double(min(100, max(0, patch.envelopeDecay))) / 100.0 * 0.35
        let release = Double(min(100, max(0, patch.envelopeRelease))) / 100.0 * 0.25
        let sustain = Double(min(100, max(0, patch.envelopeSustain))) / 100.0
        if attack > 0, normalized < attack { return normalized / attack }
        let decayStart = attack
        let decayEnd = min(0.9, decayStart + decay)
        if decay > 0, normalized < decayEnd { return 1.0 - (1.0 - sustain) * ((normalized - decayStart) / decay) }
        if release > 0, normalized > 1.0 - release { return sustain * max(0.0, (1.0 - normalized) / release) }
        return sustain
    }

    private static func triangle(phase: Double) -> Double {
        let wrapped = phase.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0.5 ? (wrapped * 4.0 - 1.0) : (3.0 - wrapped * 4.0)
    }

    /// Stateful renderer counterpart to liveWave so exports match live playback.
    private static func wave(phase: Double, shape: Int, volume: Int) -> Double {
        let table = ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, shape))].table
        let wrapped = phase - floor(phase)
        let position = wrapped * Double(table.count)
        let lower = Int(position) % table.count
        let upper = (lower + 1) % table.count
        let blend = position - floor(position)
        let sample = Double(table[lower]) + (Double(table[upper]) - Double(table[lower])) * blend
        let gains = [1.0, 0.5, 0.25, 0.0]
        return (sample / 7.5 - 1.0) * gains[min(3, max(0, volume))]
    }


    private static func noteAt(row: Int, step: Int, pattern: BytePattern) -> (note: Int, start: Int, length: Int)? {
        guard ByteChannel.allCases.indices.contains(row), pattern.steps.indices.contains(row), (0..<pattern.steps[row].count).contains(step) else { return nil }
        if let note = pattern.steps[row][step] {
            let isDrum = row == (ByteChannel.allCases.firstIndex(of: .drum) ?? -1)
            let length = isDrum ? 1 : min(pattern.steps[row].count - step, max(1, pattern.noteLengths[row][step]))
            return (note, step, length)
        }
        if row == (ByteChannel.allCases.firstIndex(of: .drum) ?? -1) { return nil }
        for candidate in stride(from: step - 1, through: 0, by: -1) {
            guard pattern.steps[row][candidate] != nil else { continue }
            let length = min(pattern.steps[row].count - candidate, max(1, pattern.noteLengths[row][candidate]))
            if candidate + length > step, let note = pattern.steps[row][candidate] {
                return (note, candidate, length)
            }
            break
        }
        return nil
    }

    private static func dmgNoiseClockRate(_ patch: ByteChannelPatch) -> Double {
        let dividerTable = [8, 16, 32, 48, 64, 80, 96, 112]
        let dividerValue = dividerTable[min(7, max(0, patch.noiseDivider))]
        return 4_194_304.0 / Double(dividerValue) / pow(2.0, Double(min(15, max(0, patch.noiseClockShift))))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
