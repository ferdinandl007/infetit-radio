# infetit radio App Store preparation

## Draft listing

| Field | Proposed value |
|---|---|
| Name | infetit radio |
| Subtitle | Make songs and tune your radio |
| Category | Music |
| Price | Free |
| Bundle ID | `com.vibeplayer.app` |
| Version | 1.0 |
| Primary locale | English (U.S.) |
| Support URL | https://github.com/ferdinandl007/infetit-radio/issues |
| Privacy policy | https://github.com/ferdinandl007/infetit-radio/blob/main/PRIVACY.md (publish the updated policy first) |

**Description**

Make an original song from an idea, or tune a station and hear what comes next. Choose a genre, mood, instruments, tempo, and voice. Write your own lyrics or let infetit radio draft verses, a chorus, and an ending.

Keep the tracks you like in your library. infetit radio generates music on your device and can write lyrics with the optional Liquid AI download or Apple Intelligence. Gemini songwriting requires an enabled setting and your own API key.

## Model sources and distribution

- **LFM3 1.7B** downloads the original Liquid AI 4-bit MLX data from [revision 91f34088](https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-4bit/tree/91f34088d6946482cbcae11b85d4657093618c34). infetit radio uses the upstream files without fine-tuning or modifying the weights. The app includes the [LFM Open License](VibePlayer/LFM3-LICENSE.txt) and verifies each model file before loading it.
- **YuE2** uses a platform-specific conversion of the original [YuE2-3B](https://huggingface.co/m-a-p/YuE2-3B) music weights from [audio.cpp’s GGUF build](https://huggingface.co/audio-cpp/Yue2-3B-GGUF). Both are CC BY-NC 4.0. Confirm that the intended distribution and monetization are covered before publishing these conversions or submitting builds that bundle them.
- The app downloads the platform-specific release from [the pinned Hugging Face repository](https://huggingface.co/ferdinandl007/vibeplayer-yue2-coreml/tree/53710b82a0a9fa83bf35090b6ee5795e78faea51), which includes attribution, conversion details, and checksums. The app binary supplies the inference runtime. The intended release is free; ensure the actual use satisfies the upstream noncommercial license before submission.

## Archive and review

The published release contains separate `YuE2MetalAssets` bundles for `macosx` and `iphoneos`, built using the [model exporter](Packages/YuE2CoreML/README.md). The default prompt budget is 5,024 tokens on macOS and 512 on iOS. The store build downloads the matching, checksum-pinned model on first use and enables the macOS sandbox; it does not stage the music model into the app bundle. Mac store builds use the built-in Core ML renderer and leave out the development-only external executable and dynamic-library paths.

On Mac, Settings can install the bundled VibePlayer Music Markdown skill into a skills folder the user selects. The app executable's `--music-cli` mode uses the same bundled Metal and Core ML renderer and the same installed model as Create. Requests and WAV results travel through stdin and stdout. ABC import and rendering are available on Mac. Recording transcription and automatic ABC score export use the separate development tools.

```sh
xcodebuild archive -scheme VibePlayer -configuration Release \
  -xcconfig VibePlayer/AppStore.xcconfig \
  -destination 'generic/platform=macOS' -archivePath /path/to/VibePlayer-Mac.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM
```

For iPhone and iPad, use `generic/platform=iOS` and a separate archive path. Export for App Store Connect using the intended team’s distribution credentials.

Before uploading:

- Register the bundle ID and create the infetit radio app record in the intended team. Verify the app name is available.
- Validate signed archives and installed size for each platform. The uncompressed iOS and iPadOS app limit is 4 GB. Test fresh installation and generation without developer-provisioned assets on a Mac, an iPhone, and an iPad. [Apple build size limits](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/)
- Test the local writer download, cancellation, a successful vocal Radio song, and Gemini consent on store-signed builds. Capture screenshots from those builds and complete App Privacy, age rating, export compliance, and content-rights declarations for the final release.
- On the store-signed Mac build, verify skill installation in a user-selected folder and verify `--music-cli status` and a render after downloading the model. Confirm the output WAV opens in the Library.
- In review notes, explain that model downloads contain fixed weights and tokenizer data, the runtime is bundled, and Gemini and Apple Intelligence are optional. Provide a reproducible download and generation scenario for review.

[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
