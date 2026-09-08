import AVFoundation
import Foundation

enum ByteTransportClock {
    static func stepDuration(bpm: Int) -> Double {
        60.0 / Double(max(1, bpm)) / 4.0
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
    private var phases = Array(repeating: 0.0, count: 4)
    private var waveFilterStates = Array(repeating: 0.0, count: 4)
    private var noiseStates: [UInt16] = Array(repeating: 0x7FFF, count: 4)
    private var noiseAccumulators = Array(repeating: 0.0, count: 4)
    private var drumSamplePositions = Array(repeating: 0, count: 4)
    private var effectsProcessor = ByteMixEffects(sampleRate: 44_100)
    private var currentStepValue = 0
    private var currentSongSlotValue = -1
    /// UI scrubbing submits one command; the realtime callback consumes it at a safe render boundary.
    private var pendingSongSlot: Int?

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
        phases = Array(repeating: 0.0, count: 4)
        waveFilterStates = Array(repeating: 0.0, count: 4)
        noiseStates = Array(repeating: 0x7FFF, count: 4)
        noiseAccumulators = Array(repeating: 0.0, count: 4)
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
        dataLock.unlock()

        // Only the realtime callback mutates oscillator and step state. This avoids racing
        // the audio thread when the user scrubs repeatedly across the timeline.
        if resetTransport {
            stepElapsed = 0
            playbackStep = 0
            lastStep = -1
            phases = Array(repeating: 0.0, count: 4)
            drumSamplePositions = Array(repeating: 0, count: 4)
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
                let drumVolume = channel == .drum && patch.drumVolumes.indices.contains(ByteDrumVoice.voice(for: note).rawValue)
                    ? patch.drumVolumes[ByteDrumVoice.voice(for: note).rawValue]
                    : 15
                let effectiveVolume = channel == .drum ? drumVolume : patch.initialVolume
                let gated = channel == .drum ? false : (patch.lengthCounter && noteNormalized > Double(effectiveLength) / 63.0)
                let envelopeLevel = channel == .drum ? 1.0 : liveEnvelope(normalized: noteNormalized, patch: patch)
                let value: Double

                switch channel {
                case .pulseA, .pulseB:
                    let duties = [0.125, 0.25, 0.50, 0.75]
                    let duty = duties[min(3, max(0, patch.duty))]
                    value = livePulse(phase: phases[channelIndex], duty: duty)
                    phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                case .wave:
                    value = liveTriangle(phase: phases[channelIndex])
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
                let masterLevel = Double(min(100, max(0, patch.masterVolume))) / 100.0
                let mixed = gated ? 0.0 : shaped * (channel == .drum ? 0.16 : (channel == .pulseA || channel == .pulseB ? 0.06 : 0.12)) * (Double(effectiveVolume) / 15.0) * envelopeLevel * masterLevel
                let sendIndex = ByteChannel.allCases.firstIndex(of: channel) ?? 0
                let send = project.effects.channelSends.indices.contains(sendIndex)
                    ? Double(min(100, max(0, project.effects.channelSends[sendIndex]))) / 100.0
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


    private func livePulse(phase: Double, duty: Double) -> Double {
        phase < duty ? 1.0 : -1.0
    }

    private func liveTriangle(phase: Double) -> Double {
        let wrapped = phase.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0.5 ? (wrapped * 4.0 - 1.0) : (3.0 - wrapped * 4.0)
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

    private func liveDrumVoice(note: Int, normalized: Double, lfsr: Double, secondsPerStep: Double) -> Double {
        // DMG drums remain LFSR noise; the kick adds a short low-frequency body whose
        // pitch falls rapidly, matching the compact impact used by Game Boy music engines.
        switch note {
        case 36:
            let bodyFrequency = 145.0 - normalized * 105.0
            let body = sin(normalized * secondsPerStep * bodyFrequency * 2.0 * .pi) * exp(-normalized * 5.5)
            return lfsr * 0.48 + body * 0.92
        case 38:
            return lfsr * (0.72 + (1.0 - normalized) * 0.18)
        case 42:
            return lfsr * 0.52
        case 49:
            return lfsr * (0.84 + (1.0 - normalized) * 0.16)
        default:
            return lfsr
        }
    }

    private func liveDrumSample(note: Int, patch: ByteChannelPatch, channelIndex: Int) -> Double {
        let voice = ByteDrumVoice.voice(for: note)
        let variant = patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1
        let sample = ByteDrumSampleBank.shared.sample(voice: voice, variant: variant)
        guard drumSamplePositions[channelIndex] < sample.count else { return 0 }
        let value = Double(sample[drumSamplePositions[channelIndex]])
        drumSamplePositions[channelIndex] += 1
        return value
    }

    private func drumVoiceIndex(_ note: Int) -> Int {
        switch note {
        case 38: return 1
        case 42: return 2
        case 49: return 3
        default: return 0
        }
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
    private(set) var playing = false

    init() {
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
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
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

    func stop() {
        timer?.invalidate()
        timer = nil
        liveState.end()
        engine.stop()
        playing = false
    }
}

enum ByteRenderer {
    static func render(project: ByteProject, patterns sourcePatterns: [BytePattern]? = nil, sampleRate: Double, onProgress: @Sendable (Double) -> Void = { _ in }) -> [Float] {
        let patterns = sourcePatterns ?? project.arrangedPatterns
        return renderStateful(project: project, patterns: patterns, sampleRate: sampleRate, onProgress: onProgress)
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
                    let masterLevel = Double(min(100, max(0, patch.masterVolume))) / 100.0
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

    private static func renderStateful(project: ByteProject, patterns: [BytePattern], sampleRate: Double, onProgress: @Sendable (Double) -> Void) -> [Float] {
        return renderStatefulAccurate(project: project, patterns: patterns, sampleRate: sampleRate, onProgress: onProgress)
    }

    private static func renderStatefulAccurate(project: ByteProject, patterns: [BytePattern], sampleRate: Double, onProgress: @Sendable (Double) -> Void) -> [Float] {
        guard !patterns.isEmpty else {
            onProgress(1.0)
            return []
        }
        onProgress(0.0)
        let secondsPerStep = ByteTransportClock.stepDuration(bpm: project.tempo)
        let totalSamples = Int(Double(patterns.count * 16) * secondsPerStep * sampleRate)
        var output = Array(repeating: Float(0), count: totalSamples * 2)
        var stepElapsed = 0.0
        var playbackStep = 0
        var patternIndex = 0
        var lastStep = -1
        var phases = Array(repeating: 0.0, count: ByteChannel.allCases.count)
        var drumSamplePositions = Array(repeating: 0, count: ByteChannel.allCases.count)
        let progressInterval = max(1, totalSamples / 100)

        var effectsProcessor = ByteMixEffects(sampleRate: sampleRate)
        for sampleIndex in 0..<totalSamples {
            if sampleIndex % progressInterval == 0 {
                onProgress(Double(sampleIndex) / Double(max(1, totalSamples)) * 0.95)
            }
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
                    value = triangle(phase: phases[channelIndex])
                    phases[channelIndex] = (phases[channelIndex] + frequency / sampleRate).truncatingRemainder(dividingBy: 1.0)
                case .drum:
                    let voice = ByteDrumVoice.voice(for: note)
                    let variant = patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1
                    let sampleData = ByteDrumSampleBank.shared.sample(voice: voice, variant: variant)
                    if drumSamplePositions[channelIndex] < sampleData.count {
                        value = Double(sampleData[drumSamplePositions[channelIndex]])
                        drumSamplePositions[channelIndex] += 1
                    } else {
                        value = 0.0
                    }
                }

                var shaped = value
                let tremoloAmount = Double(min(100, max(0, patch.tremolo))) / 100.0
                if channel != .drum && tremoloAmount > 0 {
                    let tremolo = 1.0 - tremoloAmount * 0.65 * (0.5 + 0.5 * sin((stepElapsed + Double(step) * secondsPerStep) * 2.0 * .pi * 7.0))
                    shaped *= tremolo
                }
                let masterLevel = Double(min(100, max(0, patch.masterVolume))) / 100.0
                let mixed = gated ? 0.0 : shaped * (channel == .drum ? 0.16 : (channel == .pulseA || channel == .pulseB ? 0.06 : 0.12)) * (Double(effectiveVolume) / 15.0) * envelopeLevel * masterLevel
                let sendIndex = ByteChannel.allCases.firstIndex(of: channel) ?? 0
                let send = project.effects.channelSends.indices.contains(sendIndex)
                    ? Double(min(100, max(0, project.effects.channelSends[sendIndex]))) / 100.0
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
            output[sampleIndex * 2] = Float(max(-0.9, min(0.9, dryLeft + effected.left)))
            output[sampleIndex * 2 + 1] = Float(max(-0.9, min(0.9, dryRight + effected.right)))

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

        onProgress(0.95)
        return output
    }

    static func wavData(project: ByteProject, patterns: [BytePattern]? = nil, sampleRate: Double = 44_100, onProgress: @Sendable (Double) -> Void = { _ in }) -> Data {
        let samples = render(project: project, patterns: patterns, sampleRate: sampleRate, onProgress: onProgress)
        let channels: UInt16 = 2
        let bits: UInt16 = 16
        let bytesPerSample = Int(bits / 8)
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        let conversionInterval = max(1, samples.count / 20)
        for (index, sample) in samples.enumerated() {
            pcm.append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
            if index % conversionInterval == 0 {
                onProgress(0.95 + Double(index) / Double(max(1, samples.count)) * 0.05)
            }
        }
        onProgress(1.0)
        let dataSize = UInt32(pcm.count * bytesPerSample)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(Int(sampleRate) * Int(channels) * bytesPerSample))
        data.appendLittleEndian(UInt16(Int(channels) * bytesPerSample))
        data.appendLittleEndian(bits)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in pcm { data.appendLittleEndian(sample) }
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

    private static func staticDrumVoice(note: Int, normalized: Double, lfsr: Double, secondsPerStep: Double) -> Double {
        switch note {
        case 36:
            let bodyFrequency = 145.0 - normalized * 105.0
            let body = sin(normalized * secondsPerStep * bodyFrequency * 2.0 * .pi) * exp(-normalized * 5.5)
            return lfsr * 0.48 + body * 0.92
        case 38:
            return lfsr * (0.72 + (1.0 - normalized) * 0.18)
        case 42:
            return lfsr * 0.52
        case 49:
            return lfsr * (0.84 + (1.0 - normalized) * 0.16)
        default:
            return lfsr
        }
    }

    private static func drumVoiceIndex(_ note: Int) -> Int {
        switch note {
        case 38: return 1
        case 42: return 2
        case 49: return 3
        default: return 0
        }
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
