import AVFoundation
import Foundation
import Synchronization
import YuE2CoreML
import YuE2Kit

/// Loads the indexed Metal bundle from the app or Application Support.
@MainActor
final class YuE2GenerationBackend: MusicGenerationBackend {
    private struct InstalledModel {
        let renderer: YuE2Renderer
        let directory: URL
    }
    private let metalModel: InstalledModel?
    private let outputDirectory: URL
    private let native: NativeYuE2Renderer?
    private var pairedRenderer: YuE2Renderer?
    private var rendering = false
    var isAvailable: Bool {
        #if os(macOS)
        if native != nil { return true }
        #endif
        return metalModel != nil
    }
    var canUsePairedMetal: Bool {
        guard let directory = metalModel?.directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/manifest.json").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/weights.bin").path)
    }
    var canStreamAcoustics: Bool {
        #if os(macOS)
        if native != nil { return true }
        #endif
        return metalModel?.renderer.supportsStreamingAcoustics == true
    }
    var canPlanScore: Bool {
        #if os(macOS)
        native != nil
        #else
        false
        #endif
    }
    var canPrepareRadioPair: Bool {
        #if os(macOS)
        metalModel?.renderer.supportsSongPair == true && native?.hasFullSongPCM == true
        #else
        false
        #endif
    }
    var canCreateExtended: Bool {
        #if os(macOS)
        if metalModel == nil, native != nil { return true }
        return (metalModel?.renderer.maximumFrames ?? 0) >= CreateLength.extended.maximumFrames
        #else
        return false
        #endif
    }

    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage? {
        if (request.scoreABC != nil || request.planScore) && canPlanScore || nativeMode(for: request) == .fullSongHighPrecision { return nil }
        guard let renderer = metalModel?.renderer else { return nil }
        let usage = try await renderer.promptUsage(style: request.style, lyrics: request.lyrics, scoreABC: request.scoreABC)
        return MusicPromptUsage(count: usage.count, limit: usage.limit,
                                styleTokens: usage.styleTokens, lyricTokens: usage.lyricTokens)
    }

    func waitForIdle() async throws {
        while rendering { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
    }

    func releaseResources() async {
        try? await waitForIdle()
        await native?.releaseResources()
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    func prepareRendering(_ acoustics: CreateAcoustics, compactAttentionCache: Bool, preferFullPrecision: Bool) {
        #if os(macOS)
        if !rendering {
            native?.prepare(nativeMode(acoustics, compactAttentionCache: compactAttentionCache, preferFullPrecision: preferFullPrecision))
        }
        #endif
    }

    private func nativeMode(for request: MusicGenerationRequest) -> YuE2Engine.SynthesisMode {
        let preferFullPrecision = request.purpose == .createdSong && request.synthesisSteps == RenderingSteps.thirtyTwo.rawValue
            && request.createRenderer == .metal && request.semanticPrefix.isEmpty
        return nativeMode(request.createAcoustics, compactAttentionCache: request.planScore && request.compactAttentionCache,
                          preferFullPrecision: preferFullPrecision)
    }

    private func nativeMode(_ acoustics: CreateAcoustics, compactAttentionCache: Bool,
                            preferFullPrecision: Bool) -> YuE2Engine.SynthesisMode {
        if acoustics == .streaming { return .streamingPreview }
        if compactAttentionCache { return .fullSongCompactCache }
        #if os(macOS)
        if preferFullPrecision && native?.hasFullPrecisionWeights == true { return .fullSongHighPrecision }
        #endif
        return .fullSong
    }

    init(supportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        outputDirectory = temporaryDirectory
            .appendingPathComponent("VibePlayerSongs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelRoots = [Bundle.main.resourceURL, supportDirectory].compactMap { $0 }
        #if os(macOS) && !VIBEPLAYER_APP_STORE
        native = supportDirectory.flatMap {
            NativeYuE2Renderer(root: $0.appendingPathComponent("YuE2NativeAssets", isDirectory: true))
        }
        #elseif os(macOS) || targetEnvironment(simulator)
        native = nil
        #else
        native = Bundle.main.privateFrameworksURL.flatMap { frameworks in
            let runtime = frameworks.appendingPathComponent("YuE2Audio.framework/YuE2Audio")
            return modelRoots.lazy.compactMap { root in
                NativeYuE2Renderer(root: root.appendingPathComponent("YuE2NativeAssets", isDirectory: true),
                                   embeddedRuntime: runtime)
            }.first
        }
        #endif

        for root in modelRoots {
            let directory = root.appendingPathComponent("YuE2MetalAssets", isDirectory: true)
            guard let renderer = try? YuE2Renderer(assets: directory, execution: .metal) else { continue }
            metalModel = InstalledModel(renderer: renderer, directory: directory)
            return
        }
        metalModel = nil
    }

    deinit {
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        guard isAvailable else { throw MusicGenerationError.metalUnavailable }
        while rendering {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        rendering = true
        defer { rendering = false }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let mode = nativeMode(for: request)
            #if os(macOS)
            await native?.finishPreparing(for: mode)
            #endif
            if ((request.scoreABC != nil || request.planScore) && canPlanScore) || mode == .fullSongHighPrecision, let native {
                return try await native.renderFullSong(request, mode: mode, to: output, onPreview: onPreview, onProgress: onProgress)
            }
            #if os(macOS)
            let usesNative = (request.purpose == .radio && native?.hasFullSongPCM != true) ||
                request.createAcoustics == .streaming || metalModel == nil
            if usesNative, let native, request.createRenderer != .metalPaired {
                let tokens = try await native.render(request, to: output, onPreview: onPreview, onProgress: onProgress)
                return MusicGenerationOutput(url: output, semanticTokens: tokens)
            }
            #endif
            return try await renderWithIndexedModel(request, to: output, onPreview: onPreview, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func renderWithIndexedModel(_ request: MusicGenerationRequest, to output: URL,
                                        onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                                        onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        guard let model = metalModel else { throw MusicGenerationError.metalUnavailable }
        let renderer: YuE2Renderer
        if request.purpose == .createdSong, request.createRenderer == .metalPaired {
            if let pairedRenderer { renderer = pairedRenderer }
            else {
                let directory = model.directory
                // Validate the large sidecar away from the UI and only when the user selects it.
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try YuE2Renderer(assets: directory, execution: .metalPaired)
                }.value
                try Task.checkCancellation()
                pairedRenderer = prepared
                renderer = prepared
            }
        } else { renderer = model.renderer }
        #if os(iOS)
        // Use the full-context acoustic graph exercised on the phone. The larger GPU
        // graph can fail during heap allocation before Core ML returns an error.
        let maxFrames = min(request.maxSemanticFrames, renderer.maximumFrames, 4_200)
        #else
        let maxFrames = min(request.maxSemanticFrames, renderer.maximumFrames)
        #endif
        let radio = request.purpose == .radio
        guard radio || request.minimumSemanticFrames <= maxFrames else { throw MusicGenerationError.extendedUnavailable }
        let minimum = radio ? min(request.minimumSemanticFrames, maxFrames) : request.minimumSemanticFrames
        let prefix = Array(request.semanticPrefix.prefix(max(0, maxFrames - 250)))
        let profile: AcousticProfile = switch request.createAcoustics {
        case .streaming: .streaming
        case .reference: radio && renderer.supportsFastAcoustics ? .fast : .reference
        }
        let song = SongRequest(lyrics: request.lyrics, style: request.style, seed: request.seed,
                               maximumFrames: maxFrames, minimumFrames: max(minimum, prefix.count + (prefix.isEmpty ? 0 : 250)),
                               acousticProfile: profile, semanticPrefix: prefix.isEmpty ? nil : prefix,
                               guidanceScale: request.guidanceScale,
                               synthesisSteps: profile == .streaming ? nil : request.synthesisSteps,
                               scoreABC: request.scoreABC)
        let report: @Sendable (SongProgress) -> Void = { progress in
            switch progress {
            case .tokens(let count, let limit): onProgress(.tokens(count, limit))
            case .synthesis(let step, let total): onProgress(.synthesis(step, total))
            case .waveform: onProgress(.waveform)
            case .workerRetry: break
            }
        }
        if request.createAcoustics != .streaming, let native,
           let rendered = try await native.renderHybrid(song, with: renderer, steps: request.synthesisSteps, to: output,
                                                        purpose: request.purpose,
                                                        successor: request.radioSuccessor,
                                                        onPreview: onPreview, onProgress: onProgress) { return rendered }
        let preview: (@Sendable (SongAudioPreview) -> Void)?
        if let onPreview {
            preview = { audio in onPreview(MusicAudioPreview(samples: audio.samples, totalFrames: audio.totalFrames, startFrame: audio.startFrame)) }
        } else { preview = nil }
        let result = try await renderer.render(song, to: output, streamAudio: preview != nil, onPreview: preview,
                                               onProgress: report)
        return MusicGenerationOutput(url: output, semanticTokens: result.codecTokens)
    }
}

@MainActor
private final class NativeYuE2Renderer {
    private let library: URL
    private var fastLibrary: URL?
    private let hasStandardPCM: Bool
    var hasFullSongPCM: Bool { fastLibrary != nil || hasStandardPCM }
    private let weights: URL
    private let spec: URL
    var hasFullPrecisionWeights: Bool { YuE2Engine.hasFullPrecisionWeights(at: weights) }
    private var resident: (mode: YuE2Engine.SynthesisMode, library: URL, engine: YuE2Engine)?
    private var preparation: (mode: YuE2Engine.SynthesisMode, library: URL, task: Task<YuE2Engine, Error>)?
    private var reservedRadioDraft: (request: SongRequest, draft: SongDraft)?

    init?(root: URL, embeddedRuntime: URL? = nil) {
        #if os(macOS)
        let pcmLibrary = root.appendingPathComponent("libaudiocpp-pcm.dylib")
        hasStandardPCM = FileManager.default.isReadableFile(atPath: pcmLibrary.path)
        library = hasStandardPCM ? pcmLibrary : root.appendingPathComponent("libaudiocpp.dylib")
        let fastPCM = root.appendingPathComponent("libaudiocpp-pcm-fast.dylib")
        fastLibrary = FileManager.default.isReadableFile(atPath: fastPCM.path) ? fastPCM : nil
        #else
        guard let embeddedRuntime else { return nil }
        library = embeddedRuntime
        fastLibrary = embeddedRuntime
        hasStandardPCM = false
        #endif
        weights = root.appendingPathComponent("weights", isDirectory: true)
        spec = root.appendingPathComponent("yue2.json")
        let files = [library, spec] + ["yue2-3b-q4_0.gguf", "yue2-vae-f16.gguf", "sidecars/yue2-qwen.tiktoken",
            "sidecars/yue2-vae-config.json", "sidecars/yue2-model-config.json", "sidecars/yue2-generation-config.json"
        ].map { weights.appendingPathComponent($0) }
        guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { return nil }
    }

    func prepare(_ mode: YuE2Engine.SynthesisMode) {
        guard preparation == nil else { return }
        let runtime = mode == .streamingPreview ? library : (fastLibrary ?? library)
        if resident?.mode == mode, resident?.library == runtime { return }
        resident = nil
        let task = Task { [weights, spec] in
            let engine = try await YuE2Engine.load(library: runtime, weights: weights, modelSpec: spec, mode: mode)
            try Task.checkCancellation()
            if mode == .streamingPreview {
                let warmup = YuE2Prompt(lyrics: "", style: "instrumental, warm piano", seed: 1)
                _ = try await engine.render(warmup, frames: 100, steps: 4)
            }
            return engine
        }
        preparation = (mode, runtime, task)
    }

    func finishPreparing(for mode: YuE2Engine.SynthesisMode? = nil) async {
        guard let preparation else { return }
        if let mode, mode != preparation.mode { preparation.task.cancel() }
        if let engine = try? await preparation.task.value {
            resident = (preparation.mode, preparation.library, engine)
        }
        self.preparation = nil
    }

    func releaseResources() async {
        preparation?.task.cancel()
        await finishPreparing()
        resident = nil
        reservedRadioDraft = nil
    }

    private func loadWaveformEngine(using runtime: URL, mode: YuE2Engine.SynthesisMode) async throws -> YuE2Engine? {
        let engine = try await engine(for: mode, using: runtime)
        return engine.supportsWaveformStreaming ? engine : nil
    }

    private func waveformEngine(mode: YuE2Engine.SynthesisMode = .fullSong) async throws -> YuE2Engine? {
        if let fastLibrary {
            if let engine = try? await loadWaveformEngine(using: fastLibrary, mode: mode) { return engine }
            try Task.checkCancellation()
            self.fastLibrary = nil
        }
        guard hasStandardPCM else { return nil }
        let engine = try? await loadWaveformEngine(using: library, mode: mode)
        try Task.checkCancellation()
        return engine
    }

    private func compose(_ request: SongRequest, with renderer: YuE2Renderer,
                         purpose: MusicGenerationRequest.Purpose, successor: MusicGenerationRequest.RadioSuccessor?,
                         onProgress: @escaping @Sendable (SongProgress) -> Void) async throws -> SongDraft {
        if purpose == .radio {
            let reserved = reservedRadioDraft
            reservedRadioDraft = nil
            if let reserved {
                var composedRequest = reserved.request
                composedRequest.synthesisSteps = request.synthesisSteps
                if composedRequest == request {
                    onProgress(.tokens(count: reserved.draft.codecTokens.count, limit: reserved.draft.codecTokens.count))
                    return reserved.draft
                }
            }
            if let successor, renderer.supportsSongPair {
                var next = request
                next.seed = successor.seed
                next.style = successor.style
                do {
                    let framesReported = Mutex(-1)
                    let (first, second) = try await renderer.composePair(request, next) { _, progress in
                        if case .tokens(let frames, _) = progress, framesReported.withLock({ highest in
                            guard frames > highest else { return false }
                            highest = frames
                            return true
                        }) {
                            onProgress(progress)
                        }
                    }
                    reservedRadioDraft = (next, second)
                    return first
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // The single-song path remains available if the larger cache cannot be allocated.
                }
            }
        }
        return try await renderer.compose(request, onProgress: onProgress)
    }

    func renderHybrid(_ request: SongRequest, with renderer: YuE2Renderer, steps: Int, to output: URL,
                      purpose: MusicGenerationRequest.Purpose,
                      successor: MusicGenerationRequest.RadioSuccessor?,
                      onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                      onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput? {
        #if os(macOS)
        guard let engine = try await waveformEngine() else { return nil }
        #else
        guard hasFullSongPCM else { return nil }
        #endif
        try Task.checkCancellation()
        let draft = try await compose(request, with: renderer, purpose: purpose, successor: successor) { progress in
            if case .tokens(let count, let limit) = progress { onProgress(.tokens(count, limit)) }
        }
        #if os(iOS)
        // The decoder's GPU buffers go out of scope before loading acoustic weights.
        // Drop the acoustic session before the next song to keep the phases separate.
        defer { resident = nil }
        guard let engine = try await waveformEngine() else { return nil }
        #endif
        let prompt = YuE2Prompt(lyrics: request.lyrics, style: request.style, seed: request.seed,
                                guidanceScale: request.guidanceScale ?? 1.01)
        let file = try NativeSongFile(url: output)
        onProgress(.synthesizing)
        let nativeProgress = Self.forwardNativeProgress(to: onProgress)
        if let onPreview {
            let (tiles, continuation) = AsyncStream<YuE2WaveformChunk>.makeStream()
            async let rendering: Void = renderTiles(engine, prompt: prompt, draft: draft, steps: steps,
                                                    onProgress: nativeProgress, to: continuation)
            for await tile in tiles {
                try Task.checkCancellation()
                if tile.startFrame == 0, !engine.supportsSynthesisProgress { onProgress(.waveform) }
                let chunk = try await file.append(tile.audio, totalFrames: tile.totalFrames)
                onPreview(chunk)
            }
            try await rendering
        } else {
            let audio = try await engine.renderComposed(prompt, tokens: draft.codecTokens,
                                                        naturalEnding: draft.naturalEnding, steps: steps, onProgress: nativeProgress)
            if !engine.supportsSynthesisProgress { onProgress(.waveform) }
            try await file.write(audio)
        }
        return MusicGenerationOutput(url: output, semanticTokens: draft.codecTokens,
                                     radioSuccessorSeed: purpose == .radio ? reservedRadioDraft?.request.seed : nil)
    }

    private func renderTiles(_ engine: YuE2Engine, prompt: YuE2Prompt, draft: SongDraft, steps: Int,
                             onProgress: @escaping @Sendable (YuE2RenderProgress) -> Void,
                             to continuation: AsyncStream<YuE2WaveformChunk>.Continuation) async throws {
        defer { continuation.finish() }
        _ = try await engine.renderComposed(prompt, tokens: draft.codecTokens, naturalEnding: draft.naturalEnding,
                                            steps: steps, onProgress: onProgress) { tile in continuation.yield(tile) }
    }

    private static func forwardNativeProgress(to onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void)
        -> @Sendable (YuE2RenderProgress) -> Void {
        { progress in
            switch progress {
            case .synthesis(let completed, let total): onProgress(.synthesis(completed, total))
            case .waveform: onProgress(.waveform)
            }
        }
    }

    private func engine(for mode: YuE2Engine.SynthesisMode, using preferredRuntime: URL? = nil) async throws -> YuE2Engine {
        let runtime = preferredRuntime ?? library
        if let resident, resident.mode == mode, resident.library == runtime { return resident.engine }
        resident = nil
        let engine = try await YuE2Engine.load(library: runtime, weights: weights, modelSpec: spec, mode: mode)
        resident = (mode, runtime, engine)
        return engine
    }

    func render(_ request: MusicGenerationRequest, to output: URL,
                onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> [Int] {
        try Task.checkCancellation()
        let preview = request.purpose == .createdSong && request.createAcoustics == .streaming && request.semanticPrefix.isEmpty
        let mode: YuE2Engine.SynthesisMode = preview ? .streamingPreview : .fullSong
        let engine: YuE2Engine
        if !preview, let fullSongEngine = try await waveformEngine() {
            engine = fullSongEngine
        } else {
            engine = try await self.engine(for: mode)
        }
        let prompt = YuE2Prompt(lyrics: request.lyrics, style: request.style, seed: request.seed,
                                guidanceScale: request.guidanceScale ?? 1.01)
        let file = try NativeSongFile(url: output)
        let tokens: [Int]
        if preview, let onPreview {
            let first = YuE2Engine.windowedPreviewCheckpoints[0]
            let stride = YuE2Engine.windowedPreviewCheckpoints[1] - first
            guard request.maxSemanticFrames >= first else { throw YuE2Error.invalidRequest }
            let end = first + (request.maxSemanticFrames - first) / stride * stride
            let checkpoints = (YuE2Engine.windowedPreviewCheckpoints + [1192, 1780, 2536, 3712]).filter { $0 < end } + [end]
            onProgress(.tokens(0, end))
            let minimum = min(end, max(request.minimumSemanticFrames, 1750))
            tokens = try await engine.renderProgressively(prompt, checkpoints: checkpoints, steps: 4, minimumFrames: minimum) { audio in
                let chunk = try await file.append(audio, totalFrames: end * 1_920)
                onPreview(chunk)
                onProgress(.tokens((chunk.startFrame + audio.frameCount) / 1_920, end))
            }
        } else {
            onProgress(.tokens(0, request.maxSemanticFrames))
            let prefix = Array(request.semanticPrefix.prefix(request.maxSemanticFrames - 250))
            let take = try await engine.renderTake(prompt, frames: request.maxSemanticFrames,
                                                   steps: preview ? 4 : request.synthesisSteps,
                                                   minimumFrames: max(request.minimumSemanticFrames, prefix.count + (prefix.isEmpty ? 0 : 250)),
                                                   semanticPrefix: prefix, onProgress: Self.forwardNativeProgress(to: onProgress))
            try await file.write(take.audio)
            tokens = take.tokens
        }
        onProgress(.waveform)
        return tokens
    }

    func renderFullSong(_ request: MusicGenerationRequest, mode: YuE2Engine.SynthesisMode, to output: URL,
                        onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                        onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        #if os(iOS)
        let frames = min(request.maxSemanticFrames, 4_200)
        defer { resident = nil }
        #else
        let frames = request.maxSemanticFrames
        #endif
        guard request.minimumSemanticFrames <= frames else { throw MusicGenerationError.extendedUnavailable }
        let engine: YuE2Engine
        if let waveform = try await waveformEngine(mode: mode) { engine = waveform }
        else { engine = try await self.engine(for: mode) }
        let prompt = YuE2Prompt(lyrics: request.lyrics, style: request.style, seed: request.seed,
                                guidanceScale: request.guidanceScale ?? (request.planScore ? 1 : 1.01))
        let file = try NativeSongFile(url: output)
        let progress = Self.forwardNativeProgress(to: onProgress)
        onProgress(request.planScore || request.scoreABC != nil ? .planningMusic : .tokens(0, frames))
        let tokens: [Int]
        if let onPreview, engine.supportsWaveformStreaming {
            let (tiles, continuation) = AsyncStream<YuE2WaveformChunk>.makeStream()
            async let take = renderFullSongTake(engine, prompt: prompt, frames: frames, request: request,
                                               onProgress: progress, tiles: continuation)
            for await tile in tiles {
                try Task.checkCancellation()
                if tile.startFrame == 0, !engine.supportsSynthesisProgress { onProgress(.waveform) }
                onPreview(try await file.append(tile.audio, totalFrames: tile.totalFrames))
            }
            tokens = try await take.tokens
        } else {
            let take = try await renderFullSongTake(engine, prompt: prompt, frames: frames, request: request, onProgress: progress)
            if !engine.supportsSynthesisProgress { onProgress(.waveform) }
            try await file.write(take.audio)
            tokens = take.tokens
        }
        return MusicGenerationOutput(url: output, semanticTokens: tokens)
    }

    private func renderFullSongTake(_ engine: YuE2Engine, prompt: YuE2Prompt, frames: Int,
                                   request: MusicGenerationRequest, onProgress: @escaping @Sendable (YuE2RenderProgress) -> Void,
                                   tiles: AsyncStream<YuE2WaveformChunk>.Continuation? = nil) async throws -> (audio: YuE2Audio, tokens: [Int]) {
        defer { tiles?.finish() }
        let deliver: (@Sendable (YuE2WaveformChunk) -> Void)?
        if let tiles { deliver = { tiles.yield($0) } }
        else { deliver = nil }
        return try await engine.renderTake(prompt, frames: frames, steps: request.synthesisSteps,
                                           minimumFrames: request.minimumSemanticFrames, planScore: request.planScore,
                                           score: request.scoreABC.map { try YuE2Score($0) },
                                           onProgress: onProgress, onPCM: deliver)
    }
}

private actor NativeSongFile {
    private let file: AVAudioFile
    private var position = 0

    init(url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true) else {
            throw YuE2Error.invalidAudio
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func write(_ audio: YuE2Audio) throws {
        _ = try writeBuffer(audio, totalFrames: audio.frameCount)
    }

    func append(_ audio: YuE2Audio, totalFrames: Int) throws -> MusicAudioPreview {
        let start = position
        let buffer = try writeBuffer(audio, totalFrames: totalFrames)
        let samples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: audio.samples.count))
        return MusicAudioPreview(samples: samples, totalFrames: totalFrames, startFrame: start, lowLatency: true)
    }

    private func writeBuffer(_ audio: YuE2Audio, totalFrames: Int) throws -> AVAudioPCMBuffer {
        let frames = audio.frameCount
        guard audio.sampleRate == 48_000, audio.channels == 2, frames > 0,
              audio.samples.count == frames * 2, frames <= totalFrames - position,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.int16ChannelData?[0] else { throw YuE2Error.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, value) in audio.samples.enumerated() {
            guard value.isFinite else { throw YuE2Error.invalidAudio }
            output[index] = Int16(clamping: Int((min(1, max(-1, value)) * 32768).rounded()))
        }
        try file.write(from: buffer)
        position += frames
        return buffer
    }
}

#if DEBUG
/// Supplies a short fixture for UI tests; it is never selected in normal launches.
@MainActor
final class FixtureMusicGenerationBackend: MusicGenerationBackend {
    let isAvailable = true
    let canStreamAcoustics = true
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        let arguments = ProcessInfo.processInfo.arguments
        if request.purpose == .createdSong, request.createAcoustics == .reference,
           arguments.contains("--fixture-full-context-audio"), let onPreview {
            onProgress(.synthesis(1, request.synthesisSteps))
            try await Task.sleep(for: .seconds(5))
            let samples = tone(frames: 48_000 * 18)
            onProgress(.waveform)
            onPreview(MusicAudioPreview(samples: Array(samples.prefix(48_000 * 9 * 2)), totalFrames: samples.count / 2))
            try await Task.sleep(for: .seconds(5))
            try writeFixture(samples, to: output)
            return MusicGenerationOutput(url: output)
        }
        if request.purpose == .createdSong, arguments.contains("--fixture-early-audio"), let onPreview {
            try await Task.sleep(for: .milliseconds(350))
            let samples = tone(frames: 48_000 * 40)
            onProgress(.waveform)
            let opening = 48_000 * 28
            let middle = 48_000 * 34
            onPreview(MusicAudioPreview(samples: Array(samples.prefix(opening * 2)), totalFrames: samples.count / 2))
            try await Task.sleep(for: .seconds(2))
            onPreview(MusicAudioPreview(samples: Array(samples[(opening * 2)..<(middle * 2)]),
                                        totalFrames: samples.count / 2, startFrame: opening))
            try await Task.sleep(for: .seconds(12))
            try writeFixture(samples, to: output)
            return MusicGenerationOutput(url: output)
        }
        if request.purpose == .radio, arguments.contains("--fixture-radio-gap") {
            onProgress(.tokens(40, 512))
            try await Task.sleep(for: .seconds(3))
            try writeFixture(tone(frames: 48_000 * 2), to: output)
            return MusicGenerationOutput(url: output)
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let source = Bundle.main.url(forResource: "atmosphere", withExtension: "wav") else { throw MusicGenerationError.unavailable }
        try FileManager.default.copyItem(at: source, to: output)
        return MusicGenerationOutput(url: output)
    }

    private func tone(frames: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let gain = min(1, Double(frame) / 480, Double(frames - frame - 1) / 480)
            let sample = Int16(sin(2 * .pi * 220 * Double(frame) / 48_000) * 200 * gain)
            samples[frame * 2] = sample
            samples[frame * 2 + 1] = sample
        }
        return samples
    }

    private func writeFixture(_ samples: [Int16], to url: URL) throws {
        let frames = AVAudioFrameCount(samples.count / 2)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData?[0] else { throw MusicGenerationError.unavailable }
        buffer.frameLength = frames
        for index in samples.indices { channel[index] = samples[index] }
        let fixture = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try fixture.write(from: buffer)
    }
}
#endif
