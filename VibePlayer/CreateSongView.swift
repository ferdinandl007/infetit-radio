import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import LiquidSongwriting
import UniformTypeIdentifiers
import YuE2Kit

struct CreateSongView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(MusicModelDownload.self) private var modelDownload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var prompt: String
    let openPlayer: () -> Void
    #if os(macOS)
    var desktopHistory: DesktopSongHistory? = nil
    #endif
    @ScaledMetric(relativeTo: .body) private var minimumEditorHeight: CGFloat = 112
    @State private var styles = ""
    @State private var lyrics = ""
    @State private var instrumental = false
    @AppStorage("vibe-create-acoustics") private var preferredInstrumentalAcoustics = ""
    @AppStorage("vibe-create-vocal-acoustics") private var preferredVocalAcoustics = ""
    @AppStorage("vibe-create-length") private var preferredLength = ""
    @AppStorage(RenderingSteps.createPreferenceKey) private var renderingSteps = RenderingSteps.createDefault
    @AppStorage("vibe-create-plan-score") private var planScore = true
    @AppStorage("vibe-create-compact-attention-cache") private var compactAttentionCache = false
    @AppStorage("vibe-create-follow-style-closely") private var followStyleClosely = true
    @AppStorage("vibe-create-clear-lead-vocals") private var clearLeadVocals = false
    @State private var saved = false
    @State private var showSongwritingSettings = false
    @State private var showModelSetup = false
    @State private var showStyles = false
    @State private var showLyrics = false
    @State private var showSamplePicker = false
    @State private var showGeneration = false
    @State private var sampleURL: URL?
    @State private var samplePlayer: AVAudioPlayer?
    @State private var sampleName: String?
    @State private var referenceTask: Task<Void, Never>?
    @State private var melody: MelodyReference?
    #if os(macOS)
    @State private var showMelody = false
    #endif
    @State private var catalog: AppleMusicQuery?
    @State private var polishingPrompt = false
    @State private var promptPolishTask: Task<Void, Never>?
    @State private var promptError: String?
    @FocusState private var promptFocused: Bool

    private var accent: Color {
        #if os(macOS)
        if desktopHistory != nil { return DesktopColors.accent }
        #endif
        return Color(red: 0.85, green: 0.79, blue: 1)
    }
    private var backgroundColor: Color {
        #if os(macOS)
        if desktopHistory != nil { return .clear }
        #endif
        return Color(red: 0.045, green: 0.045, blue: 0.055)
    }
    private var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var catalogQuery: AppleMusicQuery? {
        guard melody == nil, player.remixSource == nil, sampleName == nil, styles.isEmpty, lyrics.isEmpty, !instrumental else { return nil }
        return AppleMusicQuery.parse(prompt)
    }
    private var canCreate: Bool { hasPrompt || player.remixSource != nil || melody != nil }
    private var canSubmit: Bool {
        catalogQuery != nil || (player.canGenerate && canCreate && !polishingPrompt && referenceTask == nil &&
                               (sampleName == nil || player.remixSource != nil))
    }
    private var showsPlayback: Bool { player.isPlaying || player.isGenerated || !player.isSample || player.isWaitingForRadio }
    private var acoustics: CreateAcoustics {
        if player.remixSource != nil || melody != nil { return .reference }
        let preference = instrumental ? preferredInstrumentalAcoustics : preferredVocalAcoustics
        return CreateAcoustics.resolve(preference: preference, supportsEarlyPlayback: player.canStreamAcoustics)
    }
    private var canPlanVocalScore: Bool {
        player.canPlanScore && player.remixSource == nil && melody == nil
            && CreateAcoustics.resolve(preference: preferredVocalAcoustics, supportsEarlyPlayback: player.canStreamAcoustics) == .reference
    }
    private var usesCompactAttentionCache: Bool {
        #if os(macOS)
        compactAttentionCache && planScore && canPlanVocalScore && !instrumental
        #else
        false
        #endif
    }
    private var length: CreateLength {
        if let preferred = CreateLength(rawValue: preferredLength), preferred != .extended || player.canCreateExtended {
            return preferred
        }
        #if os(macOS)
        return .fullSong
        #else
        return .automatic
        #endif
    }

    private var maximumReferenceFrames: Int {
        #if os(iOS)
        return min(length.maximumFrames, 4_200) - 250
        #else
        return length.maximumFrames - 250
        #endif
    }

    var body: some View {
        workspace
        .vibeKeyboardDismissal()
        .background(backgroundColor)
        .vibeHideNavigationBar()
        .vibeEditorPresentation(isPresented: $showStyles) { SongTextEditor(kind: .styles, value: $styles, instrumental: $instrumental, idea: prompt, styles: styles) }
        .vibeEditorPresentation(isPresented: $showLyrics) {
            SongTextEditor(kind: .lyrics, value: $lyrics, instrumental: $instrumental, idea: prompt, styles: styles,
                           length: length, clearLeadVocals: clearLeadVocals,
                           showsPromptUsage: !(canPlanVocalScore && planScore))
        }
        .sheet(isPresented: $showModelSetup) { MusicModelSetupView(download: modelDownload) }
        #if os(macOS)
        .sheet(isPresented: $showMelody) {
            MelodyReferenceSheet(reference: melody, canRender: player.canRenderMelody) { reference in
                clearSample()
                melody = reference
            }
        }
        #endif
        .sheet(isPresented: $showSongwritingSettings) {
            #if os(macOS)
            SongwritingSettings().frame(minWidth: 540, minHeight: 480)
            #else
            SongwritingSettings()
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $showGeneration) { generationDetail.frame(minWidth: 520, minHeight: 580) }
        #else
        .fullScreenCover(isPresented: $showGeneration) { generationDetail }
        #endif
        .sheet(item: $catalog) { query in
            AppleMusicResults(query: query, createOriginal: player.canGenerate ? {
                catalog = nil
                enqueue()
            } : nil)
        }
        .fileImporter(isPresented: $showSamplePicker,
                      allowedContentTypes: (MusicReference.canEncodeAudio ? [.audio] : []) + [.json, .commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): loadReference(url)
            case .failure: player.errorMessage = "Couldn't open that reference."
            }
        }
        .onChange(of: prompt) { if !prompt.isEmpty { saved = false } }
        .onChange(of: player.remixSource?.originalAudio, initial: true) {
            if player.remixSource?.originalAudio != nil { melody = nil }
            if let originalLyrics = player.remixSource?.sourceLyrics, !hasPrompt, lyrics.isEmpty {
                lyrics = originalLyrics
                instrumental = originalLyrics.isEmpty
            }
        }
        .alert("Polish prompt", isPresented: Binding(get: { promptError != nil }, set: { if !$0 { promptError = nil } })) { Button("OK", role: .cancel) { promptError = nil } } message: { Text(promptError ?? "") }
        .onChange(of: acoustics, initial: true) {
            if acoustics == .streaming || hasPrompt { prepareRendering() }
        }
        .onChange(of: hasPrompt) {
            if hasPrompt && acoustics == .reference { prepareRendering() }
        }
        .onChange(of: usesCompactAttentionCache) {
            if hasPrompt && acoustics == .reference { prepareRendering() }
        }
        .onChange(of: renderingSteps) {
            if hasPrompt && acoustics == .reference { prepareRendering() }
        }
        .onDisappear { samplePlayer?.stop(); promptPolishTask?.cancel(); polishingPrompt = false }
    }

    @ViewBuilder private var workspace: some View {
        #if os(macOS)
        if let desktopHistory {
            desktopWorkspace(history: desktopHistory)
        } else {
            mobileWorkspace
        }
        #else
        mobileWorkspace
        #endif
    }

    private var mobileWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: geometry.size.height < 450 ? 12 : 18) {
                    header
                    composer(editorHeight: max(minimumEditorHeight, min(208, geometry.size.height * 0.30)))
                    if prompt.isEmpty { suggestions }
                    if saved {
                        Label("Saved to your library", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(accent).accessibilityIdentifier("idea-saved")
                    }
                    if !player.canGenerate {
                        Button("Download the music model") { showModelSetup = true }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dock.frame(maxWidth: 600).padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(red: 0.045, green: 0.045, blue: 0.055)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
            }
        }
    }

    #if os(macOS)
    private func desktopWorkspace(history: DesktopSongHistory) -> some View {
        GeometryReader { geometry in
            let availableWidth = min(geometry.size.width, 1220)
            if availableWidth >= 900 {
                HStack(alignment: .top, spacing: 28) {
                    ScrollView { desktopComposer }
                        .frame(width: min(600, availableWidth * 0.54))
                    ScrollView { history }
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 1220)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        desktopComposer
                        history
                    }
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var desktopComposer: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            composer(editorHeight: 190)
            Button(action: submit) {
                Label(catalogQuery != nil ? "Find on Apple Music" : player.isCreating ? "Queue song" :
                        melody != nil ? "Create cover" : player.remixSource == nil ? "Create song" : "Remix song",
                      systemImage: catalogQuery == nil ? "waveform" : "music.note")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 45)
                    .foregroundStyle(canSubmit ? Color(red: 0.12, green: 0.08, blue: 0.22) : .white.opacity(0.55))
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(canSubmit ? AnyShapeStyle(LinearGradient(colors: [DesktopColors.accent, Color(red: 0.91, green: 0.68, blue: 0.92)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.10)))
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityIdentifier("create-song")
            if hasPrompt && melody == nil {
                Button("Save idea", systemImage: "bookmark") { saveIdea() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DesktopColors.accent)
            }
            if prompt.isEmpty { suggestions }
            if saved {
                Label("Saved to your library", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(DesktopColors.accent).accessibilityIdentifier("idea-saved")
            }
            if !player.canGenerate {
                Button("Download the music model") { showModelSetup = true }
                    .font(.footnote.weight(.semibold))
            }
            if player.isCreating {
                Button("Generation details", systemImage: "arrow.up.right.square") { showGeneration = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("open-generation-progress")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    private var header: some View {
        HStack(spacing: 10) {
            Text("Create").font(.largeTitle.weight(.medium)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Menu {
                if player.canStreamAcoustics && melody == nil {
                    Picker("Rendering", selection: Binding(get: { acoustics }, set: { choice in
                        if instrumental { preferredInstrumentalAcoustics = choice.rawValue }
                        else { preferredVocalAcoustics = choice.rawValue }
                    })) {
                        Text("Early playback").tag(CreateAcoustics.streaming)
                        Text("High quality").tag(CreateAcoustics.reference)
                    }
                }
                Menu("Advanced rendering") {
                Picker("Full-song rendering steps", selection: $renderingSteps) {
                    Text("8 steps (faster)").tag(RenderingSteps.eight)
                    Text("16 steps").tag(RenderingSteps.sixteen)
                    Text("32 steps (highest quality)").tag(RenderingSteps.thirtyTwo)
                }
                if melody == nil {
                    Picker("Song length", selection: Binding(get: { length }, set: { preferredLength = $0.rawValue })) {
                        Text("Automatic").tag(CreateLength.automatic)
                        Text("Full song (2 min or more)").tag(CreateLength.fullSong)
                        if player.canCreateExtended {
                            Text("Extended (3½ min or more)").tag(CreateLength.extended)
                        }
                    }
                }
                Toggle("Follow style closely", isOn: $followStyleClosely)
                if canPlanVocalScore && !instrumental {
                    Toggle("Plan melody and chords", isOn: $planScore)
                    #if os(macOS)
                    if planScore {
                        Toggle("Compact attention cache", isOn: $compactAttentionCache)
                            .help("Uses a smaller cache during melody planning. The same seed can produce a different take.")
                    }
                    #endif
                }
                if !instrumental { Toggle("Clear lead vocals", isOn: $clearLeadVocals) }
                }
                #if !os(macOS)
                Button("Save idea", systemImage: "bookmark") { saveIdea() }.disabled(!canCreate)
                #endif
                Button("Songwriting settings", systemImage: "key") { showSongwritingSettings = true }
            } label: {
                HStack(spacing: 7) {
                    #if os(macOS)
                    Image(systemName: "slider.horizontal.3")
                    Text("Song options")
                    #else
                    Image(systemName: "cpu")
                    Text("Metal")
                    #endif
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(player.canGenerate ? accent : .white.opacity(0.65))
                .padding(.horizontal, 13).frame(minHeight: 44)
                #if os(macOS)
                .desktopGlass(in: Capsule(), interactive: true)
                #else
                .background(.white.opacity(0.07), in: Capsule())
                #endif
            }
            .accessibilityLabel("Create options")
            .accessibilityValue(player.canGenerate ? (acoustics == .streaming ? "Early playback" : "High quality, \(renderingSteps.rawValue) steps") : "Music model unavailable")
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
        }
    }

    private func composer(editorHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Song idea").font(.subheadline.weight(.semibold))
                Spacer()
                Button { polishPrompt() } label: {
                    Image(systemName: polishingPrompt ? "sparkles" : "wand.and.stars")
                        .foregroundStyle(accent).frame(width: 44, height: 44)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(polishingPrompt || !hasPrompt)
                .accessibilityLabel(polishingPrompt ? "Polishing prompt" : "Polish prompt")
                .accessibilityIdentifier("polish-prompt")
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(melody == nil ? "Describe a song, a feeling, or an idea…" : "Describe the new arrangement…")
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.horizontal, 3).padding(.vertical, 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: $prompt).focused($promptFocused).scrollContentBackground(.hidden)
                    .padding(.horizontal, -4).frame(height: editorHeight)
                    .accessibilityLabel("Describe your song").accessibilityIdentifier("song-prompt")
            }
            FlowLayout(spacing: 7) {
                Button { promptFocused = false; showStyles = true } label: {
                    composerChip("Styles", symbol: "music.note", selected: !styles.isEmpty)
                }.accessibilityIdentifier("edit-styles")
                Button { promptFocused = false; showLyrics = true } label: {
                    composerChip("Lyrics", symbol: "text.alignleft", selected: !lyrics.isEmpty || instrumental)
                }.accessibilityIdentifier("edit-lyrics")
                Button { promptFocused = false; showSamplePicker = true } label: {
                    composerChip("Reference", symbol: "waveform", selected: player.remixSource != nil || referenceTask != nil)
                }.accessibilityIdentifier("add-sample")
                #if os(macOS)
                Button { promptFocused = false; showMelody = true } label: {
                    composerChip("Melody", symbol: "music.note.list", selected: melody != nil)
                }.accessibilityIdentifier("add-melody")
                #endif
            }.buttonStyle(.plain)
            if let melody {
                HStack {
                    Label(melody.title, systemImage: "music.note.list").lineLimit(1)
                    Spacer(minLength: 0)
                    Button { self.melody = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Remove melody")
                }
                .font(.subheadline).buttonStyle(.plain).padding(.leading, 12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            } else if let title = player.remixSource?.title ?? sampleName {
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let reference = player.remixSource {
                            let upper = max(50, min(reference.tokens.count, maximumReferenceFrames))
                            let opening = Binding(get: { min(reference.openingFrames, upper) },
                                                  set: { player.remixSource?.openingFrames = $0 })
                            Stepper(value: opening, in: 50...upper, step: 25) {
                                Text("\(reference.originalAudio != nil ? "Keep" : "Use") first \(opening.wrappedValue / 25) sec")
                            }.font(.caption)
                        } else {
                            Text(referenceTask == nil ? "Reference unavailable" : "Listening to reference…")
                                .font(.caption).foregroundStyle(.white.opacity(0.67))
                        }
                    }
                    Spacer(minLength: 0)
                    if samplePlayer != nil {
                        Button { playSample() } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }.accessibilityLabel("Play reference")
                    }
                    Button { clearSample() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Remove reference")
                }
                .padding(.leading, 12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.24)).frame(height: 1)
        }
        #else
        .background {
            RoundedRectangle(cornerRadius: 24).fill(.linearGradient(
                colors: [Color(red: 0.105, green: 0.10, blue: 0.16), Color(red: 0.065, green: 0.066, blue: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        #endif
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["A hazy late-night drive", "Warm piano on a rainy day", "An upbeat summer anthem"], id: \.self) { example in
                    Button(example) { prompt = example }
                        .font(.footnote.weight(.medium)).padding(.horizontal, 13).frame(minHeight: 44)
                        .background(.white.opacity(0.06), in: Capsule())
                }
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var dock: some View {
        if player.isCreating {
            let status = player.isBufferingPreview ? "Buffering more audio…" : player.isPlayingPreview ? "Playing · still generating" : player.creationStatus
            let progress = player.generationProgress
            HStack(spacing: 7) {
                Button {
                    promptFocused = false
                    showGeneration = true
                } label: {
                    HStack(spacing: 9) {
                        SongStageDial(phase: min(2, generationPhase))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.activeCreation?.title ?? "Creating song").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(status).font(.caption).foregroundStyle(.white.opacity(0.76)).lineLimit(2)
                                .accessibilityIdentifier("creation-status")
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold))
                            .foregroundStyle(accent).accessibilityHidden(true)
                    }.frame(minHeight: 50).contentShape(Rectangle())
                }
                .accessibilityHint("Opens generation progress and queue")
                .accessibilityIdentifier("open-generation-progress")
                if canCreate {
                    Button(action: submit) {
                        ViewThatFits(in: .horizontal) {
                            Label(catalogQuery == nil ? "Queue" : "Find", systemImage: catalogQuery == nil ? "plus" : "music.note").font(.subheadline.weight(.semibold))
                                .fixedSize().padding(.horizontal, 12)
                            Image(systemName: "plus").font(.body.weight(.bold)).frame(width: 44)
                        }.frame(height: 44).foregroundStyle(.black).background(accent, in: Capsule())
                            .opacity(canSubmit ? 1 : 0.4)
                    }
                    .disabled(!canSubmit).accessibilityLabel("Add to generation queue").accessibilityIdentifier("queue-create-song")
                } else if player.hasCreationPreview { playButton }
                else if !player.queuedCreations.isEmpty {
                    Text("\(player.queuedCreations.count)").font(.caption.weight(.bold)).monospacedDigit()
                        .padding(8).background(.white.opacity(0.08), in: Circle())
                        .accessibilityLabel("\(player.queuedCreations.count) queued")
                }
            }.modifier(DockSurface(progress: progress, reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain).accessibilityIdentifier("create-dock")
        } else if showsPlayback {
            HStack(spacing: 7) {
                Button(action: openPlayer) {
                    HStack(spacing: 8) {
                        if !promptFocused {
                            TrackArtwork(image: player.trackArtwork, palette: player.selected.palette).frame(width: 36, height: 36)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.trackName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if player.duration > 0 {
                                Text("\(time(player.elapsed)) / \(time(player.duration))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityHint("Opens the full player")
                playButton
                Button(action: submit) {
                    Image(systemName: "plus").font(.body.weight(.bold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(accent, in: Circle())
                        .opacity(canSubmit ? 1 : 0.34)
                }
                .disabled(!canSubmit).accessibilityLabel(catalogQuery == nil ? "Create" : "Find on Apple Music").accessibilityIdentifier("create-song")
            }.modifier(DockSurface(progress: player.duration > 0 ? player.elapsed / player.duration : 0, reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain).accessibilityIdentifier("create-dock")
        } else {
            Button(action: submit) {
                Label(catalogQuery == nil ? (melody != nil ? "Create Cover" : (player.remixSource == nil ? "Create" : "Remix")) : "Find on Apple Music",
                      systemImage: catalogQuery == nil ? "waveform" : "music.note")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12).frame(minHeight: 52)
                    .foregroundStyle(canSubmit ? .black : .white.opacity(0.48))
                    .background(canSubmit ? accent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain).disabled(!canSubmit).accessibilityIdentifier("create-song")
        }
    }

    private var generationPhase: Int {
        let progress = player.generationProgress
        return progress >= 0.96 ? 3 : progress >= 0.60 ? 2 : progress >= 0.08 ? 1 : 0
    }

    private var generationDetail: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generation queue").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { showGeneration = false } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: Circle())
                }.accessibilityLabel("Close generation progress")
            }.padding(.horizontal, 20).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    generationHero
                    if let error = player.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Text(error).font(.footnote)
                            Spacer(minLength: 0)
                            Button("Dismiss") { player.errorMessage = nil }.font(.footnote.weight(.semibold))
                        }.foregroundStyle(.orange)
                    }
                    if !player.queuedCreations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Up next").font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(player.queuedCreations) { job in
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform").foregroundStyle(accent)
                                        .frame(width: 44, height: 44).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                                        .accessibilityHidden(true)
                                    Text(job.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Button { player.removeQueuedCreation(job.id) } label: {
                                        Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                                    }.accessibilityLabel("Remove \(job.title) from queue")
                                }.padding(8).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    if let notice = player.creationNotice, player.isCreating {
                        Text(notice).font(.footnote).foregroundStyle(.white.opacity(0.71))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 570)
                    .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showGeneration = false
                } label: {
                    Label("Add another prompt", systemImage: "plus")
                        .font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).frame(minHeight: 50)
                        .background(accent, in: RoundedRectangle(cornerRadius: 20))
                }.frame(maxWidth: 530).padding(.horizontal, 20).padding(.vertical, 7)
                    .frame(maxWidth: .infinity).background(Color(red: 0.045, green: 0.045, blue: 0.055))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .background(Color(red: 0.045, green: 0.045, blue: 0.055).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("generation-progress-screen")
    }

    private var generationHero: some View {
        let title = player.activeCreation?.title ?? player.lastCreatedSong?.title ?? "Create a song"
        let status = player.isCreating
            ? (player.isBufferingPreview ? "Buffering more audio…" : player.isPlayingPreview ? "Playing while rendering" : player.creationStatus)
            : (player.lastCreatedSong == nil ? "Ready for a prompt" : "Saved to Library")
        let fraction = player.isCreating ? player.generationProgress : (player.lastCreatedSong == nil ? 0 : 1)
        return VStack(spacing: 19) {
            GenerationDisc(progress: fraction, phase: generationPhase, active: player.isCreating)
                .aspectRatio(1, contentMode: .fit).frame(maxWidth: 148)
            VStack(spacing: 7) {
                Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                Text(status).font(.subheadline).foregroundStyle(accent).multilineTextAlignment(.center)
                if player.hasCreationPreview {
                    Text("\(time(player.elapsed)) played · \(time(player.creationBufferedDuration)) decoded")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.68))
                }
            }
            if player.isCreating {
                HStack(spacing: 12) {
                    if player.hasCreationPreview { playButton }
                    Button("Cancel render", role: .destructive) { player.cancelCurrentCreation() }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.73)).frame(minHeight: 44)
                        .accessibilityIdentifier("cancel-creation")
                }
            } else if player.lastCreatedSong != nil {
                Button(action: player.toggleLastCreatedSong) {
                    Label(player.isPlayingLastCreatedSong ? "Pause" : "Play song", systemImage: player.isPlayingLastCreatedSong ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                        .background(accent.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 22).frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 29).fill(.linearGradient(
                colors: [Color(red: 0.15, green: 0.12, blue: 0.24), Color(red: 0.072, green: 0.071, blue: 0.106)],
                startPoint: .topTrailing, endPoint: .bottomLeading))
        }
        .overlay { RoundedRectangle(cornerRadius: 29).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false) }
    }

    private var playButton: some View {
        Button { player.togglePlayback() } label: {
            Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
        }.accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
    }

    private func submit() {
        promptFocused = false
        if let catalogQuery { catalog = catalogQuery; return }
        enqueue()
    }

    private func prepareRendering() {
        player.prepareRendering(acoustics, compactAttentionCache: usesCompactAttentionCache,
                                preferFullPrecision: renderingSteps == .thirtyTwo && player.remixSource == nil)
    }

    private func enqueue() {
        var reference = player.remixSource
        if let attached = reference { reference?.openingFrames = min(attached.openingFrames, maximumReferenceFrames) }
        let fallback = melody.map { "Cover of \($0.title)" } ?? "Remix \(reference?.title ?? "the reference")"
        let idea = hasPrompt ? prompt.trimmingCharacters(in: .whitespacesAndNewlines) : fallback
        player.generateSong(idea: idea, instrumental: instrumental,
                            preparedLyrics: instrumental ? nil : lyrics.trimmingCharacters(in: .whitespacesAndNewlines),
                            createStyles: styles, createLength: length, acoustics: acoustics, renderingSteps: renderingSteps,
                            reference: reference,
                            followStyleClosely: followStyleClosely, clearLeadVocals: clearLeadVocals, planScore: planScore,
                            compactAttentionCache: usesCompactAttentionCache, scoreABC: melody?.score.notation)
        prompt = ""; styles = ""; lyrics = ""; instrumental = false; saved = false
        clearSample()
        melody = nil
    }

    private func composerChip(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? accent : .white.opacity(0.87))
            .padding(.horizontal, 11).frame(minHeight: 44)
            .background(selected ? accent.opacity(0.14) : .white.opacity(0.065), in: Capsule())
    }

    private func saveIdea() {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let title = clean.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        player.saveIdea(title: title, prompt: clean, styles: styles, lyrics: lyrics, instrumental: instrumental)
        promptFocused = false; saved = true
    }
    private func polishPrompt() {
        let original = prompt
        polishingPrompt = true
        promptPolishTask = Task {
            do {
                let polished = try await GeminiLyricsWriter().polish(original, kind: "song idea", idea: "", styles: styles)
                try Task.checkCancellation()
                if prompt == original { prompt = polished }
            } catch is CancellationError {
            } catch { promptError = error.localizedDescription }
            polishingPrompt = false
        }
    }
    private func loadReference(_ url: URL) {
        melody = nil
        clearSample()
        sampleName = url.deletingPathExtension().lastPathComponent
        if !["csv", "txt", "json"].contains(url.pathExtension.lowercased()) { loadSample(url) }
        referenceTask = Task {
            do {
                let reference = try await MusicReference.load(from: url)
                try Task.checkCancellation()
                player.remixSource = reference
                if !hasPrompt && lyrics.isEmpty { instrumental = true }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { player.errorMessage = error.localizedDescription }
            }
            if !Task.isCancelled { referenceTask = nil }
        }
    }

    private func loadSample(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-sample-\(UUID().uuidString).\(source.pathExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: target)
            let audio = try AVAudioPlayer(contentsOf: target)
            sampleURL = target; samplePlayer = audio
        } catch {
            try? FileManager.default.removeItem(at: target)
            player.errorMessage = "Couldn't open that sample. Try another audio file."
        }
    }
    private func playSample() {
        guard let samplePlayer else { return }
        player.pause(); samplePlayer.currentTime = 0
        if !samplePlayer.play() { player.errorMessage = "Couldn't play that sample." }
    }
    private func clearSample() {
        referenceTask?.cancel(); referenceTask = nil; player.remixSource = nil
        samplePlayer?.stop(); samplePlayer = nil
        if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
        sampleURL = nil; sampleName = nil
    }
}

private struct MelodyReference {
    let title: String
    let score: YuE2Score
}

#if os(macOS)
private struct MelodyReferenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let canRender: Bool
    let attach: (MelodyReference) -> Void
    #if !VIBEPLAYER_APP_STORE
    private let transcriber = YuE2Transcriber()
    #endif
    @State private var title: String
    @State private var notation: String
    @State private var transcription: Task<Void, Never>?
    @State private var error: String?

    init(reference: MelodyReference?, canRender: Bool, attach: @escaping (MelodyReference) -> Void) {
        self.canRender = canRender
        self.attach = attach
        _title = State(initialValue: reference?.title ?? "Reference Melody")
        _notation = State(initialValue: reference?.score.notation ?? "")
    }

    var body: some View {
        let score = try? YuE2Score(notation)
        VStack(alignment: .leading, spacing: 16) {
            Text("Reference Melody").font(.title2.bold())
            #if VIBEPLAYER_APP_STORE
            Text("Open an ABC score and review the notes before creating a new arrangement.")
                .foregroundStyle(.secondary)
            #else
            Text("Transcribe a song or open an ABC score. Review the notes before creating a new arrangement.")
                .foregroundStyle(.secondary)
            #endif
            HStack {
                #if !VIBEPLAYER_APP_STORE
                Button("Choose Song…") { chooseFile(asAudio: true) }
                    .disabled(!transcriber.isAvailable || transcription != nil)
                #endif
                Button("Open ABC…") { chooseFile(asAudio: false) }
                    .disabled(transcription != nil)
                Spacer()
                if transcription != nil {
                    ProgressView().controlSize(.small)
                    Text("Transcribing melody…").foregroundStyle(.secondary)
                }
            }
            #if !VIBEPLAYER_APP_STORE
            if !transcriber.isAvailable {
                Text("Install SheetSage2 to transcribe audio. You can still open an ABC score.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #endif
            if !canRender {
                Text("Download the music model in Create to render a cover.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $notation)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 192)
                .border(.quaternary)
                .accessibilityLabel("ABC score")
                .disabled(transcription != nil)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Save ABC…") { if let score { save(score) } }
                    .disabled(score == nil || transcription != nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Melody") {
                    guard let score else { return }
                    attach(.init(title: title, score: score))
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canRender || score == nil || transcription != nil)
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, minHeight: 380)
        .onDisappear { transcription?.cancel() }
    }

    private func chooseFile(asAudio: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = asAudio ? [.audio] : [UTType(filenameExtension: "abc") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        #if !VIBEPLAYER_APP_STORE
        if asAudio {
            transcription = Task {
                defer { transcription = nil }
                do {
                    let score = try await transcriber.transcribe(url)
                    try Task.checkCancellation()
                    update(score, from: url)
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
            return
        }
        #endif
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { update(try YuE2Score(contentsOf: url), from: url) }
        catch { self.error = error.localizedDescription }
    }

    private func update(_ score: YuE2Score, from url: URL) {
        title = url.deletingPathExtension().lastPathComponent
        notation = score.notation
    }

    private func save(_ score: YuE2Score) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).abc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(score.notation.utf8).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}
#endif

private struct AppleMusicResults: View {
    let query: AppleMusicQuery
    let createOriginal: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [AppleMusicQuery.Track]?

    var body: some View {
        NavigationStack {
            List {
                if let tracks {
                    if tracks.isEmpty { Text("No matching tracks found in this storefront.").foregroundStyle(.secondary) }
                    ForEach(tracks) { track in
                        Link(destination: track.trackViewUrl) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.trackName).font(.headline)
                                Text(track.artistName).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                } else {
                    ProgressView("Searching Apple Music…")
                }
                if let url = query.catalogURL {
                    Link("Open '\(query.term)' in Apple Music", destination: url)
                }
                if let createOriginal {
                    Button("Create an original song instead", action: createOriginal)
                }
            }
            .navigationTitle("Apple Music")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { tracks = (try? await query.tracks()) ?? [] }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

private struct SongTextEditor: View {
    enum Kind { case styles, lyrics }
    @Environment(PlayerStore.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Binding var value: String
    @Binding var instrumental: Bool
    let kind: Kind
    let idea: String
    let styles: String
    let length: CreateLength
    let clearLeadVocals: Bool
    let showsPromptUsage: Bool
    @State private var draft: String
    @State private var instrumentalDraft: Bool
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var editorError: String?
    @State private var promptUsage: MusicPromptUsage?
    @State private var undoHistory: [String] = []
    @State private var redoHistory: [String] = []
    @State private var changingHistory = false
    @AppStorage("saved-song-styles") private var savedStyles = ""
    @AppStorage("saved-song-lyrics") private var savedLyrics = ""
    @FocusState private var focused: Bool

    init(kind: Kind, value: Binding<String>, instrumental: Binding<Bool>, idea: String, styles: String,
         length: CreateLength = .automatic, clearLeadVocals: Bool = false, showsPromptUsage: Bool = true) {
        self.kind = kind; self._value = value; self._instrumental = instrumental; self.idea = idea; self.styles = styles
        self.length = length
        self.clearLeadVocals = clearLeadVocals
        self.showsPromptUsage = showsPromptUsage
        _draft = State(initialValue: value.wrappedValue); _instrumentalDraft = State(initialValue: instrumental.wrappedValue)
    }
    private var title: String { kind == .styles ? "Styles" : "Lyrics" }
    private var savedText: String { kind == .styles ? savedStyles : savedLyrics }
    private var hasContext: Bool { !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !styles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canPolish: Bool { !working && !(kind == .lyrics && instrumentalDraft) && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == .lyrics && hasContext)) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.largeTitle.bold())
                if kind == .lyrics {
                    Toggle("Instrumental", isOn: $instrumentalDraft).tint(.white).font(.subheadline)
                    Text(instrumentalDraft ? "Your lyrics are kept here if you turn this off." : "Leave this empty and lyrics will be written for you when creating.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !instrumentalDraft, let promptUsage {
                        Text("\(promptUsage.count) of \(promptUsage.limit) model tokens, including sound description")
                            .font(.footnote)
                            .foregroundStyle(promptUsage.count > promptUsage.limit ? Color.orange : Color.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(kind == .styles ? "Describe what you want your song to sound like" : "[Verse 1]\nWrite your story here…\n\n[Chorus]\nMake something they can't forget.")
                                .foregroundStyle(.white.opacity(0.62)).padding(.vertical, 8).allowsHitTesting(false)
                        }
                        TextEditor(text: $draft).focused($focused).scrollContentBackground(.hidden).padding(.horizontal, -4)
                            .disabled(kind == .lyrics && instrumentalDraft)
                            .accessibilityLabel(title).accessibilityIdentifier(kind == .styles ? "styles-editor" : "lyrics-editor")
                    }
                    #if !os(macOS)
                    VStack(spacing: 4) {
                        Menu {
                            Button("Save \(title.lowercased())", systemImage: "bookmark") {
                                if kind == .styles { savedStyles = draft } else { savedLyrics = draft }
                            }.disabled(draft.isEmpty)
                            Button("Restore saved \(title.lowercased())", systemImage: "arrow.uturn.backward") { draft = savedText }.disabled(savedText.isEmpty)
                        } label: { Image(systemName: "bookmark").frame(width: 48, height: 48) }
                            .accessibilityLabel("Saved \(title.lowercased())")
                        Button { polish() } label: {
                            if working { ProgressView().frame(width: 48, height: 48) }
                            else { Image(systemName: "wand.and.stars").frame(width: 48, height: 48) }
                        }.disabled(!canPolish).accessibilityLabel(draft.isEmpty && kind == .lyrics ? "Write lyrics for me" : "Polish \(title.lowercased())")
                            .accessibilityIdentifier(kind == .styles ? "polish-styles" : "polish-lyrics")
                        Button { finish() } label: { Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white).frame(width: 48, height: 48).background(Color(red: 1, green: 0.2, blue: 0.42), in: Circle()) }
                            .accessibilityLabel("Done")
                    }.font(.title3).padding(5).background(.white.opacity(0.12), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12)))
                    #endif
                }.frame(maxHeight: .infinity)
                    .task(id: draft) {
                        guard kind == .lyrics, showsPromptUsage else { return }
                        let text = draft
                        do {
                            try await Task.sleep(for: .milliseconds(180))
                            let usage = try await player.createPromptUsage(idea: idea, styles: styles, lyrics: text,
                                                                          length: length, clearLeadVocals: clearLeadVocals)
                            if !Task.isCancelled { promptUsage = usage }
                        } catch is CancellationError {
                        } catch {
                            if !Task.isCancelled { promptUsage = nil }
                        }
                    }
                if kind == .styles {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["mellow", "orchestral", "R&B", "synthwave", "atmospheric", "lo-fi"] +
                                    vocalLanguages.map { "\($0) vocals" }, id: \.self) { suggestion in
                                Button(suggestion) { draft += draft.isEmpty ? suggestion : ", " + suggestion }
                                    .font(.subheadline).padding(.horizontal, 16).frame(height: 42)
                                    .background(.white.opacity(0.10), in: Capsule())
                            }
                        }.buttonStyle(.plain)
                    }
                }
                #if os(macOS)
                HStack(spacing: 10) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Save \(title.lowercased())") {
                            if kind == .styles { savedStyles = draft } else { savedLyrics = draft }
                        }.disabled(draft.isEmpty)
                        Button("Restore saved \(title.lowercased())") { draft = savedText }.disabled(savedText.isEmpty)
                        Divider()
                        Button("Undo", action: undo).disabled(undoHistory.isEmpty)
                        Button("Redo", action: redo).disabled(redoHistory.isEmpty)
                        Button("Clear \(title.lowercased())") { draft = "" }.disabled(draft.isEmpty)
                    }
                    Button { polish() } label: {
                        Label(working ? "Working…" : (draft.isEmpty && kind == .lyrics ? "Write lyrics" : "Polish"), systemImage: "wand.and.stars")
                    }.disabled(!canPolish)
                        .accessibilityIdentifier(kind == .styles ? "polish-styles" : "polish-lyrics")
                    Spacer(minLength: 8)
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Done") { finish() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(DesktopColors.accent)
                }
                .padding(.top, 6)
                #endif
            }.padding(22).frame(maxWidth: 780).frame(maxWidth: .infinity)
                .songEditorBackground().vibeInlineTitle()
                #if !os(macOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoHistory.isEmpty).accessibilityLabel("Undo")
                        Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoHistory.isEmpty).accessibilityLabel("Redo")
                        Button { draft = "" } label: { Image(systemName: "trash") }.disabled(draft.isEmpty).accessibilityLabel("Clear \(title.lowercased())")
                    }
                }
                #endif
        }
        .onChange(of: draft) { oldValue, _ in
            if changingHistory { changingHistory = false; return }
            undoHistory.append(oldValue)
            if undoHistory.count > 100 { undoHistory.removeFirst() }
            redoHistory.removeAll()
        }
        .alert("Songwriting", isPresented: Binding(get: { editorError != nil }, set: { if !$0 { editorError = nil } })) { Button("OK", role: .cancel) { editorError = nil } } message: { Text(editorError ?? "") }
        .onDisappear { operationID = nil; task?.cancel() }
    }
    private func finish() { value = draft; if kind == .lyrics { instrumental = instrumentalDraft }; dismiss() }
    private func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(draft); changingHistory = true; draft = previous
    }
    private func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(draft); changingHistory = true; draft = next
    }
    private func polish() {
        let original = draft
        let id = UUID(); operationID = id; working = true
        task = Task {
            do {
                let result: String
                if kind == .lyrics && original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result = try await player.writeLyrics(idea: idea, createStyles: styles)
                } else {
                    result = try await GeminiLyricsWriter().polish(original, kind: title.lowercased(), idea: idea, styles: styles)
                }
                try Task.checkCancellation()
                if operationID == id && draft == original { draft = result }
            } catch is CancellationError {
            } catch { if operationID == id { editorError = error.localizedDescription } }
            if operationID == id { working = false; operationID = nil; task = nil }
        }
    }
}

private extension View {
    @ViewBuilder func songEditorBackground() -> some View {
        #if os(macOS)
        self.background {
            LinearGradient(colors: [Color(red: 0.25, green: 0.14, blue: 0.34),
                                    Color(red: 0.12, green: 0.13, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
        }
        #else
        self.background(Color(white: 0.1))
        #endif
    }
}

private struct SongwritingSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = false
    @State private var error: String?
    @State private var testing = false
    @State private var verified = false
    @State private var testTask: Task<Void, Never>?
    @State private var localModel = SongwritingModelDownload.shared
    @AppStorage(GeminiKeyStore.cloudConsentKey) private var useGemini = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send songwriting text to Gemini", isOn: $useGemini)
                        .disabled(testing)
                    if useGemini {
                    SecureField(hasKey ? "Replace saved key" : "API key", text: Binding(get: { key }, set: { key = $0; verified = false }))
                        .vibeTextInput()
                        .accessibilityIdentifier("gemini-api-key")
                        .disabled(testing)
                    Button("Paste key") {
                        verified = false
                        #if os(macOS)
                        key = NSPasteboard.general.string(forType: .string) ?? ""
                        #else
                        key = UIPasteboard.general.string ?? ""
                        #endif
                    }.disabled(testing)
                    Button {
                        testAndSaveKey()
                    } label: {
                        if testing { Label("Testing key…", systemImage: "hourglass") }
                        else { Text("Test and save key") }
                    }.disabled(!useGemini || testing || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if verified {
                        Label("Connection successful", systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("gemini-key-verified")
                    }
                    }
                    if hasKey {
                        Label("Key saved on this device", systemImage: "checkmark.circle")
                        Button("Remove key", role: .destructive) {
                            do { try GeminiKeyStore().remove(); hasKey = false; verified = false }
                            catch { self.error = error.localizedDescription }
                        }.disabled(testing)
                    }
                } header: {
                    Text("Gemini (optional)")
                } footer: {
                    Text("When enabled, songwriting prompts and draft lyrics are sent to Google. Testing a key sends a short test prompt; the key is stored in your Keychain.")
                }
                Section {
                    if let progress = localModel.progress {
                        ProgressView(value: progress) { Text("Downloading LFM3 1.7B…") }
                        HStack {
                            Text("\(Int(progress * 100))%")
                            Spacer()
                            if let remaining = localModel.remaining {
                                Text(remaining < 60 ? "Less than a minute left" : "About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))) left")
                            } else { Text("Estimating time…") }
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Cancel download") { localModel.cancel() }
                    } else if localModel.installed {
                        Label("Local model ready", systemImage: "checkmark.circle")
                        Button("Remove download", role: .destructive) { localModel.remove() }
                    } else if LiquidSongwriting.isSupported {
                        Button("Download LFM3 1.7B · about 1 GB") { localModel.download() }
                    } else {
                        Text("The local model requires an Apple silicon device with at least 6 GB of memory.")
                    }
                    Link("Model and license", destination: URL(string: LiquidSongwriting.repository)!)
                    if let error = localModel.error {
                        Text(error).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On-device lyrics")
                } footer: {
                    Text("When Apple Intelligence is unavailable, infetit radio can write lyrics and polish prompts with this download. The model comes from Hugging Face and runs on your device.")
                }
                if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md") {
                    NavigationLink("Privacy policy") {
                        ScrollView {
                            Text((try? AttributedString(markdown: String(contentsOf: url, encoding: .utf8),
                                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString())
                                .frame(maxWidth: 600, alignment: .leading)
                                .padding(20)
                        }
                        .navigationTitle("Privacy policy")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Songwriting")
            .vibeInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                do { hasKey = try GeminiKeyStore().read() != nil }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { testTask?.cancel() }
            .alert("Songwriting", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func testAndSaveKey() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useGemini, !candidate.isEmpty, !testing else { return }
        verified = false
        testing = true
        testTask = Task {
            defer { testing = false; testTask = nil }
            do {
                try await GeminiLyricsWriter().testKey(candidate)
                try Task.checkCancellation()
                try GeminiKeyStore().save(candidate)
                key = ""
                hasKey = true
                verified = true
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Couldn't verify this key. \(error.localizedDescription)"
            }
        }
    }
}


private struct GenerationDisc: View {
    let progress: Double
    let phase: Int
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                Circle().fill(.indigo.opacity(0.15)).padding(size * 0.035)
                let diameter = size * 0.72
                VibeArtwork(palette: 1, variant: .disc)
                    .frame(width: diameter, height: diameter).clipShape(Circle())
                ForEach([0.09, 0.125, 0.155], id: \.self) { inset in
                    Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(size * inset)
                }
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 3).padding(3)
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(AngularGradient(colors: [Color(red: 0.62, green: 0.88, blue: 1), .indigo, .purple, Color(red: 0.62, green: 0.88, blue: 1)], center: .center),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(4)
                SongStageDial(phase: active ? min(2, phase) : 3)
                    .background(Color(red: 0.093, green: 0.082, blue: 0.15), in: Circle())
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress)
        .accessibilityHidden(true)
    }
}

private struct DockSurface: ViewModifier {
    let progress: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 23)
        content.padding(.horizontal, 8).padding(.vertical, 5)
            .buttonStyle(.plain)
            .background {
                shape.fill(Color(red: 0.095, green: 0.09, blue: 0.14))
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle().fill(.linearGradient(
                                stops: [.init(color: Color(red: 0.24, green: 0.19, blue: 0.37), location: 0),
                                        .init(color: Color(red: 0.31, green: 0.24, blue: 0.47), location: 0.86),
                                        .init(color: .clear, location: 1)],
                                startPoint: .leading, endPoint: .trailing))
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.clipShape(shape).animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: progress)
                    }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.13)).allowsHitTesting(false) }
    }
}

struct SongIdeaDetail: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.dismiss) private var dismiss
    var idea: SongIdea
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SONG IDEA").font(.caption.bold()).tracking(1.4).foregroundStyle(.secondary)
                Text(idea.title).font(.largeTitle.bold())
                Text(idea.prompt).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                if let styles = idea.styles, !styles.isEmpty { Text("Styles").font(.headline); Text(styles).textSelection(.enabled) }
                if idea.instrumental == true { Text("Instrumental").font(.subheadline).foregroundStyle(.secondary) }
                else if let lyrics = idea.lyrics, !lyrics.isEmpty { Text("Lyrics").font(.headline); Text(lyrics).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("Saved \(idea.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.footnote).foregroundStyle(.secondary)
                Text("This is a saved idea, ready for a future music model.").font(.subheadline).foregroundStyle(.secondary)
                Button("Delete idea", role: .destructive) { player.deleteIdea(idea.id); dismiss() }.padding(.top, 16)
            }.frame(maxWidth: 620, alignment: .leading).padding(22).frame(maxWidth: .infinity)
        }.background(Color(red: 0.045, green: 0.045, blue: 0.055)).navigationTitle("Song idea").vibeInlineTitle()
    }
}

@MainActor @Observable
final class SongwritingModelDownload {
    static let shared = SongwritingModelDownload()
    private(set) var installed = LiquidSongwriting.isInstalled
    private(set) var progress: Double?
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var downloadID: UUID?
    private var startedAt: Date?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif
    var remaining: TimeInterval? {
        guard let progress, progress > 0.001, progress < 1, let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        return elapsed * (1 - progress) / progress
    }

    func download() {
        guard task == nil else { return }
        let id = UUID()
        downloadID = id
        error = nil
        progress = 0
        startedAt = nil
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Downloading the songwriting model")
        #endif
        task = Task {
            defer {
                #if os(macOS)
                if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
                #endif
                startedAt = nil
                downloadID = nil
                progress = nil
                task = nil
                installed = LiquidSongwriting.isInstalled
            }
            do {
                try await LiquidSongwriting.shared.download { value in
                    Task { @MainActor in
                        guard self.downloadID == id else { return }
                        if self.startedAt == nil && value > 0 { self.startedAt = Date() }
                        self.progress = max(self.progress ?? 0, value)
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        guard task == nil else { return }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                try await LiquidSongwriting.shared.removeDownload()
                installed = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
