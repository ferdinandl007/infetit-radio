import CoreML
import Foundation

// Owns a private copy of the Metal cache. The producer never reads or mutates these
// arrays after construction, and the acoustic consumer only uses them as inputs.
struct AcousticWindow: @unchecked Sendable {
    static let capacity = 512
    static let context = 64
    static let advance = capacity - 2 * context
    static let overlap = 16

    struct Plan: Sendable {
        let outputStart: Int
        let outputEnd: Int
        let input: Range<Int>

        init(start: Int, end: Int, final: Bool) {
            outputStart = start
            outputEnd = final ? end : end - AcousticWindow.context
            input = max(0, min(start - AcousticWindow.context, end - 128))..<end
        }
    }

    let plan: Plan
    fileprivate let conditioning: [String: MLMultiArray]
    let compactPosition: Int
    let absolutePosition: Int
    let finalTokens: [Int]?
    let naturalEnding: Bool

    init(plan: Plan, promptLength: Int, promptCapacity: Int, cache: DecoderCache,
         finalTokens: [Int]? = nil, naturalEnding: Bool = false) throws {
        let eos = finalTokens == nil ? 0 : 1
        self.plan = plan
        self.finalTokens = finalTokens
        self.naturalEnding = naturalEnding
        compactPosition = promptLength + plan.input.count + eos
        absolutePosition = promptLength + plan.input.upperBound + eos
        var conditioning = [String: MLMultiArray]()
        for component in CacheComponent.allCases {
            let target = try tensor(TensorSpec.cache(batch: 1, frames: promptCapacity + Self.capacity + 1))
            try cache.withArray(component) { source in
                try copyCache(source, to: target, lengths: [promptLength])
                try copyCache(source, to: target, lengths: [plan.input.count + eos],
                              sourceStart: promptLength + plan.input.lowerBound, targetStart: promptLength)
            }
            conditioning[component.rawValue] = target
        }
        self.conditioning = conditioning
    }
}

/// One consumer owns the model instances and the PCM that will be saved.
final class AcousticStreamRenderer {
    private let acoustic: Acoustic
    private let request: SongRequest
    private let limit: Int
    private let work: URL
    private let onPreview: (@Sendable (SongAudioPreview) -> Void)?
    #if !os(iOS)
    private var acousticModel: MLModel?
    private var waveformModel: MLModel?
    #endif
    private var waveform = [Float]()
    private var emitted = 0
    private var acousticSeconds = 0.0
    private var waveformSeconds = 0.0

    init(assets: ModelAssets, request: SongRequest, limit: Int, work: URL,
         onPreview: (@Sendable (SongAudioPreview) -> Void)?) {
        acoustic = Acoustic(assets: assets)
        self.request = request
        self.limit = limit
        self.work = work
        self.onPreview = onPreview
    }

    func append(_ window: AcousticWindow) throws -> WorkerResult? {
        try Task.checkCancellation()
        let stride = Acoustic.samplesPerToken
        let overlapFrames = AcousticWindow.overlap * stride
        let acousticStart = ContinuousClock.now
        let plan = window.plan
        let count = plan.input.count
        // Release each graph's private heap before opening the next on iOS.
        let latents = try autoreleasepool {
            let name = "Acoustic\(AcousticWindow.capacity)"
            #if os(iOS)
            let model = try acoustic.assets.load(name)
            #else
            let model = try acousticModel ?? acoustic.assets.load(name)
            acousticModel = model
            #endif
            return try acoustic.solve(request.seed, count: count, graphFrames: AcousticWindow.capacity,
                                      used: window.compactPosition, conditioning: window.conditioning, model: model,
                                      steps: request.acousticSteps,
                                      noiseOffset: plan.input.lowerBound, position: window.absolutePosition) { _ in }
        }
        acousticSeconds += acousticStart.duration(to: .now).seconds

        let waveformStart = ContinuousClock.now
        let (local, _) = try autoreleasepool {
            #if os(iOS)
            let vocoder = try acoustic.assets.load("Waveform")
            #else
            let vocoder = try waveformModel ?? acoustic.assets.load("Waveform")
            waveformModel = vocoder
            #endif
            return try acoustic.decode(latents, count: count, naturalEnding: window.naturalEnding,
                                       streamAudio: false, onPreview: nil, model: vocoder)
        }
        let start = plan.outputStart * stride
        let end = plan.outputEnd * stride - (window.finalTokens == nil ? 0 : 64)
        try joinWindow(local, at: plan.input.lowerBound * stride, into: &waveform,
                       appending: start..<end, overlap: overlapFrames)
        if let finalTokens = window.finalTokens {
            let pcm = makePCM(waveform, naturalEnding: window.naturalEnding, streaming: emitted > 0)
            try writeWAV(pcm, to: work.appendingPathComponent("song.wav"))
            return WorkerResult(tokens: finalTokens.map { $0 - TensorSpec.codecOffset },
                                naturalEnding: window.naturalEnding, sampleFrames: pcm.count / 2,
                                acousticSeconds: acousticSeconds,
                                waveformSeconds: waveformSeconds + waveformStart.duration(to: .now).seconds)
        }

        // Hold back the join so later windows only change samples that haven't played yet.
        let ready = end - overlapFrames
        if let onPreview {
            let estimatedFrames = limit * stride - 64
            let samples = pcmSamples(waveform[(emitted * 2)..<(ready * 2)], totalFrames: estimatedFrames,
                                     naturalEnding: false, gain: 1, streaming: true)
            onPreview(SongAudioPreview(samples: samples, totalFrames: estimatedFrames, startFrame: emitted))
            emitted = ready
        }
        waveformSeconds += waveformStart.duration(to: .now).seconds
        return nil
    }

    static var incomplete: YuE2Failure { .inference("The acoustic stream ended before the song was complete.") }
}

func joinWindow(_ local: [Float], at offset: Int, into output: inout [Float],
                appending range: Range<Int>, overlap: Int) throws {
    let middle = range.lowerBound
    let end = range.upperBound
    let blend = min(overlap, middle)
    guard middle * 2 == output.count, middle - blend >= offset, (end - offset) * 2 <= local.count else {
        throw YuE2Failure.inference("Noncontiguous acoustic window.")
    }
    for frame in (middle - blend)..<middle {
        let alpha = Float(frame - middle + blend + 1) / Float(blend + 1)
        let index = (frame - offset) * 2
        for channel in 0..<2 {
            let destination = frame * 2 + channel
            output[destination] += (local[index + channel] - output[destination]) * alpha
        }
    }
    output.append(contentsOf: local[((middle - offset) * 2)..<((end - offset) * 2)])
}
