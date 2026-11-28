import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
enum VibePlayerEntry {
    @MainActor
    static func main() {
        #if os(macOS)
        if CommandLine.arguments.dropFirst().first == "--music-cli" {
            Task { exit(await BundledMusicCommand.run(Array(CommandLine.arguments.dropFirst(2)))) }
            dispatchMain()
        }
        #endif
        VibePlayerApp.main()
    }
}

struct VibePlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(VibePlayerMacDelegate.self) private var macDelegate
    #endif
    @State private var modelDownload = MusicModelDownload()
    @State private var songwritingDownload = SongwritingModelDownload.shared
    @State private var player: PlayerStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-renderer") {
            return PlayerStore(generationBackend: FixtureMusicGenerationBackend(), lyricsWriter: FixtureLyricsWriter())
        }
        #endif
        return PlayerStore(generationBackend: YuE2GenerationBackend())
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(modelDownload)
                .preferredColorScheme(.dark)
                .onChange(of: player.shouldKeepScreenAwake, initial: true) { updateIdleTimer() }
                .onChange(of: modelDownload.isActive, initial: true) { updateIdleTimer() }
                .onChange(of: songwritingDownload.progress != nil, initial: true) { updateIdleTimer() }
                .onChange(of: scenePhase, initial: true) {
                    updateIdleTimer()
                    #if os(iOS)
                    player.setRadioRenderingInForeground(scenePhase == .active)
                    #endif
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 540)
                .onAppear {
                    macDelegate.player = player
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--fixture-renderer"), arguments.contains("--web-radio") {
                        player.webRadio.start(player: player)
                    }
                    #endif
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Playback") {
                Button(player.wantsPlayback ? "Pause" : "Play") { player.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Previous Song") { player.playPreviousRadioSong() }
                    .disabled(!player.canPlayPreviousRadioSong)
                Button("Back 15 Seconds") { player.seek(player.elapsed - 15) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button("Forward 15 Seconds") { player.seek(player.elapsed + 15) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            }
        }
        #endif
        #if os(macOS)
        Settings { AgentSettingsView() }
        #endif
    }

    private func updateIdleTimer() {
        // The GPU render can be suspended if the device goes to sleep mid-song.
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && (player.shouldKeepScreenAwake || modelDownload.isActive || songwritingDownload.progress != nil)
        #endif
    }
}

#if os(macOS)
@MainActor
private final class VibePlayerMacDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let player else { return .terminateNow }
        Task { @MainActor in
            await player.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

#if DEBUG
private struct FixtureLyricsWriter: LyricsWriter {
    func writeLyrics(for request: MusicGenerationRequest) async throws -> String {
        "[Verse]\nThe quiet evening settles in."
    }
}
#endif
