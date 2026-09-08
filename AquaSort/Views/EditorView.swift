import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(GameStore.self) private var store
    @State private var audio = ByteAudioEngine()
    @State private var page = 0
    @State private var currentStep = -1
    @State private var currentSongSlot = -1
    @State private var pendingPatternID: UUID?
    @State private var pendingPage: Int?
    @State private var patternDragStartIndex: Int?
    @State private var lastPatternDragIndex: Int?
    @State private var noteLinkSourceStep: Int?
    @State private var showLibrary = false
    @State private var showExport = false
    @State private var showImport = false
    @State private var showPatternRename = false
    @State private var patternRenameText = ""
    @State private var patternRenameID: UUID?
    @State private var playbackRefreshTask: Task<Void, Never>?
    @State private var scrubbedSongSlot: Int?
    @State private var songArrangementPage = 0

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
            GeometryReader { proxy in
                ArcadeShell {
                    VStack(spacing: 0) {
                        ScrollView(.vertical, showsIndicators: false) {
                            restoredPageContent
                                .frame(maxWidth: .infinity, alignment: .top)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 18)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)

                        restoredPageSwitcher
                            .padding(.horizontal, 5)
                            .padding(.top, 8)
                            .padding(.bottom, max(6, proxy.safeAreaInsets.bottom))
                            .background(Color.plastic.opacity(0.98))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, max(6, proxy.safeAreaInsets.top))
                .padding(.bottom, 0)
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.amber)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gbInk, lineWidth: 2))
                        .padding(.bottom, 78)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showLibrary) { ProjectLibraryView() }
        .sheet(isPresented: $showExport) { ExportView(useSongArrangement: page == 3) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.bytePocketProject, .json, .bytePocketMIDI]) { importFile($0) }
        .alert("RENAME PATTERN", isPresented: $showPatternRename) {
            TextField("PATTERN NAME", text: $patternRenameText)
            Button("SAVE") {
                if let patternRenameID { store.renamePattern(patternRenameID, name: patternRenameText); requestPlaybackRefresh() }
            }
            Button("CANCEL", role: .cancel) {}
        } message: { Text("Name this pattern for Beatpad and Song Mode.") }
        .onDisappear { playbackRefreshTask?.cancel(); audio.stop() }
    }

    @ViewBuilder
    private var restoredPageContent: some View {
        if page == 0 { restoredBeatpadPage }
        else if page == 1 { restoredSoundLabPage }
        else if page == 2 { restoredFXPage }
        else { restoredSongPage }
    }

    private var restoredHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Image("beatboi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 32, alignment: .leading)
                        .accessibilityLabel("BEATBOI")
                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.isPlaying ? Color.arcadeRed : Color.gbGlow)
                            .frame(width: 6, height: 6)
                        Text(store.isPlaying ? "SEQUENCER LIVE" : "SEQUENCER READY")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.mutedText)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .black))
                    Text(pageTitle)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
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
                    .font(.system(size: 8, weight: .black, design: .monospaced))
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
                    RestoredHeaderIcon(systemImage: "folder.fill") { showLibrary = true }
                    RestoredHeaderIcon(systemImage: "square.and.arrow.up") { showExport = true }
                }
            }
        }
        .padding(10)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.92), Color.hardwareBlack.opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.plasticHighlight.opacity(0.8), lineWidth: 1))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.amber.opacity(0.72)).frame(height: 2).padding(.horizontal, 10) }
    }

    private var restoredBeatpadPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "PERFORMANCE", detail: "16 STEP / LIVE") {
                VStack(spacing: 9) {
                    restoredTransport
                    restoredPatternActions
                }
            }
            restoredVoicing
            // The mixer cards are the Beatpad channel selectors. Tapping a card selects
            // its pad row; swiping horizontally on that same card changes its volume.
            restoredChannelMixer
            restoredPadEditor
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var restoredSoundLabPage: some View {
        VStack(spacing: 10) {
            restoredHeader
            HardwareSection(title: "SOUND LAB", detail: "SELECT A PART TO EDIT") {
                VStack(spacing: 9) {
                    restoredTransport
                    restoredPatternActions
                    restoredChannelTabs
                }
            }
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
                VStack(spacing: 9) {
                    restoredTransport
                    restoredPatternActions
                }
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
                    restoredTransport
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
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbLight)
                Spacer()
                Text(arrangementReadoutSlot.map { "BAR \(String(format: "%02d", $0 + 1)) / \(store.songArrangementLength)" } ?? "BAR — / \(store.songArrangementLength)")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
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
                        if let scrubbedSongSlot {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
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
                            let totalBars = CGFloat(max(1, store.songArrangementLength))
                            let stepProgress = CGFloat(max(0, min(15, currentStep))) / 16.0
                            let playheadX = proxy.size.width * (CGFloat(currentSongSlot) + stepProgress + 0.5) / totalBars
                            Capsule()
                                .fill(Color.gbLight)
                                .frame(width: 3, height: 27)
                                .position(x: min(proxy.size.width - 2, max(2, playheadX)), y: 11)
                                .shadow(color: Color.gbLight.opacity(0.95), radius: 5)
                                .animation(.linear(duration: 0.08), value: currentStep)
                                .animation(.easeOut(duration: 0.12), value: currentSongSlot)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        scrubSongTimeline(at: gesture.location.x, width: proxy.size.width)
                    }.onEnded { gesture in
                        scrubSongTimeline(at: gesture.location.x, width: proxy.size.width, commit: true)
                    })
                }
                .frame(height: 22)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.gbLight)
                    .frame(width: 5, height: 5)
                    .shadow(color: Color.gbLight.opacity(0.9), radius: 3)
                Text("PLAYHEAD")
                    .font(.system(size: 6, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbLight)
                Text("·")
                    .foregroundStyle(Color.mutedText)
                Text("OUTLINE = SELECTED BAR")
                    .font(.system(size: 6, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.mutedText)
                Spacer(minLength: 0)
            }
            Text("DRAG THE TIMELINE TO AUDITION A BAR  ·  ACTIVE PATTERN COLOR MATCHES BELOW")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .foregroundStyle(Color.mutedText)
            .animation(.easeOut(duration: 0.12), value: currentSongSlot)
            .accessibilityHidden(true)
        }
        .padding(10)
        .background(Color.hardwareBlack.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.plasticHighlight.opacity(0.6), lineWidth: 1))
    }

    private var songArrangementPanel: some View {
        LCDPanel(title: "ARRANGEMENT TIMELINE / \(store.songArrangementLength) BARS") {
            VStack(alignment: .leading, spacing: 7) {
                arrangementPageSelector
                HStack(spacing: 5) {
                    Text("LENGTH")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.screenShadow)
                    ForEach([16, 32, 64], id: \.self) { length in
                        Button { setSongArrangementLength(length) } label: {
                            Text("\(length)")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(store.songArrangementLength == length ? Color.gbInk : Color.screenShadow)
                                .frame(minWidth: 38, minHeight: 30)
                                .background(store.songArrangementLength == length ? Color.amber : Color.screenShadow.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.screenShadow.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(length) bar arrangement")
                        .accessibilityAddTraits(store.songArrangementLength == length ? .isSelected : [])
                    }
                    Spacer()
                    Text("TAP ASSIGN · SWIPE ↑↓ CYCLE")
                        .font(.system(size: 6, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.screenShadow)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 7) {
                    ForEach(songArrangementPageStart..<songArrangementPageEnd, id: \.self) { index in
                        RestoredSongPad(index: index, slot: store.songSlot(at: index), pattern: restoredSongPattern(at: index), color: restoredSongColor(at: index), current: index == currentSongSlot) {
                            if store.songSlot(at: index).patternID == nil { store.assignSongPattern(at: index, patternID: store.currentPatternID) } else { store.clearSongSlot(at: index) }
                            requestPlaybackRefresh()
                        } onCycle: { delta in
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
        }
        .padding(5)
        .frame(height: 54)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.98), Color.hardwareBlack.opacity(0.98)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.plasticHighlight.opacity(0.78), lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(Color.plasticHighlight.opacity(0.42)).frame(height: 1).padding(.horizontal, 14) }
        .accessibilityElement(children: .contain)
    }

    private var restoredTransport: some View {
        LCDPanel(title: "TRANSPORT / \(store.project.name)") {
            HStack(spacing: 9) {
                Button { togglePlayback() } label: {
                    ZStack {
                        Circle().fill(store.isPlaying ? Color.arcadeRed : Color.gbDeep).frame(width: 48, height: 48).overlay(Circle().stroke(Color.gbInk, lineWidth: 2))
                        Image(systemName: store.isPlaying ? "stop.fill" : "play.fill").font(.system(size: 18, weight: .black)).foregroundStyle(Color.gbLight)
                    }
                }
                .buttonStyle(ArcadePressStyle(scale: 0.9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isPlaying ? "PLAYING" : "READY").font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(Color.gbInk)
                    Text("STEP \(String(format: "%02d", max(0, currentStep + 1))) / 16").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.gbInk.opacity(0.62))
                    if page == 3, currentSongSlot >= 0 { Text("BAR \(String(format: "%02d", currentSongSlot + 1))").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundStyle(Color.gbInk.opacity(0.68)) }
                }
                Spacer(minLength: 2)
                RestoredTempoBox(value: store.project.tempo) { value in store.updateTempo(value); requestPlaybackRefresh() }
                if page == 0 { RestoredDiceButton(label: "Randomize melody") { randomizeMelody() } }
                if page == 1 { RestoredDiceButton(label: "Randomize sound") { randomizeSound() } }
            }
        }
    }

    private var restoredPatternActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PATTERN BANK")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.gbLight)
                Spacer()
                Text("\(store.project.patterns.count) / 16")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbGlow)
            }
            restoredPatternSelector
            HStack(spacing: 6) {
                RestoredActionButton(systemImage: "plus.square", label: "New pattern", disabled: store.project.patterns.count >= ByteProject.maximumPatternCount) { store.addPattern(); requestPlaybackRefresh() }
                RestoredActionButton(systemImage: "doc.on.doc", label: "Copy pattern", disabled: store.project.patterns.count >= ByteProject.maximumPatternCount) { store.duplicateCurrentPattern(); requestPlaybackRefresh() }
                RestoredActionButton(systemImage: "trash", label: "Delete pattern", destructive: true, disabled: store.project.patterns.count <= 1) { _ = store.deletePattern(store.currentPatternID); requestPlaybackRefresh() }
                Spacer(minLength: 0)
                Text("HOLD TO RENAME")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.mutedText)
            }
        }
        .padding(11)
        .background(LinearGradient(colors: [Color.plasticRaised.opacity(0.82), Color.hardwareBlack.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.plasticHighlight.opacity(0.7), lineWidth: 1))
    }

    private var restoredPatternSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color.amber)
                Text(selectedPattern.name)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbLight)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("HOLD TO RENAME")
                    .font(.system(size: 6, weight: .black, design: .monospaced))
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
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                Text(pattern.name.replacingOccurrences(of: "PATTERN ", with: "P"))
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
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
        .padding(9)
        .background(Color.hardwareBlack.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.plasticHighlight.opacity(0.72), lineWidth: 1))
    }

    private func restoredPatternColor(index: Int, selected: Bool) -> Color {
        if selected { return Color.amber }
        return Color(hue: Double(index) / 16.0, saturation: 0.68, brightness: 0.72)
    }

    private var restoredVoicing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VOICING")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.mutedText)
            HStack(spacing: 6) {
                RestoredChoiceBox(title: "KEY", value: restoredKeyNames[store.project.key], values: restoredKeyNames, index: store.project.key) { updateVoicing(key: $0) }
                RestoredChoiceBox(title: "MODE", value: store.project.mode.title, values: ByteScaleMode.allCases.map(\.title), index: ByteScaleMode.allCases.firstIndex(of: store.project.mode) ?? 0) { index in updateVoicing(mode: ByteScaleMode.allCases[index]) }
            }
        }
        .padding(10)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.72), Color.hardwareBlack.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.plasticHighlight.opacity(0.55), lineWidth: 1))
    }

    private var restoredChannelTabs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EDIT CHANNEL")
                .font(.system(size: 8, weight: .black, design: .monospaced))
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
                                .font(.system(size: 7, weight: .black, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .foregroundStyle(store.selectedChannel == channel ? Color.gbInk : Color.gbLight.opacity(0.82))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(store.selectedChannel == channel ? Color.amber : restoredChannelAccent(channel).opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(store.selectedChannel == channel ? Color.gbInk : Color.plasticHighlight, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(9)
        .background(Color.plasticRaised.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.plasticHighlight.opacity(0.55), lineWidth: 1))
    }

    private var restoredChannelMixer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHANNEL MIXER")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.gbLight)
                    Text("TAP TO EDIT  ·  SWIPE ↔ TO MIX")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.mutedText)
                }
                Spacer()
                Text("MASTER")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbGlow)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(ByteChannel.allCases) { channel in
                    RestoredChannelFader(channel: channel, accent: restoredChannelAccent(channel), volume: store.channelVolumePercent(channel), selected: store.selectedChannel == channel, muted: store.isChannelMuted(channel), soloed: store.isChannelSoloed(channel), onSelect: { store.selectedChannel = channel; store.selectedStep = nil }, onChange: { value in store.setChannelVolume(channel: channel, percent: value); requestPlaybackRefresh() }, onToggleMute: { store.toggleChannelMute(channel); requestPlaybackRefresh() }, onToggleSolo: { store.toggleChannelSolo(channel); requestPlaybackRefresh() })
                }
            }
        }
        .padding(9)
        .background(
            LinearGradient(colors: [Color.plasticRaised.opacity(0.74), Color.hardwareBlack.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.plasticHighlight.opacity(0.68), lineWidth: 1))
    }

    private var restoredPadEditor: some View {
        LCDPanel(title: "\(store.selectedChannel.title) / 16 STEP LOOP") {
            VStack(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(0..<16, id: \.self) { step in
                        RestoredNotePad(step: step, note: selectedChannelNotes[step], length: store.noteLength(channel: store.selectedChannel, step: step), covered: store.isStepCovered(channel: store.selectedChannel, step: step), channel: store.selectedChannel, accent: restoredChannelAccent(store.selectedChannel), current: step == currentStep, linkSource: noteLinkSourceStep == step, linkArmed: noteLinkSourceStep != nil && noteLinkSourceStep != step, noteName: noteName, drumName: drumName) {
                            if let source = noteLinkSourceStep, source != step, step > source {
                                store.setNoteLength(channel: store.selectedChannel, step: source, length: step - source)
                                noteLinkSourceStep = nil
                                store.presentToast("NOTE LINKED TO STEP \(step + 1)")
                            } else { toggleStepAndRefresh(channel: store.selectedChannel, step: step) }
                        } onArmLink: { source in
                            guard store.selectedChannel != .drum else { return }
                            noteLinkSourceStep = source
                            store.presentToast("LINK ARMED / TAP A LATER PAD")
                        } onSetNote: { note in store.setNote(channel: store.selectedChannel, step: step, note: note); requestPlaybackRefresh() } onSetDrum: { voice in store.setDrumVoice(step: step, voice: voice); requestPlaybackRefresh() }
                    }
                }
                Text(store.selectedChannel == .drum ? "TAP: KICK ON / OFF  •  DRAG UP/DOWN: CHANGE VOICE" : (noteLinkSourceStep == nil ? "TAP: ON / OFF  •  HOLD: ARM LINK  •  DRAG UP/DOWN: PITCH" : "LINK ARMED  •  TAP A PAD TO SET THE NOTE END"))
                    .font(.system(size: 7, weight: .black, design: .monospaced)).foregroundStyle(Color.gbInk.opacity(0.62)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var restoredSoundLab: some View {
        VStack(spacing: 10) {
            soundLabReadout
            if store.selectedChannel == .drum {
                RestoredDrumEditor(
                    accent: restoredChannelAccent(.drum),
                    patch: store.patch(for: .drum),
                    volume: { store.drumVoiceVolumePercent($0) },
                    onSelectSample: { voice, variant in
                        store.setDrumSample(voice: voice, variant: variant)
                        requestPlaybackRefresh()
                    },
                    onVolumeChange: { voice, percent in
                        store.setDrumVoiceVolume(voice: voice, percent: percent)
                        requestPlaybackRefresh()
                    }
                )
            } else {
                LCDPanel(title: "\(store.selectedChannel.title) / SYNTH PATCH") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("TOUCH PARAMETERS")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.gbInk)
                            Spacer()
                            Text("SELECT + DRAG ↔")
                                .font(.system(size: 7, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.screenShadow)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(restoredParameters(for: store.selectedChannel)) { parameter in
                                RestoredPatchCard(parameter: parameter, patch: store.patch(for: store.selectedChannel), selected: store.selectedPatchParameter[store.selectedChannel] == parameter) {
                                    store.selectedPatchParameter[store.selectedChannel] = parameter
                                } onChange: { delta in
                                    store.adjustSelectedPatch(channel: store.selectedChannel, parameter: parameter, delta: delta)
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
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbLight)
                Text(store.selectedChannel == .drum ? "RHYTHM VOICES / SAMPLE + MIX" : "SYNTH PATCH / TOUCH TO SELECT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.mutedText)
                Text("DRAG HORIZONTAL TO CHANGE THE SELECTED CONTROL")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbGlow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(LinearGradient(colors: [Color.plasticRaised.opacity(0.88), Color.hardwareBlack.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(restoredChannelAccent(store.selectedChannel).opacity(0.72), lineWidth: 1))
    }

    private var fxStation: some View {
        LCDPanel(title: "FX STATION / HARDWARE-INSPIRED") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("EFFECT BUS")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                    Spacer()
                    Text("GLOBAL")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.screenShadow)
                }
                ForEach(ByteEffect.allCases) { effect in
                    RestoredAmountCard(title: effect.title, amount: store.effectAmount(effect)) { store.setEffectAmount(effect, amount: $0); requestPlaybackRefresh() }
                }
                Rectangle()
                    .fill(Color.screenShadow.opacity(0.32))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                HStack {
                    Text("CHANNEL SENDS / PULSE 1 · PULSE 2 · TRIANGLE · DRUM")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .foregroundStyle(Color.gbInk)
                    Spacer()
                    Text("0% DRY / 100% WET")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.screenShadow)
                }
                ForEach(ByteChannel.allCases) { channel in
                    RestoredAmountCard(title: "FX SEND / \(channel == .pulseA ? "PULSE 1" : channel == .pulseB ? "PULSE 2" : channel.title)", amount: store.effectSendPercent(channel)) { store.setEffectSend(channel: channel, percent: $0); requestPlaybackRefresh() }
                }
            }
        }
    }

    private func restoredParameters(for channel: ByteChannel) -> [BytePatchParameter] {
        switch channel {
        case .pulseA, .pulseB: return [.duty, .octave, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoCycleLength, .vibratoDepth, .vibratoDelay, .bendRange]
        case .wave: return [.waveShape, .waveFilter, .waveEnvelope, .octave, .envelopeAttack, .envelopeDecay, .envelopeSustain, .envelopeRelease, .portamento, .portamentoTime, .vibratoDepth, .bendRange]
        case .drum: return [.volume, .envelope, .tremolo, .panLeft, .panRight]
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
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(Color.screenShadow)
            ForEach(0..<4, id: \.self) { pageIndex in
                let start = pageIndex * 16
                let end = start + 16
                Button {
                    songArrangementPage = pageIndex
                } label: {
                    VStack(spacing: 1) {
                        Text(["A", "B", "C", "D"][pageIndex])
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                        Text("\(start + 1)-\(end)")
                            .font(.system(size: 5, weight: .black, design: .monospaced))
                    }
                    .foregroundStyle(songArrangementPage == pageIndex ? Color.gbInk : Color.screenShadow)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(songArrangementPage == pageIndex ? Color.amber : Color.screenShadow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.screenShadow.opacity(0.55), lineWidth: 1))
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
        store.isPlaying = true
        audio.play(project: store.project, patterns: store.songPlaybackPatterns, useSongArrangement: true, startSongSlot: slot) { step, songSlot in
            Task { @MainActor in
                currentStep = step
                currentSongSlot = songSlot
                if songSlot >= 0 { songArrangementPage = min(3, songSlot / 16) }
                scrubbedSongSlot = songSlot >= 0 ? songSlot : scrubbedSongSlot
            }
        }
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
    private func randomizeMelody() { guard store.randomizeSelectedMelody() else { store.presentToast("SELECT A MELODIC CHANNEL"); return }; requestPlaybackRefresh() }
    private func randomizeSound() { guard store.randomizeSelectedPatch() else { store.presentToast("SELECT A MELODIC CHANNEL"); return }; requestPlaybackRefresh() }

    private func requestPatternSelection(_ id: UUID) {
        guard id != store.currentPatternID else { return }
        if store.isPlaying { pendingPatternID = id; store.presentToast("PATTERN SWITCH QUEUED / END OF LOOP") }
        else { store.selectPattern(id); requestPlaybackRefresh() }
    }
    private func beginPatternRename(_ pattern: BytePattern) { patternRenameID = pattern.id; patternRenameText = pattern.name; showPatternRename = true }
    private func setPage(_ newPage: Int) {
        guard newPage != page else { return }
        if store.isPlaying { pendingPage = newPage; store.presentToast("PAGE SWITCH QUEUED / END OF LOOP") }
        else { applyPageNow(newPage) }
    }
    private func applyPageNow(_ newPage: Int) {
        page = newPage
        if store.isPlaying { audio.update(project: store.project, patterns: newPage == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: newPage == 3) }
        if newPage != 3 { currentSongSlot = -1 }
    }
    private func requestPlaybackRefresh() {
        guard store.isPlaying else { return }
        audio.update(project: store.project, patterns: page == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: page == 3)
    }
    private func togglePlayback() {
        playbackRefreshTask?.cancel()
        if store.isPlaying { pendingPatternID = nil; pendingPage = nil; store.stopPlayback(); audio.stop(); return }
        store.isPlaying = true
        audio.play(project: store.project, patterns: page == 3 ? store.songPlaybackPatterns : [selectedPattern], useSongArrangement: page == 3, startSongSlot: page == 3 ? scrubbedSongSlot : nil) { step, slot in
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
        if url.pathExtension.lowercased() == "mid", let imported = ByteMIDI.importIntoProject(data, project: store.project) { store.importProject(imported); store.presentToast("MIDI IMPORTED") }
        else if let imported = try? JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data) { store.importProject(imported); store.presentToast("PROJECT OPENED") }
        else { store.presentToast("UNKNOWN FILE") }
    }
}

private struct RestoredHeaderIcon: View {
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color.gbLight)
                .frame(width: 44, height: 44)
                .background(Color.plasticRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.plasticHighlight, lineWidth: 1))
        }
        .buttonStyle(ArcadePressStyle())
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
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.plasticHighlight.opacity(disabled ? 0.28 : 0.8), lineWidth: 1))
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
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(selected ? Color.gbInk : Color.gbLight.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(selected ? Color.amber : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Color.gbInk : Color.plasticHighlight.opacity(0.45), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(ArcadePressStyle())
    }
}

private struct RestoredDiceButton: View {
    let label: String
    let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: "dice.fill").font(.system(size: 20, weight: .black)).foregroundStyle(Color.gbInk).frame(width: 52, height: 48).background(LinearGradient(colors: [Color.amber, Color.linkedOrange.opacity(0.8)], startPoint: .top, endPoint: .bottom)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gbInk, lineWidth: 2)) }.buttonStyle(ArcadePressStyle(scale: 0.88)).accessibilityLabel(label) }
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
    var body: some View { VStack(spacing: 1) { Text("BPM").font(.system(size: 8, weight: .black, design: .monospaced)); Text("\(value)").font(.system(size: 14, weight: .black, design: .monospaced)) }.foregroundStyle(Color.gbInk).frame(width: 66, height: 46).background(Color.amber).overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2)).gesture(DragGesture(minimumDistance: 0).onChanged { gesture in if start == nil { start = value }; let proposed = restoredBound((start ?? value) + Int((gesture.translation.width / 8).rounded()) + Int((-gesture.translation.height / 8).rounded()), 60, 240); if proposed != last { last = proposed; onChange(proposed) } }.onEnded { _ in start = nil; last = nil }) }
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
    var body: some View { HStack(spacing: 4) { VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 8, weight: .black, design: .monospaced)); Text(value).font(.system(size: 9, weight: .black, design: .monospaced)).lineLimit(1) }; Spacer(); Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .black)) }.foregroundStyle(Color.gbInk).padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 44).background(title == "KEY" ? Color.amber : Color.gbGlow).overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2)).gesture(DragGesture(minimumDistance: 0).onChanged { gesture in if start == nil { start = index }; guard !values.isEmpty else { return }; let offset = Int((gesture.translation.width / 20).rounded()); let selected = min(max((start ?? index) + offset, 0), values.count - 1); if selected != last { last = selected; onSelect(selected) } }.onEnded { _ in start = nil; last = nil }) }
}

private struct RestoredChannelFader: View {
    let channel: ByteChannel
    let accent: Color
    let volume: Int
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
                    Text(channel.title)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .opacity(muted ? 0.46 : 1)
                    Spacer(minLength: 2)
                    RestoredMiniMixerButton(title: "M", active: muted, accent: Color.arcadeRed, action: onToggleMute)
                    RestoredMiniMixerButton(title: "S", active: soloed, accent: Color.amber, action: onToggleSolo)
                    Text("\(volume)%")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                }
                .foregroundStyle(Color.gbInk)
                .padding(.horizontal, 4)
            }
            .overlay(Rectangle().stroke(selected ? Color.gbLight : Color.gbInk, lineWidth: selected ? 2 : 1.5))
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
            .accessibilityLabel("\(channel.title) channel")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Tap the channel to edit. Swipe left or right to change volume. Use M to mute or S to solo.")
        }
        .frame(minHeight: 48)
    }

    private var accessibilityValue: String {
        var parts = ["\(volume) percent"]
        if muted { parts.append("muted") }
        if soloed { parts.append("soloed") }
        return parts.joined(separator: ", ")
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
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(active ? Color.gbInk : Color.gbInk.opacity(0.58))
                .frame(width: 22, height: 22)
                .background(active ? accent : Color.gbLight.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.gbInk.opacity(active ? 0.9 : 0.34), lineWidth: active ? 1.5 : 1))
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
                    .font(.system(size: 5, weight: .black, design: .monospaced))
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
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                    Spacer()
                    Circle()
                        .fill(current ? Color.gbLight : Color.gbInk.opacity(0.22))
                        .frame(width: 6, height: 6)
                }
                Text(pattern?.name.replacingOccurrences(of: "PATTERN ", with: "P") ?? "EMPTY")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(pattern == nil ? "TAP TO ASSIGN" : "16 STEP BAR")
                    .font(.system(size: 6, weight: .black, design: .monospaced))
            }
            .foregroundStyle(Color.gbInk)
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: pattern == nil ? [Color.gbDeep.opacity(0.3), Color.gbDeep.opacity(0.16)] : [color, color.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(current ? Color.gbLight : pattern == nil ? Color.plasticHighlight.opacity(0.55) : Color.gbInk.opacity(0.45), lineWidth: current ? 3 : 1.5))
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
    }
}

private struct RestoredNotePad: View {
    let step: Int
    let note: Int?
    let length: Int
    let covered: Bool
    let channel: ByteChannel
    let accent: Color
    let current: Bool
    let linkSource: Bool
    let linkArmed: Bool
    let noteName: (Int) -> String
    let drumName: (Int) -> String
    let onTap: () -> Void
    let onArmLink: (Int) -> Void
    let onSetNote: (Int) -> Void
    let onSetDrum: (Int) -> Void
    @State private var startNote: Int?
    @State private var didDrag = false

    private var padColor: Color {
        guard channel == .drum, let note else {
            return note == nil ? Color.gbDeep.opacity(0.16) : Color.amber
        }
        switch ByteDrumVoice.voice(for: note) {
        case .kick: return .drumKick
        case .snare: return .drumSnare
        case .hiHat: return .drumPerc
        case .perc: return .drumHiHat
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: "%02d", step + 1)).font(.system(size: 9, weight: .black, design: .monospaced))
            Text(note.map(channel == .drum ? drumName : noteName) ?? "—").font(.system(size: 10, weight: .black, design: .monospaced))
            if linkSource { Text("LINK ARMED").font(.system(size: 6, weight: .black, design: .monospaced)) }
            else if linkArmed { Text("TAP TO LINK").font(.system(size: 6, weight: .black, design: .monospaced)) }
            else if note != nil && length > 1 { Text("HOLD \(length)").font(.system(size: 6, weight: .black, design: .monospaced)) }
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
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(linkSource || linkArmed ? Color.arcadeRed : current ? Color.gbLight : Color.gbInk.opacity(0.34), lineWidth: linkSource || current ? 3 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !didDrag else { return }
            onTap()
        }
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if note != nil && channel != .drum { onArmLink(step) }
        })
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { gesture in
                    didDrag = true
                    if channel == .drum {
                        let voice = ByteDrumVoice.voice(horizontal: Int(gesture.translation.width), vertical: Int(gesture.translation.height)).rawValue
                        if voice != ByteDrumVoice.voice(for: note ?? ByteDrumVoice.kick.baseNote).rawValue {
                            onSetDrum(voice)
                        } else if note == nil {
                            onSetDrum(voice)
                        }
                    } else {
                        if startNote == nil { startNote = note ?? channel.defaultNotes[step % channel.defaultNotes.count] }
                        let base = startNote ?? 60
                        let semitones = Int((-gesture.translation.height / 8).rounded())
                        onSetNote(min(96, max(24, base + semitones)))
                    }
                }
                .onEnded { _ in
                    startNote = nil
                    didDrag = false
                }
        )
    }
}

private struct RestoredDrumEditor: View {
    let accent: Color
    let patch: ByteChannelPatch
    let volume: (ByteDrumVoice) -> Int
    let onSelectSample: (ByteDrumVoice, Int) -> Void
    let onVolumeChange: (ByteDrumVoice, Int) -> Void

    var body: some View {
        LCDPanel(title: "DRUM KIT / VOICE MIX · DRUM FADER = MASTER") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("VOICE")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                    Spacer()
                    Text("SAMPLE")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                }
                .foregroundStyle(Color.gbInk.opacity(0.62))
                ForEach(ByteDrumVoice.allCases) { voice in
                    RestoredDrumVoiceRow(
                        voice: voice,
                        accent: accent,
                        sample: patch.drumSamples.indices.contains(voice.rawValue) ? patch.drumSamples[voice.rawValue] : 1,
                        volume: volume(voice),
                        onSelectSample: { onSelectSample(voice, $0) },
                        onVolumeChange: { onVolumeChange(voice, $0) }
                    )
                }
                Text("TAP SAMPLE 1 OR 2. SWIPE LEFT / RIGHT ON A VOICE TO MIX IT. DRAG THE BEAT PAD UP, DOWN, LEFT, OR RIGHT TO CHOOSE KICK, SNARE, PERC, OR HI-HAT.")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbInk.opacity(0.68))
            }
        }
    }
}

private struct RestoredDrumVoiceRow: View {
    let voice: ByteDrumVoice
    let accent: Color
    let sample: Int
    let volume: Int
    let onSelectSample: (Int) -> Void
    let onVolumeChange: (Int) -> Void
    @State private var startVolume: Int?
    @State private var lastVolume: Int?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                voiceColor.opacity(0.16)
                voiceColor.opacity(0.72)
                    .animation(.easeOut(duration: 0.12), value: volume)
                    .frame(width: proxy.size.width * CGFloat(volume) / 100.0)
                HStack(spacing: 5) {
                    Text(voice.title)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                    Text("\(volume)%")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                    Spacer(minLength: 2)
                    ForEach(1...2, id: \.self) { variant in
                        Button { onSelectSample(variant) } label: {
                            Text("\(variant)")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
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
            .overlay(Rectangle().stroke(Color.gbInk.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
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
        .accessibilityElement(children: .contain)
    }

    private var voiceColor: Color {
        switch voice {
        case .kick: return .drumKick
        case .snare: return .drumSnare
        case .hiHat: return .drumPerc
        case .perc: return .drumHiHat
        }
    }
}


private struct RestoredPatchCard: View {
    let parameter: BytePatchParameter
    let patch: ByteChannelPatch
    let selected: Bool
    let onSelect: () -> Void
    let onChange: (Int) -> Void
    @State private var lastX: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected ? Color.gbInk : Color.screenShadow.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text(parameter.title)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 2)
                Text(restoredPatchValue)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbInk)
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
            Text("DRAG ↔ TO ADJUST")
                .font(.system(size: 6, weight: .black, design: .monospaced))
                .foregroundStyle(Color.screenShadow.opacity(0.78))
        }
        .padding(9)
        .frame(minHeight: 68)
        .background(selected ? Color.amber : Color.gbDeep.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Color.gbInk : Color.gbInk.opacity(0.3), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .gesture(DragGesture(minimumDistance: 8).onChanged { gesture in
            onSelect()
            let move = gesture.translation.width - lastX
            if abs(move) >= 8 {
                onChange(Int((move / 8).rounded()))
                lastX = gesture.translation.width
            }
        }.onEnded { _ in lastX = 0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parameter.title)
        .accessibilityValue(restoredPatchValue)
        .accessibilityHint("Tap to select. Swipe left or right to adjust.")
    }

    private var restoredPatchValue: String {
        switch parameter {
        case .duty: return ["12.5%", "25%", "50%", "75%"][min(3, max(0, patch.duty))]
        case .octave: return patch.octave >= 0 ? "+\(patch.octave)" : "\(patch.octave)"
        case .volume: return "\(patch.initialVolume)/15"
        case .waveShape: return "\(patch.waveShape)"
        case .waveVolume: return "\(patch.waveVolume)"
        case .envelopeDirection: return patch.envelopeIncrease ? "UP" : "DOWN"
        case .sweepDirection: return patch.sweepIncrease ? "UP" : "DOWN"
        case .panLeft: return patch.panLeft ? "ON" : "OFF"
        case .panRight: return patch.panRight ? "ON" : "OFF"
        case .lengthCounter: return patch.lengthCounter ? "ON" : "OFF"
        default: return "—"
        }
    }

    private var restoredPatchFraction: CGFloat {
        switch parameter {
        case .duty: return CGFloat(min(3, max(0, patch.duty)) + 1) / 4
        case .octave: return CGFloat(min(4, max(0, patch.octave + 2))) / 4
        case .volume: return CGFloat(patch.initialVolume) / 15
        case .waveVolume: return CGFloat(patch.waveVolume) / 3
        default: return selected ? 0.72 : 0.42
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
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text("\(amount)%")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                }
                .foregroundStyle(Color.gbInk)
                .padding(.horizontal, 8)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gbInk.opacity(0.38), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 7).onChanged { gesture in
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


struct LegacyEditorView: View {
    @Environment(GameStore.self) private var store
    @State private var audio = ByteAudioEngine()
    @State private var showLibrary = false
    @State private var showExport = false
    @State private var showPurchase = false
    @State private var showImport = false
    @State private var showProjectExporter = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var currentStep = -1
    @State private var projectDocument = ByteProjectDocument()

    private var selectedPattern: BytePattern {
        store.project.patterns.first(where: { $0.id == store.currentPatternID }) ?? store.project.patterns[0]
    }

    private var selectedChannelNotes: [Int?] {
        let index = ByteChannel.allCases.firstIndex(of: store.selectedChannel) ?? 0
        return selectedPattern.steps[index]
    }

    var body: some View {
        ZStack {
            PocketBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    transport
                    patternPicker
                    channelPicker
                    padEditor
                    effectsPanel
                    actionBar
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.amber)
                        .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
                        .padding(.bottom, 18)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showLibrary) { ProjectLibraryView() }
        .sheet(isPresented: $showExport) { ExportView(useSongArrangement: false) }
        .sheet(isPresented: $showPurchase) { UnlockView() }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.bytePocketProject, .json, .bytePocketMIDI]) { result in
            importFile(result)
        }
        .fileExporter(isPresented: $showProjectExporter, document: projectDocument, contentTypes: [.bytePocketProject], defaultFilename: store.project.name.lowercased()) { _ in }
        .alert("RENAME QUEST", isPresented: $showRename) {
            TextField("PROJECT NAME", text: $renameText)
            Button("SAVE") { store.renameProject(renameText) }
            Button("CANCEL", role: .cancel) {}
        } message: { Text("Give this run a memorable name.") }
        .onDisappear { audio.stop() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Image("beatboi")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 122, height: 26, alignment: .leading)
                    .accessibilityLabel("BEATBOI")
                Text("BEATPAD / 4-CHANNEL DMG")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.mutedText)
            }
            Spacer()
            HeaderIcon(systemImage: "folder.fill") { showLibrary = true }
        }
    }

    private var transport: some View {
        LCDPanel(title: "TRANSPORT / \(store.project.name)") {
            HStack(spacing: 11) {
                Button { togglePlayback() } label: {
                    Image(systemName: store.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(Color.gbLight)
                        .frame(width: 54, height: 50)
                        .background(Color.gbInk)
                        .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isPlaying ? "PLAYING" : "READY")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                    Text("STEP \(String(format: "%02d", max(0, currentStep + 1))) / 16")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.gbInk.opacity(0.62))
                }
                Spacer(minLength: 4)
                TempoBox(value: store.project.tempo) { value in store.updateTempo(value) }
            }
        }
    }

    private var patternPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SONG PATTERNS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbLight)
                Spacer()
                Text("16 MAX")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbGlow)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.project.patterns) { pattern in
                        Button {
                            store.selectPattern(pattern.id)
                            store.presentToast("\(pattern.name) READY")
                        } label: {
                            Text(pattern.name)
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.gbInk)
                                .frame(width: 92, height: 42)
                                .background(pattern.id == store.currentPatternID ? Color.amber : Color.gbLight)
                                .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var channelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHANNELS / VOLUME")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(Color.gbLight)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ByteChannel.allCases) { channel in
                    Button {
                        store.selectedChannel = channel
                        store.selectedStep = nil
                    } label: {
                        HStack {
                            Text(channel.title)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                            Spacer()
                            Text("\(store.channelVolumePercent(channel))%")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                        }
                        .foregroundStyle(Color.gbInk)
                        .padding(10)
                        .background(store.selectedChannel == channel ? Color.amber : Color.gbLight)
                        .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                        let delta = Int((value.translation.width / 4).rounded())
                        store.setChannelVolume(channel: channel, percent: store.channelVolumePercent(channel) + delta)
                    })
                }
            }
        }
    }

    private var padEditor: some View {
        LCDPanel(title: "\(store.selectedChannel.title) / 16 STEP LOOP") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                ForEach(0..<16, id: \.self) { step in
                    let note = selectedChannelNotes[step]
                    Button {
                        store.toggleStep(channel: store.selectedChannel, step: step)
                    } label: {
                        VStack(spacing: 4) {
                            Text(String(format: "%02d", step + 1))
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                            Text(note.map(noteName) ?? "—")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                        }
                        .foregroundStyle(note == nil ? Color.gbInk.opacity(0.46) : Color.gbInk)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(note == nil ? Color.gbDeep.opacity(0.16) : Color.amber)
                        .overlay(Rectangle().stroke(step == currentStep ? Color.gbInk : Color.gbInk.opacity(0.34), lineWidth: step == currentStep ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var effectsPanel: some View {
        LCDPanel(title: "FX STATION") {
            VStack(alignment: .leading, spacing: 8) {
                Text("GAME BOY-STYLE TRACKER EFFECTS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.gbInk)
                ForEach(ByteEffect.allCases) { effect in
                    Text(effect.title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbInk)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            PixelButton("IMPORT", systemImage: "square.and.arrow.down", accent: .gbLight) { showImport = true }
            PixelButton("EXPORT", systemImage: "square.and.arrow.up", accent: .amber) { showExport = true }
        }
    }

    private var footer: some View {
        Text("4 CHANNELS / LOCAL PROJECT / NO ADS")
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(Color.mutedText)
    }

    private func togglePlayback() {
        if store.isPlaying {
            store.stopPlayback()
            audio.stop()
        } else {
            store.isPlaying = true
            audio.play(project: store.project, patterns: [selectedPattern]) { step, _ in
                Task { @MainActor in currentStep = step }
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let data = try? Data(contentsOf: url) else {
            store.presentToast("IMPORT FAILED")
            return
        }
        if url.pathExtension.lowercased() == "mid", let imported = ByteMIDI.importIntoProject(data, project: store.project) {
            store.importProject(imported)
            store.presentToast("MIDI IMPORTED")
        } else if let imported = try? JSONDecoder.bytePocketDecoder.decode(ByteProject.self, from: data) {
            store.importProject(imported)
            store.presentToast("PROJECT OPENED")
        } else {
            store.presentToast("UNKNOWN FILE")
        }
    }

    private func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[(midi % 12 + 12) % 12])\(midi / 12 - 1)"
    }
}

private struct HeaderIcon: View {
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color.gbLight)
                .frame(width: 42, height: 38)
                .background(Color.plasticRaised)
                .overlay(Rectangle().stroke(Color.gbMid, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

private struct TempoBox: View {
    let value: Int
    let onChange: (Int) -> Void
    @State private var startValue: Int?
    @State private var lastValue: Int?

    var body: some View {
        VStack(spacing: 1) {
            Text("BPM")
                .font(.system(size: 8, weight: .black, design: .monospaced))
            Text("\(value)")
                .font(.system(size: 14, weight: .black, design: .monospaced))
        }
        .foregroundStyle(Color.gbInk)
        .frame(width: 72, height: 50)
        .background(Color.amber)
        .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if startValue == nil { startValue = self.value }
            let proposed = min(240, max(60, startValue! + Int((-value.translation.height / 8).rounded())))
            if proposed != lastValue { lastValue = proposed; onChange(proposed) }
        }.onEnded { _ in startValue = nil; lastValue = nil })
    }
}

struct ProjectLibraryView: View {
    @Environment(GameStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                List {
                    Section {
                        ForEach(store.projects) { project in
                            Button { store.selectProject(project); dismiss() } label: {
                                HStack {
                                    Image(systemName: project.id == store.project.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(project.id == store.project.id ? Color.amber : Color.gbLight)
                                    VStack(alignment: .leading) {
                                        Text(project.name).font(.system(size: 14, weight: .black, design: .monospaced))
                                        Text("\(project.patterns.count) PATTERN\(project.patterns.count == 1 ? "" : "S") · \(project.tempo) BPM")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.mutedText)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .onDelete { offsets in offsets.forEach { store.deleteProject(store.projects[$0]) } }
                    }
                    Section { Button { store.newProject(); dismiss() } label: { Label("NEW PROJECT", systemImage: "plus.square.fill") } }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.gbLight)
            }
            .navigationTitle("PROJECT CART")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("DONE") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct ExportView: View {
    @Environment(GameStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let useSongArrangement: Bool
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
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbLight)
                        .multilineTextAlignment(.center)
                    exportButton("PROJECT FILE", "EDITABLE / REOPEN ANYTIME", "doc.fill") { projectDocument = store.projectDocument(); showProjectExporter = true }
                    exportButton("MIDI FILE", "4 CHANNELS / NOTE DATA", "pianokeys") { midiDocument = ByteMIDIDocument(data: ByteMIDI.export(project: store.project, patterns: useSongArrangement ? store.songPlaybackPatterns : store.project.arrangedPatterns)); showMIDIExporter = true }
                    exportButton("WAV AUDIO", "SYNTHESIZED / 44.1 KHZ", "waveform") { startWaveExport() }
                    if isRenderingWave { renderProgressView }
                    Spacer()
                }
                .padding(22)
            }
            .navigationTitle("EXPORT")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("DONE") { dismiss() }.disabled(isRenderingWave) } }
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
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(Color.gbLight)
            ProgressView(value: exportProgress).tint(Color.gbGlow)
            Text("SYNTHESIZING EVERY SAMPLE — KEEP THIS WINDOW OPEN")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
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

    private func exportButton(_ title: String, _ detail: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 34)
                VStack(alignment: .leading) { Text(title).font(.system(size: 13, weight: .black, design: .monospaced)); Text(detail).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.mutedText) }
                Spacer(); Image(systemName: "chevron.right")
            }
            .foregroundStyle(Color.gbInk)
            .padding(14)
            .background(Color.gbLight)
            .overlay(Rectangle().stroke(Color.gbInk, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(isRenderingWave)
        .opacity(isRenderingWave ? 0.55 : 1)
    }
}

struct UnlockView: View {
    @Environment(GameStore.self) private var store
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                VStack(spacing: 16) {
                    Text("FX CARTRIDGE").font(.system(size: 27, weight: .black, design: .monospaced)).foregroundStyle(Color.gbLight)
                    Text("OPTIONAL CLASSIC EFFECTS / CORE IS FREE").font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(Color.mutedText)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ECHO").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(Color.gbGlow)
                        Text("BIT CRUSH").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(Color.gbGlow)
                        Text("VIBRATO").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(Color.gbGlow)
                        Text("WIDE PULSE").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(Color.gbGlow)
                    }
                    .padding(16)
                    .background(Color.gbDeep)
                    .overlay(Rectangle().stroke(Color.gbMid, lineWidth: 2))
                    switch storeKit.status {
                    case .available(let product): PixelButton("LOAD FX / \(product.displayPrice)", systemImage: "sparkle", accent: .amber) { Task { if await storeKit.purchase() { store.setUnlocked(true); dismiss() } } }
                    case .purchased: Text("FX CARTRIDGE LOADED").foregroundStyle(Color.gbGlow)
                    default: Text("CONNECTING TO CART…").foregroundStyle(Color.mutedText)
                    }
                    Button("RESTORE PURCHASES") { Task { if await storeKit.restore() { store.setUnlocked(true); dismiss() } } }
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.gbLight)
                    Spacer()
                }
                .padding(22)
            }
            .navigationTitle("OPTIONAL FX")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("CLOSE") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
