import CAudioBridge
import Foundation

public struct YuE2Prompt: Sendable {
    public let lyrics: String
    public let style: String
    public let seed: UInt64
    public let guidanceScale: Float

    public init(lyrics: String, style: String, seed: UInt64, guidanceScale: Float = 1.01) {
        self.lyrics = lyrics
        self.style = style
        self.seed = seed
        self.guidanceScale = guidanceScale
    }
}

public struct YuE2Audio: Sendable {
    /// Interleaved Float32 PCM.
    public let samples: [Float]
    public let sampleRate: Int
    public let channels: Int

    public var frameCount: Int { samples.count / channels }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
}

public struct YuE2WaveformChunk: Sendable {
    public let audio: YuE2Audio
    public let startFrame: Int
    public let totalFrames: Int
}

public enum YuE2RenderProgress: Sendable {
    case synthesis(completed: Int, total: Int)
    case waveform
}

public enum YuE2Error: LocalizedError {
    case native(String)
    case invalidRequest
    case invalidAudio
    case invalidContinuation
    case busy

    public var errorDescription: String? {
        switch self {
        case .native(let detail): detail
        case .invalidRequest: "Provide a style, a valid seed, increasing positive frame counts, and text guidance of at least 1."
        case .invalidAudio: "YuE2 returned an unexpected audio format or duration."
        case .invalidContinuation: "YuE2 returned an invalid semantic token continuation."
        case .busy: "This YuE2 session is already generating audio."
        }
    }
}

/// Owns one loaded Metal session. Reuse it for the life of the generation UI.
public actor YuE2Engine {
    public enum SynthesisMode: Sendable {
        case fullSong
        case fullSongCompactCache
        case fullSongHighPrecision
        case streamingPreview
    }

    private static let fullPrecisionModel = "yue2-3b-bf16.gguf"
    private static let fullPrecisionVAE = "yue2-vae-f32.gguf"

    public static func hasFullPrecisionWeights(at directory: URL) -> Bool {
        [fullPrecisionModel, fullPrecisionVAE].allSatisfy {
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Model outputs one semantic frame per 40 ms.
    public static let framesPerSecond = 25
    public static let previewCheckpoints = [75, 150, 275, 475, 775]
    public static let windowedPreviewCheckpoints = [100, 184, 352, 520, 772]

    private final class Session {
        let handle: OpaquePointer

        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { yu_close(handle) }
    }

    private struct Render {
        let audio: YuE2Audio
        let tokens: [Int]
        let score: String?
    }

    private final class RenderObserver {
        let onPCM: (@Sendable (YuE2WaveformChunk) -> Void)?
        let onProgress: (@Sendable (YuE2RenderProgress) -> Void)?
        let totalFrames: Int
        let naturalEnding: Bool?
        var streamedFrames: Int?
        var received = 0
        var invalid = false

        init(totalFrames: Int = 0, naturalEnding: Bool? = true,
             onPCM: (@Sendable (YuE2WaveformChunk) -> Void)? = nil,
             onProgress: (@Sendable (YuE2RenderProgress) -> Void)?) {
            self.totalFrames = totalFrames
            self.naturalEnding = naturalEnding
            self.onPCM = onPCM
            self.onProgress = onProgress
        }

        static let receiveSamples: yu_pcm_callback = { context, samples, frames, rate, channels, start, total in
            guard let context else { return 1 }
            let observer = Unmanaged<RenderObserver>.fromOpaque(context).takeUnretainedValue()
            guard !Task.isCancelled else { return 1 }
            let expected = observer.streamedFrames ?? (observer.naturalEnding == nil ? total : observer.totalFrames)
            guard let samples, rate == 48_000, channels == 2, total == expected, total <= observer.totalFrames,
                  start == observer.received, frames > 0, frames <= total - start else {
                observer.invalid = true
                return 1
            }
            let audio = YuE2Audio(samples: Array(UnsafeBufferPointer(start: samples, count: frames * 2)),
                                  sampleRate: Int(rate), channels: Int(channels))
            observer.streamedFrames = total
            let naturalEnding = observer.naturalEnding ?? (total < observer.totalFrames)
            let output = naturalEnding ? audio : YuE2Engine.fadeEnd(audio, startFrame: start, totalFrames: total)
            observer.received += frames
            observer.onPCM?(YuE2WaveformChunk(audio: output, startFrame: start, totalFrames: total))
            return 0
        }

        static let receiveProgress: yu_progress_callback = { context, stage, completed, total in
            guard let context, !Task.isCancelled else { return 1 }
            let observer = Unmanaged<RenderObserver>.fromOpaque(context).takeUnretainedValue()
            switch stage {
            case Int32(YU_PROGRESS_SYNTHESIS): observer.onProgress?(.synthesis(completed: Int(completed), total: Int(total)))
            case Int32(YU_PROGRESS_WAVEFORM): observer.onProgress?(.waveform)
            default: break
            }
            return 0
        }
    }

    private let session: Session
    private let mode: SynthesisMode
    private var generating = false
    public nonisolated let supportsWaveformStreaming: Bool
    public nonisolated let supportsSynthesisProgress: Bool

    @concurrent
    public static func load(library: URL, weights: URL, modelSpec: URL? = nil,
                            mode: SynthesisMode = .fullSong) async throws -> YuE2Engine {
        try Task.checkCancellation()
        return try YuE2Engine(library: library, weights: weights, modelSpec: modelSpec, mode: mode)
    }

    private init(library: URL, weights: URL, modelSpec: URL?, mode: SynthesisMode) throws {
        let preview: Int32 = mode == .streamingPreview ? 1 : 0
        let compactCache: Int32 = mode == .fullSongCompactCache ? 1 : 0
        func open(_ libraryPath: UnsafePointer<CChar>, _ weightsPath: UnsafePointer<CChar>,
                  _ specPath: UnsafePointer<CChar>?) -> OpaquePointer? {
            if mode == .fullSongHighPrecision {
                return Self.fullPrecisionModel.withCString { model in
                    Self.fullPrecisionVAE.withCString { vae in
                        yu_open_with_models(libraryPath, weightsPath, specPath, preview, compactCache, model, vae)
                    }
                }
            }
            return yu_open_configured(libraryPath, weightsPath, specPath, preview, compactCache)
        }
        let handle = library.path.withCString { libraryPath in
            weights.path.withCString { weightsPath in
                if let modelSpec {
                    return modelSpec.path.withCString { open(libraryPath, weightsPath, $0) }
                }
                return open(libraryPath, weightsPath, nil)
            }
        }
        guard let handle else { throw YuE2Error.native(String(cString: yu_error())) }
        session = Session(handle)
        self.mode = mode
        supportsWaveformStreaming = yu_supports_pcm(handle) != 0
        supportsSynthesisProgress = yu_supports_progress(handle) != 0
    }

    /// Render a single take and let the model end it within the frame budget.
    public func render(_ prompt: YuE2Prompt, frames: Int, steps: Int = 8, minimumFrames: Int? = nil) throws -> YuE2Audio {
        try renderTake(prompt, frames: frames, steps: steps, minimumFrames: minimumFrames).audio
    }

    /// Returns the take and the semantic codes that can condition a future remix.
    public func renderTake(_ prompt: YuE2Prompt, frames: Int, steps: Int = 8, minimumFrames: Int? = nil,
                           semanticPrefix: [Int] = [], planScore: Bool = false, score: YuE2Score? = nil,
                           onProgress: (@Sendable (YuE2RenderProgress) -> Void)? = nil,
                           onPCM: (@Sendable (YuE2WaveformChunk) -> Void)? = nil)
        throws -> (audio: YuE2Audio, tokens: [Int]) {
        let take = try renderSong(prompt, frames: frames, steps: steps, minimumFrames: minimumFrames,
                                  semanticPrefix: semanticPrefix, planScore: planScore, score: score,
                                  onProgress: onProgress, onPCM: onPCM)
        return (take.audio, take.tokens)
    }

    public func renderSong(_ prompt: YuE2Prompt, frames: Int, steps: Int = 8, minimumFrames: Int? = nil,
                           semanticPrefix: [Int] = [], planScore: Bool = true, score: YuE2Score? = nil,
                           onProgress: (@Sendable (YuE2RenderProgress) -> Void)? = nil,
                           onPCM: (@Sendable (YuE2WaveformChunk) -> Void)? = nil)
        throws -> (audio: YuE2Audio, tokens: [Int], score: String?) {
        guard !generating else { throw YuE2Error.busy }
        try validate(prompt, checkpoints: [frames], steps: steps)
        if let minimumFrames, !(25...frames).contains(minimumFrames) { throw YuE2Error.invalidRequest }
        guard semanticPrefix.count < frames, semanticPrefix.allSatisfy({ (0..<32_768).contains($0) }) else {
            throw YuE2Error.invalidContinuation
        }
        if planScore || score != nil {
            guard mode != .streamingPreview, semanticPrefix.isEmpty else { throw YuE2Error.invalidRequest }
        }
        let observer = RenderObserver(totalFrames: frames * 1_920 - 64, naturalEnding: nil,
                                      onPCM: onPCM, onProgress: onProgress)
        let result = try render(prompt, frames: frames, steps: steps,
                                minimumFrames: mode == .streamingPreview ? frames : minimumFrames, prefix: semanticPrefix,
                                planScore: planScore, score: score, observer: observer)
        guard onPCM == nil || observer.received == result.audio.frameCount else { throw YuE2Error.invalidAudio }
        let audio = result.tokens.count == frames ? Self.fadeEnd(result.audio) : result.audio
        return (audio, result.tokens, score?.notation ?? result.score)
    }

    /// Renders the complete song in one acoustic pass. With the PCM-enabled runtime,
    /// `onPCM` receives finalized stereo waveform tiles while later tiles decode.
    public func renderComposed(_ prompt: YuE2Prompt, tokens: [Int], naturalEnding: Bool, steps: Int = 8,
                               onProgress: (@Sendable (YuE2RenderProgress) -> Void)? = nil,
                               onPCM: (@Sendable (YuE2WaveformChunk) -> Void)? = nil) throws -> YuE2Audio {
        guard !generating else { throw YuE2Error.busy }
        guard mode != .streamingPreview, tokens.allSatisfy({ (0..<32_768).contains($0) }) else {
            throw YuE2Error.invalidRequest
        }
        try validate(prompt, checkpoints: [tokens.count], steps: steps)
        let frames = tokens.count * 1_920 - 64
        let observer = RenderObserver(totalFrames: frames, naturalEnding: naturalEnding, onPCM: onPCM, onProgress: onProgress)
        let result = try render(prompt, frames: tokens.count, steps: steps, minimumFrames: tokens.count,
                                prefix: tokens, observer: observer)
        guard result.audio.frameCount == frames, onPCM == nil || observer.received == frames else {
            throw YuE2Error.invalidAudio
        }
        return naturalEnding ? result.audio : Self.fadeEnd(result.audio)
    }

    /// Delivers contiguous PCM as successive renders complete. Enqueue each chunk promptly.
    /// Stopping the task cancels before the next native render or delivery.
    @discardableResult public func renderProgressively(
        _ prompt: YuE2Prompt,
        checkpoints: [Int]? = nil,
        steps: Int = 4,
        minimumFrames: Int? = nil,
        onAudio: @Sendable (YuE2Audio) async throws -> Void
    ) async throws -> [Int] {
        guard !generating else { throw YuE2Error.busy }
        let windowed = mode == .streamingPreview
        let checkpoints = checkpoints ?? (windowed ? Self.windowedPreviewCheckpoints : Self.previewCheckpoints)
        try validate(prompt, checkpoints: checkpoints, steps: steps)
        if let minimumFrames, let last = checkpoints.last, !(25...last).contains(minimumFrames) {
            throw YuE2Error.invalidRequest
        }
        if windowed {
            let window = Int(YU_PREVIEW_WINDOW_FRAMES)
            let stride = window - Int(YU_PREVIEW_OVERLAP_FRAMES)
            guard checkpoints.allSatisfy({ $0 >= window && ($0 - window).isMultiple(of: stride) }) else {
                throw YuE2Error.invalidRequest
            }
        }
        generating = true
        defer { generating = false }

        var previous: Render?
        for (index, frames) in checkpoints.enumerated() {
            let minimum = minimumFrames.map { min(frames, max($0, (previous?.tokens.count ?? 0) + 25)) } ?? frames
            let current = try render(prompt, frames: frames, steps: steps,
                                     minimumFrames: minimum, prefix: previous?.tokens ?? [])
            let overlap = Int(Double(current.audio.sampleRate) * 0.22)
            // A future acoustic window changes the overlap at the end of the current render.
            let holdback = windowed ? current.audio.sampleRate : overlap
            let ended = current.tokens.count < frames
            let final = ended || index == checkpoints.count - 1
            let chunk = try Self.splice(previous: previous?.audio, current: current.audio,
                                       holdback: holdback, overlap: overlap, final: final)
            try Task.checkCancellation()
            try await onAudio(final && !ended ? Self.fadeEnd(chunk) : chunk)
            if final { return current.tokens }
            previous = current
        }
        throw YuE2Error.invalidRequest
    }

    private func validate(_ prompt: YuE2Prompt, checkpoints: [Int], steps: Int) throws {
        guard !prompt.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.seed <= UInt64(Int64.max),
              prompt.guidanceScale.isFinite, prompt.guidanceScale >= 1,
              !checkpoints.isEmpty, checkpoints.allSatisfy({ (25...15_000).contains($0) }),
              zip(checkpoints, checkpoints.dropFirst()).allSatisfy({ $1 - $0 >= 25 }),
              (1...64).contains(steps) else { throw YuE2Error.invalidRequest }
    }

    private func render(_ prompt: YuE2Prompt, frames: Int, steps: Int,
                        minimumFrames: Int?, prefix: [Int], planScore: Bool = false, score: YuE2Score? = nil,
                        observer: RenderObserver? = nil) throws -> Render {
        try Task.checkCancellation()
        let encoded = prefix.isEmpty ? nil : String(decoding: try JSONEncoder().encode(prefix), as: UTF8.self)
        let minimum = Int32(minimumFrames ?? 0)
        let guidance = String(prompt.guidanceScale)
        func run(_ lyrics: UnsafePointer<CChar>, _ style: UnsafePointer<CChar>, _ prefix: UnsafePointer<CChar>?,
                 _ score: UnsafePointer<CChar>?) -> OpaquePointer? {
            yu_render_observed(session.handle, lyrics, style, prompt.seed, Int32(frames), Int32(steps), minimum, prefix,
                               guidance, planScore ? 1 : 0, score,
                               observer?.onPCM == nil ? nil : RenderObserver.receiveSamples,
                               observer?.onProgress == nil ? nil : RenderObserver.receiveProgress,
                               observer.map { Unmanaged.passUnretained($0).toOpaque() })
        }
        let result = prompt.lyrics.withCString { lyrics in
            prompt.style.withCString { style in
                if let score { return score.notation.withCString { run(lyrics, style, nil, $0) } }
                if let encoded { return encoded.withCString { run(lyrics, style, $0, nil) } }
                return run(lyrics, style, nil, nil)
            }
        }
        guard let result else {
            if observer?.invalid == true { throw YuE2Error.invalidAudio }
            try Task.checkCancellation()
            throw YuE2Error.native(String(cString: yu_error()))
        }
        defer { yu_result_close(result) }
        try Task.checkCancellation()

        let sampleRate = Int(yu_sample_rate(result))
        let channels = Int(yu_channels(result))
        let frameCount = yu_frames(result)
        guard sampleRate == 48_000, channels == 2, frameCount > 0,
              frameCount <= frames * 1_920, let samples = yu_samples(result) else {
            throw YuE2Error.invalidAudio
        }
        var size = 0
        guard let tokenJSON = yu_tokens(result, &size), size > 0,
              let tokens = try? JSONDecoder().decode([Int].self, from: Data(bytes: tokenJSON, count: size)),
              tokens.count >= (minimumFrames ?? 1), tokens.count <= frames,
              tokens.starts(with: prefix) else {
            throw YuE2Error.invalidContinuation
        }
        let audio = YuE2Audio(samples: Array(UnsafeBufferPointer(start: samples, count: frameCount * channels)),
                              sampleRate: sampleRate, channels: channels)
        let scoreResult = yu_score(result, &size).flatMap {
            String(bytes: UnsafeBufferPointer(start: $0, count: size), encoding: .utf8)
        }
        return Render(audio: audio, tokens: tokens, score: scoreResult)
    }

    private static func fadeEnd(_ audio: YuE2Audio, startFrame: Int = 0, totalFrames: Int? = nil) -> YuE2Audio {
        let total = totalFrames ?? audio.frameCount
        let fadeFrames = min(audio.sampleRate * 3 / 2, total / 2)
        let fadeStart = total - fadeFrames
        let first = max(fadeStart, startFrame)
        let end = startFrame + audio.frameCount
        guard fadeFrames > 1, first < end else { return audio }
        var samples = audio.samples
        for frame in first..<end {
            let phase = Float(frame - fadeStart) / Float(fadeFrames - 1)
            let gain = 0.5 + 0.5 * cos(.pi * phase)
            for channel in 0..<audio.channels { samples[(frame - startFrame) * audio.channels + channel] *= gain }
        }
        return YuE2Audio(samples: samples, sampleRate: audio.sampleRate, channels: audio.channels)
    }

    private static func splice(previous: YuE2Audio?, current: YuE2Audio, holdback: Int,
                               overlap: Int, final: Bool) throws -> YuE2Audio {
        let end = current.frameCount - (final ? 0 : holdback)
        let start = (previous?.frameCount ?? holdback) - holdback
        guard start >= 0, end > start, previous.map({ $0.frameCount <= end }) ?? true else {
            throw YuE2Error.invalidAudio
        }
        let channels = current.channels
        var pcm = Array(current.samples[(start * channels)..<(end * channels)])
        if let previous {
            for frame in 0..<overlap {
                let phase = Float(frame) / Float(overlap - 1)
                let fade = 0.5 - 0.5 * cos(.pi * phase)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let prior = previous.samples[start * channels + index]
                    pcm[index] = prior + (pcm[index] - prior) * fade
                }
            }
        } else {
            // Short NAR renders can begin mid-waveform. Ramp from silence without shifting time.
            let fadeFrames = min(end, current.sampleRate / 40)
            for frame in 0..<fadeFrames {
                let phase = Float(frame) / Float(fadeFrames - 1)
                let gain = 0.5 - 0.5 * cos(.pi * phase)
                for channel in 0..<channels { pcm[frame * channels + channel] *= gain }
            }
        }
        return YuE2Audio(samples: pcm, sampleRate: current.sampleRate, channels: channels)
    }
}
