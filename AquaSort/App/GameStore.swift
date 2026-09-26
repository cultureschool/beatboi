import Foundation
import Observation

@MainActor
@Observable
final class GameStore {
    var project: ByteProject
    var projects: [ByteProject]
    var selectedChannel: ByteChannel = .drum
    var selectedStep: Int?
    var currentPatternID: UUID
    var isPlaying = false
    var isUnlocked = false
    var selectedPatchParameter: [ByteChannel: BytePatchParameter] = [:]
    var toast: String?
    /// Projects removed from the cart, most recent first. Kept on disk as well as in memory, so a
    /// deletion can still be put back after the app is relaunched.
    private var deletedProjects: [ByteProject] = []
    /// Ids the user removed from the recovery list one row at a time, most recent first, kept on
    /// disk so a dismissed row stays gone on the next launch. Only preserved payload rows consult
    /// it: a deleted project is the cart's own stack, and dismissing one records its id here as
    /// well, because the same project is still inside the rolling backup for a generation and would
    /// otherwise come back labelled as an earlier launch.
    private var dismissedPreservedIDs: [UUID] = []

    private let defaults: UserDefaults
    private static let projectsKey = "bytePocket.projects"
    private static let selectedProjectKey = "bytePocket.selectedProject"
    /// Rolling copy of the library as it stood the last time it read back cleanly. Only a
    /// payload that decoded is ever allowed to land here, so it is always a known-good state.
    private static let projectsBackupKey = "bytePocket.projects.backup"
    /// Raw bytes of a stored library that could not be read in full, kept so a bad read or a
    /// degraded save can never leave the user with no copy of their work.
    private static let projectsQuarantineKey = "bytePocket.projects.unreadable"
    /// Projects the user removed from the cart, kept so a deletion is not confined to the session
    /// that made it. Its own payload rather than a slot in the live library, because these are the
    /// only copies of that work once the rolling backup rotates past them.
    private static let projectsDeletedKey = "bytePocket.projects.deleted"
    /// Ids the user cleared from the recovery list one row at a time. Ids only, because the payloads
    /// a dismissed row came from are never rewritten — this is how a single row is hidden without
    /// touching bytes that a build might not be able to re-encode.
    private static let dismissedRecoverableKey = "bytePocket.projects.dismissed"
    /// Version 1 stored a bare `[ByteProject]` array. Version 2 wraps it in an envelope so the
    /// container itself can be versioned, which is what makes the next format change detectable.
    private static let legacyLibraryVersion = 1
    private static let currentLibraryVersion = LibraryEnvelope.introducedVersion
    private static let historyLimit = 80
    /// The two recovery bounds. They are product decisions rather than implementation details, and
    /// they are deliberately different numbers because passing each one fails in the opposite
    /// direction.
    ///
    /// `deletedProjectsLimit` caps the projects the user removed from the cart. Each entry is a whole
    /// project, and once the rolling backup has rotated past it the stack is the only copy left — so
    /// ageing one out destroys that recovery copy. That is why this is the small bound: deleted work
    /// is a safety net, not an archive. (A deleted project is still inside the backup for one
    /// generation, which is why the recovery list has to suppress it rather than rely on the cap.)
    ///
    /// `dismissedRecoverableLimit` caps the ids of rows the user cleared one at a time. Each entry is
    /// an id, and the payload it came from is never rewritten, so ageing one out loses nothing at
    /// all: it only means that row is offered again. Holding more of them is nearly free, which is why
    /// it is the generous bound — it is the one standing between a cleared row and its return.
    ///
    /// Both are internal rather than private so tests can build fixtures at the bound instead of
    /// hardcoding it, and `testRecoveryBoundsArePinned` is what keeps a change to either deliberate.
    static let deletedProjectsLimit = 20
    static let dismissedRecoverableLimit = 50
    /// How long a project or pattern name may be. Enforced by the rename paths below.
    private static let maximumNameLength = 28

    /// What went wrong the last time the stored library was read, if anything. The editor
    /// surfaces this so a recovered launch is never mistaken for the library having vanished.
    struct LibraryRecovery: Equatable {
        /// A stored library was present but could not be read at all.
        var unreadableLibrary = false
        /// Projects that were stored but individually unreadable, so they are missing here.
        var droppedProjects = 0
        /// The rolling backup was loaded because the primary payload was unusable.
        var usedBackup = false
        /// The stored data declared a format version this build does not know. It is loaded as
        /// far as it can be and its original bytes are preserved rather than discarded.
        var newerFormatFound = false
    }

    private(set) var libraryRecovery: LibraryRecovery?

    /// One project kept in a payload that is no longer the live library.
    struct RecoveredProject: Identifiable, Equatable {
        enum Source: String, Equatable {
            /// The payload the previous launch read back as, before it was rotated forward.
            case backup
            /// The most recent payload that could not be read in full.
            case quarantine
            /// A project the user removed from the cart, still kept in its own stack.
            case deleted

            var title: String {
                switch self {
                case .backup: return "LAST LAUNCH"
                case .quarantine: return "UNREADABLE COPY"
                case .deleted: return "DELETED"
                }
            }
        }

        let project: ByteProject
        let source: Source

        var id: UUID { project.id }
    }

    /// Everything the app is still holding on to from earlier payloads. `projects` are the ones
    /// this build can decode and put back in the cart; the counters cover entries that are
    /// preserved but cannot be read, so the surface never implies a project is gone when its
    /// bytes are still on disk.
    struct PreservedLibrary: Equatable {
        var projects: [RecoveredProject] = []
        var unreadableEntries = 0
        var unreadableCopies = 0

        var isEmpty: Bool { projects.isEmpty && unreadableEntries == 0 && unreadableCopies == 0 }
    }

    /// A preserved project as the recovery surface presents it: the copy itself, plus what putting
    /// it back will do to the cart.
    struct RecoveryCandidate: Identifiable, Equatable {
        enum Kind: Equatable {
            /// The cart no longer has this project. Restoring puts it back exactly as preserved.
            case missing
            /// The cart already holds this project under the same id with different content, which
            /// is what a project edited last session looks like. Restoring keeps both: the
            /// preserved copy arrives as a project of its own.
            case earlierVersion
        }

        let recovered: RecoveredProject
        let kind: Kind

        var project: ByteProject { recovered.project }
        var source: RecoveredProject.Source { recovered.source }
        var id: UUID { recovered.project.id }

        /// What the row calls this copy.
        var title: String {
            switch kind {
            case .missing: return recovered.source.title
            case .earlierVersion: return "EARLIER VERSION"
            }
        }

        var iconName: String {
            switch kind {
            case .earlierVersion: return "clock.arrow.circlepath"
            case .missing:
                // A deletion is put back the same way a preserved copy is, but it is work the user
                // removed on purpose, so it keeps the arrow the retired restore row used.
                return recovered.source == .deleted
                    ? "arrow.uturn.backward.circle.fill"
                    : "lifepreserver.fill"
            }
        }

        var restoreHint: String {
            switch (kind, recovered.source) {
            case (.earlierVersion, _):
                return "Adds this version to the cart as a separate copy, leaving the project already there alone"
            case (.missing, .deleted):
                return "Puts this deleted project back in the cart"
            case (.missing, _):
                return "Puts this preserved project back in the cart"
            }
        }
    }

    /// Decoded once at launch from the payloads that were preserved before the load path rotated
    /// the backup. Kept as a snapshot so editing the live library cannot make the recovery surface
    /// shift underneath the user.
    private(set) var preservedLibrary = PreservedLibrary()

    /// Preserved projects already brought back as a *copy* this session. A plain restore is driven
    /// by cart membership, but a copy leaves the preserved id in the cart too, so without this the
    /// same row could be restored over and over.
    private var consumedPreservedIDs: Set<UUID> = []

    #if DEBUG
    /// UI-test hooks (launch argument gated, inert in normal use). Each has to run before the
    /// snapshot in `init`, and exactly once per process: SwiftUI may evaluate the store's initial
    /// value more than once, and a second seed would wipe a restore mid-test. Each one plants every
    /// key it depends on, so a test can run on its own rather than inheriting state a previous test
    /// happened to leave behind.
    ///
    /// Compiled out of a release build, and not merely left inert there: these fixtures *replace*
    /// the stored library, so shipping them would mean a launch argument could destroy real work on
    /// a user's device. The cost is that the UI tests only exercise these paths in the Debug
    /// configuration they already build, which is the configuration the scheme's test action uses.
    ///
    /// `--preserved-projects-ui-test` plants the whole recovery surface.
    ///
    /// `--preserved-projects-ui-test-backup` plants a rolling backup still holding a project the
    /// user cleared, together with the dismissal for it. That is the arrangement a single launch
    /// cannot produce, because the launch path rotates the backup forward before the user can act.
    ///
    /// `--preserved-projects-ui-test-backup-undismissed` plants the same backup without the
    /// dismissal, so the row is reachable. It is the control for the mode above: on its own, "the
    /// cleared project is not offered" would pass just as well if the fixture offered nothing at all.
    private static var didSeedPreservedCopiesForUITest = false

    private static func seedPreservedCopiesForUITestIfNeeded(in defaults: UserDefaults) {
        let arguments = ProcessInfo.processInfo.arguments
        let plantsWholeSurface = arguments.contains("--preserved-projects-ui-test")
        let plantsBackup = arguments.contains("--preserved-projects-ui-test-backup")
        let plantsBackupUndismissed = arguments.contains("--preserved-projects-ui-test-backup-undismissed")
        guard plantsWholeSurface || plantsBackup || plantsBackupUndismissed,
              !didSeedPreservedCopiesForUITest else { return }
        didSeedPreservedCopiesForUITest = true

        // Fixed ids, so a project planted by one launch is recognisably the same project on the
        // next. A relaunch test compares what one launch left behind, which needs the ids to match.
        let ghostID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lostID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let erasedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let original = ByteProject(id: ghostID, name: "GHOST TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        var edited = original
        edited.tempo = 150
        let lost = ByteProject(id: lostID, name: "LOST TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        let erased = ByteProject(id: erasedID, name: "ERASED TAKE", patterns: [BytePattern.empty(name: "PATTERN 01")])
        guard let cart = try? JSONEncoder.bytePocketEncoder.encode([edited]) else { return }

        if plantsBackup || plantsBackupUndismissed {
            // The backup holds the cleared deletion beside the cart's own project, so the cleared
            // one is the only row this launch can offer — and the cart is written here too, so the
            // fixture does not depend on what a previous launch left there either.
            guard let backup = try? JSONEncoder.bytePocketEncoder.encode([erased, edited]) else { return }
            defaults.set(cart, forKey: projectsKey)
            defaults.set(backup, forKey: projectsBackupKey)
            defaults.removeObject(forKey: projectsDeletedKey)
            defaults.removeObject(forKey: projectsQuarantineKey)
            if plantsBackup {
                guard let dismissed = try? JSONEncoder.bytePocketEncoder.encode([erasedID]) else { return }
                defaults.set(dismissed, forKey: dismissedRecoverableKey)
            } else {
                defaults.removeObject(forKey: dismissedRecoverableKey)
            }
            return
        }

        // Three cases at once: a project the cart has lost, the version of the cart's own project
        // from before it was edited, and a project the user deleted. All of them are rows in the
        // one recovery list, which is what these tests need to see.
        guard let preserved = try? JSONEncoder.bytePocketEncoder.encode([original, lost]),
              let deleted = try? JSONEncoder.bytePocketEncoder.encode([erased]) else { return }
        defaults.set(cart, forKey: projectsKey)
        defaults.removeObject(forKey: projectsBackupKey)
        defaults.set(deleted, forKey: projectsDeletedKey)
        defaults.set(preserved, forKey: projectsQuarantineKey)
        defaults.removeObject(forKey: dismissedRecoverableKey)
    }
    #endif

    private struct HistoryEntry {
        let project: ByteProject
        let currentPatternID: UUID
        /// The cart and the recovery bookkeeping as they stood. Carried only by entries that guard a
        /// change in library *membership* — restoring, adding, importing or deleting a project —
        /// because that is what an ordinary project snapshot cannot describe. Nil for plain edits.
        var library: LibrarySnapshot? = nil
    }

    /// Everything outside the selected project that a library-level step can change. The deleted
    /// stack is here because a delete both changes membership and pushes onto it; without it in the
    /// snapshot, undoing a restore of a deleted project would leave the project in neither the cart
    /// nor the stack, which is the one way an undo could destroy work. The dismissed ids travel with
    /// it for the same reason: undoing a dismissal has to put the row back, not just the project.
    private struct LibrarySnapshot {
        let projects: [ByteProject]
        let consumedPreservedIDs: Set<UUID>
        let deletedProjects: [ByteProject]
        let dismissedPreservedIDs: [UUID]
    }

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var historyCurrent: HistoryEntry

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        Self.seedPreservedCopiesForUITestIfNeeded(in: defaults)
        #endif
        // Capture the preserved payloads before `loadLibrary` rotates the backup. Reading it
        // afterwards would only ever offer back the library that just loaded, which is no
        // recovery at all: the interesting copy is the one from the previous launch.
        let preservedPayloads: [(RecoveredProject.Source, Data)] = [
            (.backup, defaults.data(forKey: Self.projectsBackupKey)),
            (.quarantine, defaults.data(forKey: Self.projectsQuarantineKey)),
        ].compactMap { source, data in data.map { (source, $0) } }
        self.isUnlocked = defaults.bool(forKey: "bytePocket.unlocked")
        let loaded = Self.loadLibrary(from: defaults)
        let savedProjects = loaded.projects
        // Read after the library so an entry whose project is already back in the cart can be
        // dropped: the cart is the newer copy by definition.
        let deleted = Self.loadDeletedProjects(from: defaults, excluding: savedProjects)

        let selectedID = defaults.string(forKey: Self.selectedProjectKey).flatMap(UUID.init(uuidString:))
        let selected = savedProjects.first(where: { $0.id == selectedID }) ?? savedProjects[0]
        self.projects = savedProjects
        self.project = selected
        let initialPatternID = selected.arrangedPatterns.first?.id ?? selected.patterns[0].id
        self.currentPatternID = initialPatternID
        self.historyCurrent = HistoryEntry(project: selected, currentPatternID: initialPatternID)
        self.deletedProjects = deleted
        self.dismissedPreservedIDs = Self.loadDismissedRecoverableIDs(from: defaults)
        self.libraryRecovery = loaded.recovery
        // A deleted project is offered through the delete path, so it is filtered out of the other
        // payloads here. Otherwise deleting a project and relaunching would list it twice, once as
        // "last launch" and once as "deleted".
        self.preservedLibrary = Self.decodePreservedLibrary(
            from: preservedPayloads,
            suppressing: Set(deleted.map(\.id))
        )

        // Say so rather than quietly showing a different library than the user left. Work that can
        // still be brought back is the more actionable message, so it wins the single toast slot.
        if !missingRecoverableProjects.isEmpty {
            presentToast("PROJECTS RECOVERABLE · OPEN PROJECT CART")
        } else if let recovery = loaded.recovery {
            if recovery.usedBackup {
                presentToast("LIBRARY RESTORED FROM BACKUP")
            } else if recovery.unreadableLibrary {
                presentToast("LIBRARY UNREADABLE · ORIGINAL KEPT")
            } else if recovery.newerFormatFound {
                presentToast("LIBRARY FROM A NEWER VERSION · ORIGINAL KEPT")
            } else {
                presentToast("\(recovery.droppedProjects) PROJECT(S) UNREADABLE · SKIPPED")
            }
        }
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

    /// The paid Export Pack adds WAV audio export; all four classic channels are free.
    var visibleChannels: [ByteChannel] { ByteChannel.allCases }

    func setUnlocked(_ value: Bool) {
        isUnlocked = value
        defaults.set(value, forKey: "bytePocket.unlocked")
    }

    /// Adds a blank project and makes it current. Like a restore, this changes library membership,
    /// so it is recorded as an undo step rather than wiping the history — NEW PROJECT in the cart is
    /// no longer a one-way door.
    func newProject() {
        let number = projects.count + 1
        let created = ByteProject(name: String(format: "NEW QUEST %02d", number), patterns: [BytePattern.empty(name: "PATTERN 01")])
        recordUndoableStep()
        projects.insert(created, at: 0)
        adoptProject(created)
        presentToast("NEW PROJECT · UNDO AVAILABLE")
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
        project.patterns[index].name = String(clean.prefix(Self.maximumNameLength)).uppercased()
        touch()
    }

    /// Opens an imported project. A file whose id is already in the cart replaces that project
    /// rather than adding a second one, so the step is recorded first: undo has to put the replaced
    /// content back, not merely drop a project.
    func importProject(_ imported: ByteProject) {
        recordUndoableStep()
        if let index = projects.firstIndex(where: { $0.id == imported.id }) {
            projects[index] = imported
        } else {
            projects.insert(imported, at: 0)
        }
        adoptProject(imported)
    }

    /// True while a deleted project is still waiting to be put back. The stack is persisted, so
    /// this stays true across a relaunch instead of dying with the session that deleted it. It is
    /// defined through the same list the cart renders, so it can never disagree with a visible row.
    var canRestoreDeletedProject: Bool {
        recoveryCandidates.contains { $0.source == .deleted }
    }

    /// Every project the cart can still put back, in one list: work the user deleted, then work
    /// preserved from an earlier payload. A project the cart has lost comes back as itself; a copy
    /// whose id is already in the cart — the usual shape of "you edited this last session" — comes
    /// back as a separate copy. Copies already brought back this session are left out, so no row can
    /// be restored twice.
    var recoveryCandidates: [RecoveryCandidate] {
        var candidates: [RecoveryCandidate] = []
        var claimed = Set<UUID>()

        // Deletions lead. They are the most recent change and the one the user made on purpose, so
        // they are the likeliest to be wanted back. An entry whose id is somehow already in the
        // cart is stale, because the cart holds the newer copy.
        for deleted in deletedProjects where !projects.contains(where: { $0.id == deleted.id }) {
            guard claimed.insert(deleted.id).inserted else { continue }
            candidates.append(RecoveryCandidate(
                recovered: RecoveredProject(project: deleted, source: .deleted),
                kind: .missing
            ))
        }

        for recovered in preservedLibrary.projects {
            guard !consumedPreservedIDs.contains(recovered.project.id) else { continue }
            // Rows the user cleared one at a time. The payload is untouched, so this is the only
            // thing that keeps a dismissed row from reappearing with the bytes it came from.
            guard !dismissedPreservedIDs.contains(recovered.project.id) else { continue }
            if let existing = projects.first(where: { $0.id == recovered.project.id }) {
                // A preserved payload that matches the cart exactly is just the rolling backup
                // doing its job. Only a copy that actually differs is worth a row.
                guard existing != recovered.project else { continue }
                guard claimed.insert(recovered.project.id).inserted else { continue }
                candidates.append(RecoveryCandidate(recovered: recovered, kind: .earlierVersion))
            } else {
                guard claimed.insert(recovered.project.id).inserted else { continue }
                candidates.append(RecoveryCandidate(recovered: recovered, kind: .missing))
            }
        }

        return candidates
    }

    /// Recoverable projects the cart has lost outright. These are worth interrupting a launch for;
    /// an earlier version can wait quietly in the cart, and a deletion is the user's own doing, so
    /// neither is reported at launch.
    var missingRecoverableProjects: [RecoveryCandidate] {
        recoveryCandidates.filter { $0.kind == .missing && $0.source != .deleted }
    }

    /// True when the cart has something to say about recoverable work: a project to put back —
    /// deleted or preserved — an earlier version to keep beside it, or bytes that are kept but could
    /// not be decoded. A clean launch has none of those, so the surface stays out of the way instead
    /// of nagging about a backup that mirrors the current library.
    var hasRecoverableProjects: Bool {
        !recoveryCandidates.isEmpty
            || preservedLibrary.unreadableEntries > 0
            || preservedLibrary.unreadableCopies > 0
    }

    /// Brings one row of the recovery list back into the cart.
    ///
    /// A deleted project is put back by consuming its stack entry. A preserved project is put back
    /// additively — the preserved payloads are left alone — so the same bytes stay available until
    /// they are discarded or rotated away.
    ///
    /// When the cart already holds that project under the same id, the preserved version arrives as
    /// a project of its own with a fresh id and a free name, so nothing already in the cart is
    /// overwritten or replaced.
    ///
    /// Every restore is recorded as an ordinary undo step, so a tap in the wrong place can be taken
    /// back with the same control that undoes an edit instead of leaving a stray project to delete.
    @discardableResult
    func restoreRecoveredProject(_ candidate: RecoveryCandidate) -> Bool {
        if candidate.source == .deleted {
            return restoreDeleted(candidate)
        }

        let preservedID = candidate.id
        guard !consumedPreservedIDs.contains(preservedID) else {
            presentToast("COPY ALREADY RESTORED")
            return false
        }

        let alreadyInCart = projects.contains(where: { $0.id == preservedID })
        // The cart already holds this project, so only an earlier version can be brought back beside
        // it. A stale row for a project that is already there unchanged is refused.
        guard !alreadyInCart || candidate.kind == .earlierVersion else {
            presentToast("PROJECT IS ALREADY IN THE CART")
            return false
        }

        // Recorded before anything changes, so undo puts the cart and the row back together.
        recordUndoableStep()

        if !alreadyInCart {
            projects.insert(candidate.recovered.project, at: 0)
            adoptProject(candidate.recovered.project)
            presentToast("PROJECT RECOVERED · UNDO AVAILABLE")
            return true
        }

        var copy = candidate.recovered.project
        copy.id = UUID()
        copy.name = uniqueCopyName(for: copy.name)
        consumedPreservedIDs.insert(preservedID)
        projects.insert(copy, at: 0)
        adoptProject(copy)
        presentToast("EARLIER VERSION ADDED · UNDO AVAILABLE")
        return true
    }

    /// Puts one deleted project back. The stack entry is consumed, which is what takes the row out
    /// of the recovery list — unlike a preserved copy, there is no separate consumed-id set, so
    /// undoing this restores the entry and the row together.
    private func restoreDeleted(_ candidate: RecoveryCandidate) -> Bool {
        guard let index = deletedProjects.firstIndex(where: { $0.id == candidate.id }) else {
            presentToast("PROJECT IS ALREADY IN THE CART")
            return false
        }
        // Recorded before anything changes, so undo puts the cart and the row back together.
        recordUndoableStep()
        let recovered = deletedProjects.remove(at: index)
        projects.insert(recovered, at: 0)
        adoptProject(recovered)
        persistDeletedProjects()
        presentToast("PROJECT RESTORED · UNDO AVAILABLE")
        return true
    }

    /// Snapshots the state a library-level step is about to change, so undo can put it back — and
    /// pushes it as a normal step, meaning a restore no longer clears the history the way project
    /// selection does.
    private func recordUndoableStep() {
        var step = historyCurrent
        step.library = currentLibrarySnapshot()
        pushUndoStep(step)
    }

    private func currentLibrarySnapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            projects: projects,
            consumedPreservedIDs: consumedPreservedIDs,
            deletedProjects: deletedProjects,
            dismissedPreservedIDs: dismissedPreservedIDs
        )
    }

    /// Makes a project that was just added to or replaced in the cart the current one. This is what
    /// project selection does minus the history reset, which would throw away the step that undoes
    /// it.
    private func adoptProject(_ adopted: ByteProject) {
        project = adopted
        selectedStep = nil
        currentPatternID = adopted.arrangedPatterns.first?.id ?? adopted.patterns[0].id
        if let index = projects.firstIndex(where: { $0.id == adopted.id }) { projects[index] = adopted }
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID, library: currentLibrarySnapshot())
        persistSelection()
    }

    /// A name for a restored copy that no project in the cart already uses, so two rows never read
    /// the same. Trimmed to the same 28-character limit every other project name keeps.
    private func uniqueCopyName(for base: String) -> String {
        let taken = Set(projects.map(\.name))
        func candidate(_ suffix: String) -> String {
            String(base.prefix(max(1, Self.maximumNameLength - suffix.count))) + suffix
        }
        var index = 1
        var name = candidate(" COPY")
        while taken.contains(name) {
            index += 1
            name = candidate(" COPY \(index)")
        }
        return name
    }

    /// Drops every recoverable copy for good. The cart presents deletions and preserved payloads as
    /// one list with one control, so discarding clears both: the quarantine and deleted payloads go
    /// outright. The backup is re-mirrored from the live library rather than being left empty, so
    /// clearing the old copies does not also throw away the rolling safety net for the current cart.
    ///
    /// This is the one destructive action in the cart, it is confirmed, and it is deliberately not
    /// undoable: the bytes it drops are gone, not merely hidden behind a history step. The undo
    /// history is cleared along with them, because the snapshots it holds were taken before the
    /// purge and still carry the deleted stack — a leftover step could otherwise put back exactly
    /// what the user just confirmed discarding.
    func discardRecoverableProjects() {
        preservedLibrary = PreservedLibrary()
        consumedPreservedIDs.removeAll()
        deletedProjects.removeAll()
        dismissedPreservedIDs.removeAll()
        defaults.removeObject(forKey: Self.projectsQuarantineKey)
        defaults.removeObject(forKey: Self.dismissedRecoverableKey)
        // Removing the last entry clears the payload key, so the next launch has nothing to read.
        persistDeletedProjects()
        if let current = defaults.data(forKey: Self.projectsKey) {
            defaults.set(current, forKey: Self.projectsBackupKey)
        } else {
            defaults.removeObject(forKey: Self.projectsBackupKey)
        }
        resetHistory()
        presentToast("RECOVERABLE PROJECTS DISCARDED")
    }

#if DEBUG
    /// A build-gated dump of everything the recovery layer is holding, so a written-up report can be
    /// read instead of guessed at. Debug builds only: it describes the app's stored payloads, which
    /// is support information rather than something a shipped build should be able to print.
    ///
    /// The payload lines expose sizes, never contents — a payload that could not be decoded stays
    /// unreadable here too. The row list at the end does name projects, because "which of my work can
    /// still be brought back" is the question a report exists to answer.
    func recoveryDiagnosticsReport() -> String {
        func payloadLine(_ label: String, _ key: String) -> String {
            guard let data = defaults.data(forKey: key) else { return "\(label): absent" }
            return "\(label): \(data.count) bytes"
        }

        var lines = ["RECOVERY DIAGNOSTICS"]
        // What produced the report comes first: a dump pasted into a bug report is otherwise missing
        // the one thing needed to act on it. Read from the running bundle rather than baked in, so a
        // report can never claim to be from a build other than the one that wrote it.
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("app: \(version) (build \(build))")
        lines.append("os: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append(payloadLine("primary", Self.projectsKey))
        lines.append(payloadLine("backup", Self.projectsBackupKey))
        lines.append(payloadLine("quarantine", Self.projectsQuarantineKey))
        lines.append(payloadLine("deleted", Self.projectsDeletedKey))
        lines.append(payloadLine("dismissed", Self.dismissedRecoverableKey))
        lines.append("deleted stack: \(deletedProjects.count) of \(Self.deletedProjectsLimit)")
        lines.append("dismissed ids: \(dismissedPreservedIDs.count) of \(Self.dismissedRecoverableLimit)")

        let candidates = recoveryCandidates
        let missing = candidates.filter { $0.kind == .missing }.count
        lines.append("recoverable rows: \(candidates.count) (missing \(missing), earlier version \(candidates.count - missing))")
        for source in [RecoveredProject.Source.deleted, .backup, .quarantine] {
            lines.append("  from \(source.rawValue): \(candidates.filter { $0.source == source }.count)")
        }
        lines.append("unreadable entries: \(preservedLibrary.unreadableEntries)")
        lines.append("unreadable copies: \(preservedLibrary.unreadableCopies)")

        if let load = libraryRecovery {
            lines.append(
                "last load: unreadableLibrary=\(load.unreadableLibrary) droppedProjects=\(load.droppedProjects) "
                    + "usedBackup=\(load.usedBackup) newerFormatFound=\(load.newerFormatFound)"
            )
        } else {
            lines.append("last load: clean")
        }

        for candidate in candidates {
            let kind = candidate.kind == .missing ? "missing" : "earlier version"
            lines.append("  \(candidate.project.name) [\(candidate.source.rawValue), \(kind)]")
        }
        return lines.joined(separator: "\n")
    }
#endif

    /// Removes a project from the cart. This used to clear the undo history and lean on a single
    /// in-memory "restore last deleted" slot, so deleting twice in a row left the first project
    /// with no way back and a relaunch lost the slot entirely. It is now a membership step like a
    /// restore, and the stack it feeds is written to disk.
    func deleteProject(_ project: ByteProject) {
        guard projects.count > 1, projects.contains(where: { $0.id == project.id }) else { return }
        recordUndoableStep()
        // A project deleted again after being restored replaces its earlier entry rather than
        // piling up a duplicate, so the stack holds at most one copy per project.
        deletedProjects.removeAll { $0.id == project.id }
        deletedProjects.insert(project, at: 0)
        if deletedProjects.count > Self.deletedProjectsLimit {
            deletedProjects.removeLast(deletedProjects.count - Self.deletedProjectsLimit)
        }
        projects.removeAll { $0.id == project.id }
        let next = self.project.id == project.id ? projects[0] : self.project
        adoptProject(next)
        persistDeletedProjects()
        presentToast("PROJECT DELETED · UNDO AVAILABLE")
    }

    /// Puts the most recently deleted project back. Retained as the store-level shortcut while the
    /// cart offers deletions as ordinary recovery rows, and routed through the same path so there
    /// is only one way a project comes back.
    ///
    /// Entries whose project is already in the cart are skipped rather than restored twice, which
    /// is how a stale payload left by an older build behaves.
    func restoreDeletedProject() {
        guard let candidate = recoveryCandidates.first(where: { $0.source == .deleted }) else { return }
        restoreRecoveredProject(candidate)
    }

    /// Removes one row from the recovery list, leaving every other row alone.
    ///
    /// A deleted row is dropped from the delete stack. A preserved row cannot be taken out of the
    /// payload — those bytes are deliberately never rewritten, so a build that cannot read one entry
    /// still keeps it — so its id is recorded as dismissed and the row is filtered from the list.
    /// Either way the id is remembered, because a deleted project is also still inside the rolling
    /// backup for a generation and would otherwise come back as a preserved row on the next launch.
    ///
    /// It is an ordinary undoable step, so a row removed by mistake comes back with the same control
    /// that undoes an edit. Nothing here is a substitute for the bulk discard: that one erases the
    /// bytes, and this only stops offering them.
    @discardableResult
    func dismissRecoverableProject(_ candidate: RecoveryCandidate) -> Bool {
        let id = candidate.id
        if candidate.source == .deleted {
            guard deletedProjects.contains(where: { $0.id == id }) else { return false }
        } else {
            guard preservedLibrary.projects.contains(where: { $0.id == id }),
                  !dismissedPreservedIDs.contains(id) else { return false }
        }

        // Recorded before anything changes, so undo puts the row and the state back together.
        recordUndoableStep()
        dismissedPreservedIDs.removeAll { $0 == id }
        dismissedPreservedIDs.insert(id, at: 0)
        if dismissedPreservedIDs.count > Self.dismissedRecoverableLimit {
            dismissedPreservedIDs.removeLast(dismissedPreservedIDs.count - Self.dismissedRecoverableLimit)
        }
        if candidate.source == .deleted {
            deletedProjects.removeAll { $0.id == id }
            persistDeletedProjects()
        }
        persistDismissedRecoverableIDs()
        // Unlike the other membership steps this one adopts no project, so it has to advance the
        // current step itself. Redo replays whatever `historyCurrent` holds, and left stale it would
        // undo the dismissal and then refuse to redo it.
        historyCurrent = HistoryEntry(
            project: project,
            currentPatternID: currentPatternID,
            library: currentLibrarySnapshot()
        )
        presentToast("RECOVERY ROW REMOVED · UNDO AVAILABLE")
        return true
    }

    func renameProject(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        project.name = String(clean.prefix(Self.maximumNameLength)).uppercased()
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

    /// Applies a voicing change across every pattern.
    ///
    /// A **key change transposes** melodic material by the interval to the new key, so the
    /// song keeps its shape and simply moves into that key. Re-quantizing towards the new
    /// key instead would ratchet notes downward: snapping breaks ties toward the lower pitch,
    /// and in a diatonic scale every non-scale pitch class sits above its lower neighbour, so
    /// each key change dragged the melody a semitone lower until it bottomed out.
    ///
    /// A **mode change re-snaps** the melodic rows into the new scale. Drum rows are untouched.
    ///
    /// Transposed notes are held inside the 24...96 register, so a note already sitting on an
    /// edge of that range stays put rather than leaving the playable pitch range.
    func updateVoicing(key: Int? = nil, mode: ByteScaleMode? = nil) {
        var semitoneShift = 0
        if let key {
            let newKey = key.clamped(to: 0...11)
            semitoneShift = Self.shortestSemitoneShift(from: project.key, to: newKey)
            project.key = newKey
        }
        if let mode { project.mode = mode }

        let melodicRows = ByteChannel.allCases.enumerated().filter { $0.element != .drum }.map { $0.offset }
        for patternIndex in project.patterns.indices {
            for row in melodicRows {
                for step in project.patterns[patternIndex].steps[row].indices {
                    guard let note = project.patterns[patternIndex].steps[row][step] else { continue }
                    let moved = semitoneShift == 0 ? note : (note + semitoneShift).clamped(to: 24...96)
                    project.patterns[patternIndex].steps[row][step] = project.mode.quantize(moved, key: project.key)
                }
            }
        }
        touch()
    }

    /// Signed distance between two keys, taking the shortest path around the octave so that
    /// C to B moves down a semitone instead of up eleven.
    private static func shortestSemitoneShift(from oldKey: Int, to newKey: Int) -> Int {
        let raw = ((newKey - oldKey) % 12 + 12) % 12
        return raw > 6 ? raw - 12 : raw
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

    /// Fills the pattern in front of the user with a fresh random drum beat and reports the feel
    /// it landed on, so the caller can say which backbeat it just heard.
    ///
    /// Guarded to the drum row for the same reason `randomizeSelectedMelody` is guarded to the
    /// melodic ones: a dice that rewrites a row the user is not looking at reads as a dice that
    /// does nothing. The two never overlap, so one button can mean whichever row is selected.
    func shuffleSelectedDrums() -> ByteDrumFeel? {
        guard selectedChannel == .drum,
              let index = project.patterns.firstIndex(where: { $0.id == currentPatternID }) else { return nil }
        let feel = project.patterns[index].shuffleDrums(nextInt: { range in Int.random(in: range) })
        selectedStep = nil
        touch()
        return feel
    }

    /// Clears one channel row while keeping the edit undoable and recoverable.
    func clearChannelRow(_ channel: ByteChannel) {
        guard let patternIndex, project.patterns.indices.contains(patternIndex) else { return }
        let row = channelIndex(channel)
        project.patterns[patternIndex].steps[row] = Array(repeating: nil, count: project.loopLength)
        project.patterns[patternIndex].noteLengths[row] = Array(repeating: 1, count: project.loopLength)
        selectedChannel = channel
        selectedStep = nil
        touch()
        presentToast("\(channel.title) ROW CLEARED · UNDO AVAILABLE")
    }

    /// Returns a stable 0–100 activity value for mixer meters. A covered melodic step
    /// still counts as active, so sustained notes remain visible between note starts.
    func channelActivityLevel(_ channel: ByteChannel, step: Int, songSlot slotIndex: Int = -1) -> Int {
        guard isPlaying, (0..<project.loopLength).contains(step) else { return 0 }
        let row = channelIndex(channel)
        let hasSolo = project.channelPatches.contains(where: { $0.soloed })
        let channelPatch = patch(for: channel)
        guard !channelPatch.muted, !hasSolo || channelPatch.soloed else { return 0 }

        let pattern: BytePattern
        if slotIndex >= 0, let id = self.songSlot(at: slotIndex).patternID,
           let songPattern = project.pattern(with: id) {
            pattern = songPattern
        } else if let patternIndex {
            pattern = project.patterns[patternIndex]
        } else {
            return 0
        }
        guard pattern.steps.indices.contains(row), pattern.steps[row].indices.contains(step) else { return 0 }
        if pattern.steps[row][step] != nil { return 100 }
        guard channel != .drum else { return 0 }
        return noteStart(row: row, step: step, in: pattern) == nil ? 0 : 74
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
                : channel.rootNote(for: project.key)
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

    // MARK: - Step sweeps

    /// The run of steps one drag is painting or clearing, and the value it paints.
    /// `note` is a pitch on a melodic channel and a drum voice's note on the drum row;
    /// nil means "whatever the channel defaults to".
    private var sweep: (channel: ByteChannel, painting: Bool, note: Int?, steps: Set<Int>)?

    /// Starts a run of steps from a single drag.
    ///
    /// `painting` is decided by the caller from the state of the step the gesture
    /// began on, so the whole run has exactly one meaning: a drag either adds notes
    /// or removes them, never both. That is the paint-or-eraser idiom, and it is
    /// also what keeps a sweep predictable — you know what it will do before you
    /// move, because it is set by the pad you started on.
    ///
    /// `note` carries the same idea one step further: a run paints the value it
    /// started on, which is the note the origin pad was holding — so dragging across
    /// the grid repeats *that* note rather than stamping the channel's root note over
    /// a melody the user just wrote. A run begun on an empty pad has no such value and
    /// passes nil, and each channel supplies its own default.
    ///
    /// Nothing in a sweep calls `touch()`. The run commits once, in
    /// `endStepSweep`, and because `touch()` snapshots the state from *before* the
    /// whole run, a sweep of any length is a single undo step rather than one per
    /// step. It is likewise a single write to disk instead of one per step.
    func beginStepSweep(channel: ByteChannel, step: Int, painting: Bool, note: Int? = nil) {
        // A run left open by an interrupted gesture is committed here rather than
        // leaked, or its steps would be folded into whichever edit came next.
        endStepSweep()
        sweep = (channel, painting, note, [])
        applySweep(step)
    }

    /// Adds one step to the run in progress. Steps already in the run are ignored,
    /// so a finger that wanders back over a step does not toggle it twice.
    func extendStepSweep(step: Int) {
        applySweep(step)
    }

    /// Commits the run: one history entry and one write for the whole sweep.
    func endStepSweep() {
        guard let finished = sweep else { return }
        sweep = nil
        guard !finished.steps.isEmpty else { return }
        selectedChannel = finished.channel
        touch()
    }

    /// Applies one step of the run in progress. Split out of `toggleStep` on
    /// purpose: the paint branch has to stay silent about history and disk, which is
    /// the whole point of a sweep.
    private func applySweep(_ step: Int) {
        guard var running = sweep,
              let patternIndex,
              (0..<project.loopLength).contains(step),
              !running.steps.contains(step) else { return }
        running.steps.insert(step)
        sweep = running

        let row = channelIndex(running.channel)
        if running.painting {
            // Same hold-trimming rule as a single tap, so painting over a held note
            // ends it where the new one starts instead of stacking two notes.
            if running.channel != .drum,
               let previousStart = noteStart(row: row, step: step, in: project.patterns[patternIndex]),
               previousStart < step {
                project.patterns[patternIndex].noteLengths[row][previousStart] = step - previousStart
            }
            project.patterns[patternIndex].steps[row][step] = running.note
                ?? (running.channel == .drum
                    ? ByteDrumVoice.note(voice: .kick)
                    : running.channel.rootNote(for: project.key))
        } else {
            project.patterns[patternIndex].steps[row][step] = nil
        }
        project.patterns[patternIndex].noteLengths[row][step] = 1
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

    /// The note a step holds, or nil when it is empty. Used by the pad grid to audition a
    /// step through the audio engine, so a melody can be built by ear.
    func note(channel: ByteChannel, step: Int) -> Int? {
        guard let patternIndex, (0..<project.loopLength).contains(step) else { return nil }
        return project.patterns[patternIndex].steps[channelIndex(channel)][step]
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
        }
        touch()
    }

    func effectAmount(_ effect: ByteEffect) -> Int {
        switch effect {
        case .echo: return project.effects.echoAmount
        case .bitCrush: return project.effects.bitCrushAmount
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
        case .octaveFlutterSpeed: patch.octaveFlutterAmount = (patch.octaveFlutterAmount + delta).clamped(to: 0...100)
        case .octaveFlutterPattern: patch.octaveFlutterPattern = (patch.octaveFlutterPattern + delta.signum()).clamped(to: 0...(ByteOctaveFlutterPattern.allCases.count - 1))
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

    /// Sets a Sound Lab control from an absolute fader position. The UI uses this path
    /// for both direct track drags and VoiceOver adjustments, so every parameter has a
    /// real writable value instead of relying on a gesture-specific delta.
    func setPatchValue(channel: ByteChannel, parameter: BytePatchParameter, value: Int) {
        guard let index = project.channelPatches.firstIndex(where: { $0.channel == channel }) else { return }
        var patch = project.channelPatches[index]
        switch parameter {
        case .tone:
            if channel == .wave {
                patch.waveShape = value.clamped(to: 0...(ByteWaveShape.allCases.count - 1))
            } else {
                patch.duty = value.clamped(to: 0...3)
            }
        case .duty: patch.duty = value.clamped(to: 0...3)
        case .envelopeAttack: patch.envelopeAttack = value.clamped(to: 0...100)
        case .envelopeDecay: patch.envelopeDecay = value.clamped(to: 0...100)
        case .envelopeSustain: patch.envelopeSustain = value.clamped(to: 0...100)
        case .envelopeRelease: patch.envelopeRelease = value.clamped(to: 0...100)
        case .portamento: patch.portamento = value.clamped(to: 0...100)
        case .portamentoTime: patch.portamentoTime = value.clamped(to: 0...100)
        case .octaveFlutterSpeed: patch.octaveFlutterAmount = value.clamped(to: 0...100)
        case .octaveFlutterPattern: patch.octaveFlutterPattern = value.clamped(to: 0...(ByteOctaveFlutterPattern.allCases.count - 1))
        case .vibratoCycleLength: patch.vibratoCycleLength = value.clamped(to: 0...100)
        case .vibratoDepth: patch.vibratoDepth = value.clamped(to: 0...100)
        case .vibratoDelay: patch.vibratoDelay = value.clamped(to: 0...100)
        case .bendRange: patch.bendRange = value.clamped(to: 0...24)
        case .octave: patch.octave = value.clamped(to: -2...2)
        case .tremolo: patch.tremolo = value.clamped(to: 0...100)
        case .envelope: patch.envelope = value.clamped(to: 0...100)
        case .waveShape: patch.waveShape = value.clamped(to: 0...(ByteWaveShape.allCases.count - 1))
        case .waveFilter: patch.waveFilter = value.clamped(to: 0...100)
        case .waveEnvelope: patch.waveEnvelope = value.clamped(to: 0...100)
        case .volume: patch.initialVolume = value.clamped(to: 0...15)
        case .envelopeDirection: patch.envelopeIncrease = value >= 50
        case .envelopePace: patch.envelopePace = value.clamped(to: 0...7)
        case .sweepPace: patch.sweepPace = value.clamped(to: 0...7)
        case .sweepDirection: patch.sweepIncrease = value >= 50
        case .sweepShift: patch.sweepShift = value.clamped(to: 0...7)
        case .waveVolume: patch.waveVolume = value.clamped(to: 0...3)
        case .drumSample:
            if patch.drumSamples.indices.contains(patch.drumVoice) { patch.drumSamples[patch.drumVoice] = value.clamped(to: 1...2) }
        case .panLeft: patch.panLeft = value >= 50
        case .panRight: patch.panRight = value >= 50
        case .lengthCounter: patch.lengthCounter = value >= 50
        case .length: patch.length = value.clamped(to: 0...63)
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
    // Sound design stays available in the core app; the Export Pack gates WAV
    // export without making the instrument editor paywalled.
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
            pushUndoStep(historyCurrent)
        }

        project.modifiedAt = .now
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        persist()
    }

    private func restoreHistoryEntry(_ entry: HistoryEntry) {
        // A membership step carries the whole cart, including whether the row it consumed is free
        // to be offered again. Plain edits leave it nil and only move the selected project.
        if let library = entry.library {
            projects = library.projects
            consumedPreservedIDs = library.consumedPreservedIDs
            deletedProjects = library.deletedProjects
            dismissedPreservedIDs = library.dismissedPreservedIDs
        }
        project = entry.project
        currentPatternID = project.patterns.contains(where: { $0.id == entry.currentPatternID })
            ? entry.currentPatternID
            : (project.arrangedPatterns.first?.id ?? project.patterns[0].id)
        selectedStep = nil
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID, library: entry.library)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        persist()
        // Only a membership step can move the deleted stack or the dismissed ids, and undoing one
        // has to move both payloads with it, or a relaunch would resurrect work the user just
        // cleared from the list.
        if entry.library != nil {
            persistDeletedProjects()
            persistDismissedRecoverableIDs()
        }
    }

    private func pushUndoStep(_ entry: HistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        historyCurrent = HistoryEntry(project: project, currentPatternID: currentPatternID)
    }

    private func persistSelection() {
        defaults.set(project.id.uuidString, forKey: Self.selectedProjectKey)
        persist()
    }

    /// Writes the live library. This runs on every edit — including every tick of a fader drag — so
    /// it uses the compact storage encoder rather than the pretty-printing one exports use.
    private func persist() {
        // An empty library reads back as "nothing stored", which is indistinguishable from a
        // corrupt one, so a transient empty state must never overwrite real saved work.
        guard !projects.isEmpty else { return }
        if let data = encodeLibrary() {
            defaults.set(data, forKey: Self.projectsKey)
        }
        defaults.set(project.id.uuidString, forKey: Self.selectedProjectKey)
    }

    /// The last rendered take, kept so a second export of an unchanged arrangement reuses the file
    /// instead of synthesizing the same track again.
    ///
    /// A render reads the project *and* the pattern sequence the export screen chose — Song Mode
    /// plays a different arrangement than the page the sheet was opened from — so both are kept as
    /// the entry's key. Everything else the render reads lives inside the project, so a snapshot
    /// that still matches is the whole invalidation story: editing anything makes the comparison
    /// fail and the next export renders afresh, with no separate "clear the cache" call to forget.
    ///
    /// What it holds is a URL, not audio: the render streams into the file the handover needs, so
    /// there is no second copy to keep warm and nothing to spill. It lives here rather than in
    /// `ExportView`'s state because a sheet's `@State` is torn down with the sheet, and saving to
    /// Files then tapping SHARE WAV opens it twice.
    private var cachedWave: CachedWave?

    private struct CachedWave {
        let project: ByteProject
        /// Already run through `patternsIgnoringIdentity`, so a plain comparison is a comparison of
        /// what the renderer would actually hear.
        let patterns: [BytePattern]
        let url: URL
    }

    /// The id every pattern takes on inside a cache key.
    private static let waveKeyPatternID = UUID()

    /// Drops pattern identity out of a cache key by giving every pattern the same id.
    ///
    /// Pattern `id` is not something the renderer reads, and a derived sequence can carry a fresh
    /// id for every read: Song Mode fills its silent bars with a newly built `EMPTY BAR` pattern
    /// each time it is asked, so comparing ids would miss the cache on any arrangement with a gap
    /// in it — precisely the long takes where a second synthesis costs the most. Every other field
    /// stays in the comparison, so a new audio-relevant field on `BytePattern` cannot quietly slip
    /// past the key the way a hand-written list of fields would let it.
    private static func patternsIgnoringIdentity(_ patterns: [BytePattern]) -> [BytePattern] {
        patterns.map { pattern in
            var normalized = pattern
            normalized.id = waveKeyPatternID
            return normalized
        }
    }

    /// The file holding these exact inputs, or nil when they have changed since the last render and
    /// the track has to be synthesized again.
    ///
    /// A hit also requires the file to still be there. The take lives in the temporary directory,
    /// which the system may reclaim while the app is running, so an entry that named a file which is
    /// gone would hand the share sheet nothing while the screen still claimed a finished take.
    func cachedWaveURL(project: ByteProject, patterns: [BytePattern]) -> URL? {
        guard let cached = cachedWave,
              cached.project == project,
              cached.patterns == Self.patternsIgnoringIdentity(patterns),
              FileManager.default.fileExists(atPath: cached.url.path) else { return nil }
        return cached.url
    }

    /// Records a finished render. One entry: the next render replaces it, so the cache never grows
    /// with the number of takes the user has exported, and what it holds is one URL — the audio it
    /// names is the file the render streamed to disk, never more than a single take's worth.
    func cacheWaveURL(_ url: URL, project: ByteProject, patterns: [BytePattern]) {
        cachedWave = CachedWave(project: project, patterns: Self.patternsIgnoringIdentity(patterns), url: url)
    }

    /// Encoded JSON for each project, kept so a save only re-encodes the project that changed.
    ///
    /// The library is stored as one payload, so encoding it wholesale makes a save cost scale with
    /// the *number of projects the user owns* rather than with what they just edited — and this
    /// runs on every tick of a fader drag. Caching each project's own JSON and splicing the pieces
    /// together keeps an edit proportional to the project that changed.
    private var encodedProjects: [UUID: EncodedProject] = [:]

    private struct EncodedProject {
        let snapshot: ByteProject
        let json: Data
    }

    /// Serializes the live library as `{"schemaVersion":n,"projects":[…]}`.
    ///
    /// The container is written by hand rather than through `LibraryEnvelope` so unchanged
    /// projects can be spliced in as their cached bytes. The shape it produces is the envelope's
    /// shape, and `testSplicedLibraryPayloadStillDecodesAsTheWholeEnvelope` pins that equality so
    /// the two cannot drift apart silently. JSON object members are unordered, so a spliced payload
    /// is a valid encoding of the same value, not a second format.
    ///
    /// Returns nil when a project cannot be encoded, which leaves the previously stored payload in
    /// place — the same outcome as the wholesale encode failing, since neither write would happen.
    private func encodeLibrary() -> Data? {
        var jsonPieces: [Data] = []
        jsonPieces.reserveCapacity(projects.count)
        var nextCache: [UUID: EncodedProject] = [:]
        nextCache.reserveCapacity(projects.count)

        for project in projects {
            let entry: EncodedProject
            if let cached = encodedProjects[project.id], cached.snapshot == project {
                entry = cached
            } else if let encoded = try? JSONEncoder.bytePocketStorageEncoder.encode(project) {
                entry = EncodedProject(snapshot: project, json: encoded)
            } else {
                return nil
            }
            nextCache[project.id] = entry
            jsonPieces.append(entry.json)
        }
        // Rebuilt from the live library, so a removed project's bytes are not held on to.
        encodedProjects = nextCache

        var payload = Data()
        payload.append(Data("{\"schemaVersion\":\(Self.currentLibraryVersion),\"projects\":[".utf8))
        for (index, piece) in jsonPieces.enumerated() {
            if index > 0 { payload.append(0x2C) }
            payload.append(piece)
        }
        payload.append(Data("]}".utf8))
        return payload
    }

    /// Writes the deleted-project stack. Called only when the stack actually changes — never from
    /// `persist()`, which runs on every edit — so an ordinary fader move does not re-encode it.
    ///
    /// An empty stack removes the payload rather than storing an empty one, so an install with
    /// nothing deleted has nothing for the launch path to read.
    private func persistDeletedProjects() {
        guard !deletedProjects.isEmpty else {
            defaults.removeObject(forKey: Self.projectsDeletedKey)
            return
        }
        let envelope = LibraryEnvelope(schemaVersion: Self.currentLibraryVersion, projects: deletedProjects)
        if let data = try? JSONEncoder.bytePocketStorageEncoder.encode(envelope) {
            defaults.set(data, forKey: Self.projectsDeletedKey)
        }
    }

    /// Writes the dismissed-row ids, and only when that list changes. An empty list removes the
    /// payload, so a cart with nothing dismissed has nothing for the launch path to read.
    private func persistDismissedRecoverableIDs() {
        guard !dismissedPreservedIDs.isEmpty else {
            defaults.removeObject(forKey: Self.dismissedRecoverableKey)
            return
        }
        if let data = try? JSONEncoder.bytePocketStorageEncoder.encode(dismissedPreservedIDs) {
            defaults.set(data, forKey: Self.dismissedRecoverableKey)
        }
    }

    /// A stored entry that never fails to decode, so one unreadable project cannot take the
    /// rest of the library down with it.
    private struct LenientProject: Codable {
        let project: ByteProject?

        init(project: ByteProject?) {
            self.project = project
        }

        init(from decoder: Decoder) throws {
            project = try? ByteProject(from: decoder)
        }

        /// Writes the project inline rather than wrapped in a container, so the stored shape does
        /// not change just because reading it is lenient.
        func encode(to encoder: Encoder) throws {
            try project?.encode(to: encoder)
        }
    }

    /// Versioned container for the stored library.
    ///
    /// Version 1 was a bare `[ByteProject]` array with no envelope at all. Reading that shape is
    /// the migration: it decodes as version 1 and the next save writes the current version. The
    /// two shapes are mutually exclusive — an array is not a keyed container and vice versa — so
    /// detection needs no sniffing.
    private struct LibraryEnvelope: Codable {
        static let introducedVersion = 2

        let schemaVersion: Int
        let projects: [LenientProject]

        init(schemaVersion: Int, projects: [ByteProject]) {
            self.schemaVersion = schemaVersion
            self.projects = projects.map { LenientProject(project: $0) }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.introducedVersion
            projects = try container.decodeIfPresent([LenientProject].self, forKey: .projects) ?? []
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, projects }
    }

    /// Decodes the preserved payloads once at launch so the recovery surface is a stable snapshot
    /// rather than something that shifts as the live library is edited. A project kept in both
    /// payloads is listed once, under the backup, since that is a payload the library previously
    /// read back cleanly.
    ///
    /// `suppressedIDs` are the projects in the deleted stack. They are offered through the delete
    /// path instead, which keeps them labelled as work the user removed rather than as a payload
    /// that happened to survive, and it is what stops one project being listed twice.
    private static func decodePreservedLibrary(
        from payloads: [(RecoveredProject.Source, Data)],
        suppressing suppressedIDs: Set<UUID>
    ) -> PreservedLibrary {
        var result = PreservedLibrary()
        var seen = Set<UUID>()
        for (source, data) in payloads {
            // Empty data is not preserved work; it is UserDefaults echoing back a key it was given.
            guard !data.isEmpty else { continue }
            guard let stored = decodeStoredLibrary(data) else {
                result.unreadableCopies += 1
                continue
            }
            result.unreadableEntries += stored.dropped
            for project in stored.projects
            where !suppressedIDs.contains(project.id) && seen.insert(project.id).inserted {
                result.projects.append(RecoveredProject(project: project, source: source))
            }
        }
        return result
    }

    /// Reads the projects the delete path set aside. Persisting them is what lets a deletion
    /// outlive the session that made it, so this is the launch half of that contract.
    ///
    /// Decoding is lenient in the same way the library is: an entry that will not decode is
    /// skipped rather than taking the rest with it, and bytes that cannot be read at all are kept.
    /// Entries whose project is already in the cart are dropped, since the cart is the newer copy.
    private static func loadDeletedProjects(from defaults: UserDefaults, excluding cart: [ByteProject]) -> [ByteProject] {
        guard let data = defaults.data(forKey: projectsDeletedKey), !data.isEmpty else { return [] }
        guard let stored = decodeStoredLibrary(data) else {
            // Park the unreadable bytes somewhere a later build can still try them. Only when the
            // library load did not already occupy that key: both are valid, and neither should
            // evict the other. The payload itself is left untouched, so nothing is rewritten here.
            if defaults.data(forKey: projectsQuarantineKey) == nil {
                defaults.set(data, forKey: projectsQuarantineKey)
            }
            return []
        }
        let cartIDs = Set(cart.map(\.id))
        var seen = Set<UUID>()
        return stored.projects.filter { !cartIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Reads the ids the user cleared from the recovery list one row at a time.
    ///
    /// This is a hint about what not to show, never data, so it fails open: a payload that will not
    /// decode simply hides nothing and the row comes back, rather than a project being lost. Ids are
    /// de-duplicated on the way in so a hand-edited payload cannot make one row consume several.
    private static func loadDismissedRecoverableIDs(from defaults: UserDefaults) -> [UUID] {
        guard let data = defaults.data(forKey: dismissedRecoverableKey),
              let ids = try? JSONDecoder.bytePocketDecoder.decode([UUID].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Reads a stored library in any shape this app has ever written, reporting how many entries
    /// were unreadable and which version the payload declared. Returns nil when the payload is
    /// not a library at all, rather than an empty one.
    private static func decodeStoredLibrary(_ data: Data) -> (projects: [ByteProject], dropped: Int, version: Int)? {
        guard !data.isEmpty else { return nil }

        if let envelope = try? JSONDecoder.bytePocketDecoder.decode(LibraryEnvelope.self, from: data) {
            let projects = envelope.projects.compactMap(\.project)
            return (projects, envelope.projects.count - projects.count, envelope.schemaVersion)
        }

        // Version 1: a bare array of projects with no envelope.
        if let entries = try? JSONDecoder.bytePocketDecoder.decode([LenientProject].self, from: data) {
            let projects = entries.compactMap(\.project)
            return (projects, entries.count - projects.count, legacyLibraryVersion)
        }

        return nil
    }

    /// Loads the library without ever letting a single bad project replace it with silence.
    ///
    /// A project that would not decode used to fail the whole array decode, and the next save
    /// then overwrote every project with a blank one. Each entry is now decoded on its own, the
    /// primary payload is mirrored to a rolling backup once it reads back cleanly, and bytes that
    /// cannot be read are preserved instead of discarded.
    ///
    /// A library rebuilt from the backup is written back to the primary, so recovery is a
    /// one-time event rather than something the user is told about on every launch. A payload
    /// that is only *partly* readable is deliberately left alone: its unreadable entries are
    /// still in the primary, and rewriting it here would trade bytes we cannot read for the
    /// appearance of a clean load.
    private static func loadLibrary(from defaults: UserDefaults) -> (projects: [ByteProject], recovery: LibraryRecovery?) {
        if let data = defaults.data(forKey: projectsKey),
           let stored = decodeStoredLibrary(data),
           !stored.projects.isEmpty {
            // Only a payload that just read back is allowed to become the fallback copy.
            defaults.set(data, forKey: projectsBackupKey)

            // A version 1 payload is migrated in place by being read: nothing is rewritten here,
            // so a failed read still cannot damage what is on disk. A payload from a newer build
            // is loaded as far as this build understands it, with its original bytes preserved.
            let newerFormat = stored.version > currentLibraryVersion
                || stored.projects.contains { $0.schemaVersion > ByteProject.currentSchemaVersion }
            guard stored.dropped > 0 || newerFormat else { return (stored.projects, nil) }

            defaults.set(data, forKey: projectsQuarantineKey)
            return (
                stored.projects,
                LibraryRecovery(droppedProjects: stored.dropped, newerFormatFound: newerFormat)
            )
        }

        // The primary is missing or unreadable: preserve its bytes before anything overwrites them.
        if let unreadable = defaults.data(forKey: projectsKey) {
            defaults.set(unreadable, forKey: projectsQuarantineKey)
        }
        if let backup = defaults.data(forKey: projectsBackupKey),
           let stored = decodeStoredLibrary(backup),
           !stored.projects.isEmpty {
            // Heal the primary with the payload that just decoded, so the next launch takes the
            // clean path instead of recovering all over again and telling the user their library
            // was restored a second time. The unreadable primary was copied to quarantine just
            // above, so this cannot discard anything.
            //
            // The backup is promoted verbatim rather than re-encoded: if the backup itself held
            // entries this build cannot read, re-encoding would drop those bytes from the only
            // surviving copy. Healing is a relocation, never a rewrite.
            defaults.set(backup, forKey: projectsKey)
            return (
                stored.projects,
                LibraryRecovery(unreadableLibrary: true, droppedProjects: stored.dropped, usedBackup: true)
            )
        }

        // Nothing recoverable: first launch, or a library that could never be read. The blank
        // project is a starting point, not a replacement for saved work.
        let hadStoredData = defaults.data(forKey: projectsKey) != nil
        return ([.blank], hadStoredData ? LibraryRecovery(unreadableLibrary: true) : nil)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
