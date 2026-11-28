import Foundation
#if os(macOS)
import AVFoundation
#endif

/// A snapshot of the controls, independent of the player UI and the model runtime.
struct MusicProfile: Equatable, Sendable {
    enum Category: String, Sendable { case genre, mood, instrument, voice, language }
    struct Trait: Equatable, Sendable {
        let name: String
        let category: Category
        let intensity: Double
    }
    let name: String
    let traits: [Trait]
    let tempo: Double
    var soundDescription: String? = nil
}

enum CreateRenderer: Sendable {
    case metal, metalPaired
}

enum CreateLength: String, Sendable {
    case automatic, fullSong, extended

    var maximumFrames: Int { self == .extended ? 6_400 : 5_200 }
    var minimumFrames: Int {
        switch self {
        case .automatic: 200
        case .fullSong: 3_000
        case .extended: 5_250
        }
    }
}

enum CreateAcoustics: String, Sendable {
    case streaming, reference

    static func resolve(preference: String, supportsEarlyPlayback: Bool) -> Self {
        supportsEarlyPlayback && preference == Self.streaming.rawValue ? .streaming : .reference
    }
}

enum RenderingSteps: Int, CaseIterable, Sendable {
    case eight = 8, sixteen = 16, thirtyTwo = 32

    static let createPreferenceKey = "vibe-create-rendering-steps"
    #if os(iOS)
    static let createDefault: Self = .eight
    #else
    static let createDefault: Self = .thirtyTwo
    #endif
    static let radioPreferenceKey = "vibe-rendering-steps"
    static var radioPreferred: Self {
        Self(rawValue: UserDefaults.standard.integer(forKey: radioPreferenceKey)) ?? .sixteen
    }
}

struct RadioRenderTiming {
    static let crossfadeSeconds: TimeInterval = 2
    static let targetRealtimeRate = 1.10
    static let minimumSteps = RenderingSteps.eight.rawValue

    let voice: MusicGenerationRequest.Voice
    let steps: Int
    let elapsed: Duration
    let synthesis: Duration
    let audioDuration: TimeInterval

    func stepCount(preferred: RenderingSteps, readySongs: Int, voice: MusicGenerationRequest.Voice) -> Int {
        guard readySongs >= 2, voice == self.voice, synthesis > .zero else { return Self.minimumSteps }
        let budget = Duration.seconds(max(0, audioDuration - Self.crossfadeSeconds) / Self.targetRealtimeRate)
        guard elapsed <= budget else { return Self.minimumSteps }
        let current = min(steps, preferred.rawValue)
        let extraStep = synthesis / Double(steps)
        return current < preferred.rawValue && elapsed + extraStep <= budget ? current + 1 : current
    }
}

/// Text and generation parameters accepted by the YuE2 renderer.
struct MusicGenerationRequest: Equatable, Sendable {
    enum Voice: Sendable { case instrumental, vocals, unspecified }
    enum Purpose: Sendable { case radio, createdSong }
    struct RadioSuccessor: Equatable, Sendable {
        let seed: UInt64
        let style: String
    }
    let stationName: String
    var style: String
    private(set) var lyrics: String
    let voice: Voice
    let purpose: Purpose
    let seed: UInt64
    /// YuE2 semantic frames at 25 Hz; a ceiling, not a guaranteed song duration.
    var maxSemanticFrames: Int
    var synthesisSteps: Int
    var createRenderer: CreateRenderer = .metal
    var minimumSemanticFrames = 200
    var createAcoustics: CreateAcoustics = .reference
    var planScore = false
    var scoreABC: String?
    var compactAttentionCache = false
    var guidanceScale: Float? = nil
    var semanticPrefix: [Int] = []
    var radioSuccessor: RadioSuccessor?
    var radioUsesLongerLyrics = false
    var radioLyricTheme = ""
    var listenerTheme: String? = nil
    var radioLyricLanguage = "English"

    func withLyrics(_ lyrics: String) -> MusicGenerationRequest {
        var request = self
        request.lyrics = lyrics
        return request
    }
}

struct MusicPromptBuilder {
    private static let clearVocals = "upfront lead vocal, clear diction, light vocal reverb"

    static let radioArrangements = [
        "syncopated lead phrases and a steady bass ostinato",
        "rolling arpeggios and a light offbeat groove",
        "legato melody and slowly changing layered harmonies",
        "short call-and-response motifs and a shuffled rhythm",
        "a sparse opening that builds into a wide, layered refrain",
        "a half-time feel with a low-register melodic hook",
        "alternating bright and dark chords with a rising melody",
        "a simple descending melody with a contrasting rhythmic bridge",
        "a flowing bass melody and short, punctuated chords",
        "a stop-and-start groove and a long, sustained refrain"
    ]

    static func radioTitle(seed: UInt64) -> String {
        let modifiers = ["Amber", "Blue", "Clouded", "Distant", "Evening", "Fading", "Golden", "Harbor", "Hidden",
                         "Indigo", "Late", "Lunar", "Midnight", "Morning", "Paper", "Quiet", "Silver", "Soft", "Velvet", "Winter"]
        let nouns = ["Arcade", "Avenue", "Breeze", "Current", "Daydream", "Echoes", "Frequency", "Gardens",
                     "Horizon", "Lanterns", "Light", "Mirage", "Orbit", "Rain", "Rooftops", "Signal", "Skies", "Tide", "Transit", "Waves"]
        let adjective = modifiers[Int(seed % UInt64(modifiers.count))]
        let noun = nouns[Int(seed / UInt64(modifiers.count) % UInt64(nouns.count))]
        return "\(adjective) \(noun)"
    }

    /// The Create screen starts with its own description instead of inheriting a radio station.
    func makeCreateRequest(idea: String, styles: String, instrumental: Bool, seed: UInt64,
                           length: CreateLength = .automatic, followStyleClosely: Bool = false,
                           clearLeadVocals: Bool = false, renderingSteps: RenderingSteps = .createDefault) -> MusicGenerationRequest {
        let voice: MusicGenerationRequest.Voice = instrumental ? .instrumental : .vocals
        var parts = [instrumental ? "instrumental" : "vocal music"]
        let cleanStyles = styles.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if length == .fullSong { parts.append("full arrangement with a closing section") }
        if length == .extended { parts.append("extended arrangement with a closing section") }
        if !cleanStyles.isEmpty { parts.append("styles: " + cleanStyles) }
        if clearLeadVocals && !instrumental { parts.append(Self.clearVocals) }
        if !cleanIdea.isEmpty { parts.append("song idea: " + cleanIdea) }
        return MusicGenerationRequest(stationName: "Your song", style: parts.joined(separator: "; "), lyrics: "",
                                      voice: voice, purpose: .createdSong, seed: seed, maxSemanticFrames: length.maximumFrames,
                                      synthesisSteps: renderingSteps.rawValue, minimumSemanticFrames: length.minimumFrames,
                                      guidanceScale: followStyleClosely ? 1.2 : nil)
    }

    func makeRequest(profile: MusicProfile, seed: UInt64, maxSemanticFrames: Int = 5_000, idea: String = "",
                     voiceOverride: MusicGenerationRequest.Voice? = nil, renderingSteps: RenderingSteps = .sixteen) -> MusicGenerationRequest {
        let active = profile.traits.filter { $0.intensity.isFinite && $0.intensity > 0 }
        func values(_ category: MusicProfile.Category) -> [MusicProfile.Trait] {
            active.filter { $0.category == category }.sorted {
                if $0.intensity == $1.intensity { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.intensity > $1.intensity
            }
        }
        func description(_ trait: MusicProfile.Trait) -> String {
            let level = min(1, max(0, trait.intensity))
            let emphasis = level < 0.34 ? "subtle" : level < 0.67 ? "moderate" : "prominent"
            return "\(emphasis) \(trait.name.lowercased())"
        }
        let voices = values(.voice)
        let language = values(.language).first?.name
        let voice = voices.first { $0.name.caseInsensitiveCompare("Instrumental") == .orderedSame || $0.name.caseInsensitiveCompare("Vocals") == .orderedSame }
        let voiceMode: MusicGenerationRequest.Voice
        if let voiceOverride {
            voiceMode = voiceOverride
        } else if let voice {
            voiceMode = voice.name.caseInsensitiveCompare("Instrumental") == .orderedSame ? .instrumental : .vocals
        } else if language == nil, profile.traits.contains(where: { $0.category == .voice }) {
            voiceMode = .unspecified
        } else {
            voiceMode = .vocals
        }
        var parts: [String] = []
        switch voiceMode {
        case .instrumental: parts.append("instrumental")
        case .vocals:
            parts.append(language.map { "vocals sung in \($0)" } ?? "vocal music")
            parts.append(Self.clearVocals)
        case .unspecified: break
        }
        let genres = values(.genre).map(description)
        let moods = values(.mood).map(description)
        let instruments = values(.instrument).map(description)
        if !genres.isEmpty { parts.append("styles: " + genres.joined(separator: ", ")) }
        if !moods.isEmpty { parts.append("moods: " + moods.joined(separator: ", ")) }
        if !instruments.isEmpty { parts.append("instruments: " + instruments.joined(separator: ", ")) }
        let tempo = profile.tempo.isFinite ? min(180, max(50, profile.tempo.rounded())) : 90
        parts.append("\(Int(tempo)) BPM")
        if let description = profile.soundDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            parts.append("sound direction: " + description)
        }
        let cleanIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdea.isEmpty { parts.append("song idea: " + cleanIdea) }
        let themes = [profile.soundDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", cleanIdea]
        return MusicGenerationRequest(stationName: profile.name, style: parts.joined(separator: "; "), lyrics: "",
                                      voice: voiceMode, purpose: .radio, seed: seed, maxSemanticFrames: maxSemanticFrames,
                                      synthesisSteps: renderingSteps.rawValue,
                                      radioLyricTheme: themes.filter { !$0.isEmpty }.joined(separator: " "),
                                      radioLyricLanguage: language ?? "English")
    }

    func makeRadioPlaybackRequest(profile: MusicProfile, seed: UInt64, idea: String,
                                  voiceOverride: MusicGenerationRequest.Voice?, arrangement: Int,
                                  renderingSteps: RenderingSteps = .eight) -> MusicGenerationRequest {
        #if os(macOS)
        var request = makeRequest(profile: profile, seed: seed, maxSemanticFrames: CreateLength.fullSong.maximumFrames,
                                  idea: idea, voiceOverride: voiceOverride, renderingSteps: renderingSteps)
        request.minimumSemanticFrames = CreateLength.fullSong.minimumFrames
        request.style += "; full arrangement with a closing section"
        #else
        var request = makeRequest(profile: profile, seed: seed, maxSemanticFrames: 4_200,
                                  idea: idea, voiceOverride: voiceOverride, renderingSteps: renderingSteps)
        request.minimumSemanticFrames = 2_000
        #endif
        request.style += "; " + Self.radioArrangements[arrangement % Self.radioArrangements.count]
        return request
    }
}

/// A renderer must produce a complete local audio file playable by AVAudioPlayer.
/// Implementations own inference, cancellation and temporary-file management.
@MainActor
protocol MusicGenerationBackend {
    var isAvailable: Bool { get }
    var canUsePairedMetal: Bool { get }
    var canStreamAcoustics: Bool { get }
    var canPlanScore: Bool { get }
    var canCreateExtended: Bool { get }
    var canPrepareRadioPair: Bool { get }
    func prepareRendering(_ acoustics: CreateAcoustics, compactAttentionCache: Bool, preferFullPrecision: Bool)
    func waitForIdle() async throws
    func releaseResources() async
    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage?
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput
}

struct MusicGenerationOutput {
    let url: URL
    var semanticTokens: [Int] = []
    var radioSuccessorSeed: UInt64?
}

struct MusicReference: Equatable, Sendable {
    let title: String
    let tokens: [Int]
    let originalAudio: URL?
    var openingFrames: Int
    var sourceLyrics: String?

    var prefix: [Int] { Array(tokens.prefix(openingFrames)) }

    static var canEncodeAudio: Bool {
        #if os(macOS) && !VIBEPLAYER_APP_STORE
        let files = referenceEncoder
        return FileManager.default.isExecutableFile(atPath: files.executable.path)
            && FileManager.default.isReadableFile(atPath: files.model.path)
            && FileManager.default.isReadableFile(atPath: files.encoder.path)
        #else
        return false
        #endif
    }

    @concurrent
    static func load(from url: URL) async throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let tokens: [Int]
        if ["csv", "txt", "json"].contains(ext) {
            tokens = try readCodes(url)
        } else {
            #if os(macOS) && !VIBEPLAYER_APP_STORE
            tokens = try await encodeAudio(url)
            #else
            throw MusicGenerationError.referenceEncoderUnavailable
            #endif
        }
        return Self(title: url.deletingPathExtension().lastPathComponent, tokens: tokens,
                    originalAudio: nil, openingFrames: min(750, tokens.count))
    }

    private static func readCodes(_ url: URL) throws -> [Int] {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...262_144).contains(size) else { throw MusicGenerationError.invalidReference }
        let data = try Data(contentsOf: url)
        let tokens: [Int]
        if url.pathExtension.lowercased() == "json" {
            tokens = (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        } else {
            let fields = String(decoding: data, as: UTF8.self).split { $0 == "," || $0.isWhitespace }
            tokens = fields.compactMap { Int($0) }
            guard tokens.count == fields.count else { throw MusicGenerationError.invalidReference }
        }
        guard (50...15_000).contains(tokens.count), tokens.allSatisfy({ (0..<32_768).contains($0) }) else {
            throw MusicGenerationError.invalidReference
        }
        return tokens
    }

    #if os(macOS) && !VIBEPLAYER_APP_STORE
    private static var referenceEncoder: (executable: URL, model: URL, encoder: URL) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YuE2NativeAssets/Reference")
        return (root.appendingPathComponent("yue-tokenize"),
                root.appendingPathComponent("yue2-mothersuperior-realaudio-tokenizer-v4-Q8_0.gguf"),
                root.appendingPathComponent("MERT-v2-FullSong-Q8_0.gguf"))
    }

    private static func encodeAudio(_ url: URL) async throws -> [Int] {
        guard canEncodeAudio else { throw MusicGenerationError.referenceEncoderUnavailable }
        let files = referenceEncoder
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("reference.wav")
        let codes = directory.appendingPathComponent("codes.csv")
        do {
            let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let format = source.processingFormat
            guard (1...2).contains(format.channelCount), format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw MusicGenerationError.invalidReference
            }
            let limit = min(source.length, AVAudioFramePosition(format.sampleRate * 60))
            let output = try AVAudioFile(forWriting: clip, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            while source.framePosition < limit {
                try Task.checkCancellation()
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(32_768, limit - source.framePosition)))
                guard buffer.frameLength > 0 else { throw MusicGenerationError.invalidReference }
                try output.write(from: buffer)
            }
        }
        let process = Process()
        process.executableURL = files.executable
        process.arguments = ["--model", files.model.path, "--audio", clip.path, "--out", codes.path, "--device", "MTL0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(90)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw MusicGenerationError.invalidReference }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0 else { throw MusicGenerationError.invalidReference }
        return try readCodes(codes)
    }
    #endif
}

struct AppleMusicQuery: Identifiable, Sendable {
    let term: String
    let artistOnly: Bool
    var id: String { term }

    static func parse(_ prompt: String) -> Self? {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        let lead = /(?i)^(?:please\s+)?(?:i want|i would like|i'd like|play|find|give me|listen to)\s+/
        let body = request.replacing(lead, with: "")
        let artist = /(?i)^(?:a\s+|an\s+|some\s+)?(?:song|track|music)\s+(?:by|from)\s+(.+)$/
        if let match = body.wholeMatch(of: artist) { return Self(term: String(match.1), artistOnly: true) }
        let namedArtist = /^(?:(?i:a|an|some)\s+)?([\p{Lu}][\p{L}'’.-]*(?:\s+[\p{Lu}][\p{L}'’.-]*){0,4})\s+(?i:song|track|music)$/
        if let match = body.wholeMatch(of: namedArtist), request != body || match.1.contains(where: \.isWhitespace) {
            return Self(term: String(match.1), artistOnly: true)
        }
        if request != body, let match = body.wholeMatch(of: /^(.+)\s+(?i:by)\s+(.+)$/) {
            return Self(term: "\(match.1) \(match.2)", artistOnly: false)
        }
        return nil
    }

    struct Track: Decodable, Identifiable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let trackViewUrl: URL
        var id: Int { trackId }
    }

    @concurrent
    func tracks() async throws -> [Track] {
        struct Response: Decodable { let results: [Track] }
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "song"),
                            URLQueryItem(name: "limit", value: "12"),
                            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")]
        if artistOnly { query.queryItems?.append(URLQueryItem(name: "attribute", value: "artistTerm")) }
        let (data, response) = try await URLSession.shared.data(from: query.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let results = try JSONDecoder().decode(Response.self, from: data).results
        return results.filter { $0.trackViewUrl.scheme == "https" && $0.trackViewUrl.host == "music.apple.com" }
            .filter { !artistOnly || $0.artistName.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    var catalogURL: URL? {
        var query = URLComponents(string: "https://music.apple.com/search")
        query?.queryItems = [URLQueryItem(name: "term", value: term)]
        return query?.url
    }
}

struct MusicAudioPreview: Sendable {
    let samples: [Int16]
    let totalFrames: Int
    var startFrame = 0
    var lowLatency = false
}

struct MusicPromptUsage: Sendable {
    let count: Int
    let limit: Int
    let styleTokens: Int
    let lyricTokens: Int
}

enum MusicGenerationProgress: Sendable {
    case planningMusic, tokens(Int, Int), synthesizing, synthesis(Int, Int), waveform
}

extension MusicGenerationBackend {
    var canPrepareRadioPair: Bool { false }
    var canUsePairedMetal: Bool { false }
    var canStreamAcoustics: Bool { false }
    var canPlanScore: Bool { false }
    var canCreateExtended: Bool { false }
    func prepareRendering(_ acoustics: CreateAcoustics, compactAttentionCache: Bool, preferFullPrecision: Bool) {}
    func waitForIdle() async throws {}
    func releaseResources() async {}
    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage? { nil }
}

struct UnavailableMusicGenerationBackend: MusicGenerationBackend {
    let isAvailable = false
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        throw MusicGenerationError.metalUnavailable
    }
}

enum MusicGenerationError: LocalizedError {
    case unavailable, metalUnavailable, extendedUnavailable, invalidReference, referenceEncoderUnavailable, promptTooLong(count: Int, limit: Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Song generation isn't available yet."
        case .metalUnavailable: "The Metal music model is unavailable on this device."
        case .extendedUnavailable: "Extended songs require the 4:16 Metal model. Select Automatic length to use the installed model."
        case .invalidReference: "Couldn't use this opening. Choose a valid YuE2 reference or a generated song with an available audio file."
        case .referenceEncoderUnavailable: "Import YuE2 semantic codes, or use a Mac with the Reference Audio model installed to import a recording."
        case .promptTooLong(let count, let limit): "The description and lyrics use \(count) tokens. The music model can use \(limit). Shorten the description or reduce the lyrics, then create again."
        }
    }
}
