import CoreML
import Foundation
import Synchronization

public enum AcousticProfile: String, Codable, Sendable {
    case reference
    /// Use the optional smaller graph when it can synthesize the whole song.
    case fast
    /// Render overlapping acoustic windows while the Metal decoder keeps composing.
    case streaming
}

public struct SongRequest: Codable, Equatable, Sendable {
    public var lyrics: String
    public var style: String
    public var seed: UInt64
    public var maximumFrames: Int?
    public var acousticProfile: AcousticProfile?
    public var minimumFrames: Int
    /// An opening to keep, expressed as zero-based semantic codec indices.
    public var semanticPrefix: [Int]?
    /// Semantic classifier-free guidance for the style and lyrics. Omit to use the direct-mode default.
    public var guidanceScale: Float?
    /// Midpoint steps per acoustic pass. Omit to use eight steps.
    public var synthesisSteps: Int?
    /// ABC melody score to realize before the semantic music tokens.
    public var scoreABC: String?
    var acousticSteps: Int { synthesisSteps ?? 8 }

    public init(lyrics: String, style: String, seed: UInt64, maximumFrames: Int? = nil,
                minimumFrames: Int = 200, acousticProfile: AcousticProfile? = nil, semanticPrefix: [Int]? = nil,
                guidanceScale: Float? = nil, synthesisSteps: Int? = nil, scoreABC: String? = nil) {
        self.acousticProfile = acousticProfile
        self.lyrics = lyrics
        self.style = style
        self.seed = seed
        self.maximumFrames = maximumFrames
        self.minimumFrames = minimumFrames
        self.semanticPrefix = semanticPrefix
        self.guidanceScale = guidanceScale
        self.synthesisSteps = synthesisSteps
        self.scoreABC = scoreABC
    }
}

public enum SongProgress: Codable, Sendable, Equatable {
    case tokens(count: Int, limit: Int)
    case synthesis(step: Int, total: Int)
    case waveform
    case workerRetry(stage: Int, signal: Int32)
}

public struct SongResult: Codable, Sendable {
    public let audioURL: URL
    public let codecTokens: [Int]
    public let naturalEnding: Bool
    public let sampleRate: Int
    public let channels: Int
    public let sampleFrames: Int
    public let synthesisSteps: Int
    public let fullSongContext: Bool
    public let tokenSeconds: Double
    public let acousticSeconds: Double
    public let waveformSeconds: Double
    public var duration: Double { Double(sampleFrames) / Double(sampleRate) }
}

public struct SongDraft: Sendable {
    /// Semantic codec indices without the end token, at 25 frames per second.
    public let codecTokens: [Int]
    public let naturalEnding: Bool
}

public struct SongPromptUsage: Sendable {
    public let count: Int
    public let limit: Int
    public let styleTokens: Int
    public let lyricTokens: Int
}

public enum YuE2Failure: LocalizedError {
    case assets(String)
    case request(String)
    case inference(String)
    case worker(String)

    public var errorDescription: String? {
        switch self {
        case .assets(let detail): "YuE2 model assets: \(detail)"
        case .request(let detail): "YuE2 request: \(detail)"
        case .inference(let detail): "YuE2 inference: \(detail)"
        case .worker(let detail): "YuE2 worker: \(detail)"
        }
    }
}

public enum Execution: Sendable {
    /// Run in the app process, expanding the cache when the bundle has additional stages.
    case embedded
    /// Decode version 3 weights with Metal and run the full acoustic pass in Core ML.
    case metal
    /// Use the reversible layout emitted by Scripts/prepare_paired.py.
    case metalPaired
    #if os(macOS)
    /// Each cache capacity and the acoustic render run in separate helper processes.
    case isolated(worker: URL, stageTimeout: TimeInterval = 900)
    #endif
}

public final class YuE2Renderer: Sendable {
    private let active = Mutex(false)
    let assets: ModelAssets
    let execution: Execution
    private let pairedWeights: URL?
    #if os(macOS)
    private let promptCache = Decoder.PromptCache()
    #endif

    public var supportsSongPair: Bool {
        if case .metal = execution { return MetalDecoder.supportsSongPair }
        return false
    }

    private var usesMetal: Bool {
        switch execution {
        case .metal, .metalPaired: true
        default: false
        }
    }

    public var maximumFrames: Int { assets.decoderCapacities(useMetal: usesMetal).last ?? 0 }
    public var supportsFastAcoustics: Bool { assets.hasFastAcousticGraph }
    public var supportsStreamingAcoustics: Bool { usesMetal && assets.manifest.acousticFrames.contains(AcousticWindow.capacity) }

    @concurrent
    public func promptUsage(style: String, lyrics: String, scoreABC: String? = nil) async throws -> SongPromptUsage {
        try Task.checkCancellation()
        let tokenizer = try Tokenizer(url: assets.url("tokenizer.tiktoken"))
        let request = SongRequest(lyrics: lyrics, style: style, seed: 0, scoreABC: scoreABC)
        let prompt = try tokenizer.prompt(request)
        return try SongPromptUsage(count: prompt.map(\.count).max() ?? 0, limit: assets.manifest.promptCapacity,
                                   styleTokens: tokenizer.encode(style).count, lyricTokens: tokenizer.encode(lyrics).count)
    }

    public init(assets: URL, execution: Execution = .embedded) throws {
        self.assets = try ModelAssets(directory: assets)
        switch execution {
        case .metal, .metalPaired:
            guard self.assets.manifest.version == 3,
                  FileManager.default.fileExists(atPath: self.assets.url("metal-decoder.json").path) else {
                throw YuE2Failure.assets("Metal execution requires an indexed version 3 bundle.")
            }
        default: break
        }
        if case .metalPaired = execution { self.pairedWeights = try PairedWeights.verifiedFile(in: assets) }
        else { self.pairedWeights = nil }
        self.execution = execution
    }

    /// Composes with the Metal decoder and returns the complete semantic sequence in memory.
    @concurrent
    public func compose(_ request: SongRequest,
                        onProgress: @escaping @Sendable (SongProgress) -> Void = { _ in }) async throws -> SongDraft {
        try Task.checkCancellation()
        guard usesMetal else { throw YuE2Failure.request("Song composition requires the Metal decoder.") }
        guard active.withLock({ value in
            if value { return false }
            value = true
            return true
        }) else { throw YuE2Failure.request("This renderer already has an active song.") }
        defer { active.withLock { $0 = false } }

        let stage = try compositionStage(request)
        #if os(macOS)
        let decoder = Decoder(assets: assets, pairedWeights: pairedWeights, promptCache: promptCache)
        #else
        let decoder = Decoder(assets: assets, pairedWeights: pairedWeights)
        #endif
        guard let draft = try await decoder.run(stage, progress: onProgress) else {
            throw YuE2Failure.inference("Missing semantic tokens.")
        }
        return draft
    }

    /// Shares each projection weight read across two independent songs on supported Macs.
    @concurrent
    public func composePair(_ first: SongRequest, _ second: SongRequest,
                            onProgress: @escaping @Sendable (Int, SongProgress) -> Void = { _, _ in }) async throws
        -> (SongDraft, SongDraft) {
        #if os(macOS)
        try Task.checkCancellation()
        guard supportsSongPair else { throw YuE2Failure.request("Two-song Metal composition is unavailable.") }
        guard active.withLock({ value in
            if value { return false }
            value = true
            return true
        }) else { throw YuE2Failure.request("This renderer already has an active song.") }
        defer { active.withLock { $0 = false } }
        let stages = try [compositionStage(first), compositionStage(second)]
        let drafts = try Decoder(assets: assets, promptCache: promptCache).runPair(stages, progress: onProgress)
        return (drafts[0], drafts[1])
        #else
        throw YuE2Failure.request("Two-song Metal composition is unavailable.")
        #endif
    }

    private func compositionStage(_ request: SongRequest) throws -> Stage {
        let limit = try assets.limits(for: request, useMetal: true)
        guard let capacity = assets.decoderCapacities(useMetal: true).first(where: { $0 >= limit }) else {
            throw YuE2Failure.assets("The requested song length requires a larger decoder.")
        }
        return Stage(request: request, limit: limit, capacity: capacity, index: 0, isAcoustic: false, useMetal: true)
    }

    /// Creates a stereo 48 kHz PCM16 WAV. Existing output survives cancellation or a failed render.
    @concurrent
    public func render(
        _ request: SongRequest, to output: URL,
        onProgress: @escaping @Sendable (SongProgress) -> Void = { _ in }
    ) async throws -> SongResult {
        try await render(request, to: output, onPreview: nil, onProgress: onProgress)
    }

    /// Offers a buffered opening or consecutive PCM ranges while decoding the waveform.
    @concurrent
    public func render(
        _ request: SongRequest, to output: URL,
        streamAudio: Bool = false,
        onPreview: (@Sendable (SongAudioPreview) -> Void)?,
        onProgress: @escaping @Sendable (SongProgress) -> Void = { _ in }
    ) async throws -> SongResult {
        guard output.isFileURL, output.pathExtension.lowercased() == "wav" else {
            throw YuE2Failure.request("Use a local .wav destination.")
        }
        let parent = try output.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey])
        guard parent.isDirectory == true else { throw YuE2Failure.request("Create the output directory first.") }
        try Task.checkCancellation()
        guard active.withLock({ value in
            if value { return false }
            value = true
            return true
        }) else { throw YuE2Failure.request("This renderer already has an active song.") }
        defer { active.withLock { $0 = false } }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yue2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let limits = try assets.limits(for: request, useMetal: usesMetal)
        let windowed = request.acousticProfile == .streaming && supportsStreamingAcoustics && limits > AcousticWindow.capacity
        let workerResult: WorkerResult
        let tokenSeconds: Double
        if windowed {
            guard let capacity = assets.decoderCapacities(useMetal: true).first(where: { $0 >= limits }) else {
                throw YuE2Failure.assets("The requested song length requires a larger decoder.")
            }
            let stage = Stage(request: request, limit: limits, capacity: capacity, index: 0, isAcoustic: false, useMetal: true)
            (workerResult, tokenSeconds) = try await renderStreaming(stage, work: work, onPreview: onPreview, progress: onProgress)
        } else {
            (workerResult, tokenSeconds) = try await renderFullSong(request, limit: limits, work: work,
                                                                    streamAudio: streamAudio, onPreview: onPreview, progress: onProgress)
        }
        let wav = try Data(contentsOf: work.appendingPathComponent("song.wav"), options: .mappedIfSafe)
        guard workerResult.sampleFrames == workerResult.tokens.count * Acoustic.samplesPerToken - 64,
              wav.count == 44 + 4 * workerResult.sampleFrames,
              wav.prefix(4) == Data("RIFF".utf8) else {
            throw YuE2Failure.inference("The renderer returned an incomplete WAV.")
        }
        try Task.checkCancellation()
        try wav.write(to: output, options: .atomic)
        let fullSongContext = !windowed || workerResult.tokens.count < AcousticWindow.advance + AcousticWindow.context
        return SongResult(audioURL: output, codecTokens: workerResult.tokens,
                          naturalEnding: workerResult.naturalEnding, sampleRate: 48_000, channels: 2,
                          sampleFrames: workerResult.sampleFrames, synthesisSteps: request.acousticSteps, fullSongContext: fullSongContext,
                          tokenSeconds: tokenSeconds, acousticSeconds: workerResult.acousticSeconds,
                          waveformSeconds: workerResult.waveformSeconds)
    }

    private func renderFullSong(_ request: SongRequest, limit: Int, work: URL, streamAudio: Bool,
                                onPreview: (@Sendable (SongAudioPreview) -> Void)?, progress: @Sendable (SongProgress) -> Void)
    async throws -> (WorkerResult, Double) {
        #if os(macOS)
        if case .isolated(let worker, let timeout) = execution {
            try await runIsolated(request, limit: limit, worker: worker, timeout: timeout, work: work, progress: progress)
            let timing = try readRecord(WorkerTimings.self, at: work.appendingPathComponent("timing.json"))
            return (try readRecord(WorkerResult.self, at: work.appendingPathComponent("result.json")), timing.tokenSeconds)
        }
        #endif
        let tokenStarted = ContinuousClock.now
        if assets.manifest.version == 3 {
            guard let capacity = assets.decoderCapacities(useMetal: usesMetal).first(where: { $0 >= limit }) else {
                throw YuE2Failure.assets("The requested song length requires a larger decoder.")
            }
            let stage = Stage(request: request, limit: limit, capacity: capacity, index: 0,
                              isAcoustic: false, useMetal: usesMetal)
            try await Decoder(assets: assets, pairedWeights: pairedWeights).run(stage, in: work, progress: progress)
        } else {
            let acousticInput = work.appendingPathComponent("acoustic-input.json")
            for (index, capacity) in assets.manifest.decoderFrames.enumerated() {
                try Task.checkCancellation()
                let stage = Stage(request: request, limit: limit, capacity: capacity, index: index, isAcoustic: false)
                try await Decoder(assets: assets).run(stage, in: work, progress: progress)
                if FileManager.default.fileExists(atPath: acousticInput.path) { break }
                if index > 0 {
                    try FileManager.default.removeItem(at: work.appendingPathComponent("stage-\(index - 1)", isDirectory: true))
                }
            }
            guard FileManager.default.fileExists(atPath: acousticInput.path) else {
                throw YuE2Failure.inference("The decoder did not produce a complete token sequence.")
            }
        }
        let tokenSeconds = tokenStarted.duration(to: .now).seconds
        let result = try await Acoustic(assets: assets).render(request, checkpointAt: work, useMetal: usesMetal,
                                                               streamAudio: streamAudio, onPreview: onPreview, progress: progress)
        return (result, tokenSeconds)
    }

    private func renderStreaming(_ stage: Stage, work: URL, onPreview: (@Sendable (SongAudioPreview) -> Void)?,
                                 progress: @escaping @Sendable (SongProgress) -> Void) async throws -> (WorkerResult, Double) {
        let renderer = AcousticStreamRenderer(assets: assets, request: stage.request, limit: stage.limit,
                                              work: work, onPreview: onPreview)
        #if os(iOS)
        // Keep only one workload submitting to the phone GPU at a time. The audio
        // player consumes the previous window while Metal and Core ML take turns.
        let start = ContinuousClock.now
        var result: WorkerResult?
        try await Decoder(assets: assets, pairedWeights: pairedWeights).run(stage, in: work, onWindow: { window in
            if window.finalTokens != nil { progress(.waveform) }
            result = try renderer.append(window)
        }, progress: progress)
        guard let result else { throw AcousticStreamRenderer.incomplete }
        let tokenSeconds = max(0, start.duration(to: .now).seconds - result.acousticSeconds - result.waveformSeconds)
        return (result, tokenSeconds)
        #else
        let (windows, continuation) = AsyncThrowingStream.makeStream(of: AcousticWindow.self, bufferingPolicy: .bufferingOldest(1))
        async let composition = streamWindows(stage, work: work, to: continuation, progress: progress)
        for try await window in windows {
            if let result = try renderer.append(window) { return (result, try await composition) }
        }
        throw AcousticStreamRenderer.incomplete
        #endif
    }

    #if !os(iOS)
    private func streamWindows(_ stage: Stage, work: URL, to continuation: AsyncThrowingStream<AcousticWindow, any Error>.Continuation,
                               progress: @escaping @Sendable (SongProgress) -> Void) async throws -> Double {
        let start = ContinuousClock.now
        do {
            try await Decoder(assets: assets, pairedWeights: pairedWeights).run(stage, in: work, onWindow: { window in
                while true {
                    try Task.checkCancellation()
                    switch continuation.yield(window) {
                    case .enqueued: return
                    case .dropped: try await Task.sleep(for: .milliseconds(30))
                    case .terminated: throw CancellationError()
                    @unknown default: throw CancellationError()
                    }
                }
            }, progress: progress)
            progress(.waveform)
            continuation.finish()
            return start.duration(to: .now).seconds
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }
    #endif
}

struct Manifest: Codable, Sendable {
    let version: Int
    let promptCapacity: Int
    let decoderFrames: [Int]
    let acousticFrames: [Int]
    let conditioningBatch: Int?
    let metalFrames: Int?
    var batch: Int { conditioningBatch ?? 2 }

    func acousticCapacity(for count: Int, profile: AcousticProfile?, hasFastGraph: @autoclosure () -> Bool) -> Int? {
        guard let reference = acousticFrames.first(where: { $0 >= count }) else { return nil }
        if profile == .fast, count <= 3328, reference > 3328, hasFastGraph() { return 3328 }
        return reference
    }
}

struct ModelAssets: Sendable {
    let directory: URL
    let manifest: Manifest

    init(directory: URL) throws {
        guard directory.isFileURL else { throw YuE2Failure.assets("Use a local asset directory.") }
        self.directory = directory.standardizedFileURL
        manifest = try readRecord(Manifest.self, at: directory.appendingPathComponent("manifest.json"))
        let m = manifest
        guard (1...3).contains(m.version), (1...2).contains(m.batch),
              m.version != 3 || m.batch == 2, (32...5_024).contains(m.promptCapacity),
              Self.valid(m.decoderFrames, maximum: 5200), Self.valid(m.acousticFrames, maximum: 6400),
              let acoustic = m.acousticFrames.last, let decoder = m.decoderFrames.last,
              acoustic >= decoder else { throw YuE2Failure.assets("Invalid version or graph capacities.") }
        if let extended = m.metalFrames {
            guard m.version == 3, extended > decoder, m.acousticFrames.contains(extended) else {
                throw YuE2Failure.assets("The extended Metal decoder needs a matching acoustic graph.")
            }
        }
        let autoregressive = m.version >= 2
            ? ["Autoregressive"] : ["Prefill"] + m.decoderFrames.map { "Decoder\($0)" }
        for name in autoregressive + ["Waveform"] + m.acousticFrames.map({ "Acoustic\($0)" }) {
            guard FileManager.default.fileExists(atPath: url("\(name).mlmodelc/coremldata.bin").path) else {
                throw YuE2Failure.assets("Missing compiled graph \(name).")
            }
        }
        guard FileManager.default.fileExists(atPath: url("tokenizer.tiktoken").path),
              (try? url("embeddings.f16").resourceValues(forKeys: [.fileSizeKey]).fileSize)
                == TensorSpec.vocabulary * TensorSpec.hidden * 2 else {
            throw YuE2Failure.assets("Missing tokenizer or invalid embedding table size.")
        }
    }

    private static func valid(_ frames: [Int], maximum: Int) -> Bool {
        !frames.isEmpty && frames == Array(Set(frames)).sorted()
            && frames.allSatisfy { (128...maximum).contains($0) }
    }

    func decoderCapacities(useMetal: Bool) -> [Int] {
        if useMetal, let extended = manifest.metalFrames { return manifest.decoderFrames + [extended] }
        return manifest.decoderFrames
    }

    func limits(for request: SongRequest, useMetal: Bool = false) throws -> Int {
        guard (1...64).contains(request.acousticSteps) else {
            throw YuE2Failure.request("Use between 1 and 64 synthesis steps.")
        }
        guard let ceiling = decoderCapacities(useMetal: useMetal).last else {
            throw YuE2Failure.assets("There are no decoder capacities.")
        }
        let limit = request.maximumFrames ?? ceiling
        if let scale = request.guidanceScale {
            guard scale.isFinite, scale >= 1 else {
                throw YuE2Failure.request("Text guidance must be a finite number of at least 1.")
            }
            guard manifest.batch == 2 else {
                throw YuE2Failure.request("Adjustable text guidance requires a two-branch model bundle.")
            }
        }
        // The YuE2 tokenizer has tokens up to 128 UTF-8 bytes long.
        let maximumInputBytes = max(32_768, manifest.promptCapacity * 128)
        guard (128...ceiling).contains(limit), (128...limit).contains(request.minimumFrames),
              !request.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.lyrics.utf8.count + request.style.utf8.count + (request.scoreABC?.utf8.count ?? 0) <= maximumInputBytes else {
            throw YuE2Failure.request("Check the style, input length, and frame limits for this asset bundle.")
        }
        if let prefix = request.semanticPrefix, !prefix.isEmpty {
            guard request.scoreABC == nil, prefix.count < limit, prefix.allSatisfy({ (0..<32768).contains($0) }) else {
                throw YuE2Failure.request("The reference needs valid semantic codes and room for new music.")
            }
        }
        return limit
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    var hasFastAcousticGraph: Bool {
        let graph = url("Acoustic3328.mlmodelc")
        return ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy { path in
            let size = try? graph.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (size ?? 0) > 0
        }
    }

    func load(_ name: String) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        #if os(iOS)
        // MPSGraph can abort the process allocating Prefill's GPU heap on iPhone.
        // Prefill runs once per song. The Metal token decoder and acoustic graphs stay on the GPU.
        if name == "Prefill" { configuration.computeUnits = .cpuOnly }
        #endif
        if manifest.version >= 2, name == "Prefill" || name == "GrowableDecoder" || name.hasPrefix("Decoder") {
            configuration.functionName = name
            return try MLModel(contentsOf: url("Autoregressive.mlmodelc"), configuration: configuration)
        }
        return try MLModel(contentsOf: url("\(name).mlmodelc"), configuration: configuration)
    }
}


struct Stage: Codable {
    let request: SongRequest
    let limit: Int
    let capacity: Int
    let index: Int
    let isAcoustic: Bool
    let referenceCache: Bool?
    let useMetal: Bool?

    init(request: SongRequest, limit: Int, capacity: Int, index: Int, isAcoustic: Bool,
         referenceCache: Bool? = nil, useMetal: Bool? = nil) {
        self.request = request
        self.limit = limit
        self.capacity = capacity
        self.index = index
        self.isAcoustic = isAcoustic
        self.referenceCache = referenceCache
        self.useMetal = useMetal
    }
}

struct Checkpoint: Codable {
    let tokens: [Int]
    let lengths: [Int]
    let randomState: UInt64
    let finished: Bool
    let naturalEnding: Bool
    let storedFrames: Int
}

struct WorkerResult: Codable {
    let tokens: [Int]
    let naturalEnding: Bool
    let sampleFrames: Int
    let acousticSeconds: Double
    let waveformSeconds: Double
}

struct WorkerTimings: Codable { let tokenSeconds: Double }

func readRecord<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

func writeRecord<T: Encodable>(_ value: T, to url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
