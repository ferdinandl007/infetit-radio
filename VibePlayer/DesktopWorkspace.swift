#if os(macOS)
import SwiftUI

enum DesktopColors {
    static let background = Color(red: 0.10, green: 0.07, blue: 0.18)
    static let panel = Color(red: 0.070, green: 0.067, blue: 0.069)
    static let raised = Color(red: 0.29, green: 0.22, blue: 0.43)
    static let accent = Color(red: 0.79, green: 0.73, blue: 1)
}

extension View {
    func desktopPanel() -> some View {
        self
    }

    @ViewBuilder
    func desktopGlass<S: Shape>(in shape: S, tint: Color = .clear, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.clear.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay { shape.fill(tint).allowsHitTesting(false) }
                .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
        }
    }

    @ViewBuilder
    func desktopGlassGroup() -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) { self }
        } else {
            self
        }
    }
}

private struct DesktopBackdrop: View {
    var body: some View {
        ZStack {
            DesktopColors.background
            RadialGradient(colors: [Color(red: 0.92, green: 0.25, blue: 0.40).opacity(0.67), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 530)
            RadialGradient(colors: [Color(red: 0.43, green: 0.26, blue: 0.90).opacity(0.70), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 600)
            RadialGradient(colors: [Color(red: 0.05, green: 0.55, blue: 0.63).opacity(0.56), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 370)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct DesktopWorkspace: View {
    private enum Page: String, CaseIterable {
        case home = "Home", radio = "Radio", create = "Create", library = "Library"

        var icon: String {
            switch self {
            case .home: "house"
            case .radio: "dot.radiowaves.left.and.right"
            case .create: "waveform.badge.plus"
            case .library: "square.stack.3d.up"
            }
        }
    }

    @Environment(PlayerStore.self) private var player
    @Binding var showPlayer: Bool
    @Binding var prompt: String
    let newStation: () -> Void
    let importAudio: () -> Void
    @State private var page: Page = .radio
    @State private var stationCategory: StationCategory?
    @State private var stationSearch = ""
    @State private var preparingRemix = false

    var body: some View {
        NavigationStack {
            ZStack {
                pageContent
                    .opacity(showPlayer || page == .create ? 0 : 1)
                    .allowsHitTesting(!showPlayer && page != .create)
                    .accessibilityHidden(showPlayer || page == .create)
                CreateSongView(prompt: $prompt, openPlayer: { showPlayer = true },
                               desktopHistory: DesktopSongHistory(preparingRemix: preparingRemix, remix: remix))
                    .opacity(!showPlayer && page == .create ? 1 : 0)
                    .allowsHitTesting(!showPlayer && page == .create)
                    .accessibilityHidden(showPlayer || page != .create)
                if showPlayer {
                    PlayerView(close: { showPlayer = false })
                }
            }
            .background { DesktopBackdrop().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !showPlayer {
                        if player.isCreating && page != .create {
                            Button { navigate(to: .create) } label: {
                                HStack(spacing: 10) {
                                    ProgressView(value: player.generationProgress)
                                        .tint(DesktopColors.accent)
                                        .frame(width: 76)
                                    Text(player.creationStatus.isEmpty ? "Creating your song…" : player.creationStatus)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.indigo.opacity(0.4), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Song creation: \(player.creationStatus)")
                            .accessibilityHint("Open Create for progress and cancellation")
                        }
                        MiniPlayer { showPlayer = true }
                            .frame(maxWidth: 600)
                        navigationPill
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var navigationPill: some View {
        HStack(spacing: 4) {
            navigationButton(.radio, shortcut: "1")
            navigationButton(.create, shortcut: "2")
            navigationButton(.library, shortcut: "3")
        }
        .padding(5)
        .desktopGlass(in: Capsule())
        .desktopGlassGroup()
    }

    private func navigationButton(_ item: Page, shortcut: KeyEquivalent) -> some View {
        Button { navigate(to: item) } label: {
            Label(item.rawValue, systemImage: item.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
                .background(page == item && !showPlayer ? DesktopColors.accent.opacity(0.30) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityIdentifier("desktop-nav-\(item.rawValue.lowercased())")
        .accessibilityAddTraits(page == item && !showPlayer ? .isSelected : [])
        .help(item.rawValue)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .home:
            home
        case .radio:
            RadioView(category: $stationCategory, query: $stationSearch) {
                if !player.radioMode { player.select(player.selected) }
                showPlayer = true
            } openStation: { station in
                player.select(station)
                showPlayer = true
            } newStation: {
                newStation()
            } importAudio: {
                importAudio()
            }
        case .create:
            Color.clear
        case .library:
            DesktopLibrary(preparingRemix: preparingRemix, importAudio: importAudio, remix: remix) { station in
                player.select(station)
                showPlayer = true
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                homeComposer
                stationShelf
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { shortcuts }
                    VStack(spacing: 10) { shortcuts }
                }
                if !player.savedSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Recently saved", destination: .library)
                        ForEach(player.savedSongs.prefix(3)) { song in
                            DesktopSongRow(song: song, preparingRemix: preparingRemix, remix: remix)
                        }
                    }
                }
            }
            .frame(maxWidth: 1230)
            .padding(23)
            .frame(maxWidth: .infinity)
        }
        .desktopPanel()
        .padding(10)
    }

    private var homeComposer: some View {
        VStack(spacing: 19) {
            Text("Make a song")
                .font(.system(size: 38, weight: .medium))
                .tracking(-1.5)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 13) {
                TextField("Describe a song you want to make…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("desktop-home-prompt")
                Button { navigate(to: .create) } label: {
                    HStack(spacing: 8) {
                        Text("Continue in Create")
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .foregroundStyle(.white)
                    .desktopGlass(in: RoundedRectangle(cornerRadius: 8),
                                  tint: DesktopColors.accent.opacity(0.82), interactive: true)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("desktop-open-create")
            }
            .padding(14)
            .desktopGlass(in: RoundedRectangle(cornerRadius: 15), tint: .white.opacity(0.06))
            .frame(maxWidth: 565)
        }
        .padding(.vertical, 25)
        .frame(maxWidth: .infinity, minHeight: 225)
        .background {
            GeometryReader { geometry in
                Image("DesktopRecord")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.52), DesktopColors.panel],
                                       startPoint: .topTrailing, endPoint: .bottom)
                    }
                    .mask { LinearGradient(colors: [.black, .black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom) }
                    .accessibilityHidden(true)
            }
        }
        .desktopGlassGroup()
    }

    @ViewBuilder private var shortcuts: some View {
        shortcut(player.selected.name, subtitle: "Current station", icon: "dot.radiowaves.left.and.right") {
            navigate(to: .radio)
        }
        shortcut("Library", subtitle: player.savedSongs.count.formatted() + (player.savedSongs.count == 1 ? " saved song" : " saved songs"),
                 icon: "square.stack.3d.up") {
            navigate(to: .library)
        }
    }

    private func shortcut(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if icon == "dot.radiowaves.left.and.right" {
                    DesktopCoverArt(index: DesktopCoverArt.index(for: player.selected))
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image("DesktopRecord").resizable().scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(11)
            .frame(minWidth: 205, maxWidth: .infinity, alignment: .leading)
            .desktopGlass(in: RoundedRectangle(cornerRadius: 11), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stationShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Explore stations", destination: .radio)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(player.vibes.filter { StationCatalog.preset(for: $0) != nil }.prefix(8)) { station in
                        DesktopStationCard(station: station) {
                            navigate(to: .radio)
                            player.select(station)
                            showPlayer = true
                        }
                        .frame(width: 165)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sectionHeader(_ title: String, destination: Page) -> some View {
        HStack {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button("See all") { navigate(to: destination) }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("See all \(title.lowercased())")
        }
    }

    private func navigate(to page: Page) {
        self.page = page
        showPlayer = false
    }

    private func remix(_ song: SavedSong) {
        guard !preparingRemix else { return }
        preparingRemix = true
        Task {
            defer { preparingRemix = false }
            do {
                try await player.remix(song)
                navigate(to: .create)
            } catch {
                player.errorMessage = error.localizedDescription
            }
        }
    }
}

struct DesktopStationCard: View {
    let station: Vibe
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                DesktopCoverArt(index: DesktopCoverArt.index(for: station))
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(station.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(station.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(station.name)
        .accessibilityHint(station.subtitle)
        .accessibilityIdentifier("station-\(station.name)")
    }
}

struct DesktopCoverArt: View {
    let index: Int

    static func index(for station: Vibe) -> Int {
        switch StationCatalog.preset(for: station)?.category {
        case .chill: 0
        case .pop: 1
        case .christmas: 2
        case .workout: 3
        case .focus: 4
        case .nightlife: 5
        case .jazzAndSoul: 6
        case .cinematic: 7
        case nil: abs(station.palette % 8)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            Image("DesktopCovers")
                .resizable()
                .interpolation(.high)
                .frame(width: side * 4, height: side * 2)
                .position(x: geometry.size.width * 0.5 + (1.5 - CGFloat(index % 4)) * side,
                          y: geometry.size.height * 0.5 + (0.5 - CGFloat(index / 4)) * side)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct DesktopLibrary: View {
    private enum Section: String, CaseIterable {
        case songs = "Songs", ideas = "Ideas", stations = "Stations"
        var icon: String {
            switch self {
            case .songs: "music.note"
            case .ideas: "text.bubble"
            case .stations: "antenna.radiowaves.left.and.right"
            }
        }
    }

    @Environment(PlayerStore.self) private var player
    @State private var section: Section = .songs
    @State private var search = ""
    @State private var newestFirst = true
    let preparingRemix: Bool
    let importAudio: () -> Void
    let remix: (SavedSong) -> Void
    let openStation: (Vibe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Library").font(.system(size: 32, weight: .medium)).tracking(-0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Open audio file", systemImage: "plus", action: importAudio)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                HStack(spacing: 15) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Button {
                            self.section = section
                            search = ""
                        } label: {
                            Text(section.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .foregroundStyle(self.section == section ? Color.primary : Color.secondary)
                                .overlay(alignment: .bottom) {
                                    if self.section == section {
                                        Capsule().fill(DesktopColors.accent).frame(height: 2)
                                            .padding(.horizontal, 11)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(self.section == section ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    DesktopSearchField(placeholder: "Search \(section.rawValue.lowercased())", query: $search)
                        .accessibilityIdentifier("desktop-library-search")
                    if section != .stations {
                        Menu {
                            Picker("Sort by", selection: $newestFirst) {
                                Text("Newest first").tag(true)
                                Text("Oldest first").tag(false)
                            }
                        } label: {
                            Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                                .fixedSize()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Sort library")
                    }
                }
            }
            .padding(20)
            Divider().overlay(.white.opacity(0.06))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    libraryContent
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .desktopPanel()
        .padding(10)
    }

    @ViewBuilder private var libraryContent: some View {
        switch section {
        case .songs:
            let songs = player.savedSongs
                .filter { matches($0.title, $0.style) }
                .sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
            if songs.isEmpty {
                empty("No saved songs", description: "Create a song or like a Radio track to save it here.")
            } else {
                ForEach(songs) { song in
                    DesktopSongRow(song: song, preparingRemix: preparingRemix, remix: remix)
                }
            }
        case .ideas:
            let ideas = player.songIdeas
                .filter { matches($0.title, $0.prompt) }
                .sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
            if ideas.isEmpty {
                empty("No song ideas", description: "Use Save idea in Create to keep a draft.")
            } else {
                ForEach(ideas) { idea in
                    NavigationLink {
                        SongIdeaDetail(idea: idea)
                    } label: {
                        libraryRow(icon: "text.bubble", title: idea.title, subtitle: idea.prompt)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .stations:
            let stations = player.vibes.filter {
                (StationCatalog.preset(for: $0) == nil || player.savedIDs.contains($0.id)) && matches($0.name, $0.subtitle)
            }
            if stations.isEmpty {
                empty("No saved stations", description: "Build a station or bookmark one from the player.")
            } else {
                ForEach(stations) { station in
                    Button { openStation(station) } label: {
                        libraryRow(icon: "antenna.radiowaves.left.and.right", title: station.name, subtitle: station.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func matches(_ title: String, _ subtitle: String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || title.localizedCaseInsensitiveContains(term) || subtitle.localizedCaseInsensitiveContains(term)
    }

    private func empty(_ title: String, description: String) -> some View {
        Group {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(title, systemImage: section.icon, description: Text(description))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func libraryRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(DesktopColors.accent)
                .frame(width: 46, height: 46)
                .background(DesktopColors.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopColors.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct DesktopSongHistory: View {
    @Environment(PlayerStore.self) private var player
    let preparingRemix: Bool
    let remix: (SavedSong) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your songs").font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(player.savedSongs.count.formatted())
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(player.savedSongs.count) saved songs")
            }
            if let active = player.activeCreation, player.isCreating {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) {
                        SongStageDial(phase: player.generationProgress < 0.6 ? 1 : 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(active.title).font(.headline).lineLimit(1)
                            Text(player.creationStatus).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("creation-status")
                        }
                        Spacer()
                        Button("Cancel generation", systemImage: "xmark") { player.cancelCurrentCreation() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    ProgressView(value: player.generationProgress).tint(DesktopColors.accent)
                        .accessibilityLabel("Generation progress")
                }
                .padding(11)
                .background(DesktopColors.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(player.queuedCreations) { job in
                HStack {
                    Label(job.title, systemImage: "clock").lineLimit(1)
                    Spacer()
                    Button("Remove \(job.title) from queue", systemImage: "xmark") { player.removeQueuedCreation(job.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(9)
            }
            if player.savedSongs.isEmpty && !player.isCreating {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text("Completed songs will appear here."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            LazyVStack(spacing: 6) {
                ForEach(player.savedSongs) { song in
                    DesktopSongRow(song: song, preparingRemix: preparingRemix, remix: remix)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DesktopSongRow: View {
    @Environment(PlayerStore.self) private var player
    @State private var hovered = false
    @State private var confirmDelete = false
    let song: SavedSong
    let preparingRemix: Bool
    let remix: (SavedSong) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button { player.playSavedSong(song) } label: {
                HStack(spacing: 12) {
                    DesktopCoverArt(index: Int(song.id.uuid.0) % 8)
                        .frame(width: 58, height: 58)
                        .overlay {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                                .frame(width: 27, height: 27)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if !song.style.isEmpty {
                            Text(song.style).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(song.title)")
            Menu {
                if song.semanticFilename != nil || MusicReference.canEncodeAudio {
                    Button(preparingRemix ? "Preparing reference…" : "Remix in Create", systemImage: "waveform.path") {
                        remix(song)
                    }
                    .disabled(preparingRemix)
                }
                Button("Delete song", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 29, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Song options for \(song.title)")
        }
        .padding(6)
        .background(DesktopColors.raised.opacity(hovered ? 0.5 : 0), in: RoundedRectangle(cornerRadius: 9))
        .onHover { hovered = $0 }
        .alert("Delete \(song.title)?", isPresented: $confirmDelete) {
            Button("Delete Song", role: .destructive) { player.deleteSavedSong(song) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the song and its audio from your library.")
        }
    }
}

struct DesktopSearchField: View {
    let placeholder: String
    @Binding var query: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
    }
}

private struct DesktopPlaybackBar: View {
    @Environment(PlayerStore.self) private var player
    @State private var scrubPosition: Double?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            trackButton
                .frame(minWidth: 132, maxWidth: 235, alignment: .leading)
            VStack(spacing: 3) {
                transport
                seekBar
            }
            .frame(maxWidth: 620)
            actions
                .frame(minWidth: 84, maxWidth: 235, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 66)
        .desktopGlass(in: RoundedRectangle(cornerRadius: 18))
        .desktopGlassGroup()
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-playback-bar")
        .onChange(of: player.trackName) { scrubPosition = nil }
    }

    private var trackButton: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if player.radioMode {
                    DesktopCoverArt(index: DesktopCoverArt.index(for: player.selected))
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else if let songID = player.currentSavedSongID {
                    DesktopCoverArt(index: Int(songID.uuid.0) % 8)
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    TrackArtwork(image: player.trackArtwork, palette: player.selected.palette)
                        .frame(width: 39, height: 39)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.radioMode && (player.isWaitingForRadio || player.isSample) ? player.selected.name : player.trackName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.isWaitingForRadio ? player.radioRenderStage.title :
                            player.radioMode ? (player.isSample ? "Radio" : player.selected.name) :
                            player.trackArtist ?? (player.isGenerated ? "Your library" : "Imported audio"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("Toggles the full player")
        .accessibilityIdentifier("desktop-open-player")
    }

    private var transport: some View {
        HStack(spacing: 13) {
            if player.radioMode {
                iconButton("Previous song", icon: "backward.end.fill", action: player.playPreviousRadioSong)
                    .disabled(!player.canPlayPreviousRadioSong)
            } else {
                iconButton("Back 15 seconds", icon: "gobackward.15") { player.seek(player.elapsed - 15) }
                    .disabled(!player.canSeek)
            }
            Button(action: player.togglePlayback) {
                Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .desktopGlass(in: Circle(), tint: DesktopColors.accent.opacity(0.41), interactive: true)
            }
            .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
            .accessibilityIdentifier("desktop-playback-toggle")
            if player.radioMode {
                iconButton("Next song", icon: "forward.end.fill", action: player.playNextRadioSong)
                    .disabled(!player.canPlayNextRadioSong)
            } else {
                iconButton("Forward 15 seconds", icon: "goforward.15") { player.seek(player.elapsed + 15) }
                    .disabled(!player.canSeek)
            }
        }
    }

    private var seekBar: some View {
        let duration = max(player.duration, 0.001)
        return HStack(spacing: 7) {
            Text(time(scrubPosition ?? player.elapsed)).accessibilityHidden(true)
            Slider(value: Binding(
                get: { min(scrubPosition ?? player.elapsed, duration) },
                set: { position in
                    if scrubPosition == nil { player.seek(position) }
                    else { scrubPosition = position }
                }
            ), in: 0...duration, onEditingChanged: { scrubbing in
                if scrubbing {
                    scrubPosition = player.elapsed
                } else if let position = scrubPosition {
                    scrubPosition = nil
                    player.seek(position)
                }
            })
            .tint(DesktopColors.accent)
            .controlSize(.small)
            .disabled(!player.canSeek || player.isWaitingForRadio)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier("desktop-playback-position")
            Text(time(player.duration)).accessibilityHidden(true)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 7) {
            iconButton(player.liked ? "Saved to library" : "Like and save song", icon: player.liked ? "heart.fill" : "heart") {
                player.likeCurrentSong()
            }
            .foregroundStyle(player.liked ? DesktopColors.accent : Color.primary)
            .disabled(!player.isGenerated || player.liked)
            iconButton("Toggle full player", icon: "rectangle.expand.vertical", action: open)
        }
    }

    private func iconButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 29, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .help(title)
    }
}
#endif
