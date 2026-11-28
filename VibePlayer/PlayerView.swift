import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif

struct PlayerView: View {
    private enum SoundEditor: Identifiable {
        case genres, voice
        var id: Self { self }
    }

    @Environment(PlayerStore.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var close: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .subheadline) private var tempoWidth: CGFloat = 122
    @State private var soundEditor: SoundEditor?
    @State private var showImporter = false
    @State private var showFullQueue = false
    @State private var radioScrubPosition: Double?
    @State private var soundChangeToShow: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var scrollAtTop = true
    @State private var dragStartedAtTop: Bool?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PlayerBackground(palette: player.selected.palette, audioLevel: player.audioLevel, beatPulse: player.beatPulse).ignoresSafeArea()
                if !player.radioMode {
                    singleTrackPlayer(geometry: geometry)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            scrollMarker
                            VStack(spacing: 8) {
                                dismissHandle
                                header
                            }
                            playback
                            soundControls.padding(.vertical, 4)
                            aboutSound
                        }.padding(.horizontal, 20).padding(.bottom, 40).frame(maxWidth: 620).frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }.coordinateSpace(name: "player-scroll")
                        .onPreferenceChange(PlayerScrollOffsetKey.self) { scrollAtTop = $0 >= -2 }
                        .simultaneousGesture(dismissGesture)
                }
            }.offset(y: dragOffset)
        }
        .tint(.white).vibePlayerControls()
        .overlay(alignment: .bottom) {
            if player.radioMode, soundChangeToShow != nil {
                Text("Sound changes apply to the next song generated.")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.86), in: Capsule())
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("radio-sound-change")
            }
        }
        .onChange(of: player.radioSoundChangeID) { _, id in soundChangeToShow = id }
        .task(id: soundChangeToShow) {
            guard let id = soundChangeToShow else { return }
            AccessibilityNotification.Announcement("Sound changes apply to the next song generated.").post()
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            if soundChangeToShow == id { soundChangeToShow = nil }
        }
        .sheet(item: $soundEditor) { editor in TagEditor(showVoice: editor == .voice) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): player.load(url: url, name: url.deletingPathExtension().lastPathComponent)
            case .failure: player.errorMessage = "Couldn't import this audio file. Please try again."
            }
        }
        .alert("infetit radio", isPresented: Binding(get: { player.errorMessage != nil && soundEditor == nil && !showImporter }, set: { if !$0 { player.errorMessage = nil } })) { Button("OK", role: .cancel) { player.errorMessage = nil } } message: { Text(player.errorMessage ?? "") }
    }
    private var scrollMarker: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PlayerScrollOffsetKey.self, value: proxy.frame(in: .named("player-scroll")).minY)
        }.frame(height: 0)
    }
    private func closePlayer() { if let close { close() } else { dismiss() } }
    private var dismissHandle: some View {
        Button { closePlayer() } label: {
            #if os(macOS)
            Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(height: 36).vibeGlass()
            #else
            Capsule().fill(.white.opacity(0.35)).frame(width: 50, height: 5)
                .frame(width: 100, height: 36).contentShape(Rectangle())
            #endif
        }.buttonStyle(.plain).accessibilityLabel("Close player").accessibilityIdentifier("player-dismiss-handle")
    }
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragStartedAtTop == nil { dragStartedAtTop = scrollAtTop }
                guard dragStartedAtTop == true, value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.5 else { return }
                dragOffset = min(value.translation.height, 350)
            }
            .onEnded { value in
                defer { dragStartedAtTop = nil }
                guard dragOffset > 0 else { return }
                if value.translation.height > 100 || (value.translation.height > 35 && value.predictedEndTranslation.height > 220) {
                    closePlayer()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }
    private func singleTrackPlayer(geometry: GeometryProxy) -> some View {
        #if os(macOS)
        let artworkSize = max(100, min(220, geometry.size.height * 0.25, geometry.size.width - 64))
        let contentSpacing: CGFloat = 8
        let artworkTopPadding: CGFloat = 4
        let bottomPadding: CGFloat = 8
        #else
        let artworkSize = min(geometry.size.width - 64, 390)
        let contentSpacing: CGFloat = 22
        let artworkTopPadding: CGFloat = 12
        let bottomPadding: CGFloat = 35
        #endif
        return ScrollView {
            VStack(spacing: contentSpacing) {
                scrollMarker
                dismissHandle
                HStack {
                    AirPlayButton().frame(width: 44, height: 44).vibeGlassCircle().accessibilityLabel("Audio output")
                    Spacer()
                    Text("NOW PLAYING").font(.caption.bold()).tracking(1.5).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Menu { Button("Import audio", systemImage: "square.and.arrow.down") { showImporter = true } } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).vibeGlassCircle()
                    }.accessibilityLabel("More options")
                }
                TrackArtwork(image: player.trackArtwork, palette: player.selected.palette)
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: artworkSize)
                    .shadow(color: .black.opacity(0.25), radius: 28, y: 18)
                    .padding(.top, artworkTopPadding).accessibilityIdentifier("track-artwork")
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.trackName).font(.title2.bold()).lineLimit(2).accessibilityIdentifier("track-title")
                    Text(player.trackArtist ?? (player.isGenerated ? "Your song" : "Audio from your device"))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.68))
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 5) {
                    Slider(value: Binding(get: { min(player.elapsed, max(player.duration, 0)) }, set: { player.seek($0) }), in: 0...max(player.duration, 0.001))
                        .tint(.white).disabled(!player.canSeek).accessibilityLabel("Playback position")
                    HStack { Text(time(player.elapsed)); Spacer(); Text("-" + time(max(0, player.duration - player.elapsed))) }
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                }
                HStack {
                    Button { player.seek(player.elapsed - 15) } label: { Image(systemName: "gobackward.15").font(.title2).frame(width: 52, height: 52) }.accessibilityLabel("Back 15 seconds").disabled(!player.canSeek)
                    Spacer()
                    Button { player.togglePlayback() } label: { Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill").font(.system(size: 34, weight: .bold)).frame(width: 70, height: 70) }
                        .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play").accessibilityIdentifier("player-playback")
                    Spacer()
                    Button { player.seek(player.elapsed + 15) } label: { Image(systemName: "goforward.15").font(.title2).frame(width: 52, height: 52) }.accessibilityLabel("Forward 15 seconds").disabled(!player.canSeek)
                }.frame(maxWidth: 270).padding(.vertical, 6)
                Menu {
                    Button("15 minutes") { player.setSleepTimer(15) }
                    Button("30 minutes") { player.setSleepTimer(30) }
                    Button("1 hour") { player.setSleepTimer(60) }
                    if player.sleepMinutes != nil { Button("Turn off timer") { player.setSleepTimer(nil) } }
                } label: { Label("Sleep timer", systemImage: player.sleepMinutes == nil ? "moon.fill" : "moon.zzz.fill").font(.subheadline).padding(.horizontal, 16).frame(height: 44).vibeGlass() }
                    .accessibilityLabel("Sleep timer")
            }.padding(.horizontal, 28).padding(.bottom, bottomPadding).frame(maxWidth: 500).frame(maxWidth: .infinity)
        }.coordinateSpace(name: "player-scroll")
            .onPreferenceChange(PlayerScrollOffsetKey.self) { scrollAtTop = $0 >= -2 }
            .simultaneousGesture(dismissGesture)
            .accessibilityIdentifier("single-track-player")
    }
    private var soundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shape your sound").font(.headline).accessibilityAddTraits(.isHeader)
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer(spacing: 9) { soundPills }
            } else { soundPills }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var soundPills: some View {
        let language = player.selected.tags.first { $0.category == .language }?.name
        return FlowLayout(spacing: 9) {
            ForEach(player.selected.tags.filter { $0.category != .language }) { tag in
                SoundControl(name: tag.name, symbol: tag.symbol, value: tag.intensity, valueText: "\(Int(tag.intensity * 100)) percent") { value, commit in
                    player.setIntensity(tag.name, value: value, commit: commit)
                }
            }
            SoundControl(name: player.selected.tempo < 90 ? "Slow" : player.selected.tempo < 130 ? "Medium" : "Fast", symbol: "speedometer", value: (player.selected.tempo - 50) / 130, valueText: "\(Int(player.selected.tempo)) beats per minute", fixedWidth: tempoWidth) { value, commit in
                player.setTempo(50 + value * 130, commit: commit)
            }.accessibilityIdentifier("tempo-control")
            Button { soundEditor = .voice } label: {
                Label(language ?? "Language", systemImage: "globe")
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 44).vibeGlass()
            }.buttonStyle(.plain)
                .accessibilityLabel("Song language").accessibilityValue(language ?? "Automatic")
                .accessibilityIdentifier("radio-language")
            Button { soundEditor = .genres } label: {
                Label("Add", systemImage: "plus").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 44).vibeGlass()
            }.buttonStyle(.plain)
        }
    }
    private var aboutSound: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("About this sound").font(.headline)
            Text(player.isGenerated ? "A song made from your sound settings." : player.isSample ? "A short instrumental sample to explore the player. Your vibe settings are saved on this device." : "Playing audio from your device. Your vibe settings are saved on this device.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            Text("SOUND PROFILE").font(.caption2.bold()).tracking(1.3).foregroundStyle(.white.opacity(0.55)).padding(.top, 8)
            Text(player.selected.prompt).font(.footnote).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled).accessibilityIdentifier("music-style-prompt")
            if player.canGenerate {
                Button {
                    if player.radioLoadingMessage != nil { player.cancelRadioPreparation() } else { player.prepareRadio() }
                } label: {
                    Label(player.radioLoadingMessage != nil ? "Cancel preparation" : "Prepare songs", systemImage: player.radioLoadingMessage != nil ? "xmark" : "sparkles")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(12)
                }.buttonStyle(.plain).background(.white.opacity(0.12), in: Capsule()).accessibilityIdentifier("generate-song")
                    .disabled(player.radioReadyCount >= player.radioQueueCapacity && player.radioLoadingMessage == nil)
            } else {
                Text(MusicGenerationError.metalUnavailable.localizedDescription).font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).playerContentSurface()

    }
    private var header: some View {
        HStack(alignment: .center) {
            AirPlayButton().frame(width: 44, height: 44).vibeGlassCircle().accessibilityLabel("Audio output")
            Spacer()
            Text(player.selected.name).font(.title2.weight(.semibold))
                .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { player.toggleSaved() } label: { Image(systemName: player.savedIDs.contains(player.selected.id) ? "bookmark.fill" : "bookmark").font(.headline).frame(width: 44, height: 44).vibeGlassCircle() }.accessibilityLabel(player.savedIDs.contains(player.selected.id) ? "Remove bookmark" : "Bookmark vibe")
        }
    }
    private var playback: some View {
        VStack(alignment: .leading, spacing: 14) {
            let rowLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            rowLayout {
                currentRadioTrack
                trackActions
            }
            if player.canSeek && (!player.isWaitingForRadio || player.isGenerated) {
                radioSeekBar
            }
            radioTransport
            if player.canGenerate {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1).accessibilityHidden(true)
                radioPlaylist
            }
        }
        .padding(16)
        .playerConsoleSurface()
        .foregroundStyle(.white)
    }

    private var currentRadioTrack: some View {
        let isWaiting = player.isWaitingForRadio
        let position = player.duration > 0 ? min(1, max(0, player.elapsed / player.duration)) : 0
        return HStack(spacing: 12) {
            RadioPositionDisc(palette: player.selected.palette, position: isWaiting ? 0 : position)
            VStack(alignment: .leading, spacing: 3) {
                Text(isWaiting ? "Off air" : player.isPlaying ? "Now playing" : "Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isWaiting ? Color.white.opacity(0.72) : RadioConsoleColors.lavender)
                Text(isWaiting ? player.selected.name : player.trackName)
                    .font(.headline).lineLimit(2)
                if isWaiting {
                    Text("Waiting for audio").font(.caption).foregroundStyle(.white.opacity(0.74))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("radio-current-track")
    }

    private var trackActions: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Button { player.likeCurrentSong() } label: {
                    Image(systemName: player.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.liked ? "Saved to library" : "Like and save song")
                .disabled(!player.isGenerated || player.liked)
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 22)
                Button { player.disliked.toggle() } label: {
                    Image(systemName: player.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(player.disliked ? "Remove dislike" : "Dislike")
            }.vibeGlass()
            Menu {
                Button("Restart song", systemImage: "arrow.counterclockwise") { player.seek(0) }
                    .disabled(!player.canSeek)
                Button("Import audio", systemImage: "square.and.arrow.down") { showImporter = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).vibeGlassCircle()
            }.accessibilityLabel("More options")
        }
    }

    private var radioSeekBar: some View {
        VStack(spacing: 3) {
            Slider(value: Binding(
                get: { min(radioScrubPosition ?? player.elapsed, player.duration) },
                set: { position in
                    if radioScrubPosition == nil { player.seek(position) }
                    else { radioScrubPosition = position }
                }
            ), in: 0...max(player.duration, 0.001), onEditingChanged: { scrubbing in
                if scrubbing {
                    radioScrubPosition = player.elapsed
                } else if let position = radioScrubPosition {
                    radioScrubPosition = nil
                    player.seek(position)
                }
            })
            .tint(RadioConsoleColors.lavender)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier("radio-seek")
            HStack {
                Text(time(radioScrubPosition ?? player.elapsed))
                Spacer()
                Text(time(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.74))
            .accessibilityHidden(true)
        }
        .onChange(of: player.trackName) { radioScrubPosition = nil }
    }

    private var radioPlaylist: some View {
        let playlist = player.radioPlaylistItems
        let current = playlist.firstIndex { $0.position == .current }
        let first = max(0, (current ?? 0) - 1)
        let end = min(playlist.count, (current ?? -1) + 3)
        let shown = showFullQueue ? playlist[...] : playlist[first..<end]
        let loading = player.radioLoadingMessage != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playlist").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if player.radioReadyCount > 0 {
                    Text("\(player.radioReadyCount) ready")
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                        .accessibilityIdentifier("radio-ready-count")
                }
            }
            VStack(spacing: 0) {
                ForEach(shown) { track in playlistRow(track) }
                if playlist.count > end - first {
                    Button(showFullQueue ? "Show less" : "Show all \(playlist.count) songs") { showFullQueue.toggle() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioConsoleColors.lavender)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("radio-queue-disclosure")
                }
                if loading {
                    let stage = player.radioRenderStage
                    HStack(spacing: 10) {
                        SongStageDial(phase: stage.phase)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stage.title).font(.subheadline.weight(.semibold))
                            if let detail = stage.detail {
                                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.74))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 48)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(player.isWaitingForRadio ? "Waiting for audio" : "Preparing in the background")
                    .accessibilityIdentifier("radio-loading")
                }
                if playlist.isEmpty && !loading {
                    Text("Songs are queued as you listen.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    private func playlistRow(_ track: RadioPlaylistItem) -> some View {
        let isCurrent = track.position == .current
        let status = switch track.position {
        case .earlier: "Earlier"
        case .current: player.isPlaying ? "Playing" : "Current"
        case .upcoming: "Ready"
        }
        return Button { player.playRadioSong(track.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "waveform" : "music.note")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RadioConsoleColors.lavender)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.semibold))
                    if isCurrent { Text(status).font(.caption).foregroundStyle(RadioConsoleColors.lavender) }
                }
                Spacer(minLength: 8)
                Text(time(track.duration)).font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(6)
            .background(RadioConsoleColors.lavender.opacity(isCurrent ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(track.title)
        .accessibilityValue(status)
        .accessibilityHint(isCurrent ? "Restarts this song" : "Plays this song")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(isCurrent ? "radio-playlist-current" : track.position == .upcoming ? "radio-queued-track" : "radio-playlist-earlier")
    }

    private var radioTransport: some View {
        ViewThatFits(in: .horizontal) {
            radioTransport(showJumps: true)
            radioTransport(showJumps: false)
        }
    }

    private func radioTransport(showJumps: Bool) -> some View {
        HStack(spacing: 0) {
            if player.canGenerate {
                Button { player.playPreviousRadioSong() } label: {
                    Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 48)
                }
                .accessibilityLabel("Previous song")
                .disabled(!player.canPlayPreviousRadioSong)
            } else {
                Button { player.seek(0) } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.title2).frame(width: 44, height: 48)
                }.accessibilityLabel("Restart audio")
            }
            Spacer()
            if showJumps {
                Button { player.seek(player.elapsed - 15) } label: { Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 48) }
                    .accessibilityLabel("Back 15 seconds").disabled(!player.canSeek)
                Spacer()
            }
            Button { player.togglePlayback() } label: {
                Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.18))
                    .frame(width: 52, height: 52)
                    .background(RadioConsoleColors.lavender, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(player.wantsPlayback ? "Pause" : "Play").accessibilityIdentifier("player-playback")
            Spacer()
            if showJumps {
                Button { player.seek(player.elapsed + 15) } label: { Image(systemName: "goforward.15").font(.title3).frame(width: 44, height: 48) }
                    .accessibilityLabel("Forward 15 seconds").disabled(!player.canSeek)
                Spacer()
            }
            if player.canGenerate {
                Button { player.playNextRadioSong() } label: {
                    Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 48)
                }
                .accessibilityLabel("Next song")
                .disabled(!player.canPlayNextRadioSong)
                Spacer()
            }
            Menu {
                Button("15 minutes") { player.setSleepTimer(15) }
                Button("30 minutes") { player.setSleepTimer(30) }
                Button("1 hour") { player.setSleepTimer(60) }
                if player.sleepMinutes != nil { Button("Turn off timer") { player.setSleepTimer(nil) } }
            } label: { Image(systemName: player.sleepMinutes == nil ? "moon.fill" : "moon.zzz.fill").font(.title2).frame(width: 44, height: 48) }.accessibilityLabel("Sleep timer")
        }
    }
}

private enum RadioConsoleColors {
    static let lavender = Color(red: 0.85, green: 0.79, blue: 1)
    static let ice = Color(red: 0.65, green: 0.91, blue: 0.99)
}

private struct RadioPositionDisc: View {
    let palette: Int
    let position: Double

    var body: some View {
        ZStack {
            VibeArtwork(palette: palette, variant: .disc).padding(6)
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(position))
                .stroke(RadioConsoleColors.lavender, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }
}

struct SongStageDial: View {
    let phase: Int
    private let symbols = ["ellipsis", "music.note", "waveform", "checkmark"]

    var body: some View {
        let active = max(0, min(symbols.count - 1, phase))
        ZStack {
            Circle().fill(RadioConsoleColors.ice.opacity(0.08))
            ForEach(symbols.indices, id: \.self) { index in
                let start = CGFloat(index) / 4
                Circle()
                    .trim(from: start + 0.018, to: start + 0.232)
                    .stroke(index <= active ? RadioConsoleColors.ice.opacity(index == active ? 1 : 0.48) : .white.opacity(0.16),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbols[active]).font(.caption.weight(.semibold))
                .foregroundStyle(RadioConsoleColors.ice)
        }
        .padding(2)
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
}

private struct PlayerScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct TrackArtwork: View {
    var image: PlatformImage?
    var palette: Int
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    #if os(macOS)
                    Image(nsImage: image).resizable().scaledToFill()
                    #else
                    Image(uiImage: image).resizable().scaledToFill()
                    #endif
                } else {
                    VibeArtwork(palette: palette, variant: .hero)
                    Image(systemName: "music.note").font(.system(size: max(14, geometry.size.width * 0.18), weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: min(24, geometry.size.width * 0.12)))
        }.accessibilityLabel(image == nil ? "Default song artwork" : "Album artwork")
    }
}
func time(_ seconds: TimeInterval) -> String { let value = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", value / 60, value % 60) }

struct SoundControl: View {
    var name: String
    var symbol: String
    var value: Double
    var valueText: String
    var fixedWidth: CGFloat? = nil
    var update: (Double, Bool) -> Void
    var body: some View {
        HStack(spacing: 8) { Image(systemName: symbol); Text(name) }
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(width: fixedWidth, height: 44)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.20))
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, (geo.size.width - 10) * value)) }
                        .padding(5)
                }
            }
            .vibeGlass()
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Capsule())
                        .gesture(DragGesture(minimumDistance: 4).onChanged { gesture in
                            update(min(1, max(0, gesture.location.x / max(geo.size.width, 1))), false)
                        }.onEnded { gesture in
                            update(min(1, max(0, gesture.location.x / max(geo.size.width, 1))), true)
                        })
                        .simultaneousGesture(SpatialTapGesture().onEnded { gesture in
                            update(min(1, max(0, gesture.location.x / max(geo.size.width, 1))), true)
                        })
                }
            }
            .focusable()
            .onKeyPress(.leftArrow) { update(max(0, value - 0.1), true); return .handled }
            .onKeyPress(.rightArrow) { update(min(1, value + 0.1), true); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name).accessibilityValue(valueText)
            .accessibilityHint("Swipe up or down to adjust, or drag horizontally")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: update(min(1, value + 0.1), true)
                case .decrement: update(max(0, value - 0.1), true)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("sound-control-\(symbol)-\(name)")
    }
}
struct PlayerBackground: View {
    var palette: Int
    var audioLevel: Double
    var beatPulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.16, green: 0.09, blue: 0.26)
                Circle().fill(Color.blue.opacity(0.65)).frame(width: geo.size.width * 1.25).blur(radius: 80).offset(x: -geo.size.width * (drifting ? 0.22 : 0.45), y: -geo.size.height * (drifting ? 0.06 : 0.17))
                Circle().fill((palette == 2 ? Color.teal : Color.pink).opacity(0.45)).frame(width: geo.size.width).blur(radius: 85).offset(x: geo.size.width * (drifting ? 0.30 : 0.55), y: -geo.size.height * (drifting ? 0.24 : 0.35))
                Circle().fill((palette == 2 ? Color.blue : Color.purple).opacity(0.68)).frame(width: geo.size.width * 1.2).blur(radius: 90).offset(x: drifting ? geo.size.width * 0.18 : -20, y: geo.size.height * (drifting ? 0.06 : 0.16))
                Circle().fill(Color.pink.opacity(0.46)).frame(width: geo.size.width).blur(radius: 90).offset(x: geo.size.width * (drifting ? 0.16 : 0.4), y: geo.size.height * (drifting ? 0.31 : 0.45))
                LinearGradient(colors: [.black.opacity(0.10), .clear, .black.opacity(0.24)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color.white.opacity(reduceMotion ? 0 : audioLevel * 0.055)).frame(width: geo.size.width * 0.75).blur(radius: 90)
                    .scaleEffect(beatPulse ? 1.1 : 0.9)
                    .animation(.easeOut(duration: 0.3), value: beatPulse)
                    .animation(.easeOut(duration: 0.2), value: audioLevel)
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .onAppear { startDrift() }
        .onChange(of: reduceMotion) { startDrift() }
    }
    private func startDrift() {
        if reduceMotion { drifting = false }
        else { withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drifting = true } }
    }
}
#if os(macOS)
struct AirPlayButton: View {
    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) } label: {
            Image(systemName: "speaker.wave.2").frame(maxWidth: .infinity, maxHeight: .infinity)
        }.buttonStyle(.plain).help("Open sound output settings")
    }
}
#else
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .white; return view }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(proposal: proposal, subviews: subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified) }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let width = proposal.width ?? 350
        var rows: [[(Int, CGSize)]] = [[]]; var rowWidth: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > width { rows.append([]); rowWidth = 0 }
            rows[rows.count - 1].append((i, size)); rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
        }
        var positions = Array(repeating: CGPoint.zero, count: subviews.count); var y: CGFloat = 0
        for row in rows where !row.isEmpty {
            let total = row.reduce(CGFloat.zero) { $0 + $1.1.width } + CGFloat(row.count - 1) * spacing
            let height = row.map { $0.1.height }.max() ?? 0; var x = max(0, (width - total) / 2)
            for (index, size) in row { positions[index] = CGPoint(x: x, y: y + (height - size.height) / 2); x += size.width + spacing }
            y += height + spacing
        }
        return (CGSize(width: width, height: max(0, y - spacing)), positions)
    }
}

extension View {
    @ViewBuilder func playerContentSurface() -> some View {
        #if os(macOS)
        self
        #else
        self.background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)))
        #endif
    }
    @ViewBuilder func playerConsoleSurface() -> some View {
        #if os(macOS)
        self
        #else
        self.background {
            RoundedRectangle(cornerRadius: 26).fill(.linearGradient(
                colors: [Color(red: 0.105, green: 0.10, blue: 0.16), Color(red: 0.045, green: 0.054, blue: 0.085)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }.overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.14)) }
        #endif
    }
    @ViewBuilder func vibePlayerControls() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain).menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
    @ViewBuilder func vibeGlass() -> some View {
        if #available(iOS 26, macOS 26, *) { self.foregroundStyle(.white).glassEffect(.clear.interactive(), in: Capsule()) }
        else { self.foregroundStyle(.white).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.2))) }
    }
    @ViewBuilder func vibeGlassCircle() -> some View {
        if #available(iOS 26, macOS 26, *) { self.foregroundStyle(.white).glassEffect(.clear.interactive(), in: Circle()) }
        else { self.foregroundStyle(.white).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.15))) }
    }
}

extension View {
    @ViewBuilder func vibeHideNavigationBar() -> some View {
        #if os(macOS)
        self
        #else
        self.toolbar(.hidden, for: .navigationBar)
        #endif
    }
    @ViewBuilder func vibeInlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }
    @ViewBuilder func vibeEditorPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented) { content().frame(minWidth: 580, minHeight: 500) }
        #else
        self.fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
    @ViewBuilder func vibePickerPresentation() -> some View {
        #if os(macOS)
        self.frame(minWidth: 580, minHeight: 500)
        #else
        self.presentationDetents([.large]).presentationDragIndicator(.visible)
        #endif
    }
    @ViewBuilder func vibeTextInput() -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }
    @ViewBuilder func vibeKeyboardDismissal() -> some View {
        #if os(macOS)
        self
        #else
        self.scrollDismissesKeyboard(.interactively)
        #endif
    }
}
