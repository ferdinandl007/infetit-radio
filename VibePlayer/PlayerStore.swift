import SwiftUI
import AVFoundation
import MediaPlayer
import Synchronization
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

struct SongIdea: Identifiable, Codable {
    var id = UUID()
    var title: String
    var prompt: String
    var styles: String? = nil
    var lyrics: String? = nil
    var instrumental: Bool? = nil
    var createdAt = Date()
}

struct SavedSong: Identifiable, Codable {
    let id: UUID
    let title: String
    let filename: String
    let style: String
    let lyrics: String
    let createdAt: Date
    var semanticFilename: String?
}

private struct GeneratedTrack {
    let url: URL
    let request: MusicGenerationRequest
    #if os(macOS)
    let broadcastID = UUID()
    #endif
    var duration: TimeInterval = 0
    var semanticTokens: [Int] = []
    var radioTitle: String?
    var radioSavedID: UUID?
}

struct CreationJob: Identifiable {
    let id = UUID()
    let idea: String
    let styles: String
    let lyrics: String?
    let instrumental: Bool
    let renderer: CreateRenderer
    let length: CreateLength
    let acoustics: CreateAcoustics
    let renderingSteps: RenderingSteps
    let planScore: Bool
    let compactAttentionCache: Bool
    let followStyleClosely: Bool
    let clearLeadVocals: Bool
    let reference: MusicReference?
    let scoreABC: String?
    var title: String { idea.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ") }
}

struct RadioPlaylistItem: Identifiable {
    enum Position { case earlier, current, upcoming }

    let id: URL
    let title: String
    let duration: TimeInterval
    let position: Position
}

enum RadioRenderStage {
    case preparing, lyrics, composing(frames: Int), synthesizing, rendering(step: Int, total: Int), finishing

    var title: String {
        switch self {
        case .preparing: "Preparing song"
        case .lyrics: "Writing lyrics"
        case .composing: "Composing"
        case .synthesizing, .rendering: "Rendering audio"
        case .finishing: "Finishing audio"
        }
    }

    var detail: String? {
        switch self {
        case .composing(let frames):
            frames > 0 ? "\(frames / 25 / 60):\(String(format: "%02d", frames / 25 % 60)) composed" : nil
        case .rendering(let step, let total): step == 0 ? "Preparing synthesis" : "Step \(step) of \(total)"
        default: nil
        }
    }

    var phase: Int {
        switch self {
        case .preparing, .lyrics: 0
        case .composing: 1
        case .synthesizing, .rendering: 2
        case .finishing: 3
        }
    }
}

// The producer writes PCM once, then publishes the end frame to the audio thread.
final class PreviewPCM: @unchecked Sendable {
    static let sampleRate = 48_000
    static let reserve = sampleRate * 3 / 4
    static let fade = sampleRate / 80

    private let samples: UnsafeMutablePointer<Int16>
    private let capacity: Int
    let written = Atomic<Int>(0)
    let played = Atomic<Int>(0)
    let complete = Atomic<Bool>(false)
    let wantsPlayback = Atomic<Bool>(false)
    let needsBuffer = Atomic<Bool>(false)

    // These variables belong to the engine's render thread.
    private var cursor = 0
    private var gain: Float = 0

    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2)
    }

    deinit { samples.deallocate() }

    func sourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] silence, _, frames, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
            silence.pointee = ObjCBool(!render(Int(frames), left: left, right: right))
            return noErr
        }
    }

    @MainActor
    func append(_ input: UnsafeBufferPointer<Int16>, at start: Int) throws {
        let count = input.count / 2
        guard count > 0, input.count.isMultiple(of: 2), let address = input.baseAddress,
              start == written.load(ordering: .relaxed), count <= capacity - start else {
            throw MusicGenerationError.unavailable
        }
        (samples + start * 2).initialize(from: address, count: input.count)
        written.store(start + count, ordering: .releasing)
    }

    func render(_ count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let finished = complete.load(ordering: .acquiring)
        let available = written.load(ordering: .acquiring)
        let requested = wantsPlayback.load(ordering: .acquiring)
        if requested, !finished, available - cursor <= Self.reserve {
            needsBuffer.store(true, ordering: .releasing)
        }
        let running = requested && !needsBuffer.load(ordering: .acquiring)
        let ramp = 1 / Float(Self.fade)
        var wroteAudio = false
        for frame in 0..<count {
            gain = running ? min(1, gain + ramp) : max(0, gain - ramp)
            if cursor < available, running || gain > 0 {
                let amplitude = gain / 32768
                left[frame] = Float(samples[cursor * 2]) * amplitude
                right[frame] = Float(samples[cursor * 2 + 1]) * amplitude
                cursor += 1
                wroteAudio = true
            } else {
                left[frame] = 0
                right[frame] = 0
            }
        }
        played.store(cursor, ordering: .releasing)
        return wroteAudio
    }
}

@MainActor @Observable
private final class PreviewPlayback {
    private let engine = AVAudioEngine()
    private let pcm: PreviewPCM
    private let acoustics: CreateAcoustics
    private let lowLatency: Bool
    private(set) var bufferedDuration: TimeInterval = 0
    private var lastChunk: ContinuousClock.Instant?
    private var renderRate = 1.0
    private var hasStarted = false
    private var endObservedAt: ContinuousClock.Instant?

    init(_ preview: MusicAudioPreview, acoustics: CreateAcoustics) throws {
        let rate = Double(PreviewPCM.sampleRate)
        guard (1...PreviewPCM.sampleRate * 300).contains(preview.totalFrames),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw MusicGenerationError.unavailable
        }
        let pcm = PreviewPCM(capacity: preview.totalFrames)
        self.pcm = pcm
        self.acoustics = acoustics
        self.lowLatency = preview.lowLatency
        let node = pcm.sourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try append(preview)
    }

    func append(_ preview: MusicAudioPreview) throws {
        try preview.samples.withUnsafeBufferPointer { try pcm.append($0, at: preview.startFrame) }
        let now = ContinuousClock.now
        if let lastChunk, acoustics == .streaming || lowLatency {
            let audio = Double(preview.samples.count / 2) / Double(PreviewPCM.sampleRate)
            let delta = lastChunk.duration(to: now).components
            let measured = min(2.5, (Double(delta.seconds) + Double(delta.attoseconds) / 1e18) / audio)
            renderRate = 0.40 * renderRate + 0.60 * measured
        }
        lastChunk = now
        bufferedDuration = Double(pcm.written.load(ordering: .relaxed)) / Double(PreviewPCM.sampleRate)
    }

    var elapsed: TimeInterval {
        Double(pcm.played.load(ordering: .acquiring)) / Double(PreviewPCM.sampleRate)
    }

    var needsBuffer: Bool { pcm.needsBuffer.load(ordering: .acquiring) }

    var readyToPlay: Bool {
        if pcm.complete.load(ordering: .acquiring) { return true }
        let available = bufferedDuration - elapsed
        if hasStarted, !needsBuffer { return available >= 1.5 }
        if lowLatency {
            let reserve = hasStarted ? 5 + min(9, max(0, (renderRate - 1) * 12)) : 2.5
            return available >= reserve
        }
        // Whole-song synthesis is already complete when these PCM tiles arrive.
        if acoustics != .streaming { return available >= 7.5 }
        let minimum = hasStarted ? 28.0 : 24.0
        let additional = min(18, max(0, (renderRate - 1) * 60))
        return available >= minimum + additional
    }

    var hasEnded: Bool {
        guard pcm.complete.load(ordering: .acquiring), elapsed >= bufferedDuration else { return false }
        let now = ContinuousClock.now
        guard let endObservedAt else { self.endObservedAt = now; return false }
        return endObservedAt.duration(to: now) >= .seconds(max(0.15, engine.outputNode.presentationLatency))
    }

    func play() throws {
        if !engine.isRunning { try engine.start() }
        hasStarted = true
        pcm.needsBuffer.store(false, ordering: .releasing)
        pcm.wantsPlayback.store(true, ordering: .releasing)
    }

    func pause() { pcm.wantsPlayback.store(false, ordering: .releasing) }

    func stop() { pause(); engine.stop() }

    func appendRemainder(at url: URL) throws {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let start = pcm.written.load(ordering: .relaxed)
        guard source.length >= start, source.processingFormat.channelCount == 2,
              source.processingFormat.sampleRate == Double(PreviewPCM.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else {
            throw MusicGenerationError.unavailable
        }
        source.framePosition = AVAudioFramePosition(start)
        while source.framePosition < source.length {
            let offset = Int(source.framePosition)
            try source.read(into: buffer)
            guard let samples = buffer.int16ChannelData?[0] else { throw MusicGenerationError.unavailable }
            try pcm.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength) * 2), at: offset)
        }
        bufferedDuration = Double(source.length) / Double(PreviewPCM.sampleRate)
        pcm.complete.store(true, ordering: .releasing)
    }
}

@MainActor @Observable
final class PlayerStore: NSObject, AVAudioPlayerDelegate {
    var vibes: [Vibe] = []
    var songIdeas: [SongIdea] = []
    private(set) var savedSongs: [SavedSong] = []
    private var currentTrack: GeneratedTrack?
    private var radioPlaylist: [GeneratedTrack] = []
    private var radioPlaybackIndex: Int?
    private var preparedRadioSeed: UInt64?
    private var radioRenderTiming: RadioRenderTiming?
    let radioQueueCapacity = 10
    private var radioArrangement = Int.random(in: MusicPromptBuilder.radioArrangements.indices)
    private var usedRadioTitles: Set<String> = []
    private var currentSavedID: UUID?
    var currentSavedSongID: UUID? { currentSavedID }
    private(set) var radioMode = true
    private var radioWantsPlayback = false
    private var radioPreloading = false
    private var radioPreparationSuspended = false
    #if os(macOS)
    private var radioActivity: NSObjectProtocol?
    let webRadio = WebRadio()

    var webRadioSnapshot: WebRadioSnapshot {
        let live = radioMode && isPlaying && currentTrack?.request.purpose == .radio && audio?.isPlaying == true
        let station = live ? currentTrack?.request.stationName ?? selected.name : selected.name
        return WebRadioSnapshot(station: station, description: selected.subtitle, title: live ? trackName : nil,
                                state: live ? "live" : (isWaitingForRadio ? "preparing" : "off-air"),
                                position: live ? audio?.currentTime ?? 0 : 0, duration: live ? duration : 0)
    }

    var webRadioTracks: [WebRadioTrack] {
        guard radioMode else { return [] }
        var tracks: [GeneratedTrack] = []
        if let currentTrack, currentTrack.request.purpose == .radio { tracks.append(currentTrack) }
        if radioPlaylist.indices.contains(nextRadioIndex) { tracks.append(radioPlaylist[nextRadioIndex]) }
        return tracks.map { WebRadioTrack(id: $0.broadcastID, url: $0.url) }
    }
    #else
    private var radioRenderingInForeground = true
    #endif
    private var replaceWhenReady = false
    private var isEditingRadio = false
    private var prioritizeNextRadioSong = false
    private(set) var radioSoundChangeID: UUID?
    private var radioTrackEnded = false
    private var radioCanRetry = true
    var remixSource: MusicReference?
    private var fadingPlayer: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?
    var selectedID: UUID?
    var isPlaying = false
    var audioLevel: Double = 0
    var beatPulse = false
    private var smoothedLevel: Double = 0
    private var lastBeat = Date.distantPast
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var trackName = "A little atmosphere"
    private(set) var trackArtist: String?
    private(set) var trackArtwork: PlatformImage?
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID = UUID()
    var isSample = true
    private(set) var isGenerated = false
    private(set) var isGenerating = false
    private(set) var isWritingLyrics = false
    private(set) var isCreating = false
    private(set) var generationProgress = 0.0
    private(set) var radioRenderStage: RadioRenderStage = .preparing
    private(set) var creationStatus = ""
    private(set) var creationNotice: String?
    private(set) var activeCreation: CreationJob?
    private(set) var queuedCreations: [CreationJob] = []
    private(set) var lastCreatedSong: SavedSong?
    private var creationAutoplay = false
    private(set) var isBufferingPreview = false
    var canGenerate: Bool { generationBackend.isAvailable }
    var canUsePairedMetal: Bool { generationBackend.canUsePairedMetal }
    var canStreamAcoustics: Bool { generationBackend.canStreamAcoustics }
    var canPlanScore: Bool { generationBackend.canPlanScore }
    var canRenderMelody: Bool {
        #if os(macOS)
        canGenerate
        #else
        false
        #endif
    }
    func prepareRendering(_ acoustics: CreateAcoustics, compactAttentionCache: Bool = false, preferFullPrecision: Bool = false) {
        generationBackend.prepareRendering(acoustics, compactAttentionCache: compactAttentionCache, preferFullPrecision: preferFullPrecision)
    }
    var canCreateExtended: Bool { generationBackend.canCreateExtended }
    private var nextRadioIndex: Int { (radioPlaybackIndex ?? -1) + 1 }
    var radioReadyCount: Int { min(radioQueueCapacity, radioPlaylist.count - nextRadioIndex) }
    var canPlayPreviousRadioSong: Bool { radioMode && (radioPlaybackIndex ?? 0) > 0 }
    var canPlayNextRadioSong: Bool { radioMode && radioPlaylist.indices.contains(nextRadioIndex) }
    var radioPlaylistItems: [RadioPlaylistItem] {
        radioPlaylist.enumerated().map { index, track in
            let position: RadioPlaylistItem.Position = if index == radioPlaybackIndex { .current }
                else if index < nextRadioIndex { .earlier }
                else { .upcoming }
            return RadioPlaylistItem(id: track.url, title: track.radioTitle ?? track.request.stationName,
                                     duration: track.duration, position: position)
        }
    }
    var isWaitingForRadio: Bool { radioMode && radioWantsPlayback && !isPlaying }
    var shouldKeepScreenAwake: Bool { isCreating || isWaitingForRadio || (radioPreloading && !isPlaying && isGenerating) }
    var radioLoadingMessage: String? {
        guard radioMode, canGenerate, !isCreating,
              isWaitingForRadio || isGenerating || isEditingRadio || automaticGenerationTask != nil else { return nil }
        if prioritizeNextRadioSong || isEditingRadio { return "Updating your sound…" }
        return isGenerated ? "Preparing the next song…" : "Preparing your station…"
    }
    var wantsPlayback: Bool { isPlaying || isWaitingForRadio }
    var errorMessage: String?
    var liked = false
    var disliked = false
    var sleepMinutes: Int?
    private var sleepTimer: Timer?
    var savedIDs: Set<UUID> = []
    private var audio: AVAudioPlayer?
    private var previewPlayer: PreviewPlayback?
    private var previewGenerationID: UUID?
    var canSeek: Bool { duration > 0 && previewGenerationID == nil }
    var isPlayingPreview: Bool { previewGenerationID != nil && isPlaying && !isBufferingPreview }
    var hasCreationPreview: Bool { previewGenerationID != nil }
    var creationBufferedDuration: TimeInterval { hasCreationPreview ? previewPlayer?.bufferedDuration ?? 0 : 0 }
    var isPlayingLastCreatedSong: Bool { lastCreatedSong?.id != nil && currentSavedID == lastCreatedSong?.id && isPlaying }
    private var timer: Timer?
    private let defaultsKey = "vibe-player-vibes-v1"
    private var generationBackend: any MusicGenerationBackend
    private let lyricsWriter: any LyricsWriter
    private var generationTask: Task<Void, Never>?
    private var automaticGenerationTask: Task<Void, Never>?
    private var generationID: UUID?

    var selectedIndex: Int { vibes.firstIndex(where: { $0.id == selectedID }) ?? 0 }
    var selected: Vibe { vibes[selectedIndex] }

    @discardableResult
    func reloadMusicModel() -> Bool {
        guard !isGenerating, !isCreating else { return false }
        let backend = YuE2GenerationBackend()
        guard backend.isAvailable else { return false }
        generationBackend = backend
        return true
    }

    override convenience init() { self.init(generationBackend: UnavailableMusicGenerationBackend(), lyricsWriter: GeminiLyricsWriter()) }

    convenience init(generationBackend: any MusicGenerationBackend) {
        self.init(generationBackend: generationBackend, lyricsWriter: GeminiLyricsWriter())
    }

    init(generationBackend: any MusicGenerationBackend, lyricsWriter: any LyricsWriter) {
        self.generationBackend = generationBackend
        self.lyricsWriter = lyricsWriter
        super.init()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            for key in [defaultsKey, "vibe-player-song-ideas", "saved-vibes", "imported-audio-filename", "imported-audio-name",
                        "vibe-player-saved-songs", "vibe-create-acoustics", "vibe-create-vocal-acoustics",
                        RenderingSteps.createPreferenceKey, RenderingSteps.radioPreferenceKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let saved = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([Vibe].self, from: $0) } ?? []
        vibes = StationCatalog.merging(saved)
        persist()
        if let data = UserDefaults.standard.data(forKey: "vibe-player-song-ideas"), let ideas = try? JSONDecoder().decode([SongIdea].self, from: data) { songIdeas = ideas }
        if let data = UserDefaults.standard.data(forKey: "vibe-player-saved-songs"),
           let songs = try? JSONDecoder().decode([SavedSong].self, from: data) { savedSongs = songs }
        selectedID = vibes.first?.id
        savedIDs = Set((UserDefaults.standard.stringArray(forKey: "saved-vibes") ?? []).compactMap(UUID.init(uuidString:)))
        if let filename = UserDefaults.standard.string(forKey: "imported-audio-filename"),
           let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            load(url: directory.appendingPathComponent(filename), name: UserDefaults.standard.string(forKey: "imported-audio-name") ?? "Imported audio", sample: true)
            isSample = false
            loadTrackMetadata(from: directory.appendingPathComponent(filename))
        } else if let url = Bundle.main.url(forResource: "atmosphere", withExtension: "wav") {
            load(url: url, name: "A little atmosphere", sample: true)
            radioMode = true
        }
        setupRemoteCommands()
    }

    @discardableResult
    func createStation(named name: String, basedOn source: Vibe?, soundDescription: String,
                       instrumental: Bool) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        let description = soundDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags = (source?.tags ?? []).filter { tag in
            tag.name != "Vocals" && tag.name != "Instrumental" && (!instrumental || tag.category != .language)
        }
        if let voice = tagOptions.first(where: { $0.name == (instrumental ? "Instrumental" : "Vocals") }) {
            tags.append(voice)
        }
        let station = Vibe(name: cleanName, subtitle: "Custom station", tags: tags, tempo: source?.tempo ?? 100,
                           palette: source?.palette ?? 0, soundDescription: description.isEmpty ? source?.soundDescription : description)
        vibes.append(station)
        persist()
        select(station)
        return true
    }

    func select(_ vibe: Vibe) {
        guard !radioMode || selectedID != vibe.id else { return }
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        discardRadioQueue()
        radioMode = true
        radioWantsPlayback = canGenerate && (isPlaying || radioWantsPlayback)
        replaceWhenReady = true
        radioCanRetry = true
        radioPreparationSuspended = false
        radioSoundChangeID = nil
        selectedID = vibe.id
        isEditingRadio = false
        updateNowPlaying()
        if radioWantsPlayback { scheduleRadioUpdate() }
    }
    func updateSelected(_ update: (inout Vibe) -> Void) {
        guard !vibes.isEmpty else { return }
        let previous = selected.musicProfile
        update(&vibes[selectedIndex]); persist(); updateNowPlaying()
        if selected.musicProfile != previous {
            applyRadioSoundChange()
        }
    }
    func setIntensity(_ name: String, value: Double, commit: Bool = false) {
        guard let index = vibes[selectedIndex].tags.firstIndex(where: { $0.name == name }) else { return }
        let intensity = min(1, max(0, value))
        let changed = vibes[selectedIndex].tags[index].intensity != intensity
        vibes[selectedIndex].tags[index].intensity = intensity
        radioControlChanged(changed, commit: commit)
    }
    func setTempo(_ value: Double, commit: Bool = false) {
        let tempo = min(180, max(50, value.rounded()))
        let changed = vibes[selectedIndex].tempo != tempo
        vibes[selectedIndex].tempo = tempo
        radioControlChanged(changed, commit: commit)
    }
    private func radioControlChanged(_ changed: Bool, commit: Bool) {
        guard changed || (commit && isEditingRadio) else { return }
        isEditingRadio = !commit
        if commit {
            persist()
            applyRadioSoundChange()
        }
    }
    private func applyRadioSoundChange() {
        isEditingRadio = false
        guard canGenerate else { return }
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        preparedRadioSeed = nil
        radioMode = true
        radioWantsPlayback = isPlaying || radioWantsPlayback
        prioritizeNextRadioSong = true
        radioCanRetry = true
        radioSoundChangeID = UUID()
        scheduleRadioUpdate()
    }
    func persist() {
        if let data = try? JSONEncoder().encode(vibes) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
    func saveIdea(title: String, prompt: String, styles: String? = nil, lyrics: String? = nil, instrumental: Bool? = nil) {
        songIdeas.insert(SongIdea(title: title, prompt: prompt, styles: styles, lyrics: lyrics, instrumental: instrumental), at: 0)
        if let data = try? JSONEncoder().encode(songIdeas) { UserDefaults.standard.set(data, forKey: "vibe-player-song-ideas") }
    }
    func deleteIdea(_ id: UUID) {
        songIdeas.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(songIdeas) { UserDefaults.standard.set(data, forKey: "vibe-player-song-ideas") }
    }
    func toggleSaved() {
        if savedIDs.contains(selected.id) { savedIDs.remove(selected.id) } else { savedIDs.insert(selected.id) }; UserDefaults.standard.set(savedIDs.map(\.uuidString), forKey: "saved-vibes")
    }
    func generateSong(
        idea: String = "", instrumental: Bool? = nil, preparedLyrics: String? = nil,
        createStyles: String? = nil, createRenderer: CreateRenderer = .metal, createLength: CreateLength = .automatic,
        acoustics: CreateAcoustics = .reference, renderingSteps: RenderingSteps = .createDefault, reference: MusicReference? = nil,
        followStyleClosely: Bool = true, clearLeadVocals: Bool = false, planScore: Bool = true,
        compactAttentionCache: Bool = false, scoreABC: String? = nil
    ) {
        if let createStyles {
            guard canGenerate else { errorMessage = MusicGenerationError.metalUnavailable.errorDescription; return }
            guard scoreABC == nil || (canRenderMelody && reference == nil) else {
                errorMessage = "Melody covers need the Mac YuE2 renderer and a single reference."
                return
            }
            let useScore = planScore && scoreABC == nil && canPlanScore && reference == nil && acoustics == .reference
                && instrumental != true && createRenderer == .metal
            queuedCreations.append(CreationJob(idea: idea, styles: createStyles, lyrics: preparedLyrics,
                                               instrumental: instrumental ?? false, renderer: createRenderer,
                                               length: createLength, acoustics: reference == nil ? acoustics : .reference,
                                               renderingSteps: renderingSteps,
                                               planScore: useScore,
                                               compactAttentionCache: useScore && compactAttentionCache,
                                               followStyleClosely: followStyleClosely, clearLeadVocals: clearLeadVocals,
                                               reference: reference, scoreABC: scoreABC))
            if !isCreating {
                cancelGeneration()
                errorMessage = nil
                #if os(macOS)
                startNextCreation(autoplay: !webRadio.isRunning)
                #else
                startNextCreation(autoplay: true)
                #endif
            }
            return
        }
        runGeneration(idea: idea, instrumental: instrumental, preparedLyrics: preparedLyrics)
    }

    func removeQueuedCreation(_ id: UUID) { queuedCreations.removeAll { $0.id == id } }

    func cancelCurrentCreation() {
        guard isCreating else { return }
        cancelGeneration()
        startNextCreation(autoplay: !isPlaying && !radioMode)
        fillRadioQueue()
    }

    private func startNextCreation(autoplay: Bool) {
        guard !isGenerating, !queuedCreations.isEmpty else { return }
        let job = queuedCreations.removeFirst()
        runGeneration(idea: job.idea, instrumental: job.instrumental, preparedLyrics: job.lyrics,
                      job: job, autoplay: autoplay)
    }

    private func runGeneration(idea: String, instrumental: Bool?, preparedLyrics: String?,
                               job: CreationJob? = nil, autoplay: Bool = false) {
        let isPrompted = job != nil
        guard !isGenerating else { return }
        guard canGenerate else { errorMessage = MusicGenerationError.metalUnavailable.errorDescription; return }
        automaticGenerationTask?.cancel()
        automaticGenerationTask = nil
        if isPrompted && autoplay { radioMode = false; radioWantsPlayback = false; isEditingRadio = false; discardRadioQueue() }
        activeCreation = job
        creationAutoplay = isPrompted && autoplay
        let voiceOverride: MusicGenerationRequest.Voice? = instrumental.map { $0 ? .instrumental : .vocals }
        #if os(macOS)
        let listenerSuggestion = !isPrompted && radioMode && idea.isEmpty ? webRadio.nextSuggestion(for: selected.id) : nil
        let isListenerSong = listenerSuggestion != nil
        #else
        let isListenerSong = false
        #endif
        let reservedSeed = isPrompted || isListenerSong ? nil : preparedRadioSeed
        if !isPrompted { preparedRadioSeed = nil }
        let seed = reservedSeed ?? UInt64.random(in: 0...UInt64(Int64.max))
        let radioProfile = selected.musicProfile
        let arrangement = radioArrangement
        func makeCreateRequest(for job: CreationJob, idea: String) -> MusicGenerationRequest {
            var request = MusicPromptBuilder().makeCreateRequest(idea: idea, styles: job.styles, instrumental: job.instrumental,
                                                                  seed: seed, length: job.length, followStyleClosely: job.followStyleClosely,
                                                                  clearLeadVocals: job.clearLeadVocals, renderingSteps: job.renderingSteps)
            request.createRenderer = job.length == .extended ? .metal : job.renderer
            request.createAcoustics = job.acoustics
            request.planScore = job.planScore
            request.compactAttentionCache = job.compactAttentionCache
            if let scoreABC = job.scoreABC {
                request.scoreABC = scoreABC
                request.createRenderer = .metal
                request.createAcoustics = .reference
                request.minimumSemanticFrames = 200
                request.maxSemanticFrames = 7_500
            }
            return request
        }
        var request = job.map { makeCreateRequest(for: $0, idea: idea) }
            ?? MusicPromptBuilder().makeRadioPlaybackRequest(profile: radioProfile, seed: seed, idea: idea,
                                                            voiceOverride: voiceOverride, arrangement: arrangement)
        #if os(macOS)
        if let listenerSuggestion {
            request.listenerTheme = listenerSuggestion.text
            if request.voice != .vocals {
                request.style += "; in the station's established style, evoke this imagery: “\(listenerSuggestion.text)”"
            }
        }
        #endif
        if !isPrompted, let radioRenderTiming {
            request.synthesisSteps = radioRenderTiming.stepCount(preferred: RenderingSteps.radioPreferred,
                                                               readySongs: radioReadyCount, voice: request.voice)
        }
        if request.voice == .vocals, let preparedLyrics, !preparedLyrics.isEmpty { request = request.withLyrics(preparedLyrics) }
        let id = UUID()
        let started = ContinuousClock.now
        let title = idea.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        generationID = id
        isGenerating = true
        isCreating = isPrompted
        generationProgress = 0.04
        radioRenderStage = .preparing
        if !isPrompted { errorMessage = nil }
        creationStatus = isPrompted ? "Preparing your song…" : ""
        creationNotice = nil
        if !isPrompted { updateNowPlaying() }
        generationTask = Task { [weak self, generationBackend, lyricsWriter] in
            defer {
                if isPrompted, let self, !self.isGenerating {
                    self.startNextCreation(autoplay: !self.isPlaying && !self.radioMode)
                    if !self.isGenerating && self.errorMessage == nil { self.fillRadioQueue() }
                }
            }
            var resultURL: URL?
            do {
                // A cancelled Radio job can still be inside acoustic prediction. Let it
                // release its GPU allocations before starting another render or writer model.
                try await generationBackend.waitForIdle()
                try Task.checkCancellation()
                guard self?.generationID == id else { return }
                #if os(macOS)
                if !isPrompted, request.voice == .vocals, request.lyrics.isEmpty {
                    generationBackend.prepareRendering(.reference, compactAttentionCache: false, preferFullPrecision: false)
                }
                #endif
                var prepared = request
                if let job, job.scoreABC == nil {
                    self?.creationStatus = "Rewriting your idea…"
                    do {
                        if let rewritten = try await lyricsWriter.rewriteIdea(idea, styles: job.styles) {
                            try Task.checkCancellation()
                            guard self?.generationID == id else { return }
                            prepared = makeCreateRequest(for: job, idea: rewritten)
                            if !request.lyrics.isEmpty { prepared = prepared.withLyrics(request.lyrics) }
                        } else {
                            self?.creationNotice = "Using your original idea. Automatic rewriting is unavailable right now."
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        guard self?.generationID == id else { return }
                        self?.creationNotice = "Couldn't rewrite your idea, so we're using the original."
                    }
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                }
                if prepared.voice == .vocals && prepared.lyrics.isEmpty {
                    self?.isWritingLyrics = true
                    self?.creationStatus = "Writing lyrics…"
                    if !isPrompted {
                        self?.radioRenderStage = .lyrics
                        let usage = try await generationBackend.promptUsage(for: prepared)
                        prepared.radioUsesLongerLyrics = (usage?.limit ?? 0) >= 512
                        try Task.checkCancellation()
                        guard self?.generationID == id else { return }
                    }
                    let lyrics = try await lyricsWriter.writeLyrics(for: prepared)
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                    guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GeminiLyricsError.empty }
                    prepared = prepared.withLyrics(lyrics)
                    self?.isWritingLyrics = false
                }
                if let reference = job?.reference {
                    prepared.semanticPrefix = reference.prefix
                }
                if let usage = try await generationBackend.promptUsage(for: prepared), usage.count > usage.limit {
                    if isPrompted { self?.creationStatus = "Revising the prompt to fit…" }
                    prepared = try await Self.fitMusicPrompt(prepared, usage: usage,
                                                              backend: generationBackend, writer: lyricsWriter)
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                    if isPrompted { self?.creationNotice = "The writing model revised a copy of your text to fit the music model." }
                }
                self?.creationStatus = "Preparing the music model…"
                let suggestedTitle = isPrompted ? nil : try? await lyricsWriter.suggestRadioTitle(for: prepared)
                try Task.checkCancellation()
                guard self?.generationID == id else { return }
                if !isPrompted { self?.radioRenderStage = .preparing }
                let acoustics = prepared.createAcoustics
                let streamsAudio = isPrompted && self?.creationAutoplay == true && job?.reference?.originalAudio == nil
                let stream = streamsAudio ? AsyncStream.makeStream(of: MusicAudioPreview.self) : nil
                let previewTask = stream.map { stream in
                    Task { @MainActor [weak self] in
                        for await preview in stream.stream {
                            self?.receivePreview(preview, title: title.isEmpty ? "Your song" : title, generation: id, acoustics: acoustics)
                        }
                    }
                }
                defer { stream?.continuation.finish(); previewTask?.cancel() }
                let onPreview: (@Sendable (MusicAudioPreview) -> Void)?
                if let stream { onPreview = { preview in stream.continuation.yield(preview) } }
                else { onPreview = nil }
                if !isPrompted, !isListenerSong, reservedSeed == nil, request.voice == .instrumental, prepared.style == request.style,
                   generationBackend.canPrepareRadioPair,
                   self?.canComposeRadioPairAhead == true {
                    let nextSeed = Self.newRadioSeed(excluding: prepared.seed)
                    let next = MusicPromptBuilder().makeRadioPlaybackRequest(profile: radioProfile, seed: nextSeed, idea: idea,
                                                                            voiceOverride: voiceOverride, arrangement: arrangement + 1)
                    prepared.radioSuccessor = .init(seed: nextSeed, style: next.style)
                }
                let synthesisTiming = Mutex((start: Optional<ContinuousClock.Instant>.none,
                                             end: Optional<ContinuousClock.Instant>.none))
                let measureRadio = !isPrompted && reservedSeed == nil && prepared.radioSuccessor == nil
                let output = try await generationBackend.generate(prepared, onPreview: onPreview) { [weak self] progress in
                    if measureRadio {
                        switch progress {
                        case .synthesizing, .synthesis(0, _):
                            synthesisTiming.withLock { if $0.start == nil { $0.start = .now } }
                        case .waveform:
                            synthesisTiming.withLock { if $0.end == nil { $0.end = .now } }
                        default: break
                        }
                    }
                    Task { @MainActor in
                        guard let self, self.generationID == id else { return }
                        let fraction: Double
                        switch progress {
                        case .planningMusic:
                            fraction = 0.08
                            guard fraction >= self.generationProgress else { return }
                            if isPrompted { self.creationStatus = job?.scoreABC == nil ? "Planning melody and chords…" : "Composing from the reference melody…" }
                            else { self.radioRenderStage = .composing(frames: 0) }
                        case .tokens(let count, let limit):
                            fraction = 0.08 + 0.52 * Double(count) / Double(max(limit, 1))
                            guard self.generationProgress < 0.60, fraction >= self.generationProgress else { return }
                            if isPrompted { self.creationStatus = "Composing music · \(count) of up to \(limit) frames" }
                            else { self.radioRenderStage = .composing(frames: count) }
                        case .synthesizing:
                            fraction = 0.60
                            guard fraction >= self.generationProgress else { return }
                            if isPrompted { self.creationStatus = "Synthesizing audio…" }
                            else { self.radioRenderStage = .synthesizing }
                        case .synthesis(let step, let total):
                            fraction = 0.60 + 0.34 * Double(step) / Double(max(total, 1))
                            guard fraction >= self.generationProgress else { return }
                            if isPrompted {
                                self.creationStatus = step == 0 ? "Preparing synthesis…" : "Whole-song synthesis · step \(step) of \(total)"
                            }
                            else { self.radioRenderStage = .rendering(step: step, total: total) }
                        case .waveform:
                            fraction = 0.96
                            if isPrompted { self.creationStatus = acoustics == .streaming ? "Finishing audio…" : "Decoding audio…" }
                            else { self.radioRenderStage = .finishing }
                        }
                        self.generationProgress = max(self.generationProgress, fraction)
                    }
                }
                let url = output.url
                resultURL = url
                stream?.continuation.finish()
                await previewTask?.value
                try Task.checkCancellation()
                guard let self, self.generationID == id else { try? FileManager.default.removeItem(at: url); return }
                if let reference = job?.reference, let original = reference.originalAudio {
                    self.creationStatus = "Blending the original opening…"
                    try await Self.preserveOpening(from: original, in: url, prefix: reference.prefix, result: output.semanticTokens)
                    try Task.checkCancellation()
                    guard self.generationID == id else { try? FileManager.default.removeItem(at: url); return }
                }
                var track = GeneratedTrack(url: url, request: prepared, semanticTokens: output.semanticTokens)
                if isPrompted {
                    let saved = try self.persistSong(track, title: title.isEmpty ? "Your song" : title)
                    self.lastCreatedSong = saved
                    let completed = GeneratedTrack(url: self.songURL(saved), request: prepared, semanticTokens: output.semanticTokens)
                    if !self.completePreview(completed, savedID: saved.id, generation: id), self.creationAutoplay {
                        try self.startTrack(completed, savedID: saved.id, crossfade: self.isPlaying)
                    }
                    self.finishGeneration(id)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    let audioFile = try AVAudioFile(forReading: url)
                    guard audioFile.length > 0 else { throw MusicGenerationError.unavailable }
                    track.duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    if measureRadio {
                        let synthesis = synthesisTiming.withLock { timing -> Duration in
                            guard let start = timing.start, let end = timing.end else { return .zero }
                            return start.duration(to: end)
                        }
                        self.radioRenderTiming = RadioRenderTiming(voice: prepared.voice, steps: prepared.synthesisSteps,
                                                                  elapsed: started.duration(to: .now), synthesis: synthesis,
                                                                  audioDuration: track.duration)
                    }
                    track.radioTitle = self.uniqueRadioTitle(suggestedTitle, seed: prepared.seed)
                    self.radioCanRetry = true
                    self.radioArrangement = (arrangement + 1) % MusicPromptBuilder.radioArrangements.count
                    self.preparedRadioSeed = output.radioSuccessorSeed
                    #if os(macOS)
                    if let listenerSuggestion { self.webRadio.finishSuggestion(listenerSuggestion.id) }
                    #endif
                    let switchToUpdatedSound = self.prioritizeNextRadioSong && self.radioWantsPlayback
                    if self.prioritizeNextRadioSong {
                        if self.radioReadyCount >= self.radioQueueCapacity && !switchToUpdatedSound {
                            let replaced = self.radioPlaylist.removeLast()
                            self.discardTemporaryTrackIfUnused(replaced)
                        }
                        self.radioPlaylist.insert(track, at: self.nextRadioIndex)
                        self.prioritizeNextRadioSong = false
                    } else {
                        self.radioPlaylist.append(track)
                    }
                    self.finishGeneration(id)
                    if self.radioWantsPlayback && (!self.isPlaying || self.replaceWhenReady || switchToUpdatedSound) {
                        self.advanceRadio(crossfade: self.isPlaying)
                    } else { self.fillRadioQueue() }
                }
                resultURL = nil
            } catch is CancellationError {
                if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
                self?.cancelPreview(generation: id)
                if let self, self.generationID == id, !isPrompted {
                    self.suspendRadioPreparation()
                    self.errorMessage = "Radio preparation stopped. Tap Play to try again."
                }
                self?.finishGeneration(id)
            } catch {
                if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
                guard let self, self.generationID == id else { return }
                #if os(macOS)
                if let listenerSuggestion { self.webRadio.finishSuggestion(listenerSuggestion.id) }
                #endif
                self.cancelPreview(generation: id)
                self.finishGeneration(id)
                if !isPrompted {
                    if (self.radioWantsPlayback || self.radioPreloading), self.radioCanRetry {
                        self.radioCanRetry = false
                        self.scheduleRadioUpdate(after: .seconds(2))
                        return
                    }
                    self.suspendRadioPreparation()
                }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't generate this song. Please try again."
                if !isPrompted { self.updateNowPlaying() }
            }
        }
    }

    private static func fitMusicPrompt(_ original: MusicGenerationRequest, usage: MusicPromptUsage,
                                       backend: any MusicGenerationBackend, writer: any LyricsWriter) async throws -> MusicGenerationRequest {
        var request = original
        var budget = usage
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let reviseStyle = request.lyrics.isEmpty || budget.lyricTokens < 32 || (attempt == 0 && budget.styleTokens > 35)
            let field: MusicPromptField = reviseStyle ? .description : .lyrics
            let text = reviseStyle ? request.style : request.lyrics
            let fieldTokens = reviseStyle ? budget.styleTokens : budget.lyricTokens
            let excess = budget.count - budget.limit
            let target = max(12, fieldTokens - excess - 10 * (attempt + 1))
            guard let revised = try await writer.reviseForMusicModel(text, field: field, targetTokens: target),
                  !revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            if reviseStyle {
                request.style = revised
            } else if request.purpose == .radio {
                let sheet = RadioLyricSheet(longer: request.radioUsesLongerLyrics)
                guard let lyrics = sheet.render(revised) else { continue }
                request = request.withLyrics(lyrics)
            } else {
                request = request.withLyrics(revised)
            }
            guard let updated = try await backend.promptUsage(for: request) else { return request }
            if updated.count <= updated.limit { return request }
            budget = updated
        }
        throw MusicGenerationError.promptTooLong(count: budget.count, limit: budget.limit)
    }

    func cancelGeneration() {
        if let generationID { cancelPreview(generation: generationID) }
        radioPreloading = false
        automaticGenerationTask?.cancel()
        automaticGenerationTask = nil
        preparedRadioSeed = nil
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
        isWritingLyrics = false
        isCreating = false
        activeCreation = nil
        generationProgress = 0
        radioRenderStage = .preparing
        creationStatus = ""
        updateNowPlaying()
    }

    #if os(macOS)
    func prepareForTermination() async {
        webRadio.stop()
        let pendingRender = generationTask
        queuedCreations.removeAll()
        pause()
        cancelGeneration()
        await pendingRender?.value
        audio?.stop()
        await generationBackend.releaseResources()
    }
    #endif
    private func scheduleRadioUpdate(after delay: Duration = .milliseconds(450)) {
        guard canGenerate else { return }
        automaticGenerationTask?.cancel()
        automaticGenerationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.automaticGenerationTask = nil
            self?.prepareRadio()
        }
    }
    func prepareRadio() {
        radioPreparationSuspended = false
        radioPreloading = true
        fillRadioQueue()
    }

    func cancelRadioPreparation() {
        if !isCreating { cancelGeneration() }
        suspendRadioPreparation()
    }

    private func suspendRadioPreparation() {
        if !isPlaying { radioWantsPlayback = false }
        radioPreloading = false
        radioPreparationSuspended = true
        updateNowPlaying()
    }

    private var canComposeRadioPairAhead: Bool {
        // Keep the first reserve and retries on the single-song path.
        radioCanRetry && !prioritizeNextRadioSong && (2..<(radioQueueCapacity - 1)).contains(radioReadyCount)
    }

    private static func newRadioSeed(excluding seed: UInt64) -> UInt64 {
        let next = UInt64.random(in: 0...UInt64(Int64.max))
        return next == seed ? next ^ 1 : next
    }

    private func uniqueRadioTitle(_ suggestion: String?, seed: UInt64) -> String {
        func key(_ title: String) -> String {
            title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let occupied = usedRadioTitles.union(savedSongs.map { key($0.title) })
        let trimmed = suggestion?.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"“”*`")))
        if let trimmed, !trimmed.isEmpty, trimmed.count <= 64,
           !trimmed.contains(where: \.isNewline), !occupied.contains(key(trimmed)) {
            usedRadioTitles.insert(key(trimmed))
            return trimmed
        }
        let base = MusicPromptBuilder.radioTitle(seed: seed)
        var title = base
        var number = 2
        while occupied.contains(key(title)) {
            title = "\(base) \(number)"
            number += 1
        }
        usedRadioTitles.insert(key(title))
        return title
    }

    private func fillRadioQueue() {
        if radioReadyCount >= radioQueueCapacity && !prioritizeNextRadioSong {
            radioPreloading = false
            return
        }
        guard radioMode, radioWantsPlayback || radioPreloading, canGenerate, !isGenerating, !radioPreparationSuspended,
              !isEditingRadio, automaticGenerationTask == nil else { return }
        #if os(iOS)
        guard radioRenderingInForeground else { return }
        #endif
        generateSong()
    }

    #if os(iOS)
    func setRadioRenderingInForeground(_ foreground: Bool) {
        guard radioRenderingInForeground != foreground else { return }
        radioRenderingInForeground = foreground
        if foreground {
            fillRadioQueue()
        } else if isGenerating, !isCreating {
            let wasPreloading = radioPreloading
            cancelGeneration()
            radioPreloading = wasPreloading
        }
    }
    #endif

    func playPreviousRadioSong() {
        guard let index = radioPlaybackIndex, canPlayPreviousRadioSong else { return }
        selectRadioSong(at: index - 1)
    }

    func playNextRadioSong() {
        guard canPlayNextRadioSong else { return }
        selectRadioSong(at: nextRadioIndex)
    }

    func playRadioSong(_ id: URL) {
        guard let index = radioPlaylist.firstIndex(where: { $0.url == id }) else { return }
        if index == radioPlaybackIndex {
            seek(0)
            if !wantsPlayback { play() }
        } else {
            selectRadioSong(at: index)
        }
    }

    private func selectRadioSong(at index: Int) {
        guard radioMode else { return }
        do {
            try startRadioSong(at: index, crossfade: isPlaying)
            radioWantsPlayback = true
            radioPreparationSuspended = false
            updateNowPlaying()
            fillRadioQueue()
        } catch {
            errorMessage = "Couldn't play this song."
        }
    }

    private func startRadioSong(at index: Int, crossfade: Bool) throws {
        try startTrack(radioPlaylist[index], savedID: nil, crossfade: crossfade)
        radioPlaybackIndex = index
        #if os(macOS)
        if webRadio.isRunning, index > 5 {
            let expired = Array(radioPlaylist.prefix(index - 5))
            radioPlaylist.removeFirst(expired.count)
            radioPlaybackIndex = index - expired.count
            for track in expired { discardTemporaryTrackIfUnused(track) }
        }
        #endif
        replaceWhenReady = false
        radioTrackEnded = false
    }

    private func advanceRadio(crossfade: Bool) {
        guard radioMode, radioWantsPlayback else { return }
        while canPlayNextRadioSong {
            do {
                try startRadioSong(at: nextRadioIndex, crossfade: crossfade)
                break
            } catch {
                let unavailable = radioPlaylist.remove(at: nextRadioIndex)
                discardTemporaryTrackIfUnused(unavailable)
                errorMessage = "Couldn't play the prepared song. Radio is preparing another."
            }
        }
        if !isPlaying && radioPreparationSuspended { radioWantsPlayback = false }
        fillRadioQueue()
        updateNowPlaying()
    }
    func writeLyrics(idea: String, createStyles: String? = nil) async throws -> String {
        let request = createStyles.map { MusicPromptBuilder().makeCreateRequest(idea: idea, styles: $0, instrumental: false, seed: 0) }
            ?? MusicPromptBuilder().makeRequest(profile: selected.musicProfile, seed: 0, idea: idea, voiceOverride: .vocals)
        return try await lyricsWriter.writeLyrics(for: request)
    }

    func createPromptUsage(idea: String, styles: String, lyrics: String, length: CreateLength,
                           clearLeadVocals: Bool) async throws -> MusicPromptUsage? {
        let request = MusicPromptBuilder().makeCreateRequest(idea: idea, styles: styles, instrumental: false,
                                                              seed: 0, length: length, clearLeadVocals: clearLeadVocals)
        return try await generationBackend.promptUsage(for: request.withLyrics(lyrics))
    }
    private func finishGeneration(_ id: UUID) {
        guard generationID == id else { return }
        generationTask = nil
        generationID = nil
        isGenerating = false
        isWritingLyrics = false
        isCreating = false
        activeCreation = nil
        generationProgress = 0
        radioRenderStage = .preparing
        creationStatus = ""
        updateNowPlaying()
    }
    private func libraryDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func songURL(_ song: SavedSong) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true).appendingPathComponent(song.filename)
    }

    func remix(_ song: SavedSong) async throws {
        let tokens: [Int]
        let audio = songURL(song)
        if let filename = song.semanticFilename,
           let saved = try? await MusicReference.load(from: audio.deletingLastPathComponent().appendingPathComponent(filename)) {
            tokens = saved.tokens
        } else { tokens = try await MusicReference.load(from: audio).tokens }
        try Task.checkCancellation()
        remixSource = MusicReference(title: song.title, tokens: tokens, originalAudio: audio,
                                     openingFrames: max(50, tokens.count / 2), sourceLyrics: song.lyrics)
    }

    @concurrent
    private static func preserveOpening(from original: URL, in revised: URL, prefix: [Int], result: [Int]) async throws {
        let applied = min(prefix.count, result.count - 250)
        guard applied > 0, result.starts(with: prefix.prefix(applied)) else { throw MusicGenerationError.invalidReference }
        let source = try AVAudioFile(forReading: original, commonFormat: .pcmFormatInt16, interleaved: true)
        let generated = try AVAudioFile(forReading: revised, commonFormat: .pcmFormatInt16, interleaved: true)
        guard source.processingFormat == generated.processingFormat, generated.processingFormat.sampleRate == 48_000 else {
            throw MusicGenerationError.invalidReference
        }
        let blendStart = min(source.length, AVAudioFramePosition(applied * 1_920))
        guard blendStart < generated.length else { throw MusicGenerationError.invalidReference }
        let blendFrames = AVAudioFrameCount(min(24_000, source.length - blendStart, generated.length - blendStart))
        let format = generated.processingFormat
        let staging = revised.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let output = try AVAudioFile(forWriting: staging, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
                  let other = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
                  let src = buffer.int16ChannelData?[0], let dst = other.int16ChannelData?[0] else {
                throw MusicGenerationError.invalidReference
            }
            func copy(_ file: AVAudioFile, until end: AVAudioFramePosition) throws {
                while file.framePosition < end {
                    try Task.checkCancellation()
                    let frames = AVAudioFrameCount(min(48_000, end - file.framePosition))
                    buffer.frameLength = frames
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { throw MusicGenerationError.invalidReference }
                    try output.write(from: buffer)
                }
            }
            try copy(source, until: blendStart)
            generated.framePosition = blendStart
            let channels = Int(format.channelCount)
            var blended: AVAudioFrameCount = 0
            while blended < blendFrames {
                try Task.checkCancellation()
                let remaining = blendFrames - blended
                buffer.frameLength = remaining
                other.frameLength = remaining
                try source.read(into: buffer, frameCount: remaining)
                try generated.read(into: other, frameCount: remaining)
                let read = min(buffer.frameLength, other.frameLength)
                guard read > 0 else { throw MusicGenerationError.invalidReference }
                for frame in 0..<Int(read) {
                    let mix = Float(Int(blended) + frame + 1) / Float(blendFrames)
                    for channel in 0..<channels {
                        let index = frame * channels + channel
                        dst[index] = Int16(clamping: Int((Float(src[index]) * (1 - mix) + Float(dst[index]) * mix).rounded()))
                    }
                }
                blended += read
                let position = blendStart + AVAudioFramePosition(blended)
                if source.framePosition != position { source.framePosition = position }
                if generated.framePosition != position { generated.framePosition = position }
                other.frameLength = read
                try output.write(from: other)
            }
            try copy(generated, until: generated.length)
        }
        _ = try FileManager.default.replaceItemAt(revised, withItemAt: staging)
    }
    private func persistSong(_ track: GeneratedTrack, title: String) throws -> SavedSong {
        let id = UUID()
        let item = SavedSong(id: id, title: title, filename: "\(id.uuidString).wav", style: track.request.style,
                             lyrics: track.request.lyrics, createdAt: Date(),
                             semanticFilename: track.semanticTokens.isEmpty ? nil : "\(id.uuidString).semantic.json")
        let directory = try libraryDirectory()
        let destination = directory.appendingPathComponent(item.filename)
        let semanticURL = item.semanticFilename.map { directory.appendingPathComponent($0) }
        try FileManager.default.copyItem(at: track.url, to: destination)
        let updated = [item] + savedSongs
        do {
            if let semanticURL { try JSONEncoder().encode(track.semanticTokens).write(to: semanticURL, options: .atomic) }
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: "vibe-player-saved-songs")
            savedSongs = updated
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let semanticURL { try? FileManager.default.removeItem(at: semanticURL) }
            throw error
        }
        return item
    }
    func likeCurrentSong() {
        guard let track = currentTrack else { return }
        if currentSavedID != nil { liked = true; return }
        do {
            let saved = try persistSong(track, title: trackName)
            if track.request.purpose == .radio {
                currentTrack?.radioSavedID = saved.id
                if let index = radioPlaybackIndex, radioPlaylist[index].url == track.url {
                    radioPlaylist[index].radioSavedID = saved.id
                }
            }
            currentSavedID = saved.id; liked = true; disliked = false
        } catch { errorMessage = "Couldn't save this song: \(error.localizedDescription)" }
    }
    func playSavedSong(_ song: SavedSong) {
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        discardRadioQueue(); radioMode = false; radioWantsPlayback = false; isEditingRadio = false
        do {
            let player = try AVAudioPlayer(contentsOf: songURL(song))
            installPlayer(player, name: song.title, sample: false, generated: true)
            currentTrack = nil; currentSavedID = song.id; liked = true
            play()
        } catch { errorMessage = "Couldn't open the saved song." }
    }
    func toggleLastCreatedSong() {
        guard let song = lastCreatedSong else { return }
        if currentSavedID == song.id { togglePlayback() }
        else { playSavedSong(song) }
    }
    func deleteSavedSong(_ song: SavedSong) {
        let remaining = savedSongs.filter { $0.id != song.id }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: "vibe-player-saved-songs")
        savedSongs = remaining
        if lastCreatedSong?.id == song.id { lastCreatedSong = nil }
        let audio = songURL(song)
        try? FileManager.default.removeItem(at: audio)
        if let filename = song.semanticFilename {
            try? FileManager.default.removeItem(at: audio.deletingLastPathComponent().appendingPathComponent(filename))
        }
        if currentSavedID == song.id { currentSavedID = nil; liked = false }
    }
    private func discardRadioQueue() {
        preparedRadioSeed = nil
        prioritizeNextRadioSong = false
        let tracks = radioPlaylist
        radioPlaylist.removeAll()
        radioPlaybackIndex = nil
        for track in tracks { discardTemporaryTrackIfUnused(track) }
    }
    private func discardCurrentTrack() {
        let track = currentTrack
        currentTrack = nil
        discardTemporaryTrackIfUnused(track)
    }

    private func discardTemporaryTrackIfUnused(_ track: GeneratedTrack?) {
        guard let track, track.url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
              track.url != currentTrack?.url,
              !radioPlaylist.contains(where: { $0.url == track.url }) else { return }
        try? FileManager.default.removeItem(at: track.url)
    }
    private func receivePreview(_ preview: MusicAudioPreview, title: String, generation: UUID, acoustics: CreateAcoustics) {
        guard generationID == generation, isCreating else { return }
        if let previewPlayer, previewGenerationID == generation {
            do {
                try previewPlayer.append(preview)
                try resumePreviewIfReady(previewPlayer)
            } catch {
                // The saved file can supply any range that was not scheduled.
            }
            return
        }
        guard creationAutoplay, preview.startFrame == 0 else { return }
        do {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
            let next = try PreviewPlayback(preview, acoustics: acoustics)
            let startsNow = next.readyToPlay
            if startsNow { try next.play() }
            stopPreview()
            fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
            audio?.stop(); audio = nil; discardCurrentTrack(); clearTrackMetadata()
            previewPlayer = next
            previewGenerationID = generation
            isBufferingPreview = !startsNow
            currentSavedID = nil; liked = false; disliked = false
            isSample = false; isGenerated = true; isPlaying = true
            trackName = title; elapsed = 0; duration = Double(preview.totalFrames) / 48_000
            startTimer(); updateNowPlaying()
        } catch {
            // The full file still plays through the normal path if the audio route rejects early playback.
        }
    }

    private func completePreview(_ track: GeneratedTrack, savedID: UUID, generation: UUID) -> Bool {
        guard previewGenerationID == generation, let previewPlayer else { return false }
        do {
            let fallback = try AVAudioPlayer(contentsOf: track.url)
            fallback.delegate = self; fallback.isMeteringEnabled = true
            try previewPlayer.appendRemainder(at: track.url)
            if isPlaying { try previewPlayer.play() }
            isBufferingPreview = false
            previewGenerationID = nil
            audio = fallback; currentTrack = track; currentSavedID = savedID; liked = true
            duration = fallback.duration
            updateNowPlaying()
            return true
        } catch {
            cancelPreview(generation: generation)
            return false
        }
    }

    private func resumePreviewIfReady(_ preview: PreviewPlayback) throws {
        guard isPlaying, isBufferingPreview || preview.needsBuffer, preview.readyToPlay else { return }
        try preview.play()
        isBufferingPreview = false
        updateNowPlaying()
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewGenerationID = nil
        isBufferingPreview = false
    }

    private func cancelPreview(generation: UUID) {
        guard previewGenerationID == generation else { return }
        stopPreview(); isPlaying = false; isGenerated = false; duration = 0; elapsed = 0
        timer?.invalidate(); updateNowPlaying()
    }
    private func startTrack(_ track: GeneratedTrack, savedID: UUID?, crossfade: Bool) throws {
        let size = try track.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        let next = try size <= 8 * 1024 * 1024
            ? AVAudioPlayer(data: Data(contentsOf: track.url))
            : AVAudioPlayer(contentsOf: track.url)
        let previous = audio
        let oldTrack = currentTrack
        let fadeDuration = crossfade && previous?.isPlaying == true
            ? min(RadioRenderTiming.crossfadeSeconds, max(0, (previous?.duration ?? 0) - (previous?.currentTime ?? 0)))
            : 0
        fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
        next.delegate = self; next.isMeteringEnabled = true; next.prepareToPlay()
        if !isPlaying {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
        }
        next.volume = fadeDuration > 0 ? 0 : 1
        guard next.play() else { throw MusicGenerationError.unavailable }
        stopPreview()
        clearTrackMetadata()
        audio = next; currentTrack = track
        currentSavedID = savedID ?? savedSongs.first { $0.id == track.radioSavedID }?.id
        trackName = track.radioTitle ?? savedSongs.first { $0.id == savedID }?.title ?? track.request.stationName
        isSample = false; isGenerated = true; duration = next.duration; elapsed = next.currentTime; isPlaying = true
        liked = currentSavedID != nil; disliked = false
        startTimer(); updateNowPlaying()
        if fadeDuration > 0, let previous {
            fadingPlayer = previous
            previous.setVolume(0, fadeDuration: fadeDuration)
            next.setVolume(1, fadeDuration: fadeDuration)
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(fadeDuration))
                previous.stop()
                self?.discardTemporaryTrackIfUnused(oldTrack)
                guard !Task.isCancelled else { return }
                self?.fadingPlayer = nil; self?.fadeTask = nil
            }
        } else {
            previous?.stop()
            discardTemporaryTrackIfUnused(oldTrack)
        }
    }
    private func installPlayer(_ next: AVAudioPlayer, name: String, sample: Bool, generated: Bool) {
        stopPreview()
        fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
        clearTrackMetadata()
        audio?.stop(); discardCurrentTrack(); currentSavedID = nil; liked = false; disliked = false
        audio = next; next.delegate = self; next.isMeteringEnabled = true; next.prepareToPlay()
        trackName = name; isSample = sample; isGenerated = generated; duration = next.duration; elapsed = 0; isPlaying = false
        audioLevel = 0; smoothedLevel = 0; timer?.invalidate()
        updateNowPlaying()
    }
    func load(url: URL, name: String, sample: Bool = false) {
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        discardRadioQueue(); radioWantsPlayback = false; isEditingRadio = false
        if !sample { radioMode = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            // Copy imported audio into the app container so it remains playable after the picker closes.
            let localURL: URL
            if sample { localURL = url } else {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                localURL = directory.appendingPathComponent("imported-audio.\(url.pathExtension)")
                if FileManager.default.fileExists(atPath: localURL.path) { try FileManager.default.removeItem(at: localURL) }
                try FileManager.default.copyItem(at: url, to: localURL)
            }
            let next = try AVAudioPlayer(contentsOf: localURL)
            installPlayer(next, name: name, sample: sample, generated: false)
            if !sample {
                UserDefaults.standard.set(localURL.lastPathComponent, forKey: "imported-audio-filename")
                UserDefaults.standard.set(name, forKey: "imported-audio-name")
            }
            if !sample { loadTrackMetadata(from: localURL) }
            updateNowPlaying()
        } catch { errorMessage = "Couldn't open this audio file. Try another audio file." }
    }
    private func clearTrackMetadata() {
        artworkTask?.cancel(); artworkTask = nil; artworkRequestID = UUID()
        trackArtwork = nil; trackArtist = nil
    }
    private func loadTrackMetadata(from url: URL) {
        let id = UUID(); artworkRequestID = id
        artworkTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata), !Task.isCancelled else { return }
            let artworkItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
            let artistItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first
            let artworkData = try? await artworkItem?.load(.dataValue)
            let artist = try? await artistItem?.load(.stringValue)
            guard !Task.isCancelled, let self, self.artworkRequestID == id else { return }
            self.trackArtwork = artworkData.flatMap(PlatformImage.init(data:))
            self.trackArtist = artist
            self.updateNowPlaying()
        }
    }
    func setSleepTimer(_ minutes: Int?) {
        sleepTimer?.invalidate(); sleepMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.sleepMinutes = nil }
        }
    }
    #if !os(macOS)
    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        // Give playback a larger I/O buffer while the next song uses CPU and GPU.
        try? session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
    }
    #endif
    func togglePlayback() { wantsPlayback ? pause() : play() }
    func play() {
        if let previewPlayer {
            do {
                isBufferingPreview = !previewPlayer.readyToPlay
                if !isBufferingPreview { try previewPlayer.play() }
                isPlaying = true; startTimer(); updateNowPlaying()
            } catch { errorMessage = "Audio couldn't resume. Try opening the song from Library when it finishes." }
            return
        }
        if radioMode, canGenerate {
            radioWantsPlayback = true
            radioCanRetry = true
            radioPreparationSuspended = false
            if replaceWhenReady || radioTrackEnded || currentTrack?.request.purpose != .radio {
                advanceRadio(crossfade: isPlaying)
                return
            }
        }
        do {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
            guard let audio, audio.play() else {
                radioWantsPlayback = false
                errorMessage = "Audio couldn't start. Try another file."
                return
            }
            isPlaying = true; startTimer(); updateNowPlaying()
            fillRadioQueue()
        } catch {
            radioWantsPlayback = false
            errorMessage = "Audio couldn't start. Check your audio output and try again."
        }
    }
    func pause() {
        radioWantsPlayback = false
        previewPlayer?.pause()
        audio?.pause()
        audio?.setVolume(1, fadeDuration: 0)
        fadingPlayer?.stop()
        isPlaying = false; audioLevel = 0; smoothedLevel = 0
        timer?.invalidate()
        updateNowPlaying()
    }
    func seek(_ value: Double) {
        guard canSeek else { return }
        let wasPreviewing = previewPlayer != nil
        if wasPreviewing { stopPreview() }
        audio?.currentTime = min(max(value, 0), duration)
        elapsed = audio?.currentTime ?? 0
        if wasPreviewing, isPlaying { isPlaying = audio?.play() == true }
        if radioMode, radioTrackEnded, elapsed < duration {
            radioTrackEnded = false
            if radioWantsPlayback { play() }
        }
        updateNowPlaying()
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audio else { return }
        radioTrackEnded = currentTrack?.request.purpose == .radio
        isPlaying = false; elapsed = radioTrackEnded ? duration : 0; audioLevel = 0; smoothedLevel = 0
        timer?.invalidate(); updateNowPlaying()
        advanceRadio(crossfade: false)
    }
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleAudio() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func sampleAudio() {
        if let previewPlayer, isPlaying {
            elapsed = min(duration, previewPlayer.elapsed)
            if previewPlayer.hasEnded {
                stopPreview(); isPlaying = false; elapsed = 0
                timer?.invalidate(); updateNowPlaying()
            } else if previewPlayer.needsBuffer, !isBufferingPreview {
                isBufferingPreview = true
                updateNowPlaying()
            }
            return
        }
        guard let audio, isPlaying else { return }
        elapsed = audio.currentTime
        if radioMode, radioWantsPlayback, canPlayNextRadioSong,
           duration - elapsed <= RadioRenderTiming.crossfadeSeconds {
            advanceRadio(crossfade: true)
            return
        }
        audio.updateMeters()
        let power = audio.averagePower(forChannel: 0)
        let level = min(1, max(0, (Double(power) + 55) / 55))
        let previous = smoothedLevel
        smoothedLevel = previous * 0.82 + level * 0.18
        audioLevel = level
        if level > 0.35 && level > previous + 0.12 && Date().timeIntervalSince(lastBeat) > 0.28 {
            lastBeat = Date()
            beatPulse.toggle()
        }
    }
    private func setupRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPreviousRadioSong() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextRadioSong() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(position) }
            return .success
        }
        updateNowPlaying()
    }
    private func updateNowPlaying() {
        #if os(macOS)
        let keepPlaying = radioMode && (radioWantsPlayback || (isGenerating && !isCreating))
        if keepPlaying, radioActivity == nil {
            radioActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "infetit radio")
        } else if !keepPlaying, let activity = radioActivity {
            ProcessInfo.processInfo.endActivity(activity)
            radioActivity = nil
        }
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = canPlayPreviousRadioSong
        commands.nextTrackCommand.isEnabled = canPlayNextRadioSong
        commands.changePlaybackPositionCommand.isEnabled = canSeek
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: trackName,
            MPMediaItemPropertyArtist: radioMode ? (currentTrack?.request.stationName ?? selected.name) : (trackArtist ?? "infetit radio"),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBufferingPreview ? 1.0 : 0.0
        ]
    }
}
