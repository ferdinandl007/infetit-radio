import SwiftUI

struct RadioView: View {
    @Environment(PlayerStore.self) private var player
    @Binding var category: StationCategory?
    @Binding var query: String
    @FocusState private var searching: Bool
    #if os(macOS)
    @State private var showsWebRadio = false
    #endif

    let openPlayer: () -> Void
    let openStation: (Vibe) -> Void
    let newStation: () -> Void
    let importAudio: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 146, maximum: 290), spacing: 16, alignment: .top)]

    private var stations: [Vibe] {
        player.vibes.filter { station in
            guard let preset = StationCatalog.preset(for: station) else { return false }
            return (category == nil || preset.category == category) && StationCatalog.matches(station, query: query)
        }
    }

    var body: some View {
        #if os(macOS)
        desktopRadio
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                currentStation
                catalog
                importButton
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 1050)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(radioBackground)
        .vibeHideNavigationBar()
        #endif
    }

    #if os(macOS)
    private var desktopRadio: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                DesktopSearchField(placeholder: "Search stations", query: $query)
                    .accessibilityIdentifier("station-search")
                currentStation
                VStack(alignment: .leading, spacing: 14) {
                    Text("Explore stations")
                        .font(.title2.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            filterButton(nil)
                            ForEach(StationCategory.allCases) { filterButton($0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("station-categories")
                    if stations.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 147, maximum: 240), spacing: 14, alignment: .top)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(stations) { station in
                                DesktopStationCard(station: station) { openStation(station) }
                            }
                        }
                    }
                }
                importButton
            }
            .frame(maxWidth: 1230)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .desktopPanel()
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .padding(10)
        .sheet(isPresented: $showsWebRadio) {
            WebRadioPanel()
        }
    }
    #endif

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                radioTitle
                Spacer(minLength: 12)
                headerActions
            }
            VStack(alignment: .leading, spacing: 12) {
                radioTitle
                headerActions
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            Button {
                showsWebRadio = true
            } label: {
                Label(player.webRadio.isRunning ? "Broadcasting" : "Web Radio",
                      systemImage: player.webRadio.isRunning ? "dot.radiowaves.left.and.right" : "globe")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 15)
                    .frame(minHeight: 44)
                    .desktopGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("web-radio")
            #endif
            newStationButton
        }
    }

    private var radioTitle: some View {
        Text("Radio")
            #if os(macOS)
            .font(.system(size: 32, weight: .medium))
            .tracking(-0.8)
            #else
            .font(.largeTitle.weight(.bold))
            #endif
            .accessibilityAddTraits(.isHeader)
    }

    private var newStationButton: some View {
        Button(action: newStation) {
            Label("New station", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                #if os(macOS)
                .desktopGlass(in: Capsule(), interactive: true)
                #else
                .background(.white.opacity(0.09), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.10)) }
                #endif
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var currentStation: some View {
        Button(action: openPlayer) {
            HStack(spacing: 15) {
                #if os(macOS)
                DesktopCoverArt(index: DesktopCoverArt.index(for: player.selected))
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                #else
                StationCover(station: player.selected)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                #endif

                VStack(alignment: .leading, spacing: 6) {
                    Text("Current station")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(player.selected.name)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(player.selected.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(macOS)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        .linearGradient(colors: [VibeArtwork.colors(for: player.selected.palette)[0].opacity(0.34), Color(white: 0.092)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)) }
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open player for \(player.selected.name)")
        .accessibilityIdentifier("open-current-station")
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Explore stations")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(stations.count == 1 ? "1 station" : "\(stations.count) stations")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("station-count")
            }
            searchField
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    filterButton(nil)
                    ForEach(StationCategory.allCases) { filterButton($0) }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("station-categories")

            if stations.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(stations) { station in
                        stationCard(station)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search stations", text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { searching = false }
                .accessibilityIdentifier("station-search")
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 4)
        .frame(minHeight: 44)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private func filterButton(_ option: StationCategory?) -> some View {
        let selected = category == option
        #if os(macOS)
        let height: CGFloat = 33
        let accent = DesktopColors.accent
        #else
        let height: CGFloat = 44
        let accent = radioAccent
        #endif
        return Button {
            searching = false
            category = option
        } label: {
            Label(option?.rawValue ?? "All", systemImage: option?.symbol ?? "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .frame(minHeight: height)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? accent : .white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stationCard(_ station: Vibe) -> some View {
        Button {
            searching = false
            openStation(station)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                StationCover(station: station)
                    .aspectRatio(1.65, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(station.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(station.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(station.name)
        .accessibilityHint(station.subtitle)
        .accessibilityIdentifier("station-\(station.name)")
    }

    private var importButton: some View {
        Button(action: importAudio) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bring your own audio").font(.headline)
                    Text("Play a file from your device").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct NewStationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: Vibe?
    @State private var name = ""
    @State private var sound = ""
    @State private var instrumental: Bool
    @FocusState private var field: Field?

    private enum Field { case name, sound }

    let startingStation: Vibe
    let catalog: [Vibe]
    let create: (String, Vibe?, String, Bool) -> Void

    init(startingStation: Vibe, catalog: [Vibe], create: @escaping (String, Vibe?, String, Bool) -> Void) {
        self.startingStation = startingStation
        self.catalog = catalog
        self.create = create
        _source = State(initialValue: startingStation)
        _instrumental = State(initialValue: Self.isInstrumental(startingStation))
    }

    private var stationBackground: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(LinearGradient(colors: [Color(red: 0.25, green: 0.14, blue: 0.34), Color(red: 0.12, green: 0.13, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
        #else
        AnyShapeStyle(radioBackground)
        #endif
    }
    private var stationAccent: Color {
        #if os(macOS)
        DesktopColors.accent
        #else
        radioAccent
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Station name").font(.subheadline.weight(.semibold))
                        TextField("e.g. Sunday Slowdown", text: $name)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            .focused($field, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { field = .sound }
                            .accessibilityLabel("Station name")
                            .accessibilityIdentifier("new-station-name")
                    }
                    sourceMenu
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Describe the sound").font(.subheadline.weight(.semibold))
                            Text("Optional").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField(source?.soundDescription ?? "e.g. Warm synths and a steady beat", text: $sound, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2...4)
                            .padding(13)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            .focused($field, equals: .sound)
                            .accessibilityLabel("Describe the sound")
                            .accessibilityIdentifier("new-station-sound")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice").font(.subheadline.weight(.semibold))
                        Picker("Voice", selection: $instrumental) {
                            Text("Vocals").tag(false)
                            Text("Instrumental").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .padding(22)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { createButton }
            .background(stationBackground)
            .navigationTitle("New station")
            .vibeInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 530, minHeight: 620)
        #endif
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            StationCover(station: source, wide: true)
                .frame(height: 128)
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .leading, endPoint: .trailing)
            Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your station" : name)
                .font(.title2.bold())
                .lineLimit(2)
                .padding(17)
        }
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .accessibilityHidden(true)
    }

    private var sourceMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with").font(.subheadline.weight(.semibold))
            Menu {
                Button {
                    changeSource(to: startingStation)
                } label: {
                    sourceLabel(startingStation)
                }
                Button {
                    changeSource(to: nil)
                } label: {
                    Label("From scratch", systemImage: source == nil ? "checkmark" : "waveform")
                }
                Divider()
                ForEach(StationCategory.allCases) { category in
                    Menu(category.rawValue, systemImage: category.symbol) {
                        ForEach(catalog.filter { station in
                            station.id != startingStation.id && StationCatalog.preset(for: station)?.category == category
                        }) { station in
                            Button { changeSource(to: station) } label: { sourceLabel(station) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: source.flatMap(StationCatalog.preset(for:))?.symbol ?? "waveform")
                        .frame(width: 23)
                        .foregroundStyle(stationAccent)
                    Text(source?.name ?? "From scratch")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(13)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .accessibilityLabel("Start with")
            .accessibilityValue(source?.name ?? "From scratch")
            .accessibilityIdentifier("new-station-template")
        }
    }

    private var createButton: some View {
        Button {
            field = nil
            create(name, source, sound, instrumental)
        } label: {
            Label("Create station", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .frame(maxWidth: 520)
                .padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(stationAccent, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(stationBackground)
        .accessibilityIdentifier("create-station")
    }

    private func sourceLabel(_ station: Vibe) -> some View {
        Label(station.name, systemImage: source?.id == station.id ? "checkmark" : StationCatalog.preset(for: station)?.symbol ?? "waveform")
    }

    private func changeSource(to station: Vibe?) {
        source = station
        if let station { instrumental = Self.isInstrumental(station) }
    }

    private static func isInstrumental(_ station: Vibe) -> Bool {
        MusicPromptBuilder().makeRequest(profile: station.musicProfile, seed: 0).voice == .instrumental
    }
}

private let radioBackground = Color(red: 0.048, green: 0.049, blue: 0.060)
private let radioAccent = Color(red: 0.97, green: 0.87, blue: 0.70)

private struct StationCover: View {
    let station: Vibe?
    var wide = false

    var body: some View {
        GeometryReader { geometry in
            let colors = VibeArtwork.colors(for: station?.palette ?? 0)
            let size = min(geometry.size.height, geometry.size.width)
            let diameter = size * (wide ? 1.62 : 1.15)
            ZStack(alignment: wide ? .trailing : .center) {
                Rectangle().fill(
                    .linearGradient(colors: [colors[0], colors[1], .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                ZStack {
                    Circle().fill(.black.opacity(0.26))
                    ForEach([0.98, 0.88, 0.78, 0.68], id: \.self) { ratio in
                        Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1)
                            .frame(width: diameter * ratio)
                    }
                    Circle()
                        .fill(.linearGradient(colors: [colors[0], colors[2]], startPoint: .top, endPoint: .bottomTrailing))
                        .frame(width: diameter * 0.53)
                    Image(systemName: station.flatMap(StationCatalog.preset(for:))?.symbol ?? "waveform")
                        .font(.system(size: diameter * 0.25, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                }
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-12))
                .offset(x: wide ? -size * 0.25 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay {
                Rectangle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
