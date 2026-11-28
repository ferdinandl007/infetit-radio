import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct RootView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(MusicModelDownload.self) private var modelDownload
    @State private var tab = 0
    @State private var createPrompt = ""
    @State private var showPlayer = ProcessInfo.processInfo.arguments.contains("--preview-player")
    @State private var showImporter = false
    @State private var stationCategory: StationCategory?
    @State private var stationSearch = ""
    @State private var stationSource: Vibe?
    @State private var openCreatedStation = false
    @State private var preparingRemix = false
    @State private var showModelSetup = false

    var body: some View {
        platformNavigation
        .tint(.white)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): player.load(url: url, name: url.deletingPathExtension().lastPathComponent)
            case .failure: player.errorMessage = "Couldn't import this audio file. Please try again."
            }
        }
        .sheet(isPresented: $showModelSetup) { MusicModelSetupView(download: modelDownload) }
        .sheet(item: $stationSource, onDismiss: {
            if openCreatedStation {
                openCreatedStation = false
                showPlayer = true
            }
        }) { source in
            NewStationView(startingStation: source, catalog: player.vibes) { name, template, sound, instrumental in
                if player.createStation(named: name, basedOn: template, soundDescription: sound, instrumental: instrumental) {
                    openCreatedStation = true
                    stationSource = nil
                }
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--preview-playing") { player.play() }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if !player.canGenerate && (!arguments.contains("--ui-testing") || arguments.contains("--show-model-setup")) {
                showModelSetup = true
            }
            #else
            if !player.canGenerate { showModelSetup = true }
            #endif
        }
        .alert("infetit radio", isPresented: Binding(get: { player.errorMessage != nil && !showPlayer && !showModelSetup && stationSource == nil && !showImporter }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK", role: .cancel) { player.errorMessage = nil }
        } message: { Text(player.errorMessage ?? "") }
    }
    @ViewBuilder private var platformNavigation: some View {
        #if os(macOS)
        DesktopWorkspace(showPlayer: $showPlayer, prompt: $createPrompt,
                         newStation: { stationSource = player.selected },
                         importAudio: { showImporter = true })
        #else
        TabView(selection: $tab) {
            NavigationStack { discover.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer } }.tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            NavigationStack { CreateSongView(prompt: $createPrompt) { showPlayer = true } }.tabItem { Label("Create", systemImage: "square.and.pencil") }.tag(2)
            NavigationStack { library.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer } }.tabItem { Label("Library", systemImage: "square.stack.3d.up") }.tag(1)
        }.fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        #endif
    }
    private var miniPlayer: some View {
        MiniPlayer { showPlayer = true }.padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var discover: some View {
        RadioView(category: $stationCategory, query: $stationSearch) {
            if !player.radioMode { player.select(player.selected) }
            showPlayer = true
        } openStation: { station in
            player.select(station)
            showPlayer = true
        } newStation: {
            stationSource = player.selected
        } importAudio: {
            showImporter = true
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Library").font(.largeTitle.bold()).padding(.top, 12)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Songs").font(.title2.bold())
                    if player.savedSongs.isEmpty {
                        Text("Songs you create or like will appear here.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(player.savedSongs) { song in
                            HStack(spacing: 14) {
                                Button { player.playSavedSong(song); showPlayer = true } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "play.fill").frame(width: 54, height: 54).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(song.title).font(.headline).lineLimit(1)
                                            Text(song.style).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Menu {
                                    if song.semanticFilename != nil || MusicReference.canEncodeAudio {
                                        Button(preparingRemix ? "Preparing reference…" : "Remix in Create", systemImage: "waveform.path") {
                                            preparingRemix = true
                                            Task {
                                                defer { preparingRemix = false }
                                                do { try await player.remix(song); tab = 2 }
                                                catch { player.errorMessage = error.localizedDescription }
                                            }
                                        }.disabled(preparingRemix)
                                    }
                                    Button("Delete song", role: .destructive) { player.deleteSavedSong(song) }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }.accessibilityLabel("Song options")
                            }
                        }
                    }
                }
                Text("Your vibes").font(.title2.bold())
                let stations = player.vibes.filter { StationCatalog.preset(for: $0) == nil || player.savedIDs.contains($0.id) }
                if stations.isEmpty {
                    Text("Stations you make or bookmark will appear here.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(stations) { vibe in
                    Button { player.select(vibe); showPlayer = true } label: {
                        HStack(spacing: 16) {
                            VibeArtwork(palette: vibe.palette, variant: .disc).frame(width: 72, height: 72)
                            VStack(alignment: .leading, spacing: 5) { Text(vibe.name).font(.headline); Text(vibe.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                            Spacer()
                            if player.savedIDs.contains(vibe.id) { Image(systemName: "bookmark.fill").foregroundStyle(.white.opacity(0.7)) }
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Song ideas").font(.title2.bold())
                    if player.songIdeas.isEmpty {
                        Text("Your saved song ideas will appear here.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(player.songIdeas) { idea in
                            NavigationLink { SongIdeaDetail(idea: idea) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "music.note").font(.title3).frame(width: 54, height: 54).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                                    VStack(alignment: .leading, spacing: 4) { Text(idea.title).font(.headline); Text(idea.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.top, 8)
                Button { showImporter = true } label: { Label("Import audio", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity).padding().background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16)) }
                    .buttonStyle(.plain).padding(.top, 12)
            }.padding(.horizontal, 22).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.background(Color(red: 0.045, green: 0.045, blue: 0.055)).vibeHideNavigationBar()
    }
}

struct MiniPlayer: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var open: () -> Void

    private var fill: Double {
        if player.isWaitingForRadio { return max(0.03, min(1, player.generationProgress)) }
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.elapsed / player.duration))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if player.radioMode { VibeArtwork(palette: player.selected.palette, variant: .disc).frame(width: 45, height: 45) }
                    else { TrackArtwork(image: player.trackArtwork, palette: player.selected.palette).frame(width: 45, height: 45) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.radioMode ? player.selected.name : player.trackName).font(.subheadline.bold()).lineLimit(1)
                        if player.isWaitingForRadio, let message = player.radioLoadingMessage {
                            let stage = player.isGenerating ? player.radioRenderStage.title : message
                            Text(stage).font(.caption).foregroundStyle(.white.opacity(0.76)).lineLimit(1)
                        } else {
                            Text(player.radioMode ? player.trackName : (player.trackArtist ?? (player.isGenerated ? "Your song" : "Audio from your device"))).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { player.togglePlayback() } label: { Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
            .buttonStyle(.plain)
            .background {
                let shape = RoundedRectangle(cornerRadius: 18)
                #if os(macOS)
                shape.fill(Color.indigo.opacity(0.22))
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.linearGradient(colors: [.pink.opacity(0.52), .purple.opacity(0.42)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geometry.size.width * fill)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.clipShape(shape)
                    }
                    .animation(reduceMotion ? nil : .linear(duration: 0.18), value: fill)
                    .accessibilityHidden(true)
                #else
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.linearGradient(colors: [Color.indigo.opacity(0.47), Color(red: 0.63, green: 0.52, blue: 0.88).opacity(0.30)],
                                                      startPoint: .leading, endPoint: .trailing))
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                                }
                                .frame(width: geometry.size.width * fill)
                                .opacity(fill > 0 ? 1 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.clipShape(shape)
                    }
                    .animation(reduceMotion ? nil : .linear(duration: 0.18), value: fill)
                    .accessibilityHidden(true)
                #endif
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}

struct VibeArtwork: View {
    enum Variant { case disc, hero }
    var palette: Int
    var variant: Variant
    static func colors(for palette: Int) -> [Color] {
        switch palette {
        case 1: [.init(red: 0.84, green: 0.48, blue: 0.64), .init(red: 0.42, green: 0.37, blue: 0.75), .init(red: 0.90, green: 0.68, blue: 0.44)]
        case 2: [.init(red: 0.18, green: 0.58, blue: 0.51), .init(red: 0.20, green: 0.32, blue: 0.56), .init(red: 0.54, green: 0.65, blue: 0.48)]
        case 3: [Color(red: 0.63, green: 0.19, blue: 0.23), Color(red: 0.15, green: 0.29, blue: 0.24), Color(red: 0.88, green: 0.56, blue: 0.33)]
        case 4: [Color(red: 0.68, green: 0.30, blue: 0.13), Color(red: 0.40, green: 0.13, blue: 0.19), Color(red: 0.91, green: 0.47, blue: 0.17)]
        case 5: [Color(red: 0.23, green: 0.37, blue: 0.58), Color(red: 0.14, green: 0.18, blue: 0.36), Color(red: 0.37, green: 0.56, blue: 0.69)]
        case 6: [Color(red: 0.25, green: 0.45, blue: 0.40), Color(red: 0.15, green: 0.24, blue: 0.26), Color(red: 0.45, green: 0.61, blue: 0.43)]
        case 7: [Color(red: 0.68, green: 0.28, blue: 0.45), Color(red: 0.39, green: 0.17, blue: 0.43), Color(red: 0.83, green: 0.42, blue: 0.59)]
        case 8: [Color(red: 0.38, green: 0.28, blue: 0.61), Color(red: 0.19, green: 0.15, blue: 0.34), Color(red: 0.53, green: 0.43, blue: 0.79)]
        case 9: [Color(red: 0.58, green: 0.36, blue: 0.20), Color(red: 0.35, green: 0.19, blue: 0.19), Color(red: 0.76, green: 0.52, blue: 0.28)]
        case 10: [Color(red: 0.24, green: 0.41, blue: 0.49), Color(red: 0.15, green: 0.22, blue: 0.34), Color(red: 0.46, green: 0.62, blue: 0.66)]
        default: [.init(red: 0.31, green: 0.50, blue: 0.72), .init(red: 0.54, green: 0.37, blue: 0.65), .init(red: 0.73, green: 0.55, blue: 0.34)]
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let colors = Self.colors(for: palette)
            ZStack {
                AngularGradient(colors: colors + [colors[0]], center: .center).blur(radius: variant == .disc ? 10 : 35)
                if variant == .disc {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 1)
                    Circle().stroke(.white.opacity(0.14), lineWidth: geometry.size.width * 0.12).padding(geometry.size.width * 0.13).blur(radius: 5)
                    Circle().fill(.black.opacity(0.88)).frame(width: geometry.size.width * 0.35)
                    Image(systemName: "waveform").font(.system(size: geometry.size.width * 0.12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1).frame(width: geometry.size.width * 0.6).offset(x: geometry.size.width * 0.23, y: -20)
                    Circle().stroke(.white.opacity(0.1), lineWidth: 35).frame(width: geometry.size.width * 0.43).offset(x: geometry.size.width * 0.23, y: -20)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: variant == .disc ? geometry.size.width / 2 : 0))
        }
    }
}
