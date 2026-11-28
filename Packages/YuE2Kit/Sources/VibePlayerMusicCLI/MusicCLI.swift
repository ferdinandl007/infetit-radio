#if os(macOS)
import AVFoundation
import Darwin
import Foundation
import YuE2Kit

@main
struct MusicCLI {
    static let help = """
        vibeplayer-music transcribe AUDIO --out SCORE.abc [--reference-assets DIRECTORY]
        vibeplayer-music render --style TEXT --out DIRECTORY [--lyrics FILE] [--score SCORE.abc]
                               [--seconds 300] [--steps 8] [--seed SEED] [--native-assets DIRECTORY]

        Transcribe writes a melody score. Render creates a new directory with song.wav and score.abc.
        Supply --score to render an edited or transcribed score, or omit it to compose a new score.
        Supply a UTF-8 lyrics file for vocals. With no lyrics file, render requests an instrumental.
        Successful commands print a JSON object with absolute artifact paths.
        """

    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
                print(help)
                return
            }
            arguments.removeFirst()
            switch command {
            case "transcribe":
                guard let input = arguments.first, !input.hasPrefix("--") else { throw Failure("Provide a reference recording.") }
                let options = try options(Array(arguments.dropFirst()), allowing: ["out", "reference-assets"])
                let output = try requiredPath("out", in: options)
                guard output.pathExtension.lowercased() == "abc" else { throw Failure("Use an .abc output path.") }
                try requireNewPath(output)
                let directory = options["reference-assets"].map { URL(fileURLWithPath: $0) } ?? YuE2Transcriber.defaultDirectory
                let score = try await YuE2Transcriber(directory: directory).transcribe(URL(fileURLWithPath: input))
                try Data(score.notation.utf8).write(to: output, options: .withoutOverwriting)
                try report(["score": output.path])
            case "render":
                try await render(try options(arguments, allowing: ["style", "out", "lyrics", "score", "seconds", "steps", "seed", "native-assets"]))
            default:
                throw Failure("Unknown command: \(command). Run with --help for usage.")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func render(_ options: [String: String]) async throws {
        let output = try requiredPath("out", in: options)
        try requireNewPath(output)
        guard let style = options["style"], !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("Provide a style with --style.")
        }
        let seconds = try integer("seconds", in: options, default: 300, range: 1...360)
        let steps = try integer("steps", in: options, default: 8, range: 1...64)
        let seed: UInt64
        if let value = options["seed"] {
            guard let parsed = UInt64(value), parsed <= UInt64(Int64.max) else { throw Failure("Provide a seed between 0 and \(Int64.max).") }
            seed = parsed
        } else {
            seed = UInt64.random(in: 0...UInt64(Int64.max))
        }
        let score = try options["score"].map { try YuE2Score(contentsOf: URL(fileURLWithPath: $0)) }
        let lyrics = try options["lyrics"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? "[instrumental]"
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !lyrics.utf8.contains(0) else {
            throw Failure("Provide nonempty UTF-8 lyrics.")
        }
        let root = options["native-assets"].map { URL(fileURLWithPath: $0) } ?? YuE2Transcriber.defaultDirectory.deletingLastPathComponent()
        let weights = root.appendingPathComponent("weights")
        let spec = root.appendingPathComponent("yue2.json")
        let library = ["libaudiocpp-pcm-fast.dylib", "libaudiocpp-pcm.dylib", "libaudiocpp.dylib"]
            .map { root.appendingPathComponent($0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
        guard let library, FileManager.default.isReadableFile(atPath: spec.path) else {
            throw Failure("Install the native Mac YuE2 runtime and weights, or pass --native-assets.")
        }
        let engine = try await YuE2Engine.load(library: library, weights: weights, modelSpec: spec)
        let direction = options["lyrics"] == nil ? "instrumental, \(style)" : style
        let prompt = YuE2Prompt(lyrics: lyrics, style: direction, seed: seed, guidanceScale: 1)
        let take = try await engine.renderSong(prompt, frames: seconds * YuE2Engine.framesPerSecond, steps: steps, score: score)
        guard let notation = take.score else { throw YuE2ScoreError.invalidScore }

        let files = FileManager.default
        let staging = output.deletingLastPathComponent().appendingPathComponent(".vibeplayer-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        try writeWAV(take.audio, to: staging.appendingPathComponent("song.wav"))
        try Data(notation.utf8).write(to: staging.appendingPathComponent("score.abc"))
        try files.moveItem(at: staging, to: output)
        try report(["audio": output.appendingPathComponent("song.wav").path,
                    "score": output.appendingPathComponent("score.abc").path,
                    "seed": String(seed)])
    }

    private static func writeWAV(_ audio: YuE2Audio, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate),
                                         channels: AVAudioChannelCount(audio.channels), interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frameCount)),
              let samples = buffer.floatChannelData?.pointee else { throw YuE2Error.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(audio.frameCount)
        audio.samples.withUnsafeBufferPointer { input in samples.update(from: input.baseAddress!, count: input.count) }
        var settings = format.settings
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        try file.write(from: buffer)
    }

    private static func options(_ arguments: [String], allowing names: Set<String>) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw Failure("Every option requires a value.") }
        var parsed: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let option = arguments[index]
            let name = String(option.dropFirst(2))
            guard option.hasPrefix("--"), names.contains(name), parsed[name] == nil else {
                throw Failure("Unknown or repeated option: \(option).")
            }
            parsed[name] = arguments[index + 1]
        }
        return parsed
    }

    private static func integer(_ name: String, in options: [String: String], default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let argument = options[name] else { return value }
        guard let number = Int(argument), range.contains(number) else {
            throw Failure("--\(name) needs an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    private static func requiredPath(_ name: String, in options: [String: String]) throws -> URL {
        guard let value = options[name], !value.isEmpty else { throw Failure("Provide --\(name).") }
        return URL(fileURLWithPath: value)
    }

    private static func requireNewPath(_ output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure("Output already exists: \(output.path)") }
    }

    private static func report(_ fields: [String: String]) throws {
        print(String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
