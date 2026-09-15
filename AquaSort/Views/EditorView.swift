import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(GameStore.self) private var store
    @Environment(StoreKitManager.self) private var storeKit
    @State private var audio = ByteAudioEngine()
    @State private var page = 0
    @State private var hasNavigatedThisLaunch = false
    // The visible station can change immediately during playback while the audio source
    // remains on its current station until the loop boundary.
    @State private var audioPage = 0
    @State private var currentStep = -1
    @State private var currentSongSlot = -1
    @State private var pendingPatternID: UUID?
    @State private var pendingPage: Int?
    @State private var patternDragStartIndex: Int?
    @State private var lastPatternDragIndex: Int?
    @State private var armedLink: PendingNoteLink?
    /// Live value readout for a pitch or voice drag on the pad grid. The pad is
    /// under the fingertip, so the value being set has to be shown elsewhere.
    @State private var scrubReadout: String?
    @State private var showLibrary = false
    @State private var showExport = false
    @State private var showImport = false
    @State private var showPatternRename = false
    @State private var patternRenameText = ""
    @State private var patternRenameID: UUID?
    @State private var showDeletePatternConfirmation = false
    @State private var patternIDToDelete: UUID?
    @State private var showClearRowConfirmation = false
    @State private var clearRowChannel: ByteChannel?
    @State private var showClearSongSlotConfirmation = false
    @State private var songSlotToClear: Int?
    @State private var playbackRefreshTask: Task<Void, Never>?
    @State private var scrubbedSongSlot: Int?
    @State private var songArrangementPage = 0
    @State private var editorScrollMetrics = EditorScrollMetrics()
    @State private var editorViewportHeight: CGFloat = 0
    @State private var logoDragOffset: CGFloat = 0
    @State private var logoDragStartFraction: CGFloat = 0
    @State private var logoDragArmed = false
    @State private var twoFingerScrollProxy: ScrollViewProxy?
    @State private var twoFingerLastDy: CGFloat?

    /// A note end waiting to be placed by the next tap on a later pad.
    ///
    /// The channel travels with the step so an armed link cannot outlive the row it was
    /// armed on: arming one on PULSE A and then switching to the drum row would otherwise
    /// leave the mode armed and invisible, and the next tap would quietly set a note length
    /// on a row that is no longer on screen.
    private struct PendingNoteLink: Equatable {
        let channel: ByteChannel
        let step: Int
    }

    /// The armed link, but only while the row it was armed on is the row on screen.
    private var linkSourceStep: Int? {
        guard let armedLink, armedLink.channel == store.selectedChannel else { return nil }
        return armedLink.step
    }

    private var pageTitle: String {
        switch page {
        case 0: return "BEATPAD"
        case 1: return "SOUND LAB"
        case 2: return "FX STATION"
        default: return "SONG MODE"
        }
    }

    private var selectedPattern: BytePattern {
        store.project.patterns.first(where: { $0.id == store.currentPatternID }) ?? store.project.patterns[0]
    }

    private var selectedChannelNotes: [Int?] {
        let row = ByteChannel.allCases.firstIndex(of: store.selectedChannel) ?? 0
        return selectedPattern.steps[row]
    }

    var body: some View {
        ZStack {
            PocketBackdrop()
            LiveAmbientField(
                active: store.isPlaying,
                phase: currentStep,
                accent: restoredChannelAccent(store.selectedChannel)
            )
            GeometryReader { proxy in
                // A small negative overlap pulls the shell/header region upward toward
                // the centered logo, removing the empty band visible beneath the branding.
                ScrollViewReader { scrollProxy in
                    // The shell sits flush beneath the brand block: the "DRAG LOGO TO
                    // SCROLL" caption now occupies the band under the logo, so the old
                    // negative overlap (which reclaimed that band) would cover it.
                    VStack(spacing: 0) {
                        // Keep the brand in its own safe-area row. This keeps it centered at
                        // the physical top of the app instead of making it compete with the
                        // Sequencer Ready status inside every page header. The logo itself is
                        // the drag scroller: drag it up or down to glide through the page.
                        VStack(spacing: 4) {
                            topBrandMark
                                .offset(y: logoDragOffset)
                                .accessibilityHint("Drag up or down to scroll the page")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: seekScroll(proxy: scrollProxy, fraction: min(1, scrollFraction + 0.12))
                                    case .decrement: seekScroll(proxy: scrollProxy, fraction: max(0, scrollFraction - 0.12))
                                    @unknown default: break
                                    }
                                }
                            Text("DRAG LOGO TO SCROLL")
                                .font(.custom("Futura-Bold", size: 7))
                                .tracking(0.6)
                                .foregroundStyle(Color.amber.opacity(0.75))
                                // The caption rides along with the logo's drag
                                // follow-offset so the whole brand block moves as one.
                                .offset(y: logoDragOffset)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        // The WHOLE brand row is the drag surface — the row's layout now
                        // contains the artwork itself, so the gesture can't be missed.
                        // The logo artwork still follows the finger and springs back on
                        // release.
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    let overflow = editorScrollMetrics.contentHeight - editorViewportHeight
                                    guard overflow > 8 else { return }
                                    if !logoDragArmed {
                                        // Arm the scrub at the current position on first touch.
                                        logoDragArmed = true
                                        logoDragStartFraction = scrollFraction
                                    }
                                    // The logo artwork follows the pull, clamped so it can't
                                    // fly off the row — it springs back on release.
                                    logoDragOffset = min(16, max(-16, gesture.translation.height))
                                    // Pull-gain: the further you pull the logo, the more each
                                    // point of pull scrolls. The ramp saturates at 34pt so gain
                                    // stabilizes (~4.75x) instead of surging for the whole pull —
                                    // a capped ramp keeps tracking speed steady and smooth.
                                    let pull = gesture.translation.height
                                    let magnitude = max(0, abs(pull) - 5)
                                    let gain = 1 + min(37.5, magnitude) / 10
                                    // Scrollbar-style direction: pull down -> the page scrolls
                                    // down; pull up -> it scrolls back up. The target is
                                    // recomputed from the pull start + the FULL translation on
                                    // every event, so a dropped event can never lose movement.
                                    let next = min(1, max(0, logoDragStartFraction + pull * gain / max(1, overflow)))
                                    seekScroll(proxy: scrollProxy, fraction: next)
                                }
                                .onEnded { gesture in
                                    logoDragArmed = false
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                                        logoDragOffset = 0
                                    }
                                    // Flick-to-glide: a quick pull keeps coasting with an
                                    // ease-out, so an immediate swipe travels a good distance
                                    // instead of stopping when the finger lifts. The glide is
                                    // capped at ~0.7 of a viewport so a hard flick covers about
                                    // one screen (drag travel + glide), like native scroll.
                                    let velocity = gesture.predictedEndTranslation.height - gesture.translation.height
                                    let overflow = editorScrollMetrics.contentHeight - editorViewportHeight
                                    guard overflow > 8, abs(velocity) > 150 else { return }
                                    let glide = (velocity > 0 ? 1.0 : -1.0) * min(0.7, abs(velocity) / 1000 * 0.85)
                                    let target = min(1, max(0, scrollFraction + glide * editorViewportHeight / max(1, overflow)))
                                    seekScroll(proxy: scrollProxy, fraction: target, animate: true)
                                }
                        )

                        ArcadeShell {
                            VStack(spacing: 0) {
                                ScrollView(.vertical, showsIndicators: false) {
                                    restoredPageContent
                                        .frame(maxWidth: .infinity, alignment: .top)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 10)
                                        .padding(.bottom, 18)
                                        // Track scroll metrics by reading the content frame directly
                                        // instead of relying on preference propagation, which does
                                        // not fire reliably inside this ScrollView hierarchy.
                                        .background {
                                            GeometryReader { contentProxy in
                                                Color.clear
                                                    .onAppear {
                                                        editorScrollMetrics = EditorScrollMetrics(
                                                            contentHeight: contentProxy.size.height,
                                                            contentMinY: contentProxy.frame(in: .named("beatboi-editor-scroll")).minY
                                                        )
                                                    }
                                                    .onChange(of: contentProxy.frame(in: .named("beatboi-editor-scroll")).minY) { _, newMinY in
                                                        editorScrollMetrics = EditorScrollMetrics(
                                                            contentHeight: contentProxy.size.height,
                                                            contentMinY: newMinY
                                                        )
                                                    }
                                            }
                                        }
                                        // Two-finger scroll bridge. Anchored to the scroll
                                        // CONTENT so its superview chain reaches the backing
                                        // UIScrollView; it drives the same seek pipeline as the
                                        // logo drag with native-feel flick momentum.
                                        .background {
                                            TwoFingerScrollBridge(
                                                onStart: { twoFingerLastDy = 0 },
                                                onChanged: { twoFingerDragChanged($0) },
                                                onEnd: { twoFingerDragEnded($0) }
                                            )
                                            .frame(width: 0, height: 0)
                                        }
                                        // The puck's seek targets hidden markers spread across the
                                        // FULL content height. Overlay means zero layout impact, so
                                        // it neither changes the measured metrics nor the scrollable
                                        // area. Markers get REAL layout frames (a VStack of thin
                                        // slices) so ScrollViewReader can resolve each id to its
                                        // own position — .position() is only a geometry effect and
                                        // every marker resolved to the same frame.
                                        .overlay(alignment: .top) {
                                            let markerHeight = max(1, editorScrollMetrics.contentHeight)
                                            VStack(spacing: 0) {
                                                ForEach(0..<561, id: \.self) { markerIndex in
                                                    Color.clear
                                                        .frame(width: 2, height: markerHeight / 561.0)
                                                        .id("beatboi-scroll-marker-\(markerIndex)")
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(height: markerHeight)
                                            .allowsHitTesting(false)
                                        }
                                }
                                .coordinateSpace(name: "beatboi-editor-scroll")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .scrollBounceBehavior(.basedOnSize)
                                .scrollIndicators(.hidden)
                                .background {
                                    GeometryReader { viewportProxy in
                                        Color.clear
                                            .onAppear {
                                                editorViewportHeight = viewportProxy.size.height
                                            }
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    EditorScrollBar(metrics: editorScrollMetrics)
                                        .padding(.trailing, 3)
                                        .allowsHitTesting(false)
                                }

                                restoredPageSwitcher
                                    .padding(.horizontal, 5)
                                    .padding(.top, 8)
                                    .padding(.bottom, max(6, proxy.safeAreaInsets.bottom))
                                    .background(Color.plastic.opacity(0.98))
                            }
                        }
                        // The shell's compensating padding drops back to 29pt: the brand
                        // row now uses its full 72pt (the caption lives in the band the
                        // old -18 overlap reclaimed), so 72 + 29 keeps the shell at the
                        // same on-screen position as the previous 72 - 18 + 47 layout.
                        .padding(.top, 29)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 8)
                    // Original brand-band padding, shifted up 47pt: the artwork now sits
                    // at its ORIGINAL rendered position as REAL LAYOUT (no .offset
                    // lift), so its hit area covers every visible pixel — the fix for
                    // the dead-zone touches — while the pixels stay exactly where the
                    // design put them. The shell padding below compensates by +29.
                    .padding(.top, max(0, max(4, proxy.safeAreaInsets.top - 12) - 47))
                    .padding(.bottom, 0)
                    .onAppear {
                        twoFingerScrollProxy = scrollProxy
                        if ProcessInfo.processInfo.arguments.contains("-GBTwoFingerTest") {
                            simulateTwoFingerSwipeForTesting()
                        }
                    }


                }
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    PocketToast(message: toast)
                        .padding(.bottom, 78)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showLibrary) { ProjectLibraryView() }
        .sheet(isPresented: $showExport) { ExportView(useSongArrangement: page == 3) }
        .task {
            configureSongLoopUITestIfNeeded()
            // XCTest launches can inherit the previous scene's @State restoration. Keep
            // the ordinary UI-test surface on Beatpad until the test deliberately selects
            // another station; this does not affect normal user navigation.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return }
            page = 0
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, !hasNavigatedThisLaunch else { return }
                page = 0
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.bytePocketProject, .json, .bytePocketMIDI]) { importFile($0) }
        .onChange(of: store.project.id) { _, _ in
            // Project-library selection can happen while the sequencer is live. Publish
            // the newly selected snapshot without restarting the transport.
            requestPlaybackRefresh()
        }
        .onChange(of: store.project.modifiedAt) { _, _ in
            // Importing or editing from a sheet may bypass an inline callback. The
            // modified-date observation keeps the live audio snapshot in sync without
            // restarting the transport or changing the visible station.
            requestPlaybackRefresh()
        }
        .alert("RENAME PATTERN", isPresented: $showPatternRename) {
            TextField("PATTERN NAME", text: $patternRenameText)
            Button("SAVE") {
                if let patternRenameID { store.renamePattern(patternRenameID, name: patternRenameText); requestPlaybackRefresh() }
            }
            Button("CANCEL", role: .cancel) {}
        } message: { Text("Name this pattern for Beatpad and Song Mode.") }
        .alert("DELETE PATTERN?", isPresented: $showDeletePatternConfirmation) {
            Button("DELETE", role: .destructive) {
                if let patternIDToDelete {
                    _ = store.deletePattern(patternIDToDelete)
                    requestPlaybackRefresh()
                }
                self.patternIDToDelete = nil
            }
            Button("CANCEL", role: .cancel) { patternIDToDelete = nil }
        } message: {
            Text("This removes the pattern from the bank and Song Mode. You can use Undo immediately if you change your mind.")
        }
        .alert("CLEAR \(clearRowChannel?.title ?? "CHANNEL")?", isPresented: $showClearRowConfirmation) {
            Button("CLEAR ROW", role: .destructive) {
                if let clearRowChannel {
                    store.clearChannelRow(clearRowChannel)
                    requestPlaybackRefresh()
                }
                self.clearRowChannel = nil
            }
            Button("CANCEL", role: .cancel) { clearRowChannel = nil }
        } message: {
            Text("This removes every note from the selected channel row. Undo is available.")
        }
        .alert("CLEAR SONG BAR?", isPresented: $showClearSongSlotConfirmation) {
            Button("CLEAR BAR", role: .destructive) {
                if let songSlotToClear {
                    store.clearSongSlot(at: songSlotToClear)
                    requestPlaybackRefresh()
                }
                self.songSlotToClear = nil
            }
            Button("CANCEL", role: .cancel) { songSlotToClear = nil }
        } message: {
            Text("This removes the pattern assignment from this Song Mode bar. Undo is available.")
        }
        .onDisappear { playbackRefreshTask?.cancel(); audio.stop() }
    }

    @ViewBuilder
    private var restoredPageContent: some View {
        if page == 0 { restoredBeatpadPage }
        else if page == 1 { restoredSoundLabPage }
        else if page == 2 { restoredFXPage }
        else { restoredSongPage }
    }

    private var topBrandMark: some View {
        Image("beatboi")
            .resizable()
            .scaledToFit()
            .frame(width: 216, height: 46)
            // NOTE: no .offset() here. The row's top padding places this artwork
            // at its original rendered position as genuine layout, so hit-testing
            // matches the pixels (an .offset lift renders outside the touchable
            // bounds, which is what made the logo feel untouchable before).
            .padding(.horizontal, 12)
            .beatGlow(active: store.isPlaying, phase: currentStep, color: .amber)
            .accessibilityLabel("BEATBOI")
            .accessibilityValue(String(format: "%.2f", scrollFraction))
            .accessibilityIdentifier("beatboi-logo")
            .accessibilityAddTraits(.isHeader)
    }

    private var restoredHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.isPlaying ? Color.arcadeRed : Color.gbGlow)
                        .frame(width: 6, height: 6)
                        .beatGlow(active: store.isPlaying, phase: currentStep, color: store.isPlaying ? .arcadeRed : .gbGlow)
                    Text(store.isPlaying ? "SEQUENCER LIVE" : "SEQUENCER READY")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.mutedText)
                    MiniBeatIndicator(step: currentStep, active: store.isPlaying)
                        .frame(width: 42, height: 12)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                // Visible only once the receipt backs the Export Pack entitlement.
                if storeKit.hasReceiptEntitlement {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 9, weight: .black))
                        Text("EXPORT PACK")
                            .font(.custom("Futura-Bold", size: 8))
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(Color.gbGlow)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(Color.hardwareBlack)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.gbGlow.opacity(0.55), lineWidth: 1))
                    .accessibilityLabel("Export Pack unlocked")
                    .accessibilityIdentifier("exportPackBadge")
                }
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .black))
                    Text(pageTitle)
                        .font(.custom("Futura-Bold", size: 8))
                        .tracking(0.7)
                }
                .foregroundStyle(Color.gbLight)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(Color.hardwareBlack)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.plasticHighlight, lineWidth: 1))
            }
            HStack(spacing: 8) {
                Text(page == 0 ? "PERFORMANCE / 4 PARTS" : page == 1 ? "SOUND DESIGN / PATCH" : page == 2 ? "EFFECTS / BUS + SENDS" : "ARRANGEMENT / \(store.songArrangementLength) SLOTS")
                    .font(.custom("Futura-Bold", size: 8))
                    .tracking(0.6)
                    .foregroundStyle(Color.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer()
                HStack(spacing: 5) {
                    RestoredHistoryButton(systemImage: "arrow.uturn.backward", label: "Undo", disabled: !store.canUndo) {
                        store.undo()
                        requestPlaybackRefresh()
                    }
                    RestoredHistoryButton(systemImage: "arrow.uturn.forward", label: "Redo", disabled: !store.canRedo) {
                        store.redo()
                        requestPlaybackRefresh()
                    }
                    RestoredHeaderIcon(systemImage: "folder.fill", label: "Open project library") { showLibrary = true }
                    RestoredHeaderIcon(systemImage: "square.and.arrow.down", label: "Import project") { showImport = true }
                    RestoredHeaderIcon(systemImage: "square.and.arrow.up", label: "Export project") { showExport = true }
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.92), Color.hardwareBlack.opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.plasticHighlight.opacity(0.8), lineWidth: 1))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.amber.opacity(0.72)).frame(height: 2).padding(.horizontal, 10) }
    }

    private var restoredBeatpadPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "PERFORMANCE", detail: "16 STEP / LIVE") {
                restoredConsole
            }
            restoredVoicing
            // The mixer cards are the Beatpad channel selectors. Tapping a card selects
            // its pad row; swiping horizontally on that same card changes its volume.
            restoredChannelMixer
            restoredPadEditor
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Cosmetic only: the performance station gets a single calm field behind its
        // existing panels, so the page reads as one instrument instead of four unrelated
        // cards. It does not alter layout or hit testing.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.hardwareBlack.opacity(0.20))
                .overlay {
                    LinearGradient(
                        colors: [restoredChannelAccent(store.selectedChannel).opacity(store.isPlaying ? 0.10 : 0.045), .clear, Color.amber.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(restoredChannelAccent(store.selectedChannel).opacity(store.isPlaying ? 0.32 : 0.14), lineWidth: 1)
                }
        }
        .animation(.easeOut(duration: 0.2), value: store.selectedChannel)
        .animation(.easeOut(duration: 0.2), value: store.isPlaying)
    }

    private var restoredSoundLabPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "SOUND LAB", detail: "SELECT A PART TO EDIT") {
                restoredConsole
            }
            restoredChannelTabs
            restoredChannelMixer
            restoredVoicing
            restoredSoundLab
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var restoredFXPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "FX STATION", detail: "GLOBAL BUS / CHANNEL ROUTING") {
                restoredConsole
            }
            fxStation
            restoredChannelMixer
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var restoredSongPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "SONG MACHINE", detail: "\(store.songArrangementLength) BARS / LOOP-BOUNDARY SAFE") {
                VStack(spacing: 9) {
                    restoredConsole
                    songTimelineReadout
                }
            }
            songArrangementPanel
            restoredChannelMixer
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var songTimelineReadout: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.isPlaying ? "ARRANGEMENT PLAYING" : "ARRANGEMENT READY")
                    .font(.custom("Futura-Bold", size: 9))
                    .foregroundStyle(Color.gbLight)
                Spacer()
                Text(arrangementReadoutSlot.map { "BAR \(String(format: "%02d", $0 + 1)) / \(store.songArrangementLength)" } ?? "BAR — / \(store.songArrangementLength)")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(arrangementReadoutSlot.map { restoredSongColor(at: $0) } ?? Color.amber)
            }
            HStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.screenShadow.opacity(0.28))
                        if let scrubbedSongSlot {
                            Capsule()
                                .fill(restoredSongColor(at: scrubbedSongSlot))
                                .frame(width: max(12, proxy.size.width * CGFloat(scrubbedSongSlot + 1) / CGFloat(max(1, store.songArrangementLength))))
                        }
                        HStack(spacing: 2) {
                            ForEach(0..<store.songArrangementLength, id: \.self) { index in
                                SongTimelineTick(index: index, current: index == currentSongSlot, color: restoredSongColor(at: index), showLabel: store.songArrangementLength <= 32)
                            }
                        }
                        songLoopMarkers(width: proxy.size.width)
                        if let scrubbedSongSlot {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(restoredSongColor(at: scrubbedSongSlot), lineWidth: 2)
                                .frame(width: max(10, proxy.size.width / CGFloat(max(1, store.songArrangementLength)) - 2), height: 28)
                                .position(
                                    x: proxy.size.width / CGFloat(max(1, store.songArrangementLength)) * (CGFloat(scrubbedSongSlot) + 0.5),
                                    y: 11
                                )
                                .shadow(color: restoredSongColor(at: scrubbedSongSlot).opacity(0.75), radius: 4)
                                .accessibilityHidden(true)
                        }
                        if store.isPlaying, currentSongSlot >= 0 {
                            songPlayhead(width: proxy.size.width)
                        }
                    }
                    .contentShape(Rectangle())
                    // Direction-gated: a mostly-vertical drag belongs to the page scroll,
                    // so the timeline only claims horizontal strokes (and plain taps).
                    .gesture(DragGesture(minimumDistance: 8).onChanged { gesture in
                        let dx = abs(gesture.translation.width)
                        let dy = abs(gesture.translation.height)
                        guard dx >= dy else { return }
                        scrubSongTimeline(at: gesture.location.x, width: proxy.size.width)
                    }.onEnded { gesture in
                        let dx = abs(gesture.translation.width)
                        let dy = abs(gesture.translation.height)
                        if gesture.translation.height == 0 || dx >= dy {
                            scrubSongTimeline(at: gesture.location.x, width: proxy.size.width, commit: true)
                        }
                    })
                }
                .frame(height: 22)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.amber)
                    .frame(width: 5, height: 5)
                    .shadow(color: Color.amber.opacity(0.9), radius: 3)
                Text("PLAYHEAD")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.amber)
                Text("·")
                    .foregroundStyle(Color.mutedText)
                Text("OUTLINE = SELECTED BAR")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.mutedText)
                Spacer(minLength: 0)
            }
            Text("DRAG THE TIMELINE TO AUDITION A BAR  ·  ACTIVE PATTERN COLOR MATCHES BELOW")
                .font(.custom("Futura-Bold", size: 8))
                .foregroundStyle(Color.mutedText)
            .animation(.easeOut(duration: 0.12), value: currentSongSlot)
            .accessibilityHidden(true)
        }
        .padding(12)
        .background(Color.hardwareBlack.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.plasticHighlight.opacity(0.6), lineWidth: 1))
    }

    private var songArrangementPanel: some View {
        LCDPanel(title: "ARRANGEMENT TIMELINE / \(store.songArrangementLength) BARS") {
            VStack(alignment: .leading, spacing: 7) {
                arrangementPageSelector
                HStack(spacing: 5) {
                    Text("LENGTH")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.screenShadow)
                    ForEach([16, 32, 64], id: \.self) { length in
                        Button { setSongArrangementLength(length) } label: {
                            Text("\(length)")
                                .font(.custom("Futura-Bold", size: 8))
                                .foregroundStyle(store.songArrangementLength == length ? Color.gbInk : Color.screenShadow)
                                .frame(minWidth: 38, minHeight: 30)
                                .background(store.songArrangementLength == length ? Color.amber : Color.screenShadow.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.screenShadow.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(length) bar arrangement")
                        .accessibilityAddTraits(store.songArrangementLength == length ? .isSelected : [])
                    }
                    Spacer()
                    Text("TAP ASSIGN · SWIPE ↑↓ CYCLE")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.screenShadow)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 7) {
                    ForEach(songArrangementPageStart..<songArrangementPageEnd, id: \.self) { index in
                        RestoredSongPad(index: index, slot: store.songSlot(at: index), pattern: restoredSongPattern(at: index), color: restoredSongColor(at: index), current: index == currentSongSlot) {
                            Haptics.selection()
                            if store.songSlot(at: index).patternID == nil {
                                _ = store.assignSongPattern(at: index, patternID: store.currentPatternID)
                                requestPlaybackRefresh()
                            } else {
                                songSlotToClear = index
                                showClearSongSlotConfirmation = true
                            }
                        } onCycle: { delta in
                            Haptics.tap()
                            store.cycleSongSlot(at: index, delta: delta)
                            requestPlaybackRefresh()
                        }
                    }
                }
            }
        }
    }

    private var restoredPageSwitcher: some View {
        HStack(spacing: 6) {
            RestoredPageButton(title: "BEATPAD", systemImage: "square.grid.2x2.fill", selected: page == 0) { setPage(0) }
            RestoredPageButton(title: "SOUND LAB", systemImage: "slider.horizontal.3", selected: page == 1) { setPage(1) }
                RestoredPageButton(title: "FX", systemImage: "dot.radiowaves.left.and.right", selected: page == 2) { setPage(2) }
                RestoredPageButton(title: "SONG", systemImage: "list.number", selected: page == 3) { setPage(3) }
                    .accessibilityIdentifier("songPageButton")
        }
        .padding(8)
        .frame(height: 54)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.98), Color.hardwareBlack.opacity(0.98)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.plasticHighlight.opacity(0.78), lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(Color.plasticHighlight.opacity(0.42)).frame(height: 1).padding(.horizontal, 14) }
        .accessibilityElement(children: .contain)
    }

    /// Shared console: transport plus pattern bank live in one LCD panel so every station
    /// starts from the same familiar hardware strip instead of stacked duplicate blocks.
    private var restoredConsole: some View {
        LCDPanel(title: "CONSOLE / \(store.project.name)") {
            VStack(spacing: 8) {
                consoleTransportRow
                Rectangle()
                    .fill(Color.screenShadow.opacity(0.30))
                    .frame(height: 1)
                consolePatternRow
            }
        }
    }

    private var consoleTransportRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Button { togglePlayback() } label: {
                    ZStack {
                        Circle()
                            .fill(store.isPlaying ? Color.arcadeRed : Color.gbDeep)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.gbInk, lineWidth: 2))
                        BeatPulseRing(active: store.isPlaying, phase: currentStep, color: .arcadeRed)
                            .frame(width: 58, height: 58)
                        Image(systemName: store.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color.gbLight)
                    }
                }
                .buttonStyle(ArcadePressStyle(scale: 0.9))
                .accessibilityLabel(store.isPlaying ? "Stop playback" : "Start playback")
                .accessibilityIdentifier("playStopButton")
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isPlaying ? "PLAYING" : "READY")
                        .font(.custom("Futura-Bold", size: 10))
                        .foregroundStyle(Color.gbInk)
                    Text("STEP \(String(format: "%02d", max(0, currentStep + 1))) / 16")
                        .font(.custom("Futura-Medium", size: 8))
                        .foregroundStyle(Color.gbInk.opacity(0.62))
                    if page == 3, currentSongSlot >= 0 {
                        Text("BAR \(String(format: "%02d", currentSongSlot + 1))")
                            .font(.custom("Futura-Bold", size: 8))
                            .foregroundStyle(Color.gbInk.opacity(0.68))
                            .accessibilityIdentifier("currentBarReadout")
                    }
                }
                Spacer(minLength: 2)
                RestoredTempoBox(value: store.project.tempo) { value in
                    store.updateTempo(value)
                    requestPlaybackRefresh()
                }
            }
            BeatStepRail(step: currentStep, active: store.isPlaying, accent: .amber)
        }
    }

    private var consolePatternRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("PATTERN BANK")
                    .font(.custom("Futura-Bold", size: 8))
                    .tracking(0.9)
                    .foregroundStyle(Color.gbInk)
                Text("\(store.project.patterns.count) / \(ByteProject.maximumPatternCount)")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbInk.opacity(0.62))
                Spacer(minLength: 2)
                Text("HOLD TO RENAME")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.screenShadow.opacity(0.85))
            }
            restoredPatternSelector
            HStack(spacing: 6) {
                RestoredActionButton(systemImage: "plus.square", label: "New pattern", disabled: store.project.patterns.count >= ByteProject.maximumPatternCount) { store.addPattern(); requestPlaybackRefresh() }
                RestoredActionButton(systemImage: "doc.on.doc", label: "Copy pattern", disabled: store.project.patterns.count >= ByteProject.maximumPatternCount) { store.duplicateCurrentPattern(); requestPlaybackRefresh() }
                RestoredActionButton(systemImage: "trash", label: "Delete pattern", destructive: true, disabled: store.project.patterns.count <= 1) {
                    guard store.project.patterns.count > 1 else { return }
                    patternIDToDelete = store.currentPatternID
                    showDeletePatternConfirmation = true
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var restoredPatternSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color.amber)
                Text(selectedPattern.name)
                    .font(.custom("Futura-Bold", size: 10))
                    .foregroundStyle(Color.gbLight)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("HOLD TO RENAME")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.mutedText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.project.patterns.enumerated()), id: \.element.id) { index, pattern in
                        Button {
                            requestPatternSelection(pattern.id)
                        } label: {
                            VStack(spacing: 2) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.custom("Futura-Bold", size: 8))
                                Text(pattern.name.replacingOccurrences(of: "PATTERN ", with: "P"))
                                    .font(.custom("Futura-Medium", size: 8))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .foregroundStyle(pattern.id == store.currentPatternID ? Color.gbInk : Color.gbLight)
                            .frame(width: 54, height: 42)
                            .background(restoredPatternColor(index: index, selected: pattern.id == store.currentPatternID))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(pattern.id == store.currentPatternID ? Color.gbLight : Color.plasticHighlight, lineWidth: pattern.id == store.currentPatternID ? 2 : 1))
                        }
                        .buttonStyle(ArcadePressStyle(scale: 0.94))
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in beginPatternRename(pattern) })
                    }
                }
                .padding(.vertical, 2)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { gesture in
                if patternDragStartIndex == nil { patternDragStartIndex = store.project.patterns.firstIndex(where: { $0.id == store.currentPatternID }) ?? 0 }
                let start = patternDragStartIndex ?? 0
                let offset = Int((-gesture.translation.height / 24).rounded())
                guard offset != 0, !store.project.patterns.isEmpty else { return }
                let target = restoredClamp(start + offset, 0, store.project.patterns.count - 1)
                if target != lastPatternDragIndex { lastPatternDragIndex = target; requestPatternSelection(store.project.patterns[target].id) }
            }.onEnded { _ in patternDragStartIndex = nil; lastPatternDragIndex = nil })
        }
        .padding(12)
        .background(Color.hardwareBlack.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.plasticHighlight.opacity(0.72), lineWidth: 1))
    }

    private func restoredPatternColor(index: Int, selected: Bool) -> Color {
        if selected { return Color.amber }
        return Color(hue: Double(index) / 16.0, saturation: 0.68, brightness: 0.72)
    }

    private var restoredVoicing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VOICING")
                .font(.custom("Futura-Bold", size: 8))
                .tracking(1)
                .foregroundStyle(Color.mutedText)
            HStack(spacing: 6) {
                RestoredChoiceBox(title: "KEY", value: restoredKeyNames[store.project.key], values: restoredKeyNames, index: store.project.key) { updateVoicing(key: $0) }
                RestoredChoiceBox(title: "MODE", value: store.project.mode.title, values: ByteScaleMode.allCases.map(\.title), index: ByteScaleMode.allCases.firstIndex(of: store.project.mode) ?? 0) { index in updateVoicing(mode: ByteScaleMode.allCases[index]) }
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.72), Color.hardwareBlack.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.plasticHighlight.opacity(0.55), lineWidth: 1))
    }

    private var restoredChannelTabs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EDIT CHANNEL")
                .font(.custom("Futura-Bold", size: 8))
                .tracking(1)
                .foregroundStyle(Color.mutedText)
            HStack(spacing: 4) {
                ForEach(ByteChannel.allCases) { channel in
                    Button { store.selectedChannel = channel; store.selectedStep = nil } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(store.selectedChannel == channel ? Color.gbInk : restoredChannelAccent(channel))
                                .frame(width: 7, height: 7)
                                .shadow(color: restoredChannelAccent(channel).opacity(0.75), radius: 3)
                            Text(channel.title)
                                .font(.custom("Futura-Bold", size: 8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .foregroundStyle(store.selectedChannel == channel ? Color.gbInk : Color.gbLight.opacity(0.82))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(store.selectedChannel == channel ? Color.amber : restoredChannelAccent(channel).opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(store.selectedChannel == channel ? Color.gbInk : Color.plasticHighlight, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.plasticRaised.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.plasticHighlight.opacity(0.55), lineWidth: 1))
    }

    private var restoredChannelMixer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHANNEL MIXER")
                        .font(.custom("Futura-Bold", size: 10))
                        .tracking(1.0)
                        .foregroundStyle(Color.gbLight)
                    Text("TAP TO EDIT  ·  SWIPE ↔ TO MIX")
                        .font(.custom("Futura-Medium", size: 8))
                        .foregroundStyle(Color.mutedText)
                }
                Spacer()
                Text("MASTER")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbGlow)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(ByteChannel.allCases) { channel in
                    RestoredChannelFader(channel: channel, accent: restoredChannelAccent(channel), volume: store.channelVolumePercent(channel), activity: store.channelActivityLevel(channel, step: currentStep, songSlot: page == 3 ? currentSongSlot : -1), selected: store.selectedChannel == channel, muted: store.isChannelMuted(channel), soloed: store.isChannelSoloed(channel), onSelect: { store.selectedChannel = channel; store.selectedStep = nil }, onChange: { value in store.setChannelVolume(channel: channel, percent: value); requestPlaybackRefresh() }, onToggleMute: { store.toggleChannelMute(channel); Haptics.toggle(); requestPlaybackRefresh() }, onToggleSolo: { store.toggleChannelSolo(channel); Haptics.toggle(); requestPlaybackRefresh() })
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.74), Color.hardwareBlack.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.plasticHighlight.opacity(0.68), lineWidth: 1))
    }

    /// Hint for the note grid. While a drag scrubs a value the readout replaces
    /// it, so the pitch stays legible while the finger is covering the pad.
    private var padEditorHint: String {
        if store.selectedChannel == .drum {
            return "TAP: HIT ON / OFF  •  DRAG ACROSS PADS: PAINT A RUN"
        }
        if linkSourceStep != nil {
            return "LINK ARMED  •  TAP A LATER PAD FOR THE NOTE END  •  TAP THIS PAD TO CANCEL"
        }
        return "TAP: ON / OFF  •  UP / DOWN: PITCH  •  ACROSS: PAINT  •  HOLD: LINK"
    }

    /// The drum row's four drag directions written out, because a voice pick with no legend
    /// is a direction the user has to guess at. Read from the model rather than spelled out
    /// here, so the legend cannot drift from what the gesture actually does.
    private var drumVoiceLegend: String {
        let up = ByteDrumVoice.voice(horizontal: 0, vertical: -1).title
        let down = ByteDrumVoice.voice(horizontal: 0, vertical: 1).title
        let left = ByteDrumVoice.voice(horizontal: -1, vertical: 0).title
        let right = ByteDrumVoice.voice(horizontal: 1, vertical: 0).title
        return "VOICE: ▲ \(up)  ▼ \(down)  ◀ \(left)  ▶ \(right)"
    }

    /// Reads one tap on the pad grid.
    ///
    /// A tap always toggles the pad it landed on, with exactly one exception: when a link is
    /// armed and the tap meets the pad that armed it, the tap disarms the mode instead —
    /// "tap the lit pad to get out", and pressing it cannot mean "delete this note". Tapping
    /// an *earlier* pad cannot complete a link either, so it cancels the mode and then behaves
    /// like the plain tap it looks like. That is what keeps a forgotten arm from silently
    /// swallowing the next few taps.
    private func resolveTap(on step: Int) {
        let channel = store.selectedChannel
        if let armed = armedLink, armed.channel == channel {
            armedLink = nil
            if step > armed.step {
                store.setNoteLength(channel: channel, step: armed.step, length: step - armed.step)
                store.presentToast("NOTE LINKED TO STEP \(step + 1)")
                return
            }
            store.presentToast("LINK CANCELLED")
            // The armed pad itself only cancels; any earlier pad cancels and then does what a
            // tap always does.
            if step == armed.step { return }
        }
        // Audition only when the tap places a note, so clearing a step
        // stays silent and the sound confirms what was just written.
        let placing = store.note(channel: channel, step: step) == nil
        toggleStepAndRefresh(channel: channel, step: step)
        if placing { auditionStep(step) }
    }

    private var restoredPadEditor: some View {
        LCDPanel(title: "\(store.selectedChannel.title) / 16 STEP LOOP", header: {
            RestoredDiceButton(label: "Randomize melody", compact: true, live: store.isPlaying) { randomizeMelody() }
        }) {
            VStack(spacing: 6) {
                RestoredNoteGrid(
                    channel: store.selectedChannel,
                    rootNote: store.selectedChannel.rootNote(for: store.project.key),
                    accent: restoredChannelAccent(store.selectedChannel),
                    currentStep: currentStep,
                    linkSourceStep: linkSourceStep,
                    note: { selectedChannelNotes[$0] },
                    length: { store.noteLength(channel: store.selectedChannel, step: $0) },
                    covered: { store.isStepCovered(channel: store.selectedChannel, step: $0) },
                    noteName: noteName,
                    drumName: drumName,
                    snap: { store.project.mode.quantize($0, key: store.project.key) },
                    onToggle: { step in resolveTap(on: step) },
                    onArmLink: { source in
                        guard store.selectedChannel != .drum else { return }
                        armedLink = PendingNoteLink(channel: store.selectedChannel, step: source)
                        store.presentToast("LINK ARMED / TAP A LATER PAD TO END THE NOTE")
                    },
                    onSetNote: { step, note in
                        store.setNote(channel: store.selectedChannel, step: step, note: note)
                        requestPlaybackRefresh()
                        audio.audition(channel: store.selectedChannel, note: note, project: store.project)
                    },
                    onSetDrum: { step, voice in
                        store.setDrumVoice(step: step, voice: voice)
                        requestPlaybackRefresh()
                        let index = min(ByteDrumVoice.allCases.count - 1, max(0, voice))
                        audio.audition(
                            channel: .drum,
                            note: ByteDrumVoice.note(voice: ByteDrumVoice.allCases[index]),
                            project: store.project
                        )
                    },
                    onScrub: { scrubReadout = $0 },
                    onSweepBegin: { step, painting, note in
                        store.beginStepSweep(
                            channel: store.selectedChannel,
                            step: step,
                            painting: painting,
                            note: note
                        )
                    },
                    onSweepExtend: { step in store.extendStepSweep(step: step) },
                    onSweepEnd: {
                        store.endStepSweep()
                        requestPlaybackRefresh()
                    }
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(scrubReadout ?? padEditorHint)
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(scrubReadout == nil ? Color.gbInk.opacity(0.62) : Color.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("padEditor.readout")
                    // The voice directions, shown only while they apply and only until a drag
                    // takes the line over for a live value.
                    if store.selectedChannel == .drum, scrubReadout == nil {
                        Text(drumVoiceLegend)
                            .font(.custom("Futura-Bold", size: 8))
                            .foregroundStyle(Color.gbInk.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // An armed link belongs to one step of one pattern. Switching rows already makes it
        // inert — this makes it gone, so the mode cannot reappear later on a pad the user has
        // stopped thinking about.
        .onChange(of: store.selectedChannel) { _, _ in armedLink = nil }
        .onChange(of: store.currentPatternID) { _, _ in armedLink = nil }
    }

    private var restoredSoundLab: some View {
        VStack(spacing: 10) {
            soundLabReadout
            if store.selectedChannel == .drum {
                RestoredDrumEditor(
                    accent: restoredChannelAccent(.drum),
                    patch: store.patch(for: .drum),
                    tempo: store.project.tempo,
                    drumHits: selectedPattern.drumHits,
                    volume: { store.drumVoiceVolumePercent($0) },
                    onSelectSample: { voice, variant in
                        store.setDrumSample(voice: voice, variant: variant)
                        requestPlaybackRefresh()
                    },
                    onVolumeChange: { voice, percent in
                        store.setDrumVoiceVolume(voice: voice, percent: percent)
                        requestPlaybackRefresh()
                    },
                    onAudition: { voice in
                        audio.audition(channel: .drum, note: ByteDrumVoice.note(voice: voice), project: store.project)
                    }
                )
            } else {
                LCDPanel(title: "\(store.selectedChannel.title) / SYNTH PATCH", header: {
            RestoredDiceButton(label: "Randomize sound", compact: true, live: store.isPlaying) { randomizeSound() }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 6) {
                            Text("TOUCH PARAMETERS")
                                .font(.custom("Futura-Bold", size: 8))
                                .foregroundStyle(Color.gbInk)
                            Text("SELECT + DRAG ↔")
                                .font(.custom("Futura-Bold", size: 8))
                                .foregroundStyle(Color.screenShadow)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {                            ForEach(restoredParameters(for: store.selectedChannel)) { parameter in
                                RestoredPatchCard(parameter: parameter, patch: store.patch(for: store.selectedChannel), selected: store.selectedPatchParameter[store.selectedChannel] == parameter) {
                                    store.selectedPatchParameter[store.selectedChannel] = parameter
                                } onChange: { value in
                                    store.setPatchValue(channel: store.selectedChannel, parameter: parameter, value: value)
                                    requestPlaybackRefresh()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var soundLabReadout: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(restoredChannelAccent(store.selectedChannel).opacity(0.18))
                    .frame(width: 52, height: 52)
                Circle()
                    .stroke(restoredChannelAccent(store.selectedChannel), lineWidth: 2)
                    .frame(width: 42, height: 42)
                Image(systemName: store.selectedChannel == .drum ? "waveform.path.ecg" : "waveform")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(restoredChannelAccent(store.selectedChannel))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.selectedChannel.title)
                    .font(.custom("Futura-Bold", size: 15))
                    .foregroundStyle(Color.gbLight)
                Text(store.selectedChannel == .drum ? "RHYTHM VOICES / SAMPLE + MIX" : "SYNTH PATCH / TOUCH TO SELECT")
                    .font(.custom("Futura-Medium", size: 8))
                    .foregroundStyle(Color.mutedText)
                Text("DRAG HORIZONTAL TO CHANGE THE SELECTED CONTROL")
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbGlow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .background(LinearGradient(colors: [Color.plasticRaised.opacity(0.88), Color.hardwareBlack.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(restoredChannelAccent(store.selectedChannel).opacity(0.72), lineWidth: 1))
    }

    private var fxStation: some View {
        LCDPanel(title: "FX STATION / HARDWARE-INSPIRED") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(store.isPlaying ? Color.gbGlow : Color.screenShadow.opacity(0.28))
                            .frame(width: 9, height: 9)
                            .shadow(color: store.isPlaying ? Color.gbGlow : .clear, radius: 5)
                        Circle()
                            .stroke(Color.gbInk.opacity(0.7), lineWidth: 1)
                            .frame(width: 13, height: 13)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isPlaying ? "EFFECT BUS LIVE" : "EFFECT BUS READY")
                            .font(.custom("Futura-Bold", size: 8))
                            .foregroundStyle(Color.gbInk)
                        Text("GLOBAL BUS / ECHO + BIT CRUSH")
                            .font(.custom("Futura-Medium", size: 8))
                            .foregroundStyle(Color.screenShadow)
                    }
                    Spacer()
                    Text("STEP \(String(format: "%02d", max(0, currentStep + 1)))")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.screenShadow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.screenShadow.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(store.isPlaying ? "Effect bus live" : "Effect bus ready")
                .accessibilityValue("Step \(max(0, currentStep + 1))")

                Text("EFFECT MODULES")
                    .font(.custom("Futura-Bold", size: 8))
                    .tracking(0.8)
                    .foregroundStyle(Color.gbInk.opacity(0.72))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(ByteEffect.allCases) { effect in
                        RestoredFXModule(
                            title: effect.title,
                            amount: store.effectAmount(effect),
                            accent: Color.gbGlow,
                            active: store.isPlaying,
                            phase: currentStep + (ByteEffect.allCases.firstIndex(of: effect) ?? 0),
                            flutterPattern: nil,
                            onPatternChange: nil
                        ) { amount in
                            store.setEffectAmount(effect, amount: amount)
                            requestPlaybackRefresh()
                        }
                    }
                }

                HStack(spacing: 7) {
                    Rectangle()
                        .fill(Color.screenShadow.opacity(0.42))
                        .frame(height: 1)
                    Text("SEND MATRIX")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.gbInk)
                    Rectangle()
                        .fill(Color.screenShadow.opacity(0.42))
                        .frame(height: 1)
                }
                HStack {
                    Text("CHANNEL ROUTING / DRY SIGNAL + FX RETURN")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.screenShadow)
                    Spacer()
                    Text("0% — 100%")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.screenShadow)
                }
                VStack(spacing: 6) {
                    ForEach(ByteChannel.allCases) { channel in
                        RestoredFXSendStrip(
                            title: channel.title,
                            amount: store.effectSendPercent(channel),
                            accent: restoredChannelAccent(channel),
                            muted: store.isChannelMuted(channel),
                            soloed: store.isChannelSoloed(channel),
                            active: store.isPlaying,
                            phase: currentStep + (ByteChannel.allCases.firstIndex(of: channel) ?? 0)
                        ) { amount in
                            store.setEffectSend(channel: channel, percent: amount)
                            requestPlaybackRefresh()
                        }
                    }
                }
            }
        }
    }

    private func restoredParameters(for channel: ByteChannel) -> [BytePatchParameter] {
        switch channel {
        // Every card here has to be a parameter the renderer reads for this channel. A card
        // that moves a field nothing reads is worse than a missing one: it looks like a control.
        case .pulseA, .pulseB: return [.duty, .octave, .octaveFlutterSpeed, .octaveFlutterPattern, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoCycleLength, .vibratoDepth, .vibratoDelay, .bendRange]
        // No `.waveFilter`: nothing in the engine renders it, so the card would filter nothing.
        case .wave: return [.waveShape, .waveEnvelope, .octave, .octaveFlutterSpeed, .octaveFlutterPattern, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoDepth, .bendRange]
        // Unreachable by design — the drum row renders the kit editor instead — and kept to the
        // parameters the sampler honours. The DMG envelope, tremolo and 4-bit volume all feed
        // the synthesized voices, which supplied one-shots bypass.
        case .drum: return [.panLeft, .panRight]
        }
    }

    private var restoredKeyNames: [String] { ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"] }
    private var songArrangementPageStart: Int { songArrangementPage * 16 }
    private var songArrangementPageEnd: Int { min(songArrangementPageStart + 16, store.songArrangementLength) }
    private var arrangementReadoutSlot: Int? {
        if currentSongSlot >= 0 { return currentSongSlot }
        if let scrubbedSongSlot, store.songSlot(at: scrubbedSongSlot).patternID != nil { return scrubbedSongSlot }
        return store.project.songArrangement.prefix(store.songArrangementLength).firstIndex(where: { $0.patternID == store.currentPatternID })
    }
    private var arrangementPageSelector: some View {
        HStack(spacing: 5) {
            Text("ARRANGEMENT PAGE")
                .font(.custom("Futura-Bold", size: 8))
                .foregroundStyle(Color.screenShadow)
            ForEach(0..<4, id: \.self) { pageIndex in
                let start = pageIndex * 16
                let end = start + 16
                Button {
                    songArrangementPage = pageIndex
                } label: {
                    VStack(spacing: 1) {
                        Text(["A", "B", "C", "D"][pageIndex])
                            .font(.custom("Futura-Bold", size: 9))
                        Text("\(start + 1)-\(end)")
                            .font(.custom("Futura-Bold", size: 8))
                    }
                    .foregroundStyle(songArrangementPage == pageIndex ? Color.gbInk : Color.screenShadow)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(songArrangementPage == pageIndex ? Color.amber : Color.screenShadow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.screenShadow.opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(start >= store.songArrangementLength)
                .opacity(start >= store.songArrangementLength ? 0.32 : 1)
                .accessibilityLabel("Arrangement page \(["A", "B", "C", "D"][pageIndex]), bars \(start + 1) through \(end)")
                .accessibilityAddTraits(songArrangementPage == pageIndex ? .isSelected : [])
            }
        }
    }
    private func restoredSongPattern(at index: Int) -> BytePattern? { guard let id = store.songSlot(at: index).patternID else { return nil }; return store.project.patterns.first(where: { $0.id == id }) }
    private func restoredSongColor(at index: Int) -> Color {
        guard let id = store.songSlot(at: index).patternID, let patternIndex = store.project.patterns.firstIndex(where: { $0.id == id }) else { return Color.gbLight.opacity(0.25) }
        return Color(hue: Double(patternIndex) / 16.0, saturation: 0.82, brightness: 0.95)
    }
    private func setSongArrangementLength(_ length: Int) {
        guard !store.isPlaying else { store.presentToast("STOP PLAYBACK TO CHANGE ARRANGEMENT LENGTH"); return }
        store.setSongArrangementLength(length)
        songArrangementPage = min(songArrangementPage, max(0, (length - 1) / 16))
        scrubbedSongSlot = nil
        currentSongSlot = -1
        requestPlaybackRefresh()
    }
    private func scrubSongTimeline(at x: CGFloat, width: CGFloat, commit: Bool = false) {
        guard width > 0 else { return }
        let index = min(max(Int((x / width * CGFloat(store.songArrangementLength)).rounded(.down)), 0), store.songArrangementLength - 1)
        songArrangementPage = index / 16
        scrubbedSongSlot = index
        guard store.songSlot(at: index).patternID != nil else {
            if commit { store.presentToast("BAR \(index + 1) IS EMPTY") }
            return
        }
        // Preview the selection while dragging, but perform only one transport change on
        // release. Repeatedly restarting the realtime engine during a gesture can race the
        // render callback; a committed scrub always begins the selected bar at step 1.
        if commit {
            if store.isPlaying {
                audio.seekSongSlot(index)
                currentSongSlot = index
            } else {
                startSongPlayback(at: index)
            }
        }
    }
    private func startSongPlayback(at slot: Int? = nil) {
        guard store.project.hasAssignedSongPattern else { store.presentToast("ASSIGN A PATTERN FIRST"); return }
        page = 3
        audioPage = 3
        store.isPlaying = true
        audio.play(project: store.project, patterns: store.songPlaybackPatterns, useSongArrangement: true, startSongSlot: slot) { step, songSlot in
            // The transport timer polls at 120 Hz but steps only change a few times
            // per beat — skip the main-actor hop when nothing moved.
            guard step != currentStep || songSlot != currentSongSlot else { return }
            Task { @MainActor in
                currentStep = step
                currentSongSlot = songSlot
                if songSlot >= 0 { songArrangementPage = min(3, songSlot / 16) }
                scrubbedSongSlot = songSlot >= 0 ? songSlot : scrubbedSongSlot
            }
        }
    }
    /// UI-test hook (launch argument gated, inert in normal use): builds a deterministic
    /// 3-bar song arrangement — bar 1 assigned, bar 2 an intentional gap, bar 3 assigned —
    /// so the loop-wrap regression test starts from a known state.
    private func configureSongLoopUITestIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--song-loop-ui-test") else { return }
        // Start from a fresh project: the simulator's persisted library is whatever
        // state the last manual session left behind, which is not deterministic.
        store.newProject()
        if store.project.patterns.count < 2 { _ = store.addPattern() }
        let patterns = store.project.patterns
        guard patterns.count >= 2 else { return }
        _ = store.assignSongPattern(at: 0, patternID: patterns[0].id)
        store.clearSongSlot(at: 1)
        _ = store.assignSongPattern(at: 2, patternID: patterns[1].id)
    }

    /// LOOP END marker for the arrangement timeline: a glow line at the edge of the
    /// last assigned bar (where playback wraps) plus a subtle dim over the dead zone
    /// beyond it, so the repeat length reads at a glance while editing.
    @ViewBuilder
    private func songLoopMarkers(width: CGFloat) -> some View {
        if store.project.hasAssignedSongPattern {
            let totalSlots = max(1, store.songArrangementLength)
            let loopBars = max(1, store.project.songSlotIndices.count)
            let loopEndX = width / CGFloat(totalSlots) * CGFloat(loopBars)
            let deadWidth = max(0, width - loopEndX)
            if deadWidth > 0.5 {
                Rectangle()
                    .fill(Color.hardwareBlack.opacity(0.55))
                    .frame(width: deadWidth)
                    .position(x: loopEndX + deadWidth / 2, y: 11)
                    .accessibilityHidden(true)
            }
            Capsule()
                .fill(Color.gbGlow)
                .frame(width: 2, height: 20)
                .position(x: min(width - 1, max(1, loopEndX)), y: 11)
                .shadow(color: Color.gbGlow.opacity(0.85), radius: 3)
                .accessibilityLabel("Loop ends after bar \(loopBars)")
        }
    }

    /// Amber playhead sweeping the arrangement timeline. Positions against the trimmed
    /// playback loop (songSlotIndices) rather than the full slot grid, so it rides the
    /// music even when trailing empty bars fall outside the loop.
    private func songPlayhead(width: CGFloat) -> some View {
        let totalBars = max(1, store.project.songSlotIndices.count)
        let clampedStep = max(0, min(15, currentStep))
        let stepProgress = CGFloat(clampedStep) / 16.0
        let rawX = width * (CGFloat(currentSongSlot) + stepProgress + 0.5) / CGFloat(totalBars)
        let playheadX = min(width - 2, max(2, rawX))
        return Capsule()
            .fill(Color.amber)
            .frame(width: 3, height: 27)
            .position(x: playheadX, y: 11)
            .shadow(color: Color.amber.opacity(0.95), radius: 6)
            .beatGlow(active: true, phase: currentStep, color: .amber)
            .animation(.linear(duration: 0.08), value: currentStep)
            .animation(.easeOut(duration: 0.12), value: currentSongSlot)
            .accessibilityHidden(true)
    }
    private func restoredClamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }
    private func restoredChannelAccent(_ channel: ByteChannel) -> Color {
        switch channel {
        case .pulseA: return .pulseAccent
        case .pulseB: return .squareAccent
        case .wave: return .triangleAccent
        case .drum: return .drumAccent
        }
    }
    private func noteName(_ midi: Int) -> String { let names = restoredKeyNames; return "\(names[(midi % 12 + 12) % 12])\(midi / 12 - 1)" }
    private func drumName(_ midi: Int) -> String { ByteDrumVoice.label(for: midi) }
    private func updateVoicing(key: Int? = nil, mode: ByteScaleMode? = nil) { store.updateVoicing(key: key, mode: mode); requestPlaybackRefresh() }
    private func toggleStepAndRefresh(channel: ByteChannel, step: Int) { store.toggleStep(channel: channel, step: step); requestPlaybackRefresh() }

    /// Plays one step through the audio engine. This is what makes the pad grid usable by
    /// ear: the pitch under the finger is heard rather than read off a note name.
    private func auditionStep(_ step: Int) {
        guard let note = store.note(channel: store.selectedChannel, step: step) else { return }
        audio.audition(channel: store.selectedChannel, note: note, project: store.project)
    }
    private func randomizeMelody() { guard store.randomizeSelectedMelody() else { store.presentToast("SELECT A MELODIC CHANNEL"); return }; requestPlaybackRefresh() }
    private func randomizeSound() { guard store.randomizeSelectedPatch() else { store.presentToast("SELECT A MELODIC CHANNEL"); return }; requestPlaybackRefresh() }

    private func requestPatternSelection(_ id: UUID) {
        Haptics.selection()
        guard id != store.currentPatternID else { return }
        if store.isPlaying { pendingPatternID = id; store.presentToast("PATTERN SWITCH QUEUED / END OF LOOP") }
        else { store.selectPattern(id); requestPlaybackRefresh() }
    }
    private func beginPatternRename(_ pattern: BytePattern) { patternRenameID = pattern.id; patternRenameText = pattern.name; showPatternRename = true }
    private func setPage(_ newPage: Int) {
        guard (0...3).contains(newPage), newPage != page else { return }
        hasNavigatedThisLaunch = true
        if store.isPlaying {
            // Change the visible page immediately so every station remains navigable live.
            // The audio source still changes only at the next 16-step boundary so a live
            // bar is never cut short.
            page = newPage
            pendingPage = newPage
            if newPage != 3 { currentSongSlot = -1 }
            store.presentToast("PAGE SWITCH QUEUED / END OF LOOP")
        } else {
            applyPageNow(newPage)
        }
    }
    private func applyPageNow(_ newPage: Int) {
        page = newPage
        audioPage = newPage
        if store.isPlaying { audio.update(project: store.project, patterns: newPage == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: newPage == 3) }
        if newPage != 3 { currentSongSlot = -1 }
    }
    private func requestPlaybackRefresh() {
        guard store.isPlaying else { return }
        audio.update(project: store.project, patterns: audioPage == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: audioPage == 3)
    }

    /// Two-finger drag in flight: cumulative translation since gesture start.
    private func twoFingerDragChanged(_ dy: CGFloat) {
        guard let scrollProxy = twoFingerScrollProxy else { return }
        let overflow = editorScrollMetrics.contentHeight - editorViewportHeight
        guard overflow > 8 else { return }
        let last = twoFingerLastDy ?? 0
        let delta = dy - last
        twoFingerLastDy = dy
        let next = min(1, max(0, scrollFraction + delta / max(1, overflow)))
        seekScroll(proxy: scrollProxy, fraction: next)
    }

    /// Two-finger drag released: flick velocity drives the capped glide.
    private func twoFingerDragEnded(_ velocityY: CGFloat) {
        guard let scrollProxy = twoFingerScrollProxy else { return }
        twoFingerLastDy = nil
        let overflow = editorScrollMetrics.contentHeight - editorViewportHeight
        guard overflow > 8, abs(velocityY) > 150 else { return }
        // Same glide model as the logo flick: capped at ~0.7 viewport heights
        // so a hard two-finger flick covers about one screen.
        let glide = (velocityY > 0 ? 1.0 : -1.0) * min(0.7, abs(velocityY) / 1000 * 0.85)
        let target = min(1, max(0, scrollFraction + glide * editorViewportHeight / max(1, overflow)))
        seekScroll(proxy: scrollProxy, fraction: target, animate: true)
    }

    /// DEBUG-only: simulates a two-finger swipe through the exact callbacks the
    /// recognizer invokes, so UI tests can exercise the pipeline even though
    /// this XCTest SDK cannot synthesize multi-touch drags.
    private func simulateTwoFingerSwipeForTesting() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            twoFingerLastDy = 0
            for step in 1...12 {
                twoFingerDragChanged(CGFloat(step) * 10)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            // Moderate flick: fires the glide without bottoming out the short
            // page, so UI tests can discriminate drag vs. glide contributions.
            twoFingerDragEnded(400)
        }
    }

    /// Current scroll position as a 0...1 fraction (0 = top of page, 1 = bottom).
    private var scrollFraction: CGFloat {
        let overflow = max(0, editorScrollMetrics.contentHeight - editorViewportHeight)
        guard overflow > 8 else { return 0 }
        return min(1, max(0, -editorScrollMetrics.contentMinY / overflow))
    }

    /// Jumps the page scroll to the given 0...1 fraction using the hidden markers.
    /// Each marker owns a real layout slice of height total/561 (~1pt), so its
    /// center sits at (index + 0.5) * total/561 and centering it yields the
    /// requested scroll offset. Sub-pixel marker spacing (~1pt) plus unanimated
    /// per-event seeks keep finger tracking visually continuous: animating each
    /// event restarts a clock and reads as stutter, while unanimated seeks move
    /// the page exactly as fast as the finger (the flick glide animates its own
    /// ease-out).
    private func seekScroll(proxy: ScrollViewProxy, fraction: CGFloat, animate: Bool = false) {
        let total = max(1, editorScrollMetrics.contentHeight)
        let viewport = max(0, editorViewportHeight)
        let overflow = max(0, total - viewport)
        guard overflow > 8 else { return }
        // Desired scroll offset = fraction * overflow; solve for the marker whose
        // center, placed at the viewport center, produces that offset.
        let desiredCenter = fraction * overflow + viewport * 0.5
        let index = min(560, max(0, Int((desiredCenter * 561.0 / total - 0.5).rounded())))
        if animate {
            withAnimation(.easeOut(duration: 0.55)) {
                proxy.scrollTo("beatboi-scroll-marker-\(index)", anchor: UnitPoint(x: 0.5, y: 0.5))
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("beatboi-scroll-marker-\(index)", anchor: UnitPoint(x: 0.5, y: 0.5))
            }
        }
    }
    private func togglePlayback() {
        playbackRefreshTask?.cancel()
        if store.isPlaying { pendingPatternID = nil; pendingPage = nil; store.stopPlayback(); audio.stop(); return }
        audioPage = page
        store.isPlaying = true
        audio.play(project: store.project, patterns: page == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: page == 3, startSongSlot: page == 3 ? scrubbedSongSlot : nil) { step, slot in
            // The transport timer polls at 120 Hz but steps only change a few times
            // per beat — skip the main-actor hop when nothing moved.
            guard step != currentStep || slot != currentSongSlot else { return }
            Task { @MainActor in
                if step == 0 && currentStep == 15 {
                    if let pendingPatternID { store.selectPattern(pendingPatternID); self.pendingPatternID = nil }
                    if let pendingPage { self.pendingPage = nil; applyPageNow(pendingPage) }
                    requestPlaybackRefresh()
                }
                currentStep = step
                currentSongSlot = slot
                if page == 3, slot >= 0 { songArrangementPage = min(3, slot / 16) }
            }
        }
    }
    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let data = try? Data(contentsOf: url) else { store.presentToast("IMPORT FAILED"); return }
        if url.pathExtension.lowercased() == "mid", let imported = ByteMIDI.importIntoProject(data, project: store.project) { store.importProject(imported); store.presentToast("MIDI IMPORTED · UNDO AVAILABLE") }
        else if let imported = try? JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data) { store.importProject(imported); store.presentToast("PROJECT OPENED · UNDO AVAILABLE") }
        else { store.presentToast("UNKNOWN FILE") }
    }
}

private struct EditorScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var contentMinY: CGFloat = 0
}

private struct EditorScrollMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = EditorScrollMetrics()

    static func reduce(value: inout EditorScrollMetrics, nextValue: () -> EditorScrollMetrics) {
        value = nextValue()
    }
}

/// Bridges a two-finger-only pan recognizer onto the editor's backing
/// UIScrollView so a two-finger drag anywhere on the page scrolls it — without
/// disturbing any one-finger behavior (native scroll, pads, knobs, faders).
///
/// Exclusivity: the scroll view's built-in pan REQUIRES the bridge to fail
/// before it can begin, so one-finger gestures reach the scroll view untouched,
/// while a two-finger drag can never also drive the native pan (no double
/// movement). The bridge's fail-fast subclass (see below) guarantees that
/// requirement resolves instantly for one-finger gestures — the recognizer
/// never lingers in "possible" — so the handshake can never wedge either
/// direction of the pair.
///
/// Drag semantics match a scrollbar (fingers move down -> page moves down),
/// mirroring the logo drag. Release velocity feeds the same capped glide used
/// by the logo flick.
private struct TwoFingerScrollBridge: UIViewRepresentable {
    var onStart: () -> Void
    var onChanged: (_ dy: CGFloat) -> Void
    var onEnd: (_ velocityY: CGFloat) -> Void

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnd = onEnd
        context.coordinator.onStart = onStart
        context.coordinator.installIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onStart, onChanged, onEnd) }

    final class BridgeView: UIView {}

    /// Pan recognizer that refuses to start unless two touches are actively
    /// driving it, and — critically — FAILS IMMEDIATELY (while still
    /// "possible") when fewer than two fingers move. Fail-fast is what keeps
    /// the `require(toFail:)` handshake with the native pan wedge-free: a
    /// one-finger drag dismisses this recognizer instantly instead of leaving
    /// it stuck in "possible" until touch-end, which is what made the second
    /// two-finger swipe stop working. After the recognizer has begun (a real
    /// two-finger drag), lifting fingers runs the normal ended path so the
    /// flick glide still fires.
    private final class TwoFingerPanGestureRecognizer: UIPanGestureRecognizer {
        // Note: UIGestureRecognizer's touch overrides take a NON-optional
        // UIEvent (unlike UIResponder's).
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            failIfUndercommitted(event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            failIfUndercommitted(event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            failIfUndercommitted(event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            failIfUndercommitted(event)
        }

        private func failIfUndercommitted(_ event: UIEvent) {
            guard state == .possible else { return }
            let active = event.allTouches?.filter {
                $0.phase != .ended && $0.phase != .cancelled
            }.count ?? 0
            if active < 2 { state = .failed }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: BridgeView?
        var onStart: () -> Void
        var onChanged: (_ dy: CGFloat) -> Void
        var onEnd: (_ velocityY: CGFloat) -> Void
        private var installed = false

        init(_ onStart: @escaping () -> Void,
             _ onChanged: @escaping (_ dy: CGFloat) -> Void,
             _ onEnd: @escaping (_ velocityY: CGFloat) -> Void) {
            self.onStart = onStart
            self.onChanged = onChanged
            self.onEnd = onEnd
        }

        /// The bridge view may not be in a window yet on the first
        /// updateUIView; retry until it lands under a UIScrollView.
        func installIfNeeded() {
            guard !installed, let view, view.window != nil else { return }
            var current: UIView? = view
            while let node = current {
                if let scrollView = node as? UIScrollView {
                    let pan = TwoFingerPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                    pan.delegate = self
                    scrollView.addGestureRecognizer(pan)
                    // Make the native one-finger pan wait for this recognizer to
                    // fail before it may begin: two-finger drags are claimed
                    // exclusively by the bridge, one-finger behavior is unchanged.
                    scrollView.panGestureRecognizer.require(toFail: pan)
                    installed = true
                    return
                }
                current = node.superview
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                onStart()
            case .changed:
                onChanged(gesture.translation(in: gesture.view).y)
            case .ended:
                onEnd(gesture.velocity(in: gesture.view).y)
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    }
}

private struct EditorScrollBar: View {
    let metrics: EditorScrollMetrics

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = proxy.size.height
            let overflow = max(0, metrics.contentHeight - viewportHeight)
            let isScrollable = overflow > 8
            let trackHeight = max(1, viewportHeight - 8)
            let thumbHeight = max(28, trackHeight * viewportHeight / max(viewportHeight, metrics.contentHeight))
            let scrollOffset = min(overflow, max(0, -metrics.contentMinY))
            let travel = max(0, trackHeight - thumbHeight)
            let progress = overflow > 0 ? scrollOffset / overflow : 0
            let thumbOffset = travel * progress

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.gbLight.opacity(isScrollable ? 0.16 : 0))
                    .frame(width: 3, height: trackHeight)
                    .padding(.top, 4)
                Capsule()
                    .fill(Color.amber.opacity(isScrollable ? 0.9 : 0))
                    .frame(width: 5, height: thumbHeight)
                    .offset(y: 4 + thumbOffset)
                    .shadow(color: Color.amber.opacity(isScrollable ? 0.42 : 0), radius: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.1), value: metrics.contentMinY)
            .accessibilityHidden(true)
        }
        .frame(width: 9)
    }
}

private struct RestoredHeaderIcon: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color.gbLight)
                .frame(width: 44, height: 44)
                .background(Color.plasticRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.plasticHighlight, lineWidth: 1))
        }
        .buttonStyle(ArcadePressStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Tap to open")
    }
}

private struct RestoredHistoryButton: View {
    let systemImage: String
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(disabled ? Color.mutedText.opacity(0.42) : Color.gbLight)
                .frame(width: 30, height: 30)
                .background(disabled ? Color.hardwareBlack.opacity(0.34) : Color.plasticRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.plasticHighlight.opacity(disabled ? 0.28 : 0.8), lineWidth: 1))
        }
        .buttonStyle(ArcadePressStyle(scale: 0.88))
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityHint(disabled ? "Unavailable" : "Tap to apply")
    }
}

private struct RestoredPageButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.custom("Futura-Bold", size: 8))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(selected ? Color.gbInk : Color.gbLight.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(selected ? Color.amber : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Color.gbInk : Color.plasticHighlight.opacity(0.45), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(ArcadePressStyle())
    }
}

private struct DiceRollValue {
    var rotation: Double = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1
}

private struct RestoredDiceButton: View {
    let label: String
    var compact = false
    var live = false
    let action: () -> Void
    @State private var rollTrigger = 0

    var body: some View {
        Button(action: {
            rollTrigger += 1
            action()
        }) {
            Image(systemName: "dice.fill")
                .font(.system(size: compact ? 13 : 20, weight: .black))
                .foregroundStyle(Color.gbInk)
                .frame(width: compact ? 34 : 52, height: compact ? 30 : 48)
                .background(LinearGradient(colors: [Color.amber, Color.linkedOrange.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 12))
                .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 12).stroke(Color.gbInk, lineWidth: compact ? 1.5 : 2))
                // Soft green halo while a channel is playing so the randomizer
                // reads as live without competing with the amber die.
                .shadow(color: live ? Color.gbGlow.opacity(0.55) : .clear, radius: live ? 6 : 0)
                // Quick physical shake-and-roll: the die rattles left/right, hops
                // up, and settles with a bounce every time it's tapped.
                .keyframeAnimator(initialValue: DiceRollValue(), trigger: rollTrigger) { content, value in
                    content
                        .rotationEffect(.degrees(value.rotation))
                        .offset(y: value.offsetY)
                        .scaleEffect(value.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-16, duration: 0.05)
                        CubicKeyframe(13, duration: 0.07)
                        CubicKeyframe(-10, duration: 0.07)
                        CubicKeyframe(8, duration: 0.07)
                        CubicKeyframe(0, duration: 0.06)
                    }
                    KeyframeTrack(\.offsetY) {
                        CubicKeyframe(-4, duration: 0.10)
                        CubicKeyframe(0, duration: 0.10)
                        CubicKeyframe(-2, duration: 0.06)
                        CubicKeyframe(0, duration: 0.06)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.14, duration: 0.07)
                        CubicKeyframe(0.94, duration: 0.09)
                        CubicKeyframe(1.0, duration: 0.16)
                    }
                }
        }
        .buttonStyle(ArcadePressStyle(scale: 0.88))
        .accessibilityLabel(label)
    }
}

private struct RestoredActionButton: View {
    let systemImage: String
    let label: String
    var destructive = false
    var disabled = false
    let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: systemImage).font(.system(size: 15, weight: .black)).foregroundStyle(disabled ? Color.mutedText.opacity(0.45) : (destructive ? Color.linkedOrange : Color.gbLight)).frame(width: 44, height: 44).background(Color.plasticRaised).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.plasticHighlight, lineWidth: 1)) }.buttonStyle(ArcadePressStyle(scale: 0.88)).disabled(disabled).accessibilityLabel(label) }
}

private struct RestoredTempoBox: View {
    let value: Int
    let onChange: (Int) -> Void
    @State private var start: Int?
    @State private var last: Int?
    var body: some View { VStack(spacing: 1) { Text("BPM").font(.custom("Futura-Bold", size: 8)); Text("\(value)").font(.custom("Futura-Bold", size: 14)) }.foregroundStyle(Color.gbInk).frame(width: 66, height: 46).background(Color.amber).overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2)).gesture(DragGesture(minimumDistance: 10).onChanged { gesture in if start == nil { start = value }; let proposed = restoredBound((start ?? value) + Int((gesture.translation.width / 8).rounded()) + Int((-gesture.translation.height / 8).rounded()), 60, 240); if proposed != last { last = proposed; onChange(proposed) } }.onEnded { _ in start = nil; last = nil }) }
    private func restoredBound(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }
}

private struct RestoredChoiceBox: View {
    let title: String
    let value: String
    let values: [String]
    let index: Int
    let onSelect: (Int) -> Void
    @State private var start: Int?
    @State private var last: Int?
    var body: some View { HStack(spacing: 4) { VStack(alignment: .leading, spacing: 1) { Text(title).font(.custom("Futura-Bold", size: 8)); Text(value).font(.custom("Futura-Bold", size: 9)).lineLimit(1) }; Spacer(); Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .black)) }.foregroundStyle(Color.gbInk).padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 44).background(title == "KEY" ? Color.amber : Color.gbGlow).overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2)).gesture(DragGesture(minimumDistance: 0).onChanged { gesture in if start == nil { start = index }; guard !values.isEmpty else { return }; let offset = Int((gesture.translation.width / 20).rounded()); let selected = min(max((start ?? index) + offset, 0), values.count - 1); if selected != last { last = selected; onSelect(selected) } }.onEnded { _ in start = nil; last = nil }) }
}

private struct RestoredChannelFader: View {
    let channel: ByteChannel
    let accent: Color
    let volume: Int
    let activity: Int
    let selected: Bool
    let muted: Bool
    let soloed: Bool
    let onSelect: () -> Void
    let onChange: (Int) -> Void
    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    @State private var start: Int?
    @State private var last: Int?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: selected ? [Color.amber, Color.linkedOrange.opacity(0.72)] : [accent.opacity(0.86), accent.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                accent.opacity(selected ? 0.64 : 0.28)
                    .frame(width: proxy.size.width * CGFloat(volume) / 100.0)
                    .animation(.easeOut(duration: 0.12), value: volume)
                HStack(spacing: 4) {
                    Circle()
                        .fill(selected ? Color.gbInk : Color.screenShadow)
                        .frame(width: 5, height: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.title)
                            .font(.custom("Futura-Bold", size: 9))
                            .opacity(muted ? 0.46 : 1)
                        RestoredActivityMeter(level: activity, accent: accent, active: activity > 0)
                            .frame(height: 5)
                    }
                    Spacer(minLength: 2)
                    RestoredMiniMixerButton(title: "M", active: muted, accent: Color.arcadeRed, action: onToggleMute)
                    RestoredMiniMixerButton(title: "S", active: soloed, accent: Color.amber, action: onToggleSolo)
                    Text("\(volume)%")
                        .font(.custom("Futura-Bold", size: 8))
                }
                .foregroundStyle(Color.gbInk)
                .padding(.horizontal, 4)
            }
            .overlay(Rectangle().stroke(selected ? Color.gbLight : Color.gbInk, lineWidth: selected ? 2 : 1.5))
            .shadow(color: selected ? Color.amber.opacity(0.34) : .clear, radius: selected ? 7 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 7)
                    .onChanged { gesture in
                        if start == nil {
                            start = volume
                            onSelect()
                        }
                        let base = start ?? volume
                        let delta = Int((gesture.translation.width / max(1, proxy.size.width) * 100).rounded())
                        let proposed = min(100, max(0, base + delta))
                        if proposed != last {
                            last = proposed
                            onChange(proposed)
                        }
                    }
                    .onEnded { _ in
                        start = nil
                        last = nil
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("channelFader.\(channel.rawValue)")
            .accessibilityLabel("\(channel.title) channel")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Tap the channel to edit. Swipe left or right to change volume. Use M to mute or S to solo.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(min(100, volume + 5))
                case .decrement: onChange(max(0, volume - 5))
                @unknown default: break
                }
            }
        }
        .frame(minHeight: 72)
    }

    private var accessibilityValue: String {
        var parts = ["\(volume) percent", "activity \(activity) percent"]
        if muted { parts.append("muted") }
        if soloed { parts.append("soloed") }
        return parts.joined(separator: ", ")
    }
}

private struct RestoredActivityMeter: View {
    let level: Int
    let accent: Color
    let active: Bool
    @State private var peak: Int = 0
    @State private var peakSetAt: TimeInterval = 0

    var body: some View {
        Group {
            if active {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate - peakSetAt
                    let heldPeak = max(level, peak - Int(elapsed * 26))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            HStack(spacing: 2) {
                                ForEach(0..<8, id: \.self) { index in
                                    let threshold = CGFloat(index + 1) / 8.0
                                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                                        .fill(CGFloat(level) / 100.0 >= threshold ? accent : Color.gbInk.opacity(0.18))
                                        .frame(maxWidth: .infinity)
                                        .shadow(color: CGFloat(level) / 100.0 >= threshold ? accent.opacity(0.55) : .clear, radius: 2)
                                }
                            }
                            if heldPeak > level {
                                Capsule()
                                    .fill(accent)
                                    .frame(width: 2, height: 5)
                                    .position(x: min(proxy.size.width - 2, max(2, proxy.size.width * CGFloat(heldPeak) / 100.0)), y: proxy.size.height / 2)
                                    .shadow(color: accent.opacity(0.9), radius: 2)
                            }
                        }
                    }
                }
                .onChange(of: level) { _, newValue in
                    if newValue > peak {
                        peak = newValue
                        peakSetAt = Date().timeIntervalSinceReferenceDate
                    }
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { index in
                        let threshold = CGFloat(index + 1) / 8.0
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(CGFloat(level) / 100.0 >= threshold ? accent : Color.gbInk.opacity(0.18))
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .onChange(of: active) { _, newValue in
            if !newValue { peak = 0; peakSetAt = 0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Channel activity")
        .accessibilityValue("\(level) percent")
    }
}

private struct RestoredMiniMixerButton: View {
    let title: String
    let active: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Futura-Bold", size: 8))
                .foregroundStyle(active ? Color.gbInk : Color.gbInk.opacity(0.58))
                .frame(width: 30, height: 30)
                .background(active ? accent : Color.gbLight.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gbInk.opacity(active ? 0.9 : 0.34), lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(ArcadePressStyle(scale: 0.88))
        .accessibilityLabel(title == "M" ? "Mute channel" : "Solo channel")
        .accessibilityValue(active ? "On" : "Off")
    }
}

private struct SongTimelineTick: View {
    let index: Int
    let current: Bool
    var color: Color = Color.plasticHighlight.opacity(0.55)
    var showLabel = true

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(current ? color : color.opacity(index % 4 == 0 ? 0.75 : 0.38))
                .frame(maxWidth: .infinity)
                .frame(height: current ? 10 : 6)
            if showLabel {
                Text(String(index + 1))
                    .font(.custom("Futura-Bold", size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Color.mutedText)
            }
        }
    }
}

private struct RestoredSongPad: View {
    let index: Int
    let slot: ByteSongSlot
    let pattern: BytePattern?
    let color: Color
    let current: Bool
    let onTap: () -> Void
    let onCycle: (Int) -> Void
    @State private var lastY: CGFloat = 0
    @State private var suppressTap = Date.distantPast

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 3) {
                HStack {
                    Text(String(format: "%02d", index + 1))
                        .font(.custom("Futura-Bold", size: 9))
                    Spacer()
                    Circle()
                        .fill(current ? Color.gbLight : Color.gbInk.opacity(0.22))
                        .frame(width: 6, height: 6)
                }
                Text(pattern?.name.replacingOccurrences(of: "PATTERN ", with: "P") ?? "EMPTY")
                    .font(.custom("Futura-Bold", size: 8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(pattern == nil ? "TAP TO ASSIGN" : "16 STEP BAR")
                    .font(.custom("Futura-Bold", size: 8))
            }
            .foregroundStyle(Color.gbInk)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: pattern == nil ? [Color.gbDeep.opacity(0.3), Color.gbDeep.opacity(0.16)] : [color, color.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(current ? Color.gbLight : pattern == nil ? Color.plasticHighlight.opacity(0.55) : Color.gbInk.opacity(0.45), lineWidth: current ? 3 : 1.5))
            .contentShape(Rectangle())
            .onTapGesture { if Date() >= suppressTap { onTap() } }
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { gesture in
                let move = gesture.translation.height - lastY
                if abs(move) >= 14 {
                    suppressTap = Date().addingTimeInterval(0.45)
                    onCycle(move < 0 ? 1 : -1)
                    lastY = gesture.translation.height
                }
            }.onEnded { _ in suppressTap = Date().addingTimeInterval(0.45); lastY = 0 })
        }
        .frame(height: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Song bar \\(index + 1)")
        .accessibilityValue(pattern?.name ?? "Empty")
        .accessibilityHint("Tap to assign or clear. Swipe up or down to change pattern.")
        .accessibilityAction { onTap() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            // Up in the drag is the next pattern, so increment means the same here: VoiceOver's
            // swipe-up is the adjustable increment, and the two gestures keep one meaning.
            case .increment: onCycle(1)
            case .decrement: onCycle(-1)
            @unknown default: break
            }
        }
    }
}

private struct LiveAmbientField: View {
    let active: Bool
    let phase: Int
    let accent: Color
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [accent.opacity(active ? (pulse ? 0.16 : 0.07) : 0.025), .clear],
                    center: .center,
                    startRadius: 20,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
                RadialGradient(
                    colors: [Color.amber.opacity(active ? (pulse ? 0.07 : 0.025) : 0.012), .clear],
                    center: .topTrailing,
                    startRadius: 5,
                    endRadius: 240
                )
            }
            .animation(.easeOut(duration: 0.24), value: pulse)
            .onChange(of: phase) { _, _ in
                guard active else { return }
                pulse = false
                withAnimation(.easeOut(duration: 0.24)) { pulse = true }
            }
            .onChange(of: active) { _, isActive in
                guard isActive else { pulse = false; return }
                pulse = false
                withAnimation(.easeOut(duration: 0.24)) { pulse = true }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 0.24)) { pulse = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

private struct MiniBeatIndicator: View {
    let step: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { beat in
                Capsule()
                    .fill(active && beat == max(0, step) % 4 ? Color.amber : Color.mutedText.opacity(0.34))
                    .frame(maxWidth: .infinity)
                    .frame(height: active && beat == max(0, step) % 4 ? 9 : 5)
                    .shadow(color: active && beat == max(0, step) % 4 ? Color.amber.opacity(0.8) : .clear, radius: 3)
                    .animation(.easeOut(duration: 0.08), value: step)
            }
        }
        .frame(height: 10)
    }
}

/// Soft amber glow that swells on each beat (phase change) while active.
/// Used by the song playhead and the active step pads so the instrument
/// visibly breathes with the sequencer clock.
private struct BeatPulseRing: View {
    let active: Bool
    let phase: Int
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(active && !expanded ? 0.78 : 0), lineWidth: 2)
            .scaleEffect(expanded ? 1.0 : 0.74)
            .animation(.easeOut(duration: 0.28), value: expanded)
            .onChange(of: phase) { _, _ in
                guard active else { return }
                expanded = false
                withAnimation(.easeOut(duration: 0.28)) { expanded = true }
            }
            .onChange(of: active) { _, isActive in
                guard isActive else { expanded = false; return }
                expanded = false
                withAnimation(.easeOut(duration: 0.28)) { expanded = true }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 0.28)) { expanded = true }
            }
            .accessibilityHidden(true)
    }
}

private struct BeatStepRail: View {
    let step: Int
    let active: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<BytePattern.barSteps, id: \.self) { index in
                let isCurrent = active && index == step
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isCurrent ? accent : index % 4 == 0 ? Color.screenShadow.opacity(0.62) : Color.screenShadow.opacity(0.25))
                    .frame(maxWidth: .infinity)
                    .frame(height: isCurrent ? 9 : index % 4 == 0 ? 6 : 4)
                    .shadow(color: isCurrent ? accent.opacity(0.8) : .clear, radius: 4)
                    .animation(.easeOut(duration: 0.08), value: step)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct BeatGlow: ViewModifier {
    let active: Bool
    let phase: Int
    var color: Color = .amber
    @State private var intensity: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .shadow(color: active ? color.opacity(0.18 + intensity * 0.85) : .clear, radius: 8)
            .onChange(of: phase) { _, _ in
                guard active else { return }
                pulse()
            }
            .onAppear {
                guard active else { return }
                pulse()
            }
    }

    private func pulse() {
        intensity = 0
        withAnimation(.easeOut(duration: 0.07)) { intensity = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            withAnimation(.easeIn(duration: 0.16)) { intensity = 0 }
        }
    }
}

private extension View {
    func beatGlow(active: Bool, phase: Int, color: Color = .amber) -> some View {
        modifier(BeatGlow(active: active, phase: phase, color: color))
    }
}

/// One step of the 16-step grid. Presentation only.
///
/// The gesture that edits a pad lives on the grid as a whole, in
/// `RestoredNoteGrid`, because a drag has to be able to travel from the pad it
/// started on to its neighbours — and a gesture attached to a pad keeps receiving
/// the touch after the finger has left that pad.
/// The value a drag is setting, drawn on the pad under the finger so a pitch or voice can be
/// read while it is being chosen instead of from a hint line across the panel.
private struct PadLiveReadout: Equatable {
    let value: String
    let detail: String
}

private struct RestoredNotePad: View {
    let step: Int
    let note: Int?
    let length: Int
    let covered: Bool
    let channel: ByteChannel
    let accent: Color
    let current: Bool
    let phase: Int
    let linkSource: Bool
    let linkArmed: Bool
    let noteName: (Int) -> String
    let drumName: (Int) -> String
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void
    /// Set while a drag is editing this pad, nil otherwise.
    let live: PadLiveReadout?

    private var padColor: Color {
        guard channel == .drum, let note else {
            return note == nil ? Color.gbDeep.opacity(0.16) : Color.amber
        }
        return ByteDrumVoice.voice(for: note).padColor
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: "%02d", step + 1)).font(.custom("Futura-Bold", size: 9))
            Text(note.map(channel == .drum ? drumName : noteName) ?? "—").font(.custom("Futura-Bold", size: 10))
            if linkSource { Text("LINK ARMED").font(.custom("Futura-Bold", size: 8)) }
            else if linkArmed { Text("TAP TO LINK").font(.custom("Futura-Bold", size: 8)) }
            else if note != nil && length > 1 { Text("HOLD \(length)").font(.custom("Futura-Bold", size: 8)) }
        }
        .foregroundStyle(Color.gbInk)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(
            LinearGradient(
                colors: channel == .drum
                    ? [padColor.opacity(0.96), padColor.opacity(0.68)]
                    : [linkSource ? Color.linkedOrange : covered || (note != nil && length > 1) ? Color.linkedOrange.opacity(0.96) : (note == nil ? Color.gbDeep.opacity(0.30) : accent.opacity(0.96)), linkSource ? Color.linkedOrange.opacity(0.68) : covered || (note != nil && length > 1) ? Color.linkedOrange.opacity(0.68) : (note == nil ? Color.gbDeep.opacity(0.18) : accent.opacity(0.68))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(linkSource || linkArmed ? Color.arcadeRed : current ? Color.gbLight : Color.gbInk.opacity(0.34), lineWidth: linkSource || current ? 3 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .beatGlow(active: current, phase: phase, color: .amber)
        // Drawn over the pad rather than beside it, so the value stays legible under the
        // finger that is choosing it — the one place the pad's own label cannot be read.
        .overlay {
            if let live {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.hardwareBlack.opacity(0.88))
                    VStack(spacing: 1) {
                        Text(live.value)
                            .font(.custom("Futura-Bold", size: 14))
                            .foregroundStyle(Color.amber)
                        Text(live.detail)
                            .font(.custom("Futura-Bold", size: 7))
                            .foregroundStyle(Color.gbGlow.opacity(0.9))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.amber, lineWidth: 2))
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notePad.\(step)")
        .accessibilityLabel("Step \(step + 1)")
        .accessibilityValue(note.map(channel == .drum ? drumName : noteName) ?? "EMPTY")
        .accessibilityAdjustableAction { direction in onAdjust(direction) }
        .contentShape(Rectangle())
    }
}

/// The 16-step grid, and the single gesture that edits it.
///
/// The gesture belongs here rather than on each pad because a drag has to be able to
/// travel from the pad it started on to its neighbours. A gesture attached to a pad
/// keeps receiving the touch after the finger has left it and never learns which pad
/// the finger is over now — which is the one thing a paint sweep needs to know. So
/// the grid measures itself, turns the touch position into a step, and reads a single
/// touch as exactly one of four things:
///
///  * movement under `tapSlop` that lifts quickly — toggle the step
///  * movement under `tapSlop` that lifts after `linkHoldDuration` — arm the note link
///  * a vertical drag — pitch on melodic channels, drum voice on the drum row
///  * a sideways drag that reaches another pad — paint (or clear) every step it crosses
///
/// The reading is resolved once per touch and then latched, so a hesitant gesture
/// cannot change its mind partway through. A sideways drag that stays on its own pad
/// has no meaning for a melodic channel and is the drum voice pick for the drum row;
/// either way it stays undecided, so it can still become a sweep if the finger keeps
/// travelling.
private struct RestoredNoteGrid: View {
    let channel: ByteChannel
    let rootNote: Int
    let accent: Color
    let currentStep: Int
    let linkSourceStep: Int?
    let note: (Int) -> Int?
    let length: (Int) -> Int
    let covered: (Int) -> Bool
    let noteName: (Int) -> String
    let drumName: (Int) -> String
    /// The pitch the pattern will really hold for a requested note. Melodic notes are
    /// quantized to the project's scale, so a drag that skipped this would announce a pitch
    /// the pattern never takes and the readout would disagree with the pad's own label.
    let snap: (Int) -> Int
    let onToggle: (Int) -> Void
    let onArmLink: (Int) -> Void
    let onSetNote: (_ step: Int, _ note: Int) -> Void
    let onSetDrum: (_ step: Int, _ voice: Int) -> Void
    /// The value under the finger, or nil once nothing is being edited.
    let onScrub: (String?) -> Void
    /// The value a run should paint: the origin pad's own note, or nil to let the store pick
    /// the channel's default.
    let onSweepBegin: (_ step: Int, _ painting: Bool, _ note: Int?) -> Void
    let onSweepExtend: (Int) -> Void
    let onSweepEnd: () -> Void

    private static let columns = 4
    private static let rows = 4
    private static let spacing: CGFloat = 6
    /// Travel before a touch stops being a tap. Positional, not timed, so a slow tap
    /// still toggles.
    private static let tapSlop: CGFloat = 10
    /// Travel per semitone while scrubbing pitch. The mapping this replaced used 8pt,
    /// which put a full octave inside 96pt — under two pad heights — so the note
    /// wanted was almost always overshot on the way there.
    private static let pointsPerSemitone: CGFloat = 12
    /// Hold still this long, then lift, to arm the note link.
    private static let linkHoldDuration: TimeInterval = 0.45

    private enum Intent: Equatable { case undecided, scrubbing, sweeping }
    @State private var intent: Intent = .undecided
    @State private var touchBeganAt: Date?
    @State private var originStep: Int?
    @State private var originNote: Int?
    /// Whether the step under the finger was empty when the touch landed. That, and
    /// not the state at sweep time, decides paint-or-clear: a drum drag sets a voice
    /// on its own origin pad as it moves, so re-reading the origin mid-gesture would
    /// turn every drum sweep into an eraser.
    @State private var originWasEmpty = true
    @State private var lastApplied: Int?
    /// Whether this touch has already written a value to its origin pad. The drum voice pick
    /// is not latched as an intent — see the drum branch of `handle` — so this is what tells
    /// the release that the touch has already had its effect and must not also toggle.
    @State private var appliedValue = false
    @State private var sweptSteps: Set<Int> = []
    @State private var sweepingPaints = true
    @State private var gridFrame: CGRect = .zero
    /// The value the drag in progress is setting, and the pad it lands on.
    @State private var live: (step: Int, readout: PadLiveReadout)?

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columns),
            spacing: Self.spacing
        ) {
            ForEach(0..<(Self.columns * Self.rows), id: \.self) { step in
                RestoredNotePad(
                    step: step,
                    note: note(step),
                    length: length(step),
                    covered: covered(step),
                    channel: channel,
                    accent: accent,
                    current: step == currentStep,
                    phase: currentStep,
                    linkSource: linkSourceStep == step,
                    linkArmed: linkSourceStep.map { step > $0 } ?? false,
                    noteName: noteName,
                    drumName: drumName,
                    onAdjust: { direction in adjust(step: step, direction: direction) },
                    live: live.flatMap { $0.step == step ? $0.readout : nil }
                )
            }
        }
        // The grid's own frame is what turns a touch into a step. Measured in global
        // coordinates and subtracted from the gesture's global location, so there is
        // no reliance on a named coordinate space resolving to this view.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { gridFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in gridFrame = frame }
            }
        }
        // `highPriorityGesture` with `minimumDistance: 0` takes the touch away from
        // the enclosing ScrollView, so a pitch drag does not fight the page. Scrolling
        // the grid stays available two-fingered, through the scroll bridge.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged(handle)
                .onEnded(finish)
        )
    }

    /// Which step sits under a global point. Derived from the measured frame rather
    /// than from per-pad hit testing, because during a sweep the finger is usually
    /// outside the pad whose gesture is still tracking it.
    private func adjust(step: Int, direction: AccessibilityAdjustmentDirection) {
        let delta = direction == .increment ? 1 : -1
        if channel == .drum {
            let currentVoice = note(step).map { ByteDrumVoice.voice(for: $0).rawValue } ?? 0
            onSetDrum(step, min(ByteDrumVoice.allCases.count - 1, max(0, currentVoice + delta)))
        } else {
            let current = note(step) ?? rootNote
            onSetNote(step, snap(min(96, max(24, current + delta))))
        }
        Haptics.selection()
    }

    private func step(at point: CGPoint) -> Int? {
        guard gridFrame.width > 0, gridFrame.height > 0 else { return nil }
        let cellWidth = (gridFrame.width - Self.spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
        let cellHeight = (gridFrame.height - Self.spacing * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
        let column = Int((point.x - gridFrame.minX) / (cellWidth + Self.spacing))
        let row = Int((point.y - gridFrame.minY) / (cellHeight + Self.spacing))
        guard (0..<Self.columns).contains(column), (0..<Self.rows).contains(row) else { return nil }
        return row * Self.columns + column
    }

    private func handle(_ gesture: DragGesture.Value) {
        if touchBeganAt == nil { begin(gesture) }

        switch intent {
        case .scrubbing:
            scrubPitch(gesture)
            return
        case .sweeping:
            extendSweep(gesture)
            return
        case .undecided:
            break
        }

        guard hypot(gesture.translation.width, gesture.translation.height) >= Self.tapSlop else { return }

        let sideways = abs(gesture.translation.width) > abs(gesture.translation.height)
        let here = step(at: gesture.location)

        // Reaching another pad on a sideways drag is the sweep. Requiring BOTH is
        // what lets a vertical pitch scrub run off the bottom of its pad — and even
        // onto the pad below it — without turning into an eraser.
        if sideways, let here, here != originStep {
            guard let origin = originStep else { return }
            intent = .sweeping
            sweepingPaints = originWasEmpty
            sweptSteps.insert(origin)
            // A drum drag may have a voice readout up on the origin pad. The run is about to
            // paint that pad, so the readout has to go or it would cover what was painted.
            live = nil
            onSweepBegin(origin, sweepingPaints, valueForSweep())
            extendSweep(gesture)
            return
        }

        if channel == .drum {
            // The drum voice pick, applied live. Deliberately not latched as an intent: a
            // finger that goes on to reach the next pad has to still be able to become a
            // sweep, and the sweep has to keep the voice that travel just picked. That is
            // also why the pick is what the release has to know about — the lift of a drag
            // that already chose a voice must not toggle the hit back off.
            applyDrumVoice(gesture)
        } else if !sideways {
            intent = .scrubbing
            scrubPitch(gesture)
        }
    }

    private func finish(_ gesture: DragGesture.Value) {
        let heldFor = gesture.time.timeIntervalSince(touchBeganAt ?? gesture.time)
        let settled = intent
        let step = originStep
        let startedEmpty = originWasEmpty
        let alreadyEdited = appliedValue
        resetTouch()
        onScrub(nil)

        switch settled {
        case .sweeping:
            onSweepEnd()
        case .scrubbing:
            break
        case .undecided:
            // A drum drag that picked a voice has already written to its pad. Toggling here
            // would delete the hit the drag just chose, which made a voice pick look like an
            // eraser.
            guard let step, !alreadyEdited else { return }
            if heldFor >= Self.linkHoldDuration, channel != .drum, !startedEmpty {
                // Held still, then lifted: arm the link. Deciding this on release is
                // what stops the arm from firing partway through a drag.
                onArmLink(step)
            } else {
                onToggle(step)
            }
        }
    }

    private func begin(_ gesture: DragGesture.Value) {
        touchBeganAt = gesture.time
        intent = .undecided
        lastApplied = nil
        appliedValue = false
        sweptSteps = []
        let start = step(at: gesture.startLocation) ?? step(at: gesture.location)
        originStep = start
        originNote = start.flatMap(note) ?? rootNote
        originWasEmpty = start.map { note($0) == nil } ?? true
    }

    private func resetTouch() {
        intent = .undecided
        touchBeganAt = nil
        originStep = nil
        originNote = nil
        lastApplied = nil
        appliedValue = false
        live = nil
    }

    /// Vertical travel sets the pitch, from the note the step held when the drag
    /// began. The tap slop is discarded first, so the first semitone lands only once
    /// the finger has clearly committed instead of jumping the moment the drag is
    /// recognised.
    private func scrubPitch(_ gesture: DragGesture.Value) {
        guard let step = originStep else { return }
        let start = originNote ?? rootNote
        let dy = gesture.translation.height
        let travel = dy < 0 ? dy + Self.tapSlop : dy - Self.tapSlop
        let semitones = Int((-travel / Self.pointsPerSemitone).rounded())
        let value = snap(min(96, max(24, start + semitones)))
        guard value != lastApplied else { return }
        lastApplied = value
        onSetNote(step, value)
        live = (step, PadLiveReadout(value: noteName(value), detail: pitchDetail(step: step, from: start, to: value)))
        onScrub("PITCH \(noteName(value))")
        Haptics.selection()
    }

    /// The small line under the live pitch: which pad is being edited, and how far the drag
    /// has taken it, so "up is higher" needs no explaining.
    private func pitchDetail(step: Int, from start: Int, to value: Int) -> String {
        let amount = value - start
        guard amount != 0 else { return "STEP \(step + 1)" }
        return "STEP \(step + 1)  •  \(amount > 0 ? "+" : "")\(amount)"
    }

    /// The drum row's voice pick, unchanged in behaviour: the direction of the drag
    /// chooses the voice.
    private func applyDrumVoice(_ gesture: DragGesture.Value) {
        guard channel == .drum, let step = originStep else { return }
        let voice = ByteDrumVoice.voice(
            horizontal: Int(gesture.translation.width),
            vertical: Int(gesture.translation.height)
        ).rawValue
        guard voice != lastApplied else { return }
        lastApplied = voice
        appliedValue = true
        onSetDrum(step, voice)
        let title = ByteDrumVoice.allCases[min(3, max(0, voice))].title
        live = (step, PadLiveReadout(value: title, detail: "STEP \(step + 1)"))
        onScrub("VOICE \(title)")
        Haptics.selection()
    }

    /// The value a run paints: whatever the origin pad is holding, so dragging away from a
    /// note repeats *that* note instead of stamping the channel's root note across a melody
    /// that was already there. An empty origin pad has no value to carry, and nil lets the
    /// store supply the channel's own default.
    ///
    /// On the drum row this is read after the sideways travel has already picked a voice on
    /// the origin pad, so a rightward drag on an empty drum row lays down the voice it picked
    /// rather than a run of kicks.
    private func valueForSweep() -> Int? {
        guard let step = originStep else { return nil }
        return note(step)
    }

    private func extendSweep(_ gesture: DragGesture.Value) {
        guard let here = step(at: gesture.location), !sweptSteps.contains(here) else { return }
        sweptSteps.insert(here)
        onSweepExtend(here)
        let count = sweptSteps.count
        // Reported on the hint line rather than on a pad: mid-run the pads carry the paint
        // itself, and covering one with a readout would hide what the drag just did.
        onScrub("\(sweepingPaints ? "PAINTING" : "CLEARING") \(count) \(count == 1 ? "STEP" : "STEPS")")
    }
}

private struct RestoredDrumEditor: View {
    let accent: Color
    let patch: ByteChannelPatch
    /// The project tempo. The run is spaced by the transport's own step so it is heard in the
    /// time of the loop it belongs to, not at an interval of its own.
    let tempo: Int
    /// This pattern's drum row, so the kit can be heard in the music and not only in isolation.
    let drumHits: [ByteDrumHit]
    let volume: (ByteDrumVoice) -> Int
    let onSelectSample: (ByteDrumVoice, Int) -> Void
    let onVolumeChange: (ByteDrumVoice, Int) -> Void
    /// Plays one voice through the engine, so a tap here is heard where the pads are heard.
    let onAudition: (ByteDrumVoice) -> Void
    /// Set while the run is playing, so the row that is sounding can light.
    @State private var sounding: ByteDrumVoice?
    @State private var runTask: Task<Void, Never>?
    @State private var flashTask: Task<Void, Never>?
    /// Which of the two checks is playing. Held separately from `runTask` so each control lights
    /// for its own run rather than both looking busy whenever either one is.
    @State private var runningCheck: Check?

    private enum Check { case kitWalk, drumRow }

    var body: some View {
        LCDPanel(title: "DRUM KIT / VOICE MIX", header: {
            RestoredAuditionButton(
                identifier: "drumKit.auditionAll",
                label: "Hear all four drum voices",
                hint: "Plays the kit from the floor up, one voice per beat in time with the tempo.",
                running: runningCheck == .kitWalk
            ) { runKitCheck(ByteDrumVoice.auditionWalk, kind: .kitWalk) }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("VOICE / CHARACTER")
                        .font(.custom("Futura-Bold", size: 8))
                    Spacer()
                    Text("SAMPLE")
                        .font(.custom("Futura-Bold", size: 8))
                }
                .foregroundStyle(Color.gbInk.opacity(0.62))
                ForEach(ByteDrumVoice.allCases) { voice in
                    RestoredDrumVoiceRow(
                        voice: voice,
                        accent: accent,
                        sample: patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1,
                        volume: volume(voice),
                        sounding: sounding == voice,
                        onSelectSample: { onSelectSample(voice, $0) },
                        onVolumeChange: { onVolumeChange(voice, $0) },
                        onAudition: { audition(voice) }
                    )
                }
                RestoredAuditionButton(
                    title: "HEAR THIS PATTERN'S DRUM ROW",
                    identifier: "drumKit.patternCheck",
                    label: "Hear this pattern's drum row",
                    hint: drumHits.isEmpty
                        ? "The drum row is empty. Tap some drum pads to write one first."
                        : "Plays this pattern's drum row in time, so the kit is heard in the music.",
                    running: runningCheck == .drumRow,
                    enabled: !drumHits.isEmpty
                ) { runKitCheck(drumHits, kind: .drumRow) }
                Text(hint)
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbInk.opacity(0.68))
            }
        }
        .onDisappear {
            runTask?.cancel()
            runningCheck = nil
        }
    }

    /// The panel's instructions. The drum-row half changes when the row is empty, because a
    /// dimmed button with nothing to explain it reads as broken rather than as unarmed.
    private var hint: String {
        let rowHalf = drumHits.isEmpty
            ? "TO CHECK A DRUM ROW HERE, WRITE ONE ON THE BEAT PAD FIRST."
            : "THE DRUM ROW BUTTON PLAYS THE BAR YOU WROTE, IN TIME."
        return "TAP A VOICE TO HEAR IT. ▶ PLAYS ALL FOUR, ONE PER BEAT. \(rowHalf) TAP SAMPLE 1 / 2 TO CHOOSE ITS HIT. SWIPE A VOICE TO MIX IT. ON THE BEAT PAD, DRAG UP FOR SNARE, DOWN FOR KICK, LEFT FOR HI-HAT, RIGHT FOR PERC."
    }

    /// Hears one voice, and lights its row while it sounds so the ear and the eye agree about
    /// which voice that was. A tap here takes over from a run in progress rather than playing
    /// under it.
    private func audition(_ voice: ByteDrumVoice) {
        runTask?.cancel()
        runTask = nil
        runningCheck = nil
        onAudition(voice)
        flashTask?.cancel()
        sounding = voice
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            if !Task.isCancelled { sounding = nil }
        }
    }

    /// Plays a kit check: one hit per step of the bar, lighting the voice's row as it sounds.
    ///
    /// Both checks go through here — the walk up the kit, and this pattern's drum row — because
    /// they are the same walk over the same bar. Two runners is how two halves of one idea come
    /// apart, and the tempo is the half that would go first.
    ///
    /// The hits play through the audition path rather than the transport, which is also what
    /// gives the check the sequence's own voice: the transport plays the drum row from a single
    /// sample position that each hit resets, so a check whose one-shots overlapped would sound
    /// fuller than the music it exists to represent. The task is held so a second tap restarts
    /// the run instead of layering a pass over it.
    private func runKitCheck(_ hits: [ByteDrumHit], kind: Check) {
        runTask?.cancel()
        // A flash left over from a tap must not clear the run's highlight a beat into it.
        flashTask?.cancel()
        let stepSeconds = ByteTransportClock.stepDuration(bpm: tempo)
        runningCheck = kind
        runTask = Task { @MainActor in
            var next = 0
            for step in 0..<BytePattern.barSteps {
                // Return rather than break: a cancelled run must not write the state a newer one
                // has already claimed as its own.
                if Task.isCancelled { return }
                if next < hits.count, hits[next].step == step {
                    let voice = hits[next].voice
                    sounding = voice
                    onAudition(voice)
                    next += 1
                }
                do { try await Task.sleep(for: .seconds(stepSeconds)) } catch { return }
            }
            sounding = nil
            runningCheck = nil
            runTask = nil
        }
    }
}

/// A kit check's transport control, in the gradient the Sound Lab's randomizer and the panel
/// headers use. It changes colour while its own run plays, so a tap that started a pass is
/// visible without a label to read.
///
/// `title` is nil for the 34×30 header slot, where the glyph carries the meaning on its own, and
/// set for the full-width button under the voice rows, where there is room to say what it plays.
private struct RestoredAuditionButton: View {
    var title: String? = nil
    let identifier: String
    let label: String
    let hint: String
    let running: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: running ? "waveform" : "play.fill")
                    .font(.system(size: 13, weight: .black))
                if let title {
                    Text(title)
                        .font(.custom("Futura-Bold", size: 10))
                        .tracking(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(Color.gbInk)
            .frame(width: title == nil ? 34 : nil, height: title == nil ? 30 : 36)
            .frame(maxWidth: title == nil ? nil : .infinity)
            .background(
                LinearGradient(
                    colors: [(running ? Color.amber : Color.gbGlow), (running ? Color.linkedOrange : Color.gbGlow).opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.gbInk, lineWidth: 1.5))
            .shadow(color: running ? Color.amber.opacity(0.7) : .clear, radius: running ? 6 : 0)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(ArcadePressStyle(scale: 0.88))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityValue(running ? "playing" : (enabled ? "idle" : "empty"))
        .accessibilityHint(hint)
    }
}

private struct RestoredDrumVoiceRow: View {
    let voice: ByteDrumVoice
    let accent: Color
    let sample: Int
    let volume: Int
    /// Whether the voice is sounding on its own right now, from the audition run.
    let sounding: Bool
    let onSelectSample: (Int) -> Void
    let onVolumeChange: (Int) -> Void
    let onAudition: () -> Void
    @State private var startVolume: Int?
    @State private var lastVolume: Int?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                voiceColor.opacity(sounding ? 0.42 : 0.16)
                voiceColor.opacity(0.72)
                    .animation(.easeOut(duration: 0.12), value: volume)
                    .frame(width: proxy.size.width * CGFloat(volume) / 100.0)
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(voice.title)
                            .font(.custom("Futura-Bold", size: 8))
                        // What the voice's shape does to its sample, so the ear knows what it is
                        // listening for instead of having to infer it from four similar hits.
                        Text(voice.character)
                            .font(.custom("Futura-Bold", size: 7))
                            .lineLimit(1)
                            .foregroundStyle(Color.gbInk.opacity(0.62))
                    }
                    Text("\(volume)%")
                        .font(.custom("Futura-Bold", size: 8))
                    Spacer(minLength: 2)
                    DrumVoiceSparkline(envelope: envelope, widthFraction: waveWidthFraction)
                    ForEach(1...2, id: \.self) { variant in
                        Button { onSelectSample(variant) } label: {
                            Text("\(variant)")
                                .font(.custom("Futura-Bold", size: 8))
                                .foregroundStyle(sample == variant ? Color.gbInk : Color.gbMid)
                                .frame(width: 27, height: 24)
                                .background(sample == variant ? Color.amber : Color.gbLight.opacity(0.55))
                                .overlay(Rectangle().stroke(Color.gbInk.opacity(0.45), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Color.gbInk)
                .padding(.horizontal, 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().stroke(sounding ? Color.amber : Color.gbInk.opacity(0.4), lineWidth: sounding ? 2 : 1))
            .contentShape(Rectangle())
            // A row is its own preview: the fastest way to know what a voice is called is to
            // hear it. The volume swipe needs 8pt of travel, so a tap still reads as a tap.
            // A row is its own preview: the fastest way to know what a voice is called is to
            // hear it. The volume swipe needs 8pt of travel, so a tap still reads as a tap —
            // the same pairing the mixer faders use.
            .onTapGesture { onAudition() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { gesture in
                        if startVolume == nil { startVolume = volume }
                        let proposed = min(100, max(0, (startVolume ?? volume) + Int((gesture.translation.width / 2).rounded())))
                        if proposed != lastVolume {
                            lastVolume = proposed
                            onVolumeChange(proposed)
                        }
                    }
                    .onEnded { _ in startVolume = nil; lastVolume = nil }
            )
        }
        .frame(height: 42)
        .animation(.easeOut(duration: 0.12), value: sounding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drumVoice.\(voice.rawValue)")
        .accessibilityLabel("\(voice.title) voice")
        .accessibilityValue("\(voice.character), \(volume)%\(sounding ? ", sounding" : "")")
        .accessibilityHint("Tap to hear it. Swipe left or right to set its level. Tap 1 or 2 to choose the sample.")
        .accessibilityAction { onAudition() }
        .accessibilityAdjustableAction { direction in
            // Same 5-point step the mixer faders use under VoiceOver, so the drum mixer
            // and the channel mixer agree on how fast a swipe moves.
            switch direction {
            case .increment: onVolumeChange(min(100, volume + 5))
            case .decrement: onVolumeChange(max(0, volume - 5))
            @unknown default: break
            }
        }
    }

    /// The mixer row and the pad share one mapping, so the swatch beside a voice
    /// cannot disagree with the pads holding it.
    private var voiceColor: Color { voice.padColor }

    /// The voice's outline, taken from the sample the row has selected — so switching 1 / 2
    /// changes the picture as well as the sound it stands for.
    private var envelope: [Double] {
        ByteDrumSampleBank.shared.envelope(voice: voice, variant: sample)
    }

    /// How much of the sparkline's slot this voice fills: its length against the longest hit in
    /// the kit, which is what makes a click look like a stub beside a full tail.
    private var waveWidthFraction: Double {
        let bank = ByteDrumSampleBank.shared
        let longest = bank.longestOutputFrameCount(variant: sample)
        return min(1, max(0, Double(bank.outputFrameCount(voice: voice, variant: sample)) / Double(longest)))
    }
}

/// One voice's shaped hit, drawn as the outline it is heard as.
///
/// The points come from the reader playback uses, and the drawn width is this voice's length
/// against the longest hit in the kit — so the row says "TIGHTER · CLICK" in words and shows a
/// stub beside the kick's full tail, rather than four pictures that each fill their own box.
private struct DrumVoiceSparkline: View {
    let envelope: [Double]
    /// How much of the slot the hit fills, from 0 to 1.
    let widthFraction: Double

    /// A fixed slot, so the four rows line up and the lengths can be compared between them.
    private static let slotWidth: CGFloat = 46
    private static let slotHeight: CGFloat = 18

    var body: some View {
        DrumVoiceWave(envelope: envelope)
            .fill(Color.gbInk.opacity(0.72))
            .frame(width: max(1, Self.slotWidth * CGFloat(min(1, max(0, widthFraction)))), height: Self.slotHeight)
            .frame(width: Self.slotWidth, height: Self.slotHeight, alignment: .leading)
            .background(Color.gbInk.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            // The row's value already names the shape; the picture is the same fact in another
            // form, so it would only repeat itself to a reader who cannot see it.
            .accessibilityHidden(true)
    }
}

/// A hit's outline, mirrored about the middle of its rect so it reads as a waveform rather than
/// as a mountain.
private struct DrumVoiceWave: Shape {
    let envelope: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard envelope.count > 1, rect.width > 0, rect.height > 0 else { return path }
        let middle = rect.midY
        let half = rect.height / 2
        let step = rect.width / CGFloat(envelope.count - 1)

        func point(_ index: Int, above: Bool) -> CGPoint {
            let level = CGFloat(min(1, max(0, envelope[index]))) * half
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: above ? middle - level : middle + level)
        }

        path.move(to: point(0, above: true))
        for index in envelope.indices { path.addLine(to: point(index, above: true)) }
        for index in envelope.indices.reversed() { path.addLine(to: point(index, above: false)) }
        path.closeSubpath()
        return path
    }
}

private struct RestoredPatchCard: View {
    let parameter: BytePatchParameter
    let patch: ByteChannelPatch
    let selected: Bool
    let onSelect: () -> Void
    /// Receives the absolute value represented by the fader, not a gesture delta.
    let onChange: (Int) -> Void
    @State private var dragStartValue: Int?

    private var currentValue: Int {
        switch parameter {
        case .tone: return patch.channel == .wave ? patch.waveShape : patch.duty
        case .duty: return patch.duty
        case .envelopeAttack: return patch.envelopeAttack
        case .envelopeDecay: return patch.envelopeDecay
        case .envelopeSustain: return patch.envelopeSustain
        case .envelopeRelease: return patch.envelopeRelease
        case .portamento: return patch.portamento
        case .portamentoTime: return patch.portamentoTime
        case .vibratoCycleLength: return patch.vibratoCycleLength
        case .vibratoDepth: return patch.vibratoDepth
        case .vibratoDelay: return patch.vibratoDelay
        case .octaveFlutterSpeed: return patch.octaveFlutterAmount
        case .octaveFlutterPattern: return patch.octaveFlutterPattern
        case .bendRange: return patch.bendRange
        case .octave: return patch.octave
        case .tremolo: return patch.tremolo
        case .envelope: return patch.envelope
        case .waveShape: return patch.waveShape
        case .waveFilter: return patch.waveFilter
        case .waveEnvelope: return patch.waveEnvelope
        case .volume: return patch.initialVolume
        case .envelopeDirection: return patch.envelopeIncrease ? 100 : 0
        case .envelopePace: return patch.envelopePace
        case .sweepPace: return patch.sweepPace
        case .sweepDirection: return patch.sweepIncrease ? 100 : 0
        case .sweepShift: return patch.sweepShift
        case .waveVolume: return patch.waveVolume
        case .drumSample: return patch.drumSamples.indices.contains(patch.drumVoice) ? patch.drumSamples[patch.drumVoice] : 1
        case .panLeft: return patch.panLeft ? 100 : 0
        case .panRight: return patch.panRight ? 100 : 0
        case .lengthCounter: return patch.lengthCounter ? 100 : 0
        case .length: return patch.length
        }
    }

    private var faderFraction: CGFloat {
        let range = parameter.range
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return CGFloat(currentValue - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected ? Color.gbInk : Color.screenShadow.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text(parameter.title)
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 2)
                Text(restoredPatchValue)
                    .font(.custom("Futura-Bold", size: 9))
                    .foregroundStyle(Color.gbInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gbDeep.opacity(0.18))
                    Capsule()
                        .fill(selected ? Color.gbInk : Color.screenShadow.opacity(0.58))
                        .frame(width: max(8, proxy.size.width * restoredPatchFraction))
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { _ in
                            Circle().fill(Color.gbInk.opacity(0.28)).frame(width: 2, height: 2)
                        }
                    }
                    .padding(.horizontal, 5)
                }
                .contentShape(Rectangle())
            }
            .frame(height: 7)
        }
        .padding(9)
        .frame(minHeight: 56)
        .background(selected ? Color.amber : Color.gbDeep.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.gbInk : Color.gbInk.opacity(0.3), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { gesture in
                    onSelect()
                    if dragStartValue == nil { dragStartValue = currentValue }
                    let range = parameter.range
                    // One full card-width should cover most continuous controls while
                    // smaller controls remain deliberately tactile.
                    let pointsPerStep: CGFloat = range.count > 10 ? 1.25 : 8.0
                    let raw = (dragStartValue ?? currentValue) + Int((gesture.translation.width / pointsPerStep).rounded())
                    onChange(min(max(raw, range.lowerBound), range.upperBound))
                }
                .onEnded { _ in dragStartValue = nil }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(parameter.title)
        .accessibilityValue(restoredPatchValue)
        .accessibilityHint("Tap to select. Swipe left or right to adjust.")
        .accessibilityAction { onSelect() }
        .accessibilityAdjustableAction { direction in
            onSelect()
            // Coarse ranges (0-100 envelope stages and such) step like the mixer fader so a
            // swipe actually moves; fine ranges (duty, sample, octave) step one unit so a
            // swipe never skips a value the drag would have stopped on.
            let step = parameter.range.count > 16 ? 5 : 1
            switch direction {
            case .increment: onChange(min(currentValue + step, parameter.range.upperBound))
            case .decrement: onChange(max(currentValue - step, parameter.range.lowerBound))
            @unknown default: break
            }
        }
    }

    private var restoredPatchValue: String {
        switch parameter {
        case .tone: return patch.channel == .wave ? ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, patch.waveShape))].title : ["12.5%", "25%", "50%", "75%"][min(3, max(0, patch.duty))]
        case .duty: return ["12.5%", "25%", "50%", "75%"][min(3, max(0, patch.duty))]
        case .octave: return patch.octave >= 0 ? "+\(patch.octave) OCT" : "\(patch.octave) OCT"
        case .octaveFlutterSpeed: return ByteEffects.octaveFlutterDivisionTitle(for: patch.octaveFlutterAmount)
        case .octaveFlutterPattern: return ByteOctaveFlutterPattern(rawValue: patch.octaveFlutterPattern)?.title ?? "BASE / +1"
        case .volume: return "\(patch.initialVolume)/15"
        case .waveShape: return ByteWaveShape.allCases[min(ByteWaveShape.allCases.count - 1, max(0, patch.waveShape))].title
        case .waveVolume: return "SHIFT \(patch.waveVolume)"
        case .envelopeDirection: return patch.envelopeIncrease ? "UP" : "DOWN"
        case .sweepDirection: return patch.sweepIncrease ? "UP" : "DOWN"
        case .panLeft: return patch.panLeft ? "ON" : "OFF"
        case .panRight: return patch.panRight ? "ON" : "OFF"
        case .lengthCounter: return patch.lengthCounter ? "ON" : "OFF"
        case .drumSample: return "SAMPLE \(currentValue)"
        case .envelopePace, .sweepPace, .sweepShift: return "\(currentValue)"
        case .bendRange: return "\(currentValue) ST"
        case .length: return "\(currentValue)"
        default: return "\(currentValue)%"
        }
    }

    private var restoredPatchFraction: CGFloat {
        min(1, max(0, faderFraction))
    }
}

private struct RestoredFXModule: View {
    let title: String
    let amount: Int
    let accent: Color
    let active: Bool
    let phase: Int
    let flutterPattern: ByteOctaveFlutterPattern?
    let onPatternChange: ((ByteOctaveFlutterPattern) -> Void)?
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.custom("Futura-Bold", size: 8))
                    .foregroundStyle(Color.gbLight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 2)
                Circle()
                    .fill(amount > 0 ? accent : Color.plasticHighlight)
                    .frame(width: 5, height: 5)
                    .shadow(color: amount > 0 ? accent.opacity(0.8) : .clear, radius: 3)
            }
            RestoredFXMeter(level: amount, accent: accent, active: active, phase: phase)
                .frame(height: 16)
            RestoredAmountCard(title: "AMOUNT", amount: amount, onChange: onChange)
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [Color.plasticRaised.opacity(0.92), Color.hardwareBlack.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(amount > 0 ? 0.72 : 0.28), lineWidth: amount > 0 ? 1.5 : 1))
        .accessibilityElement(children: .contain)
    }
}

private struct RestoredFXSendStrip: View {
    let title: String
    let amount: Int
    let accent: Color
    let muted: Bool
    let soloed: Bool
    let active: Bool
    let phase: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 4, height: 22)
                    .shadow(color: accent.opacity(0.65), radius: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(Color.gbLight)
                    Text(muted ? "MUTED" : soloed ? "SOLO MONITOR" : "ROUTED TO BUS")
                        .font(.custom("Futura-Bold", size: 8))
                        .foregroundStyle(muted ? Color.arcadeRed : soloed ? Color.amber : Color.mutedText)
                }
                Spacer(minLength: 2)
                Text("\(amount)%")
                    .font(.custom("Futura-Bold", size: 9))
                    .foregroundStyle(accent)
            }
            RestoredFXMeter(level: amount, accent: accent, active: active && !muted, phase: phase)
                .frame(height: 13)
            RestoredAmountCard(title: "SEND LEVEL", amount: amount, onChange: onChange)
        }
        .padding(8)
        .background(Color.hardwareBlack.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.48), lineWidth: 1))
        .opacity(muted ? 0.62 : 1)
        .accessibilityElement(children: .contain)
    }
}

private struct RestoredFXMeter: View {
    let level: Int
    let accent: Color
    let active: Bool
    let phase: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { index in
                    let threshold = Double(index + 1) / 12.0
                    let animatedBoost = active ? CGFloat((abs(phase + index * 3) % 4)) / 16.0 : 0
                    let fill = min(1, CGFloat(level) / 100.0 + animatedBoost)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(fill >= threshold ? (index > 9 ? Color.arcadeRed : accent) : Color.gbDeep.opacity(0.32))
                        .frame(maxWidth: .infinity)
                        .shadow(color: fill >= threshold && active ? accent.opacity(0.55) : .clear, radius: 2)
                }
            }
            .animation(.linear(duration: 0.08), value: phase)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("FX level")
            .accessibilityValue("\(level) percent")
        }
    }
}

private struct RestoredAmountCard: View {
    let title: String
    let amount: Int
    let onChange: (Int) -> Void
    @State private var start: Int?
    @State private var last: Int?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gbDeep.opacity(0.16))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.gbGlow.opacity(0.72), Color.gbGlow.opacity(0.28)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, proxy.size.width * CGFloat(min(100, max(0, amount))) / 100))
                HStack(spacing: 6) {
                    Circle().fill(Color.gbInk.opacity(0.62)).frame(width: 5, height: 5)
                    Text(title)
                        .font(.custom("Futura-Bold", size: 8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text("\(amount)%")
                        .font(.custom("Futura-Bold", size: 8))
                }
                .foregroundStyle(Color.gbInk)
                .padding(.horizontal, 8)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gbInk.opacity(0.38), lineWidth: 1))
            .contentShape(Rectangle())
            // Use a simultaneous gesture so the vertical editor ScrollView cannot swallow
            // horizontal parameter edits. The fader remains horizontal-only by design.
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { gesture in
                if start == nil { start = amount }
                let proposed = min(max((start ?? amount) + Int((gesture.translation.width / 2).rounded()), 0), 100)
                if proposed != last { last = proposed; onChange(proposed) }
            }.onEnded { _ in start = nil; last = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(amount) percent")
            .accessibilityHint("Swipe left or right to adjust.")
        }
        .frame(height: 44)
    }
}


struct ProjectLibraryView: View {
    @Environment(GameStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectIDToDelete: UUID?
    @State private var showDeleteConfirmation = false
    @State private var showDiscardRecoverableConfirmation = false
#if DEBUG
    @State private var showDiagnostics = false
#endif
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                List {
                    if store.hasRecoverableProjects {
                        Section {
                            ForEach(store.recoveryCandidates) { candidate in
                                HStack(spacing: 4) {
                                    Button {
                                        store.restoreRecoveredProject(candidate)
                                    } label: {
                                        HStack {
                                            Image(systemName: candidate.iconName)
                                                .foregroundStyle(Color.amber)
                                            VStack(alignment: .leading) {
                                                Text(candidate.project.name).font(.custom("Futura-Bold", size: 14))
                                                Text("\(candidate.title) · \(candidate.project.patterns.count) PATTERN\(candidate.project.patterns.count == 1 ? "" : "S") · \(candidate.project.tempo) BPM")
                                                    .font(.custom("Futura-Medium", size: 10))
                                                    .foregroundStyle(Color.mutedText)
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.uturn.backward.circle")
                                                .foregroundStyle(Color.gbLight)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("projectLibrary.restorePreservedProject")
                                    .accessibilityHint(candidate.restoreHint)

                                    // Dropping a single row is the quiet counterpart to restoring
                                    // it, so it gets its own control instead of hiding behind the
                                    // row's tap, which is already spoken for. The glyph is a cross
                                    // rather than a bin on purpose: this stops offering a copy, it
                                    // does not erase it, and the bin is the bulk control.
                                    Button {
                                        store.dismissRecoverableProject(candidate)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(Color.gbLight)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("projectLibrary.dismissRecoverable")
                                    .accessibilityLabel("Remove \(candidate.project.name) from the recovery list")
                                    .accessibilityHint("Stops offering this copy without erasing it. Undo brings the row back.")
                                }
                            }
                            if let notice = preservedNotice {
                                Label(notice, systemImage: "exclamationmark.triangle.fill")
                                    .font(.custom("Futura-Medium", size: 10))
                                    .foregroundStyle(Color.mutedText)
                            }
                            Button(role: .destructive) {
                                showDiscardRecoverableConfirmation = true
                            } label: {
                                Label("DISCARD RECOVERABLE PROJECTS", systemImage: "trash")
                                    .font(.custom("Futura-Bold", size: 12))
                            }
                            .accessibilityIdentifier("projectLibrary.discardRecoverable")
                            .accessibilityHint("Deletes the recoverable copies and any deleted project for good")
                        } header: {
                            Text("RECOVERABLE PROJECTS")
                        } footer: {
                            Text("Kept from an earlier launch, from a library that could not be read in full, or from a project you deleted. Restoring never changes the projects already in your cart.")
                        }
                    }
                    Section {
                        ForEach(store.projects) { project in
                            Button { store.selectProject(project); dismiss() } label: {
                                HStack {
                                    Image(systemName: project.id == store.project.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(project.id == store.project.id ? Color.amber : Color.gbLight)
                                    VStack(alignment: .leading) {
                                        Text(project.name).font(.custom("Futura-Bold", size: 14))
                                        Text("\(project.patterns.count) PATTERN\(project.patterns.count == 1 ? "" : "S") · \(project.tempo) BPM")
                                            .font(.custom("Futura-Medium", size: 10)).foregroundStyle(Color.mutedText)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .onDelete { offsets in
                            guard let first = offsets.first, store.projects.indices.contains(first), store.projects.count > 1 else { return }
                            projectIDToDelete = store.projects[first].id
                            showDeleteConfirmation = true
                        }
                    }
                    Section { Button { store.newProject(); dismiss() } label: { Label("NEW PROJECT", systemImage: "plus.square.fill") } }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.gbLight)
                // The editor's toast is behind this sheet, so a message about something done here
                // has to be repeated here to reach the user at all.
                if let toast = store.toast {
                    VStack {
                        Spacer()
                        PocketToast(message: toast)
                            .padding(.bottom, 24)
                            // The editor draws the same banner behind this sheet, so the cart's own
                            // copy carries a distinct identifier to stay tellable apart.
                            .accessibilityIdentifier("pocketToast.cart")
                    }
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .navigationTitle("PROJECT CART")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("DONE") { dismiss() } }
#if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button("REPORT") { showDiagnostics = true }
                        .accessibilityIdentifier("projectLibrary.diagnostics")
                }
#endif
            }
        }
        .alert("DELETE PROJECT?", isPresented: $showDeleteConfirmation) {
            Button("DELETE", role: .destructive) {
                if let projectIDToDelete, let project = store.projects.first(where: { $0.id == projectIDToDelete }) {
                    store.deleteProject(project)
                }
                self.projectIDToDelete = nil
            }
            Button("CANCEL", role: .cancel) { projectIDToDelete = nil }
        } message: {
            Text("This removes the project from the project cart. It is kept here so you can restore it later, even after you close the app.")
        }
        .alert("DISCARD RECOVERABLE PROJECTS?", isPresented: $showDiscardRecoverableConfirmation) {
            Button("DISCARD", role: .destructive) { store.discardRecoverableProjects() }
            Button("CANCEL", role: .cancel) { }
        } message: {
            Text("These are the only copies of that work, including any project you deleted. The projects in your cart are not affected, but this cannot be undone.")
        }
#if DEBUG
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
#endif
        .preferredColorScheme(.dark)
    }

#if DEBUG
    /// The recovery dump, shown as selectable monospaced text so it can be taken out of the app
    /// without a pasteboard round trip. Debug builds only, like the report it renders.
    private var diagnosticsSheet: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                ScrollView {
                    Text(store.recoveryDiagnosticsReport())
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("projectLibrary.diagnosticsReport")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .navigationTitle("RECOVERY DIAGNOSTICS")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("CLOSE") { showDiagnostics = false } } }
        }
        .preferredColorScheme(.dark)
    }
#endif

    /// Names what is preserved but cannot be brought back, so the surface never looks like it is
    /// silently missing a project whose bytes are in fact still on disk.
    private var preservedNotice: String? {
        var parts: [String] = []
        let entries = store.preservedLibrary.unreadableEntries
        if entries > 0 {
            parts.append("\(entries) PROJECT\(entries == 1 ? "" : "S") PRESERVED BUT UNREADABLE")
        }
        let copies = store.preservedLibrary.unreadableCopies
        if copies > 0 {
            parts.append("\(copies) LIBRARY COPY\(copies == 1 ? "" : "IES") PRESERVED BUT UNREADABLE")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ExportView: View {
    @Environment(GameStore.self) private var store
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.dismiss) private var dismiss
    let useSongArrangement: Bool
    @State private var showPaywall = false
    @State private var projectDocument = ByteProjectDocument()
    @State private var waveDocument = ByteWaveDocument()
    @State private var midiDocument = ByteMIDIDocument()
    @State private var showProjectExporter = false
    @State private var showWaveExporter = false
    @State private var showMIDIExporter = false
    @State private var exportProgress = 0.0
    @State private var isRenderingWave = false
    @State private var renderTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                VStack(spacing: 12) {
                    Text("TAKE YOUR TRACK OUT OF THE POCKET")
                        .font(.custom("Futura-Bold", size: 15))
                        .foregroundStyle(Color.gbLight)
                        .multilineTextAlignment(.center)
                    exportButton("PROJECT FILE", "EDITABLE / REOPEN ANYTIME", "doc.fill", identifier: "export.project") { projectDocument = store.projectDocument(); showProjectExporter = true }
                    exportButton("MIDI FILE", "4 CHANNELS / NOTE DATA", "pianokeys", locked: !storeKit.canExport, identifier: "export.midi") {
                        guard storeKit.canExport else { showPaywall = true; return }
                        midiDocument = ByteMIDIDocument(data: ByteMIDI.export(project: store.project, patterns: useSongArrangement ? store.songPlaybackPatterns : store.project.arrangedPatterns))
                        showMIDIExporter = true
                    }
                    exportButton("WAV AUDIO", "SYNTHESIZED / 44.1 KHZ", "waveform", locked: !storeKit.canExport, identifier: "export.wav") {
                        guard storeKit.canExport else { showPaywall = true; return }
                        startWaveExport()
                    }
                    if isRenderingWave { renderProgressView }
                    if !storeKit.canExport {
                        Text("EXPORT PACK — MIDI + WAV / ONE-TIME UNLOCK")
                            .font(.custom("Futura-Bold", size: 9))
                            .foregroundStyle(Color.mutedText)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(22)
            }
            .navigationTitle("EXPORT")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("DONE") { dismiss() }.disabled(isRenderingWave) } }
            .sheet(isPresented: $showPaywall) { ExportPaywallView() }
        }
        .fileExporter(isPresented: $showProjectExporter, document: projectDocument, contentTypes: [.bytePocketProject], defaultFilename: store.project.name.lowercased()) { _ in }
        .fileExporter(isPresented: $showMIDIExporter, document: midiDocument, contentTypes: [.bytePocketMIDI], defaultFilename: store.project.name.lowercased() + ".mid") { _ in }
        .fileExporter(isPresented: $showWaveExporter, document: waveDocument, contentTypes: [.bytePocketWave], defaultFilename: store.project.name.lowercased() + ".wav") { _ in }
        .onDisappear { renderTask?.cancel() }
        .preferredColorScheme(.dark)
    }

    private var renderProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RENDERING WAV")
                Spacer()
                Text("\(Int(exportProgress * 100))%")
            }
            .font(.custom("Futura-Bold", size: 10))
            .foregroundStyle(Color.gbLight)
            ProgressView(value: exportProgress).tint(Color.gbGlow)
            Text("SYNTHESIZING EVERY SAMPLE — KEEP THIS WINDOW OPEN")
                .font(.custom("Futura-Medium", size: 8))
                .foregroundStyle(Color.mutedText)
        }
        .padding(12)
        .background(Color.gbDeep)
        .overlay(Rectangle().stroke(Color.gbMid, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rendering WAV audio")
        .accessibilityValue("\(Int(exportProgress * 100)) percent complete")
    }

    private func startWaveExport() {
        guard !isRenderingWave else { return }
        isRenderingWave = true
        exportProgress = 0
        let project = store.project
        let patterns = useSongArrangement ? store.songPlaybackPatterns : store.project.arrangedPatterns
        let progressStream = AsyncStream<Double>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            defer { progressStream.continuation.finish() }
            return ByteRenderer.wavData(project: project, patterns: patterns) { value in
                progressStream.continuation.yield(value)
            }
        }
        renderTask = Task { @MainActor in
            async let renderedData = worker.value
            for await value in progressStream.stream { exportProgress = value }
            waveDocument = ByteWaveDocument(data: await renderedData)
            exportProgress = 1
            isRenderingWave = false
            showWaveExporter = true
        }
    }

    private func exportButton(_ title: String, _ detail: String, _ icon: String, locked: Bool = false, identifier: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 34)
                VStack(alignment: .leading) { Text(title).font(.custom("Futura-Bold", size: 13)); Text(detail).font(.custom("Futura-Medium", size: 9)).foregroundStyle(Color.mutedText) }
                Spacer()
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.amber)
                        .accessibilityLabel("\(title) requires the Export Pack")
                } else {
                    Image(systemName: "chevron.right")
                }
            }
            .foregroundStyle(Color.gbInk)
            .padding(14)
            .background(Color.gbLight)
            .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .disabled(isRenderingWave)
        .opacity(isRenderingWave ? 0.55 : 1)
    }
}

struct ExportPaywallView: View {
    @Environment(GameStore.self) private var store
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                VStack(spacing: 16) {
                    Text("EXPORT PACK").font(.custom("Futura-Bold", size: 27)).foregroundStyle(Color.gbLight)
                    Text("ONE-TIME UNLOCK / NO SUBSCRIPTION").font(.custom("Futura-Bold", size: 10)).foregroundStyle(Color.mutedText)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MIDI FILE EXPORT").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.gbGlow)
                        Text("WAV AUDIO RENDER").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.gbGlow)
                        Text("UNLOCKED FOREVER").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.gbGlow)
                    }
                    .padding(16)
                    .background(Color.gbDeep)
                    .overlay(Rectangle().stroke(Color.gbMid, lineWidth: 2))
                    Text("PROJECT FILES STAY FREE — YOUR TRACKS ALWAYS REOPEN IN THE POCKET")
                        .font(.custom("Futura-Medium", size: 8))
                        .foregroundStyle(Color.mutedText)
                        .multilineTextAlignment(.center)
                    if storeKit.hasReceiptEntitlement {
                        Text("EXPORT PACK LOADED").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.gbGlow)
                    } else {
                        // Entitlement is the only gate; a stray .purchased status with no
                        // receipt must never claim the unlock.
                        switch storeKit.status {
                        case .available(let product): PixelButton("UNLOCK / \(product.displayPrice)", systemImage: "lock.open", accent: .amber) { Task { if await storeKit.purchase() { store.setUnlocked(true); dismiss() } } }
                            .accessibilityIdentifier("exportPaywall.unlockButton")
                        case .loading: Text("CONNECTING TO CART…").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.mutedText)
                        case .failed:
                            Text("STORE UNAVAILABLE — CHECK YOUR CONNECTION").font(.custom("Futura-Bold", size: 10)).foregroundStyle(Color.mutedText)
                            PixelButton("TRY AGAIN", systemImage: "arrow.clockwise", accent: .amber) { Task { await storeKit.load() } }
                        case .purchased: Text("CONNECTING TO CART…").font(.custom("Futura-Bold", size: 11)).foregroundStyle(Color.mutedText)
                        }
                    }
                    Button("RESTORE PURCHASES") { Task { if await storeKit.restore() { store.setUnlocked(true); dismiss() } } }
                        .font(.custom("Futura-Bold", size: 10))
                        .foregroundStyle(Color.gbLight)
                        .accessibilityIdentifier("exportPaywall.restoreButton")
                    Spacer()
                }
                .padding(22)
            }
            .navigationTitle("EXPORT PACK")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("CLOSE") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
