import CoreML
import Foundation

/// A sample-accurate range of the final WAV, at 48 kHz, signed 16-bit and interleaved stereo.
public struct SongAudioPreview: Sendable {
    public let samples: [Int16]
    public let totalFrames: Int
    public let startFrame: Int
}

struct Acoustic {
    let assets: ModelAssets
    static let samplesPerToken = 1920

    func render(_ request: SongRequest, checkpointAt work: URL, useMetal: Bool = false,
                streamAudio: Bool = false,
                onPreview: (@Sendable (SongAudioPreview) -> Void)? = nil,
                progress: (SongProgress) -> Void) async throws -> WorkerResult {
        let index = try readRecord(Int.self, at: work.appendingPathComponent("acoustic-input.json"))
        guard (0..<assets.manifest.decoderFrames.count).contains(index) else {
            throw YuE2Failure.inference("Invalid acoustic checkpoint index.")
        }
        let checkpoint = work.appendingPathComponent("stage-\(index)", isDirectory: true)
        let state = try readRecord(Checkpoint.self, at: checkpoint.appendingPathComponent("checkpoint.json"))
        let count = state.tokens.count
        guard state.finished, state.lengths.count == assets.manifest.batch,
              state.lengths[0] == state.lengths.max(),
              (1...assets.manifest.promptCapacity).contains(state.lengths[0]),
              state.storedFrames == state.lengths[0] + count + 1,
              (128...(try assets.limits(for: request, useMetal: useMetal))).contains(count),
              state.tokens.allSatisfy({ (TensorSpec.codecOffset..<TensorSpec.codecOffset + 32768).contains($0) }),
              let limit = assets.manifest.acousticCapacity(for: count, profile: request.acousticProfile,
                                                            hasFastGraph: assets.hasFastAcousticGraph) else {
            throw YuE2Failure.inference("Invalid acoustic conditioning or unsupported song length.")
        }
        let start = ContinuousClock.now
        let used = state.storedFrames
        let cacheCapacity = assets.manifest.promptCapacity + limit + 1
        var conditioning = [String: MLMultiArray]()
        for name in ["keys", "values"] {
            let compact = try readTensor(checkpoint.appendingPathComponent("\(name).f16"),
                                         shape: TensorSpec.cache(batch: 1, frames: used))
            let padded = try tensor(TensorSpec.cache(batch: 1, frames: cacheCapacity))
            try copyCache(compact, to: padded, lengths: [used])
            conditioning[name] = padded
        }
        let latents = try solve(request.seed, count: count, graphFrames: limit, used: used,
                                conditioning: conditioning, model: assets.load("Acoustic\(limit)"),
                                steps: request.acousticSteps, progress: progress)
        let acousticSeconds = start.duration(to: .now).seconds
        let waveformStart = ContinuousClock.now
        progress(.waveform)
        let (waveform, previewed) = try decode(latents, count: count, naturalEnding: state.naturalEnding,
                                              streamAudio: streamAudio, onPreview: onPreview)
        let pcm = makePCM(waveform, naturalEnding: state.naturalEnding, streaming: previewed)
        try writeWAV(pcm, to: work.appendingPathComponent("song.wav"))
        return WorkerResult(tokens: state.tokens.map { $0 - TensorSpec.codecOffset },
                            naturalEnding: state.naturalEnding, sampleFrames: pcm.count / 2,
                            acousticSeconds: acousticSeconds,
                            waveformSeconds: waveformStart.duration(to: .now).seconds)
    }

    func solve(_ seed: UInt64, count: Int, graphFrames: Int, used: Int,
               conditioning: [String: MLMultiArray], model: MLModel, steps: Int, noiseOffset: Int = 0,
               position: Int? = nil, progress: (SongProgress) -> Void) throws -> [Float] {
        let width = TensorSpec.latent
        let length = graphFrames + 2
        let cacheCapacity = assets.manifest.promptCapacity + graphFrames + 1
        var inputs = conditioning
        let startPosition = position ?? used
        let (sine, cosine) = try rope([Array(startPosition ..< startPosition + length)])
        let mask = try tensor([1, 1, 1, cacheCapacity + length], filled: -10000)
        mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, stride in
            for i in 0..<used { buffer[i * stride[3]] = 0 }
            for i in cacheCapacity ..< cacheCapacity + count + 2 { buffer[i * stride[3]] = 0 }
        }
        let latentInput = try tensor([1, length, width])
        let time = try tensor([1, 1, 256])
        inputs["sine"] = sine
        inputs["cosine"] = cosine
        inputs["mask"] = mask
        inputs["latent_state"] = latentInput
        inputs["timestep"] = time
        let features = try provider(inputs)
        let frequencies = (0..<128).map { expf(-logf(10000) * Float($0) / 128) }

        func velocity(_ x: [Float], at t: Float) throws -> [Float] {
            try Task.checkCancellation()
            latentInput.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, stride in
                for frame in 0..<count {
                    for d in 0..<width { data[(frame + 1) * stride[1] + d * stride[2]] = Float16(x[frame * width + d]) }
                }
            }
            time.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, stride in
                for i in 0..<128 {
                    let angle = min(max(t, 1e-7), 1 - 1e-7) * frequencies[i]
                    data[i * stride[2]] = Float16(cosf(angle))
                    data[(i + 128) * stride[2]] = Float16(sinf(angle))
                }
            }
            let output = try requireTensor(model.prediction(from: features),
                                           "velocity", shape: [1, graphFrames, width])
            let stride = output.strides.map(\.intValue)
            return output.withUnsafeBufferPointer(ofType: Float16.self) { buf in
                (0 ..< count * width).map { i in Float(buf[(i / width) * stride[1] + (i % width) * stride[2]]) }
            }
        }

        var noise = RandomStream(state: seed ^ 0x41636F7573746963)
        for _ in 0..<(noiseOffset * width) { _ = noise.openUnit() }
        var x = [Float](repeating: 0, count: count * width)
        for i in stride(from: 0, to: x.count, by: 2) {
            let radius = sqrt(-2 * log(noise.openUnit()))
            let angle = 2 * Double.pi * noise.openUnit()
            x[i] = Float(radius * cos(angle))
            x[i+1] = Float(radius * sin(angle))
        }
        let dt = 1 / Float(steps)
        for step in 0..<steps {
            let t = 1 - Float(step) * dt
            let first = try velocity(x, at: t)
            let midpoint = x.indices.map { x[$0] - first[$0] * (dt / 2) }
            let middle = try velocity(midpoint, at: t - dt / 2)
            for i in x.indices { x[i] -= middle[i] * dt }
            guard x.allSatisfy(\.isFinite) else {
                throw YuE2Failure.inference("Nonfinite acoustic output at step \(step + 1).")
            }
            progress(.synthesis(step: step + 1, total: steps))
        }
        return x
    }

    func decode(_ latents: [Float], count: Int, naturalEnding: Bool, streamAudio: Bool,
                onPreview: (@Sendable (SongAudioPreview) -> Void)?, model: MLModel? = nil) throws -> ([Float], Bool) {
        let model = try model ?? assets.load("Waveform")
        let width = TensorSpec.latent
        let window = 128
        let halo = 16
        let samplesPerToken = Self.samplesPerToken
        let outputLength = window * samplesPerToken - 64
        let input = try tensor([1, width, 1, window])
        let features = try provider(["latents": input])
        let startTime = ContinuousClock.now
        let totalFrames = count * samplesPerToken - 64
        var emittedFrames = 0
        var waveform = [Float]()
        waveform.reserveCapacity(totalFrames * 2)
        for start in stride(from: 0, to: count, by: window - halo * 2) {
            try Task.checkCancellation()
            let end = min(start + window - halo * 2, count)
            let tile = max(0, min(start - halo, count - window))
            input.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, stride in
                for t in 0..<window {
                    for d in 0..<width { buffer[d * stride[1] + t * stride[3]] = Float16(latents[(tile + t) * width + d]) }
                }
            }
            let signal = try requireTensor(model.prediction(from: features),
                                           "waveform", shape: [1, 2, 1, outputLength])
            let strides = signal.strides.map(\.intValue)
            let lo = (start - tile) * samplesPerToken
            let hi = (end - tile) * samplesPerToken - (end == count ? 64 : 0)
            guard lo >= 0, hi >= lo, hi <= outputLength else {
                throw YuE2Failure.inference("Invalid waveform tile.")
            }
            // Adjacent tiles contain a small common region. Blend it to avoid a
            // discontinuity if their convolution context differs at the seam.
            let overlap = min(240, lo, waveform.count / 2)
            try signal.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                let join = waveform.count - overlap * 2
                for sample in (lo - overlap)..<hi {
                    for channel in 0..<2 {
                        let x = Float(buffer[channel * strides[1] + sample * strides[3]])
                        guard x.isFinite else { throw YuE2Failure.inference("Nonfinite waveform.") }
                        if sample < lo {
                            let frame = sample - (lo - overlap)
                            let alpha = Float(frame + 1) / Float(overlap + 1)
                            let index = join + frame * 2 + channel
                            waveform[index] += (x - waveform[index]) * alpha
                        } else {
                            waveform.append(x)
                        }
                    }
                }
            }
            if let onPreview, end < count, streamAudio || emittedFrames == 0 {
                // Keep the tail of each tile until the next overlap is blended. The
                // finalized WAV supplies the last tile once it has been saved.
                let ready = waveform.count / 2 - 240
                let buffered = Double(ready) / 48_000
                let elapsed = startTime.duration(to: .now).seconds
                let remainingAudio = Double(totalFrames - ready) / 48_000
                let readyToPlay = streamAudio
                    ? canStartStreaming(buffered: buffered, remaining: remainingAudio, elapsed: elapsed)
                    : buffered >= max(12, elapsed * remainingAudio / buffered * 2 + 3)
                if emittedFrames > 0 || readyToPlay {
                    let samples = pcmSamples(waveform[(emittedFrames * 2)..<(ready * 2)], totalFrames: totalFrames,
                                             naturalEnding: naturalEnding, gain: 1, streaming: true)
                    onPreview(SongAudioPreview(samples: samples, totalFrames: totalFrames, startFrame: emittedFrames))
                    emittedFrames = ready
                }
            }
        }
        guard waveform.count == totalFrames * 2 else {
            throw YuE2Failure.inference("Wrong waveform duration.")
        }
        return (waveform, emittedFrames > 0)
    }
}

func canStartStreaming(buffered: Double, remaining: Double, elapsed: Double) -> Bool {
    guard buffered >= 2.5 else { return false }
    // Allow for sustained slower-than-real-time decoding and a one-tile stall.
    let conservativeRate = elapsed / buffered * 1.5
    let deficit = remaining * max(0, conservativeRate - 1)
    return buffered >= max(1 + elapsed * 2, 1.5 + deficit)
}

/// Apply gain once before quantization, and smooth the endpoints of each render.
func makePCM(_ waveform: [Float], naturalEnding: Bool, streaming: Bool = false) -> [Int16] {
    let headroom: Float = 0.90
    let peak = streaming ? 0 : waveform.reduce(Float.zero) { max($0, abs($1)) }
    let gain = peak > headroom ? headroom / peak : 1
    return pcmSamples(waveform[...], totalFrames: waveform.count / 2, naturalEnding: naturalEnding,
                      gain: gain, streaming: streaming)
}

func pcmSamples(_ waveform: ArraySlice<Float>, totalFrames frames: Int, naturalEnding: Bool,
                gain: Float, streaming: Bool) -> [Int16] {
    let fadeIn = min(480, frames / 2)
    let fadeOut = min(naturalEnding ? 960 : 14_400, frames / 2)
    return waveform.enumerated().map { index, sample in
        let frame = (waveform.startIndex + index) / 2
        let start = fadeIn > 0 ? min(1, Float(frame) / Float(fadeIn)) : 1
        let end = fadeOut > 0 ? min(1, Float(frames - frame - 1) / Float(fadeOut)) : 1
        let magnitude = abs(sample)
        // Preview samples and the saved WAV must agree before the full-song peak is available.
        let limited = streaming && magnitude > 0.75
            ? copysignf(0.75 + 0.15 * (1 - expf(-(magnitude - 0.75) / 0.15)), sample) : sample
        let value = Int((limited * gain * start * end * 32768).rounded(.toNearestOrEven))
        return Int16(clamping: value)
    }
}

func writeWAV(_ samples: [Int16], to url: URL) throws {
    var output = Data()
    let bytes = UInt32(samples.count * 2)
    func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
    }
    output.reserveCapacity(Int(bytes) + 44)
    output.append(contentsOf: "RIFF".utf8)
    append(bytes + 36)
    output.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(2))
    append(UInt32(48000))
    append(UInt32(192000))
    append(UInt16(4))
    append(UInt16(16))
    output.append(contentsOf: "data".utf8)
    append(bytes)
    // All supported Apple targets are little-endian.
    samples.withUnsafeBytes { output.append(contentsOf: $0) }
    try output.write(to: url, options: .atomic)
}
