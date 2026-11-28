# YuE2CoreML

A standalone Swift package for turning lyrics and style into a complete stereo WAV. The library handles byte-pair tokenization, deterministic seeded sampling, full-context acoustic synthesis, and waveform decoding. Core ML is the default inference backend, with a Metal preview for token generation. Python is used when preparing the model assets.

## Prepare the assets

Use Swift 6.2 or later, a Mac with Xcode command-line tools, and a Python 3.10 or 3.11 environment. Point the exporter at the [audio.cpp YuE2-3B GGUF checkpoint](https://huggingface.co/audio-cpp/Yue2-3B-GGUF) with `yue2-3b-q4_0.gguf`, `yue2-vae-f16.gguf`, and the supplied `sidecars/` directory.

```sh
python -m pip install -r Scripts/requirements.txt
python Scripts/export_assets.py /path/to/gguf /path/to/YuE2Assets
```

The asset directory contains a versioned manifest, compiled graphs, tokenizer ranks, and a memory-mapped embedding table. Copy the entire directory as a unit. Expect approximately 6 GB for the default Mac bundle. Keep the assets outside SwiftPM source targets. Use `--platform iphoneos` or `--platform xros` with the matching SDK for another destination. The source package and model weights have separate distribution considerations. See the [YuE2 model card](https://huggingface.co/m-a-p/YuE2-3B) for model terms.

New exports default to 5,024 prompt tokens on macOS and 512 on iOS and visionOS, with up to 5,200 music frames at 25 frames per second. The prompt limit includes the sound description, formatting, and lyrics. Use `--prompt-capacity` to choose a budget from 32 to 5,024 tokens. Existing bundles retain their compiled capacity. Export and index a new bundle in a fresh directory when changing the capacity. Larger capacities increase the working set for prefill and Core ML acoustics even for short prompts. Pass `--shared-weights` to share transformer weights among the prefill and decoder functions. Pass `--conditioning-batch 1` for a smaller decoder state on mobile. This variant drops the unconditional branch used for guidance, which can produce a different take. On constrained devices, use a smaller prompt budget or smaller matching decoder and acoustic ceilings to reduce the attention working set.

## Use in an app

Add this directory as a local Swift package and link its `YuE2CoreML` library.

```swift
import YuE2CoreML

let renderer = try YuE2Renderer(assets: modelDirectory)
let request = SongRequest(
    lyrics: "[Verse]\nThe lights come up again",
    style: "English synth pop, lead vocal, clean instrumental outro",
    seed: 42,
    maximumFrames: 2400
)

let result = try await renderer.render(request, to: destinationWAV)
print(result.duration, result.naturalEnding)
```

The output contains interleaved 48 kHz stereo PCM16. The renderer defaults to eight midpoint steps over the entire acoustic context and trims convolution halos from the waveform decoder tiles. Set `SongRequest.synthesisSteps` to change the count. The frame ceiling controls the maximum duration. Inspect `naturalEnding` to distinguish the model’s end token from reaching the ceiling. The progress callback can drive UI by forwarding its values to the main actor. Send one job at a time to a renderer and keep the asset directory available throughout each job. A cancelled or failed job preserves an existing destination file.

### Faster isolated mode on macOS

Build the executable and include it as a signed helper for the containing Mac app. Provide its actual executable URL. The helper implements the same package’s internal worker command.

```swift
let renderer = try YuE2Renderer(
    assets: modelDirectory,
    execution: .isolated(worker: helperExecutableURL)
)
```

The isolated mode starts with a smaller attention cache and increases its capacity as the song grows. Each stage loads Core ML in a fresh process. The handoff saves both guidance caches, next logits, tokens, and sampler state in a private working directory. The next stage waits for a successful exit, and a worker signal triggers one retry from the prior committed checkpoint. Partial stage data is cleared before retry. Persistent failures return an error to the host app. Cancellation and stage timeouts terminate the active helper.

The embedded mode uses the compiled decoder capacities in the app process, expanding from a smaller cache only if needed on macOS 15+, iOS 18+, and visionOS 2+. For a smaller initial iPhone or headset bundle, start with `--decoder-frames 512 --acoustic-frames 512` and the target platform switch. The cache schedule can change the generated take for the same seed due to backend rounding. Both modes use the same acoustic fidelity settings. Test the compiled assets on the hardware for each target platform.

### Metal decoder preview

Export and index a version 3 bundle for the target platform. For iOS:

```sh
python Scripts/export_assets.py /path/to/gguf /path/to/YuE2MetalAssets --platform iphoneos --growable-cache
python Scripts/index_metal_weights.py /path/to/YuE2MetalAssets
```

The index describes the compiled bundle’s packed Q4 weights. Generate it from the exact bundle you will ship. Select this decoder with `YuE2Renderer(assets: modelDirectory, execution: .metal)` or the CLI’s `--metal` flag. To compare compute backends with matching model weights and conditioning, use `.embedded` with the same version 3 bundle and the same prompt and seed. Small numeric differences during token sampling can produce different takes. Both backends use the same full-context acoustic model.

On M3 Max, the standard Metal decoder schedules eight projection rows per threadgroup and unrolls its Q4 and attention loops. In a matched 3,200-token test, composition took 31.4 seconds with this tuning and 37.8 seconds with the original shader. Both runs produced the same tokens.

On Mac and iOS, the standard single-song Q4 decoder fuses the gate and up projections when the GPU can load the fused pipeline. Set `VIBEPLAYER_METAL_GATE_UP=0` to compare against the separate projections.

To add the optional paired layout, prepare the sidecar from that same indexed bundle:

```sh
python Scripts/prepare_paired.py /path/to/YuE2MetalAssets
```

Select `.metalPaired` or `--metal-paired` to use it. The sidecar adds about 792 MiB and the renderer checks that it matches the weight and index files. The paired layout was fastest in the short-context iPhone test. Performance varies with song length, and the original Metal path remains the default Metal option.

Pass `--fast-acoustic` when exporting to add `Acoustic3328.mlmodelc`, then set `SongRequest.acousticProfile` to `.fast` or pass `--fast-acoustic` to the CLI. The smaller graph is used when it covers the whole song and the reference bucket is larger. It uses the requested step count and full song context. Its PCM output can differ from the reference graph.

To extend an existing indexed bundle to 4 minutes 16 seconds, add an acoustic graph for the longer Metal context:

```sh
python Scripts/export_assets.py /path/to/gguf /path/to/YuE2MetalAssets --platform iphoneos --extend-metal-to 6400
```

The extension uses the existing Metal weights and leaves the Core ML decoder ceilings at their compiled capacities. `YuE2Renderer.maximumFrames` reports the ceiling for the selected execution mode. On the embedded and Metal renderers, an optional `onPreview` callback receives buffered PCM during waveform decoding. Pass `streamAudio: true` to receive consecutive ranges identified by `startFrame`.

For lower startup latency, select `SongRequest.acousticProfile = .streaming` with a Metal renderer whose `supportsStreamingAcoustics` is true. The 512-frame acoustic graph synthesizes overlapping sections and emits playable PCM during composition. The scheduler alternates GPU workloads and releases each acoustic and waveform graph on iOS. `SongAudioPreview.totalFrames` is an upper bound until composition ends. The PCM ranges match the saved WAV and `SongResult.sampleFrames` gives the final length. For a CLI comparison, use `--metal --streaming-acoustic`. The CLI logs when each range becomes available.

## CLI and tests

```sh
swift build -c release
swift test
.build/release/yue2-coreml /path/to/YuE2Assets lyrics.txt style.txt song.wav --seed 42
```

The Mac CLI defaults to isolated mode. Pass `--embedded` for in-process generation. It prints a JSON result on stdout and progress on stderr. The result includes the token count, whether generation ended naturally, and measured token-stage, acoustic, and waveform times.

On M3 Max Macs with at least 32 GiB of unified memory, `composePair` can share each Q4 weight read across two songs. Each song retains its own attention cache, sampling seed, and ending. Repeated Mac prompts reuse their read-only prefill output while each new song receives a fresh decoding cache.
