import CoreML
import Darwin
import Foundation
import Metal
import Synchronization

private struct MetalWeightIndex: Decodable {
    struct Projection: Decodable {
        let packed: Int
        let scale: Int
    }

    let version: Int
    let weightsBytes: Int
    let projections: [Projection]
    let norms: [Int]

    func validate(length: Int) throws {
        guard version == 1, weightsBytes == length,
              projections.count == TensorSpec.layers * 7 + 1,
              norms.count == TensorSpec.layers * 4 + 1 else {
            throw YuE2Failure.assets("Incompatible Metal weight index. Regenerate the index from this bundle.")
        }
        let layerWidths = [(2048, 2048), (1024, 2048), (1024, 2048), (2048, 2048),
                           (6144, 2048), (6144, 2048), (2048, 6144)]
        func fits(_ offset: Int, bytes: Int) -> Bool {
            offset >= 0 && offset % 4 == 0 && offset <= length - bytes
        }
        for (i, p) in projections.enumerated() {
            let (rows, columns) = i == projections.count - 1 ? (TensorSpec.logits, 2048) : layerWidths[i % 7]
            guard fits(p.packed, bytes: rows * columns / 2), fits(p.scale, bytes: rows * columns / 16) else {
                throw YuE2Failure.assets("A Metal projection exceeds its weight file.")
            }
        }
        for (i, offset) in norms.enumerated() {
            let values = i % 4 == 1 || i % 4 == 2 ? 128 : 2048
            guard fits(offset, bytes: values * 2) else {
                throw YuE2Failure.assets("A Metal normalization exceeds its weight file.")
            }
        }
    }
}

private struct DecoderKernels: Sendable {
    private struct Key: Hashable {
        let deviceID: UInt64
        let pairedLayout: Bool
        let songCount: Int
    }

    private static let cache = Mutex([Key: DecoderKernels]())

    static func load(_ device: any MTLDevice, paired: Bool, songCount: Int) throws -> DecoderKernels {
        let key = Key(deviceID: device.registryID, pairedLayout: paired, songCount: songCount)
        return try cache.withLock { kernels in
            if let prepared = kernels[key] { return prepared }
            let prepared = try DecoderKernels(device, paired: paired, songCount: songCount)
            kernels[key] = prepared
            return prepared
        }
    }

    let project: any MTLComputePipelineState
    let projectFour: (any MTLComputePipelineState)?
    let projectGateUp: (any MTLComputePipelineState)?
    let projectionRows: Int
    let rms: any MTLComputePipelineState
    let rotary: any MTLComputePipelineState
    let attend: any MTLComputePipelineState
    let reduce: any MTLComputePipelineState
    let residual: any MTLComputePipelineState
    let gate: any MTLComputePipelineState

    private init(_ device: any MTLDevice, paired: Bool, songCount: Int) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let source = bundle.url(forResource: "Decoder", withExtension: "metal") else {
            throw YuE2Failure.assets("Missing Metal decoder kernels.")
        }
        let options = MTLCompileOptions()
        #if os(macOS)
        let tuneForM3Max = !paired && device.name == "Apple M3 Max"
        #else
        let tuneForM3Max = false
        #endif
        projectionRows = tuneForM3Max ? 8 : 4
        if tuneForM3Max {
            options.preprocessorMacros = ["YUE2_M3_MAX": NSNumber(value: 1)]
        } else if paired {
            options.preprocessorMacros = ["YUE2_PAIRED_LAYOUT": NSNumber(value: 1)]
        }
        let library = try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: options)
        func pipeline(_ name: String, minimumThreads: Int = 128) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw YuE2Failure.assets("Missing Metal decoder kernel \(name).")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            guard pipeline.threadExecutionWidth == 32, pipeline.maxTotalThreadsPerThreadgroup >= minimumThreads else {
                throw YuE2Failure.inference("This GPU does not support the Metal decoder layout.")
            }
            return pipeline
        }
        project = try pipeline(paired ? "project_q4_paired" : "project_q4", minimumThreads: projectionRows * 32)
        projectFour = songCount == 2 ? try pipeline("project_q4_four", minimumThreads: projectionRows * 32) : nil
        let enableGateUp = !paired && ProcessInfo.processInfo.environment["VIBEPLAYER_METAL_GATE_UP"] != "0"
        projectGateUp = enableGateUp ? try? pipeline("project_q4_gate_up", minimumThreads: projectionRows * 32) : nil
        rms = try pipeline("rms_hidden")
        rotary = try pipeline("rotate_and_append")
        attend = try pipeline("attend_tiles")
        reduce = try pipeline("finish_attention")
        residual = try pipeline("residual")
        gate = try pipeline("activate_gate")
    }
}

final class MetalDecoder {
    let frames: Int
    private let songCount: Int
    private var batch: Int { songCount * 2 }
    private let queue: any MTLCommandQueue
    private let kernels: DecoderKernels
    private let weights: any MTLBuffer
    private let index: MetalWeightIndex
    private let keyCache: any MTLBuffer
    private let valueCache: any MTLBuffer
    private let hidden: any MTLBuffer
    private let normalized: any MTLBuffer
    private let query: any MTLBuffer
    private let key: any MTLBuffer
    private let value: any MTLBuffer
    private let attention: any MTLBuffer
    private let residual: any MTLBuffer
    private let gate: any MTLBuffer
    private let up: any MTLBuffer
    private let tileSummary: any MTLBuffer
    private let rotaryTable: any MTLBuffer
    private let logits: any MTLBuffer

    static var supportsSongPair: Bool {
        #if os(macOS)
        MTLCreateSystemDefaultDevice()?.name == "Apple M3 Max"
            && ProcessInfo.processInfo.physicalMemory >= 32 * 1_024 * 1_024 * 1_024
        #else
        false
        #endif
    }

    init(assets: ModelAssets, capacity: Int, weightFile: URL? = nil, paired: Bool = false,
         songCount: Int = 1) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw YuE2Failure.inference("Metal is unavailable on this device.")
        }
        guard songCount == 1 || (songCount == 2 && !paired && Self.supportsSongPair) else {
            throw YuE2Failure.inference("This Metal decoder cannot compose two songs together.")
        }
        self.queue = queue
        self.songCount = songCount
        let batch = songCount * 2
        frames = capacity
        index = try readRecord(MetalWeightIndex.self, at: assets.url("metal-decoder.json"))
        weights = try Self.mapWeights(weightFile ?? assets.url("Autoregressive.mlmodelc/weights/weight.bin"),
                                      index: index, device: device)
        kernels = try DecoderKernels.load(device, paired: paired, songCount: songCount)

        func buffer(_ count: Int, options: MTLResourceOptions = .storageModePrivate) throws -> any MTLBuffer {
            guard count <= device.maxBufferLength,
                  let result = device.makeBuffer(length: count, options: options) else {
                throw YuE2Failure.inference("Metal could not allocate a \(count)-byte decoder buffer.")
            }
            return result
        }
        let cacheBytes = TensorSpec.layers * batch * TensorSpec.heads * capacity * TensorSpec.headSize * 2
        keyCache = try buffer(cacheBytes, options: .storageModeShared)
        valueCache = try buffer(cacheBytes, options: .storageModeShared)
        hidden = try buffer(batch * 2048 * 2, options: .storageModeShared)
        normalized = try buffer(batch * 2048 * 2)
        query = try buffer(batch * 2048 * 2)
        key = try buffer(batch * 1024 * 2)
        value = try buffer(batch * 1024 * 2)
        attention = try buffer(batch * 2048 * 2)
        residual = try buffer(batch * 2048 * 2)
        gate = try buffer(batch * 6144 * 2)
        up = try buffer(batch * 6144 * 2)
        tileSummary = try buffer(songCount * 32 * ((capacity + 127) / 128) * 130 * 4)
        let rotary = try buffer(capacity * 128 * MemoryLayout<Float16>.stride, options: .storageModeShared)
        let values = rotary.contents().assumingMemoryBound(to: Float16.self)
        for position in 0..<capacity {
            let row = values.advanced(by: position * 128)
            for (channel, frequency) in ropeFrequencies.enumerated() {
                let phase = Float(position) * frequency
                row[channel] = Float16(sinf(phase))
                row[64 + channel] = Float16(cosf(phase))
            }
        }
        rotaryTable = rotary
        logits = try buffer(batch * TensorSpec.logits * 2, options: .storageModeShared)
    }

    private static func mapWeights(_ url: URL, index: MetalWeightIndex,
                                   device: any MTLDevice) throws -> any MTLBuffer {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw YuE2Failure.assets("Could not open the shared Metal weights.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw YuE2Failure.assets("Could not inspect the shared Metal weights.") }
        let length = Int(info.st_size)
        try index.validate(length: length)
        let page = Int(getpagesize())
        let aligned = (length + page - 1) / page * page
        guard aligned <= device.maxBufferLength,
              let memory = mmap(nil, aligned, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, 0),
              memory != MAP_FAILED else {
            throw YuE2Failure.assets("Could not map the shared Metal weights.")
        }
        guard let buffer = device.makeBuffer(bytesNoCopy: memory, length: aligned, options: .storageModeShared,
                                             deallocator: { pointer, size in _ = munmap(pointer, size) }) else {
            munmap(memory, aligned)
            throw YuE2Failure.assets("Metal rejected the mapped weight buffer.")
        }
        return buffer
    }

    private func view(_ buffer: any MTLBuffer, shape: [Int]) throws -> MLMultiArray {
        var stride = 1
        let strides = shape.reversed().map { size -> NSNumber in
            defer { stride *= size }
            return NSNumber(value: stride)
        }.reversed()
        return try MLMultiArray(dataPointer: buffer.contents(), shape: shape.map(NSNumber.init(value:)),
                                dataType: .float16, strides: Array(strides))
    }

    func withArray(_ component: CacheComponent, _ body: (MLMultiArray) throws -> Void) throws {
        let buffer = component == .keys ? keyCache : valueCache
        try body(view(buffer, shape: TensorSpec.cache(batch: batch, frames: frames)))
    }

    func predict(embedding: MLMultiArray, positions: [Int], activeSong: Int? = nil) throws -> any MLFeatureProvider {
        guard activeSong.map({ (0..<songCount).contains($0) }) ?? true,
              positions.count == batch, positions.allSatisfy({ (0..<frames).contains($0) }) else {
            throw YuE2Failure.inference("Metal decoder position is outside the cache.")
        }
        let input = try view(hidden, shape: [batch, 1, TensorSpec.hidden])
        embedding.transfer(to: input)

        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw YuE2Failure.inference("Could not schedule Metal decoder inference.")
        }
        command.label = "YuE2 decode token \(positions[0])"
        let firstSong = activeSong ?? 0
        let activeSongs = activeSong == nil ? songCount : 1
        let firstBranch = firstSong * 2
        let activeBatch = activeSongs * 2
        let projection = activeSongs == 2 ? (kernels.projectFour ?? kernels.project) : kernels.project
        let pairCacheBytes = 2 * TensorSpec.heads * frames * TensorSpec.headSize * 2
        let pairTileBytes = 32 * ((frames + 127) / 128) * 130 * MemoryLayout<Float>.stride

        func buffers(_ values: [any MTLBuffer]) {
            for (slot, buffer) in values.enumerated() { encoder.setBuffer(buffer, offset: 0, index: slot) }
        }
        func groups(_ x: Int, _ y: Int = 1, threads: Int = 128) {
            encoder.dispatchThreadgroups(MTLSize(width: x, height: y, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        }
        func barrier() { encoder.memoryBarrier(scope: .buffers) }
        func project(_ offset: Int, from input: any MTLBuffer, to output: any MTLBuffer,
                     columns: UInt32 = 2048, rows: UInt32 = 2048) {
            encoder.setComputePipelineState(projection)
            let p = index.projections[offset]
            encoder.setBuffer(weights, offset: p.packed, index: 0)
            encoder.setBuffer(weights, offset: p.scale, index: 1)
            encoder.setBuffer(input, offset: firstBranch * Int(columns) * 2, index: 2)
            encoder.setBuffer(output, offset: firstBranch * Int(rows) * 2, index: 3)
            var shape = SIMD2(columns, rows)
            encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 4)
            let rowsPerGroup = kernels.projectionRows
            groups((Int(rows) + rowsPerGroup - 1) / rowsPerGroup, threads: rowsPerGroup * 32)
        }
        func rms(_ offset: Int) {
            encoder.setComputePipelineState(kernels.rms)
            let branchOffset = firstBranch * TensorSpec.hidden * 2
            encoder.setBuffer(hidden, offset: branchOffset, index: 0)
            encoder.setBuffer(weights, offset: index.norms[offset], index: 1)
            encoder.setBuffer(normalized, offset: branchOffset, index: 2)
            var width: UInt32 = 2048
            encoder.setBytes(&width, length: 4, index: 3)
            groups(activeBatch)
            barrier()
        }
        func combine(_ kernel: any MTLComputePipelineState, first: any MTLBuffer, second: any MTLBuffer, width: Int) {
            encoder.setComputePipelineState(kernel)
            let offset = firstBranch * width * 2
            encoder.setBuffer(first, offset: offset, index: 0)
            encoder.setBuffer(second, offset: offset, index: 1)
            groups(activeBatch * width / 128)
            barrier()
        }

        for layer in 0..<TensorSpec.layers {
            let n = layer * 4, p = layer * 7
            let layerOffset = layer * songCount * pairCacheBytes
            rms(n)
            project(p, from: normalized, to: query)
            project(p + 1, from: normalized, to: key, rows: 1024)
            project(p + 2, from: normalized, to: value, rows: 1024)
            barrier()

            // Keep each song's attention dispatch and reductions identical to the single-song path.
            for song in firstSong..<(firstSong + activeSongs) {
                let batchStart = song * 2
                let queryOffset = batchStart * 2048 * 2
                let keyOffset = batchStart * 1024 * 2
                let cacheOffset = layerOffset + song * pairCacheBytes
                let summaryOffset = song * pairTileBytes
                let tiles = (max(positions[batchStart], positions[batchStart + 1]) + 128) / 128
                var context = SIMD4(UInt32(positions[batchStart]), UInt32(positions[batchStart + 1]),
                                    UInt32(frames), UInt32(tiles))

                encoder.setComputePipelineState(kernels.rotary)
                encoder.setBuffer(query, offset: queryOffset, index: 0)
                encoder.setBuffer(key, offset: keyOffset, index: 1)
                encoder.setBuffer(value, offset: keyOffset, index: 2)
                encoder.setBuffer(keyCache, offset: cacheOffset, index: 3)
                encoder.setBuffer(valueCache, offset: cacheOffset, index: 4)
                encoder.setBuffer(weights, offset: index.norms[n + 1], index: 5)
                encoder.setBuffer(weights, offset: index.norms[n + 2], index: 6)
                encoder.setBuffer(rotaryTable, offset: 0, index: 7)
                encoder.setBytes(&context, length: MemoryLayout.size(ofValue: context), index: 8)
                groups(24, 2, threads: 32)
                barrier()

                encoder.setComputePipelineState(kernels.attend)
                encoder.setBuffer(query, offset: queryOffset, index: 0)
                encoder.setBuffer(keyCache, offset: cacheOffset, index: 1)
                encoder.setBuffer(valueCache, offset: cacheOffset, index: 2)
                encoder.setBuffer(tileSummary, offset: summaryOffset, index: 3)
                encoder.setBytes(&context, length: MemoryLayout.size(ofValue: context), index: 4)
                groups(16, tiles)
                barrier()

                encoder.setComputePipelineState(kernels.reduce)
                encoder.setBuffer(tileSummary, offset: summaryOffset, index: 0)
                encoder.setBuffer(attention, offset: queryOffset, index: 1)
                var count = UInt32(tiles)
                encoder.setBytes(&count, length: MemoryLayout.size(ofValue: count), index: 2)
                groups(32)
                barrier()
            }
            project(p + 3, from: attention, to: residual)
            barrier()
            combine(kernels.residual, first: hidden, second: residual, width: 2048)

            rms(n + 3)
            if activeSongs == 1, let projectGateUp = kernels.projectGateUp {
                encoder.setComputePipelineState(projectGateUp)
                let gateWeights = index.projections[p + 4]
                let upWeights = index.projections[p + 5]
                encoder.setBuffer(weights, offset: gateWeights.packed, index: 0)
                encoder.setBuffer(weights, offset: gateWeights.scale, index: 1)
                encoder.setBuffer(weights, offset: upWeights.packed, index: 2)
                encoder.setBuffer(weights, offset: upWeights.scale, index: 3)
                encoder.setBuffer(normalized, offset: firstBranch * 2048 * 2, index: 4)
                encoder.setBuffer(gate, offset: firstBranch * 6144 * 2, index: 5)
                var shape = SIMD2<UInt32>(2048, 6144)
                encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 6)
                groups(6144 / kernels.projectionRows, threads: kernels.projectionRows * 32)
                barrier()
            } else {
                project(p + 4, from: normalized, to: gate, rows: 6144)
                project(p + 5, from: normalized, to: up, rows: 6144)
                barrier()
                combine(kernels.gate, first: gate, second: up, width: 6144)
            }
            project(p + 6, from: gate, to: residual, columns: 6144)
            barrier()
            combine(kernels.residual, first: hidden, second: residual, width: 2048)
        }

        rms(index.norms.count - 1)
        project(index.projections.count - 1, from: normalized, to: logits, rows: UInt32(TensorSpec.logits))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw YuE2Failure.inference(command.error?.localizedDescription ?? "Metal decoder command failed.")
        }
        return try provider(["logits": view(logits, shape: [batch, 1, TensorSpec.logits])])
    }
}
