import Foundation
import Observation

@MainActor
@Observable
final class GameStore {
    var project: ByteProject
    var projects: [ByteProject]
    var selectedChannel: ByteChannel = .pulseA
    var selectedStep: Int?
    var currentPatternID: UUID
    var isPlaying = false
    var isUnlocked = false
    var selectedPatchParameter: [ByteChannel: BytePatchParameter] = [:]
    var showStore = false
    var toast: String?

    private let defaults: UserDefaults
    private let projectsKey = "bytePocket.projects"
    private let selectedProjectKey = "bytePocket.selectedProject"
    private static let historyLimit = 80

    private struct HistoryEntry {
        let project: ByteProject
        let currentPatternID: UUID
    }

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var historyCurrent: HistoryEntry

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isUnlocked = defaults.bool(forKey: "bytePocket.unlocked")
        let savedProjects: [ByteProject]
        if let data = defaults.data(forKey: projectsKey),
           let saved = try? JSONDecoder.bytePocketDecoder.decode([ByteProject].self, from: data),
           !saved.isEmpty {
            savedProjects = saved
        } else {
            savedProjects = [.starter]
        }

        let selectedID = defaults.string(forKey: selectedProjectKey).flatMap(UUID.init(uuidString:))
        let selected = savedProjects.first(where: { $0.id == selectedID }) ?? savedProjects[0]
        self.projects = savedProjects
        self.project = selected
        let initialPatternID = selected.arrangedPatterns.first?.id ?? selected.patterns[0].id
        self.currentPatternID = initialPatternID
        self.historyCurrent = HistoryEntry(project: selected, currentPatternID: initialPatternID)
    }

    /// Every pattern is one classic 16-step bar. Song Mode supplies variation by chaining patterns.
    var loopLength: Int { 16 }

    /// Returns the selected pattern only; Song Mode playback is explicitly requested by the Song page.
    var playbackPatterns: [BytePattern] {
        [project.patterns.first(where: { $0.id == currentPatternID }) ?? project.patterns[0]]
    }

    var songPlaybackPatterns: [BytePattern] { project.songPatterns }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// All four classic channels are available without a purchase.
    var visibleChannels: [ByteChannel] { ByteChannel.allCases }
    var isPremium: Bool { isUnlocked }

    func setUnlocked(_ value: Bool) {
        isUnlocked = value
        defaults.set(value, forKey: "bytePocket.unlocked")
    }

    func newProject() {
        let number = projects.count + 1
        let created = ByteProject(name: String(format: "NEW QUEST %02d", number), patterns: [BytePattern.empty(name: "PATTERN 01")])
        projects.insert(created, at: 0)
        selectProject(created)
        persist()
    }

    func selectProject(_ selected: ByteProject) {
        project = selected
        if let index = projects.firstIndex(where: { $0.id == selected.id }) {
            projects[index] = selected
        }
        selectedStep = nil
        currentPatternID = selected.arrangedPatterns.first?.id ?? selected.patterns[0].id
        resetHistory()
        persistSelection()
    }

    func selectPattern(_ id: UUID) {
        guard project.patterns.contains(where: { $0.id == id }) else { return }
        currentPatternID = id
        selectedStep = nil
        // Pattern selection is navigation, not an edit, but the next edit should undo
        // back to the pattern the user actually had selected.
        historyCurrent = HistoryEntry(project: project, currentPatternID: id)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(historyCurrent)
        restoreHistoryEntry(previous)
        presentToast("UNDO")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(historyCurrent)
        restoreHistoryEntry(next)
        presentToast("REDO")
    }

    func renamePattern(_ id: UUID, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let index = project.patterns.firstIndex(where: { $0.id == id }) else { return }
        project.patterns[index].name = String(clean.prefix(28)).uppercased()
        touch()
    }

    func importProject(_ imported: ByteProject) {
        if let index = projects.firstIndex(where: { $0.id == imported.id }) {
            projects[index] = imported
        } else {
            projects.insert(imported, at: 0)
        }
        project = imported
        currentPatternID = imported.arrangedPatterns.first?.id ?? imported.patterns[0].id
        selectedStep = nil
        resetHistory()
        persist()
    }

    func deleteProject(_ project: ByteProject) {
        guard projects.count > 1 else { return }
        projects.removeAll { $0.id == project.id }
        if self.project.id == project.id { self.project = projects[0] }
        currentPatternID = self.project.arrangedPatterns.first?.id ?? self.project.patterns[0].id
        resetHistory()
        persist()
    }

    func renameProject(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        project.name = String(clean.prefix(28)).uppercased()
        touch()
    }

    func updateTempo(_ value: Int) {
        project.tempo = min(max(value, 60), 240)
        touch()
    }

    func updateLoopLength(_ value: Int) {
        project.loopLength = 16
        for index in project.patterns.indices { project.patterns[index].resize(to: 16) }
        selectedStep = nil
        touch()
    }

    /// Legacy compatibility hook. Song playback is selected by the Song page, not a project toggle.
    @available(*, deprecated, message: "Song playback is selected by the Song page")
    func toggleSongMode() {
        project.songModeEnabled = false
        touch()
    }

    func songSlot(at index: Int) -> ByteSongSlot {
        guard project.songArrangement.indices.contains(index) else { return .empty }
        return project.songArrangement[index]
    }

    func toggleSongSlot(at index: Int) {
        guard project.songArrangement.indices.contains(index), index < project.songArrangementLength else { return }
        if project.songArrangement[index].patternID != nil {
            clearSongSlot(at: index)
        } else {
            _ = assignSongPattern(at: index, patternID: currentPatternID)
        }
    }

    /// Assigns one 16-step pattern to one Song Mode pad.
    @discardableResult
    func assignSongPattern(at index: Int, patternID: UUID) -> Bool {
        guard project.songArrangement.indices.contains(index), index < project.songArrangementLength, project.pattern(with: patternID) != nil else { return false }
        project.songArrangement[index] = ByteSongSlot(patternID: patternID, isContinuation: false)
        touch()
        return true
    }

    func clearSongSlot(at index: Int) {
        guard project.songArrangement.indices.contains(index), index < project.songArrangementLength else { return }
        project.songArrangement[index] = .empty
        touch()
    }

    var songArrangementLength: Int { project.songArrangementLength }

    func setSongArrangementLength(_ value: Int) {
        let length = [16, 32, 64].min(by: { abs($0 - value) < abs($1 - value) }) ?? 16
        guard length != project.songArrangementLength else { return }
        if project.songArrangement.count < length {
            project.songArrangement.append(contentsOf: Array(repeating: .empty, count: length - project.songArrangement.count))
        } else if project.songArrangement.count > length {
            project.songArrangement = Array(project.songArrangement.prefix(length))
        }
        project.songArrangementLength = length
        touch()
    }

    /// Vertical drag on a Song Mode pad cycles through the available 16-step patterns.
    /// Selection is clamped so dragging down stops at the first pattern and dragging up
    /// stops at the last pattern instead of wrapping around.
    func cycleSongSlot(at index: Int, delta: Int) {
        guard !project.patterns.isEmpty, project.songArrangement.indices.contains(index), index < project.songArrangementLength else { return }
        let currentID = project.songArrangement[index].patternID ?? currentPatternID
        let currentIndex = project.patterns.firstIndex(where: { $0.id == currentID }) ?? 0
        let nextIndex = (currentIndex + delta).clamped(to: 0...(project.patterns.count - 1))
        _ = assignSongPattern(at: index, patternID: project.patterns[nextIndex].id)
    }

    private func normalizeSongArrangement() {
        for index in project.songArrangement.indices {
            if let id = project.songArrangement[index].patternID, project.pattern(with: id) != nil {
                project.songArrangement[index].isContinuation = false
            } else {
                project.songArrangement[index] = .empty
            }
        }
    }

    func updateVoicing(key: Int? = nil, mode: ByteScaleMode? = nil) {
        if let key { project.key = key.clamped(to: 0...11) }
        if let mode { project.mode = mode }
        let melodicRows = ByteChannel.allCases.enumerated().filter { $0.element != .drum }.map { $0.offset }
        for patternIndex in project.patterns.indices {
            for row in melodicRows {
                for step in project.patterns[patternIndex].steps[row].indices {
                    if let note = project.patterns[patternIndex].steps[row][step] {
                        project.patterns[patternIndex].steps[row][step] = project.mode.quantize(note, key: project.key)
                    }
                }
            }
        }
        touch()
    }

    /// Generates a fresh two-octave melodic sketch for the selected pulse or wave channel.
    /// Drum rows are intentionally left untouched.
    func randomizeSelectedMelody() -> Bool {
        guard selectedChannel != .drum,
              let index = project.patterns.firstIndex(where: { $0.id == currentPatternID }) else { return false }
        project.patterns[index].randomizeMelody(
            channel: selectedChannel,
            key: project.key,
            mode: project.mode,
            nextInt: { range in Int.random(in: range) }
        )
        selectedStep = nil
        touch()
        return true
    }

    /// A single tap toggles a step on or off. Pitch editing is handled by the pad's vertical drag.
    func toggleStep(channel: ByteChannel, step: Int) {
        guard (0..<project.loopLength).contains(step), let patternIndex = patternIndex else { return }
        let row = channelIndex(channel)
        if project.patterns[patternIndex].steps[row][step] == nil {
            // Drum steps are independent one-shots; only melodic channels can hold.
            if channel != .drum,
               let previousStart = noteStart(row: row, step: step, in: project.patterns[patternIndex]), previousStart < step {
                project.patterns[patternIndex].noteLengths[row][previousStart] = step - previousStart
            }
            project.patterns[patternIndex].steps[row][step] = channel == .drum
                ? ByteDrumVoice.note(voice: .kick)
                : project.mode.quantize(channel.defaultNotes[step % channel.defaultNotes.count], key: project.key)
            project.patterns[patternIndex].noteLengths[row][step] = 1
        } else {
            project.patterns[patternIndex].steps[row][step] = nil
            project.patterns[patternIndex].noteLengths[row][step] = 1
        }
        selectedChannel = channel
        selectedStep = step
        touch()
    }

    func cycleStep(channel: ByteChannel, step: Int) {
        toggleStep(channel: channel, step: step)
    }

    func setDrumVoice(step: Int, voice: Int) {
        guard let patternIndex, (0..<project.loopLength).contains(step) else { return }
        let row = channelIndex(.drum)
        project.patterns[patternIndex].steps[row][step] = ByteDrumVoice.note(voice: ByteDrumVoice.allCases[min(3, max(0, voice))])
        project.patterns[patternIndex].noteLengths[row][step] = 1
        selectedChannel = .drum
        selectedStep = step
        touch()
    }

    /// Sets the supplied sample variant for one drum voice globally in Sound Lab.
    func setDrumSample(voice: ByteDrumVoice, variant: Int) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == .drum }) else { return }
        project.channelPatches[index].drumSamples[voice.rawValue] = min(2, max(1, variant))
        selectedChannel = .drum
        touch()
    }

    /// Sets an individual drum voice level. The Drum channel fader remains the kit master.
    func setDrumVoiceVolume(voice: ByteDrumVoice, percent: Int) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == .drum }) else { return }
        let level = percent.clamped(to: 0...100)
        project.channelPatches[index].drumVolumes[voice.rawValue] = Int((Double(level) / 100.0 * 15.0).rounded()).clamped(to: 0...15)
        selectedChannel = .drum
        touch()
    }

    func drumVoiceVolumePercent(_ voice: ByteDrumVoice) -> Int {
        let value = patch(for: .drum).drumVolumes.indices.contains(voice.rawValue) ? patch(for: .drum).drumVolumes[voice.rawValue] : 15
        return Int((Double(value) / 15.0 * 100.0).rounded()).clamped(to: 0...100)
    }

    func setNote(channel: ByteChannel, step: Int, note: Int) {
        guard (0..<project.loopLength).contains(step), let patternIndex = patternIndex else { return }
        project.patterns[patternIndex].steps[channelIndex(channel)][step] = channel == .drum
            ? ByteDrumVoice.note(voice: ByteDrumVoice.voice(for: note))
            : project.mode.quantize(min(max(note, 24), 96), key: project.key)
        if project.patterns[patternIndex].noteLengths[channelIndex(channel)][step] < 1 {
            project.patterns[patternIndex].noteLengths[channelIndex(channel)][step] = 1
        }
        selectedChannel = channel
        selectedStep = step
        touch()
    }

    func clearStep(channel: ByteChannel, step: Int) {
        guard let patternIndex else { return }
        let row = channelIndex(channel)
        project.patterns[patternIndex].steps[row][step] = nil
        project.patterns[patternIndex].noteLengths[row][step] = 1
        touch()
    }

    func noteLength(channel: ByteChannel, step: Int) -> Int {
        guard channel != .drum, let patternIndex, (0..<project.loopLength).contains(step) else { return 1 }
        return project.patterns[patternIndex].noteLengths[channelIndex(channel)][step]
    }

    func isStepCovered(channel: ByteChannel, step: Int) -> Bool {
        guard channel != .drum, let patternIndex, (0..<project.loopLength).contains(step) else { return false }
        let row = channelIndex(channel)
        return project.patterns[patternIndex].steps[row][step] == nil && noteStart(row: row, step: step, in: project.patterns[patternIndex]) != nil
    }

    /// Sets a note's hold length and clears starts hidden inside its span.
    func setNoteLength(channel: ByteChannel, step: Int, length: Int) {
        guard channel != .drum, let patternIndex, (0..<project.loopLength).contains(step) else { return }
        let row = channelIndex(channel)
        guard project.patterns[patternIndex].steps[row][step] != nil else { return }
        let end = min(project.loopLength, step + max(1, min(project.loopLength, length)))
        project.patterns[patternIndex].noteLengths[row][step] = end - step
        if step + 1 < end {
            for coveredStep in (step + 1)..<end {
                project.patterns[patternIndex].steps[row][coveredStep] = nil
                project.patterns[patternIndex].noteLengths[row][coveredStep] = 1
            }
        }
        touch()
    }

    func deletePattern(_ id: UUID) -> Bool {
        guard project.patterns.count > 1,
              let index = project.patterns.firstIndex(where: { $0.id == id }) else { return false }
        project.patterns.remove(at: index)
        project.arrangement.removeAll { $0 == id }
        for slotIndex in project.songArrangement.indices where project.songArrangement[slotIndex].patternID == id {
            project.songArrangement[slotIndex] = .empty
        }
        if project.arrangement.isEmpty { project.arrangement = project.patterns.map(\.id) }
        if currentPatternID == id {
            currentPatternID = project.patterns[min(index, project.patterns.count - 1)].id
            selectedStep = nil
        }
        touch()
        return true
    }
    func addPattern() {
        guard project.patterns.count < ByteProject.maximumPatternCount else {
            presentToast("16 PATTERN LIMIT REACHED")
            return
        }
        let pattern = BytePattern.empty(name: String(format: "PATTERN %02d", project.patterns.count + 1))
        project.patterns.append(pattern)
        project.arrangement.append(pattern.id)
        currentPatternID = pattern.id
        touch()
    }

    func duplicateCurrentPattern() {
        guard project.patterns.count < ByteProject.maximumPatternCount,
              let current = project.patterns.first(where: { $0.id == currentPatternID }) ?? project.arrangedPatterns.first else {
            presentToast("16 PATTERN LIMIT REACHED")
            return
        }
        var copy = current
        copy.id = UUID()
        copy.name = String(format: "PATTERN %02d", project.patterns.count + 1)
        project.patterns.append(copy)
        project.arrangement.append(copy.id)
        currentPatternID = copy.id
        touch()
    }

    /// Explicit save action for the editor. Normal edits also autosave, but this gives the user
    /// a clear, discoverable save control beside pattern management.
    func saveProject() {
        touch()
    }

    func patch(for channel: ByteChannel) -> ByteChannelPatch {
        project.channelPatches.first(where: { $0.channel == channel }) ?? ByteChannelPatch(channel: channel)
    }

    func channelVolumePercent(_ channel: ByteChannel) -> Int {
        patch(for: channel).masterVolume.clamped(to: 0...100)
    }

    func setChannelVolume(channel: ByteChannel, percent: Int) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == channel }) else { return }
        project.channelPatches[index].masterVolume = percent.clamped(to: 0...100)
        touch()
    }

    func isChannelMuted(_ channel: ByteChannel) -> Bool {
        patch(for: channel).muted
    }

    func isChannelSoloed(_ channel: ByteChannel) -> Bool {
        patch(for: channel).soloed
    }

    func toggleChannelMute(_ channel: ByteChannel) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == channel }) else { return }
        project.channelPatches[index].muted.toggle()
        touch()
    }

    func toggleChannelSolo(_ channel: ByteChannel) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == channel }) else { return }
        project.channelPatches[index].soloed.toggle()
        touch()
    }

    func clearChannelSolos() {
        var changed = false
        for index in project.channelPatches.indices where project.channelPatches[index].soloed {
            project.channelPatches[index].soloed = false
            changed = true
        }
        if changed { touch() }
    }

    func setEffectAmount(_ effect: ByteEffect, amount: Int) {
        let value = amount.clamped(to: 0...100)
        switch effect {
        case .echo:
            project.effects.echoAmount = value
            project.effects.echo = value > 0
        case .bitCrush:
            project.effects.bitCrushAmount = value
            project.effects.bitCrush = value > 0
        case .vibrato:
            project.effects.vibratoAmount = value
            project.effects.vibrato = value > 0
        }
        touch()
    }

    func effectAmount(_ effect: ByteEffect) -> Int {
        switch effect {
        case .echo: return project.effects.echoAmount
        case .bitCrush: return project.effects.bitCrushAmount
        case .vibrato: return project.effects.vibratoAmount
        }
    }

    func effectSendPercent(_ channel: ByteChannel) -> Int {
        let index = ByteChannel.allCases.firstIndex(of: channel) ?? 0
        return project.effects.channelSends.indices.contains(index) ? project.effects.channelSends[index].clamped(to: 0...100) : 100
    }

    func setEffectSend(channel: ByteChannel, percent: Int) {
        let index = ByteChannel.allCases.firstIndex(of: channel) ?? 0
        guard project.effects.channelSends.indices.contains(index) else { return }
        project.effects.channelSends[index] = percent.clamped(to: 0...100)
        touch()
    }

    func adjustPatch(channel: ByteChannel, parameter: BytePatchParameter, delta: Int) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == channel }) else { return }
        var patch = project.channelPatches[index]
        switch parameter {
        case .tone:
            if channel == .wave {
                patch.waveShape = (patch.waveShape + delta.signum()).clamped(to: 0...(ByteWaveShape.allCases.count - 1))
            } else {
                patch.duty = (patch.duty + delta.signum()).clamped(to: 0...3)
            }
        case .duty: patch.duty = (patch.duty + delta).clamped(to: 0...3)
        case .envelopeAttack: patch.envelopeAttack = (patch.envelopeAttack + delta).clamped(to: 0...100)
        case .envelopeDecay: patch.envelopeDecay = (patch.envelopeDecay + delta).clamped(to: 0...100)
        case .envelopeSustain: patch.envelopeSustain = (patch.envelopeSustain + delta).clamped(to: 0...100)
        case .envelopeRelease: patch.envelopeRelease = (patch.envelopeRelease + delta).clamped(to: 0...100)
        case .portamento: patch.portamento = (patch.portamento + delta).clamped(to: 0...100)
        case .portamentoTime: patch.portamentoTime = (patch.portamentoTime + delta).clamped(to: 0...100)
        case .vibratoCycleLength: patch.vibratoCycleLength = (patch.vibratoCycleLength + delta).clamped(to: 0...100)
        case .vibratoDepth: patch.vibratoDepth = (patch.vibratoDepth + delta).clamped(to: 0...100)
        case .vibratoDelay: patch.vibratoDelay = (patch.vibratoDelay + delta).clamped(to: 0...100)
        case .bendRange: patch.bendRange = (patch.bendRange + delta).clamped(to: 0...24)
        case .octave: patch.octave = (patch.octave + delta).clamped(to: -2...2)
        case .tremolo: patch.tremolo = (patch.tremolo + delta).clamped(to: 0...100)
        case .envelope: patch.envelope = (patch.envelope + delta).clamped(to: 0...100)
        case .waveShape: patch.waveShape = (patch.waveShape + delta).clamped(to: 0...(ByteWaveShape.allCases.count - 1))
        case .waveFilter: patch.waveFilter = (patch.waveFilter + delta).clamped(to: 0...100)
        case .waveEnvelope: patch.waveEnvelope = (patch.waveEnvelope + delta).clamped(to: 0...100)
        case .volume: patch.initialVolume = (patch.initialVolume + delta).clamped(to: 0...15)
        case .envelopePace: patch.envelopePace = (patch.envelopePace + delta).clamped(to: 0...7)
        case .sweepPace: patch.sweepPace = (patch.sweepPace + delta).clamped(to: 0...7)
        case .sweepShift: patch.sweepShift = (patch.sweepShift + delta).clamped(to: 0...7)
        case .waveVolume: patch.waveVolume = (patch.waveVolume + delta).clamped(to: 0...3)
        case .drumSample: break
        case .length:
            patch.length = (patch.length + delta).clamped(to: 0...63)
            if channel != .drum { patch.lengthCounter = true }
        case .envelopeDirection: patch.envelopeIncrease.toggle()
        case .sweepDirection: patch.sweepIncrease.toggle()
        case .panLeft: patch.panLeft.toggle()
        case .panRight: patch.panRight.toggle()
        case .lengthCounter: patch.lengthCounter.toggle()
        }
        project.channelPatches[index] = patch
        touch()
    }

    func adjustSelectedPatch(channel: ByteChannel, parameter: BytePatchParameter, delta: Int) {
        selectedPatchParameter[channel] = parameter
        adjustPatch(channel: channel, parameter: parameter, delta: delta)
    }

    /// Randomizes only the selected melodic channel's Sound Lab patch. Drum samples stay manual.
    @discardableResult
    func randomizeSelectedPatch() -> Bool {
        guard selectedChannel != .drum,
              let index = project.channelPatches.firstIndex(where: { $0.channel == selectedChannel }) else { return false }
        var patch = project.channelPatches[index]
        if selectedChannel == .pulseA || selectedChannel == .pulseB {
            patch.duty = Int.random(in: 0...3)
        }
        patch.envelopeAttack = Int.random(in: 0...70)
        patch.envelopeDecay = Int.random(in: 0...100)
        patch.envelopeSustain = Int.random(in: 35...100)
        patch.envelopeRelease = Int.random(in: 0...70)
        patch.portamento = Int.random(in: 0...75)
        patch.portamentoTime = Int.random(in: 10...100)
        patch.vibratoCycleLength = Int.random(in: 0...100)
        patch.vibratoDepth = Int.random(in: 0...55)
        patch.vibratoDelay = Int.random(in: 0...70)
        patch.bendRange = Int.random(in: 0...12)
        patch.octave = Int.random(in: -2...2)
        project.channelPatches[index] = patch
        selectedPatchParameter[selectedChannel] = .portamento
        touch()
        return true
    }

    func adjustWaveSample(at index: Int, delta: Int) {
        guard project.waveform.indices.contains(index) else { return }
        project.waveform[index] = (project.waveform[index] + delta).clamped(to: 0...15)
        touch()
    }

    func toggleEffect(_ effect: ByteEffect) {
        // Sound design stays available in the core app. Export entitlements can be
        // added later without making the instrument editor paywalled.
        project.effects.toggle(effect)
        touch()
    }

    func togglePlayback() { isPlaying.toggle() }
    func stopPlayback() { isPlaying = false }

    func presentToast(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, self.toast == message else { return }
            self.toast = nil
        }
    }

    func projectDocument() -> ByteProjectDocument { ByteProjectDocument(project: project) }

    private var patternIndex: Int? {
        project.patterns.firstIndex(where: { $0.id == currentPatternID }) ?? project.patterns.indices.first
    }

    private func channelIndex(_ channel: ByteChannel) -> Int {
        ByteChannel.allCases.firstIndex(of: channel) ?? 0
    }

    private func noteStart(row: Int, step: Int, in pattern: BytePattern) -> Int? {
        guard (0..<project.loopLength).contains(step) else { return nil }
        for candidate in stride(from: step - 1, through: 0, by: -1) {
            guard pattern.steps[row][candidate] != nil else { continue }
            let length = pattern.noteLengths[row][candidate]
            if candidate + length > step { return candidate }
            break
        }
        return nil
    }

    private func touch() {
        // Compare content without the autosave timestamp so a no-op does not create an
        // undo entry. The snapshot is captured after the previous edit and before this
        // edit, which keeps every store mutation covered without duplicating UI logic.
        var comparableProject = project
        comparableProject.modifiedAt = historyCurrent.project.modifiedAt
        if comparableProject != historyCurrent.project {
            undoStack.append(historyCurrent)
            if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
            redoStack.removeAll()
        }

        project.modifiedAt = .now
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        persist()
    }

    private func restoreHistoryEntry(_ entry: HistoryEntry) {
        project = entry.project
        currentPatternID = project.patterns.contains(where: { $0.id == entry.currentPatternID })
            ? entry.currentPatternID
            : (project.arrangedPatterns.first?.id ?? project.patterns[0].id)
        selectedStep = nil
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        persist()
    }

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID)
    }

    private func persistSelection() {
        defaults.set(project.id.uuidString, forKey: selectedProjectKey)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder.bytePocketEncoder.encode(projects) {
            defaults.set(data, forKey: projectsKey)
        }
        defaults.set(project.id.uuidString, forKey: selectedProjectKey)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
