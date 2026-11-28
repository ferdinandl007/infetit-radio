#if os(macOS)
import AppKit
import SwiftUI
import YuE2CoreML
import YuE2Kit

struct AgentSettingsView: View {
    private enum Agent: String {
        case codex = ".agents"
        case claude = ".claude"
        case other = ""

        var destination: String { self == .other ? "skills" : "\(rawValue)/skills" }
    }

    @State private var message: String?

    var body: some View {
        Form {
            Section("Agent Skill") {
                LabeledContent("VibePlayer Music") {
                    Menu("Install Skill…") {
                        Button("Codex…") { install(for: .codex) }
                        Button("Claude Code…") { install(for: .claude) }
                        Button("Other Skills Folder…") { install(for: .other) }
                    }
                    .accessibilityIdentifier("install-agent-skill")
                }
                Text("Give your agent instructions for creating songs and arranging ABC melodies.")
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message).textSelection(.enabled)
                }
            }
            Section("Command Line") {
                Button("Copy Help Command") {
                    guard let path = Bundle.main.executableURL?.path else { return }
                    let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(quoted) --music-cli --help", forType: .string)
                }
                Text("The app includes a local command for agents and scripts. Download the music model in Create before rendering.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 485)
        .padding(.bottom, 12)
    }

    private func install(for agent: Agent) {
        let panel = NSOpenPanel()
        panel.title = "Install VibePlayer Music Skill"
        panel.message = agent == .other
            ? "Choose your agent’s skills folder."
            : "Choose \(agent.destination) in your home folder or project. You can also choose \(agent.rawValue) to create its skills folder."
        panel.prompt = "Install Skill"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        if agent != .other {
            let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
            panel.directoryURL = URL(fileURLWithPath: home).appendingPathComponent(agent.destination, isDirectory: true)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        do {
            let result = try AgentSkill.install(in: selected, configurationFolder: agent.rawValue)
            message = result ? "Installed. Start a new agent session to use VibePlayer Music."
                             : "VibePlayer Music is already installed in that folder."
        } catch {
            message = error.localizedDescription
        }
    }
}

enum AgentSkill {
    static func install(in selected: URL, configurationFolder: String, bundle: Bundle = .main) throws -> Bool {
        let skills: URL
        if !configurationFolder.isEmpty, selected.lastPathComponent == configurationFolder {
            skills = selected.appendingPathComponent("skills", isDirectory: true)
        } else if selected.lastPathComponent == "skills" || configurationFolder.isEmpty {
            skills = selected
        } else {
            throw AgentToolsError.message("Choose the \(configurationFolder)/skills folder or its parent.")
        }
        guard let source = bundle.url(forResource: "SKILL", withExtension: "md",
                                      subdirectory: "AgentSkills/vibeplayer-music") else {
            throw AgentToolsError.message("The bundled skill is missing. Reinstall the app and try again.")
        }
        let files = FileManager.default
        let folder = skills.appendingPathComponent("vibeplayer-music", isDirectory: true)
        // Refuse to follow an existing symlink in a directory selected for installation.
        for path in [skills, folder] {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AgentToolsError.message("Choose a skills folder without a symbolic link at the install location.")
            }
        }
        let destination = folder.appendingPathComponent("SKILL.md")
        let content = try Data(contentsOf: source)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try content.write(to: destination, options: .withoutOverwriting)
            return true
        } catch let writeError as CocoaError where writeError.code == .fileWriteFileExists {
            if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
               (try? Data(contentsOf: destination)) == content { return false }
            throw AgentToolsError.message("A different VibePlayer Music skill is already installed. Its file is at \(destination.path).")
        }
    }
}

private enum AgentToolsError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

enum BundledMusicCommand {
    private struct Request: Decodable {
        let style: String
        let lyrics: String?
        let score: String?
        let seconds: Int?
        let steps: Int?
        let seed: UInt64?
    }

    private struct Status: Encodable {
        let modelReady: Bool
        let maximumSeconds: Int?
        let scoreInput = true
    }

    static let help = """
        infetit radio --music-cli <command>

        status       Check whether the app's music model is installed. Prints JSON.
        render       Read one JSON request from stdin. Write a complete stereo WAV to stdout.
        --help       Show this guide.

        Render request
          style       Required. Describe the sound, instruments, genre, and voice.
          lyrics      Optional UTF-8 lyrics. Omit for an instrumental.
          score       Optional ABC melody score as a JSON string.
          seconds     Duration ceiling in seconds. Minimum 6, default 30 or the model limit.
          steps       Synthesis steps from 1 to 64, default 8.
          seed        Integer from 0 through 9223372036854775807. Omit for a random take.

        Example
          printf '%s\\n' '{"style":"soft piano and brushed drums","seconds":20,"seed":42}' |
            "/Applications/infetit radio.app/Contents/MacOS/infetit radio" --music-cli render > take.wav

        Install the music model from Create before rendering. Progress and errors go to stderr.
        To make a cover, provide ABC notation in score and the words you want sung in lyrics.
        """

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            switch arguments {
            case [], ["--help"], ["help"], ["-h"]:
                print(help)
            case ["status"]:
                let renderer = try? loadRenderer()
                let status = Status(modelReady: renderer != nil,
                                    maximumSeconds: renderer.map { $0.maximumFrames / 25 })
                print(String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
            case ["render"]:
                try await render()
            default:
                throw AgentToolsError.message("Use --music-cli --help for available commands.")
            }
            return 0
        } catch {
            report(error.localizedDescription)
            return 1
        }
    }

    private static func loadRenderer() throws -> YuE2Renderer {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        for root in [Bundle.main.resourceURL, support].compactMap({ $0 }) {
            let model = root.appendingPathComponent("YuE2MetalAssets", isDirectory: true)
            if let renderer = try? YuE2Renderer(assets: model, execution: .metal) { return renderer }
        }
        throw AgentToolsError.message("Music model unavailable. Open the app and download the music model from Create.")
    }

    @concurrent
    private static func render() async throws {
        let input = FileHandle.standardInput
        var data = Data()
        while let chunk = try input.read(upToCount: 16 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 256 * 1024 else { throw AgentToolsError.message("Render requests must be under 256 KB.") }
        }
        let request = try JSONDecoder().decode(Request.self, from: data)
        let style = request.style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { throw AgentToolsError.message("Provide a nonempty style.") }
        let score = try request.score.map { try YuE2Score($0).notation }
        let renderer = try loadRenderer()
        let ceiling = renderer.maximumFrames / 25
        let seconds = request.seconds ?? min(30, ceiling)
        let steps = request.steps ?? 8
        let seed = request.seed ?? UInt64.random(in: 0...UInt64(Int64.max))
        guard seconds >= 6, seconds <= ceiling, (1...64).contains(steps), seed <= UInt64(Int64.max) else {
            throw AgentToolsError.message("Use 6–\(ceiling) seconds, 1–64 steps, and a seed from 0 through \(Int64.max).")
        }
        let lyrics = request.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let song = SongRequest(lyrics: lyrics.isEmpty ? "[instrumental]" : lyrics,
                               style: lyrics.isEmpty ? "instrumental, \(style)" : style, seed: seed,
                               maximumFrames: seconds * 25, minimumFrames: 128, acousticProfile: .reference,
                               synthesisSteps: steps, scoreABC: score)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-cli-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appendingPathComponent("take.wav")
        report("Rendering with seed \(seed).")
        _ = try await renderer.render(song, to: output) { progress in
            switch progress {
            case .tokens(let count, let limit) where count == 0 || count.isMultiple(of: 250):
                report("Composing \(count)/\(limit) frames.")
            case .synthesis(let step, _) where step == 0: report("Synthesizing audio.")
            case .waveform: report("Decoding WAV.")
            default: break
            }
        }
        try FileHandle.standardOutput.write(contentsOf: Data(contentsOf: output, options: .mappedIfSafe))
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
#endif
