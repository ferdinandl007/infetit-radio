import Foundation

public struct YuE2Score: Equatable, Sendable {
    public let notation: String

    public init(_ notation: String) throws {
        let clean = notation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 128 * 1024, !clean.utf8.contains(0),
              clean.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("K:") }) else {
            throw YuE2ScoreError.invalidScore
        }
        self.notation = clean + "\n"
    }

    public init(contentsOf url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 128 * 1024 + 1) ?? Data()
        guard data.count <= 128 * 1024, let notation = String(data: data, encoding: .utf8) else {
            throw YuE2ScoreError.invalidScore
        }
        try self.init(notation)
    }
}

public enum YuE2ScoreError: LocalizedError {
    case invalidScore, missingTranscriber, invalidRecording, transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScore: "Choose a UTF-8 ABC score with a key (K:) and keep it under 128 KB."
        case .missingTranscriber: "Install the SheetSage2 tools to transcribe a recording. You can also import an ABC score."
        case .invalidRecording: "Choose a playable mono or stereo recording between 1 second and 5 minutes."
        case .transcriptionFailed(let detail): "SheetSage2 couldn't transcribe the recording. \(detail)"
        }
    }
}

#if os(macOS)
import AVFoundation

public struct YuE2Transcriber: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YuE2NativeAssets/Reference", isDirectory: true)
    }

    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    private var executable: URL { directory.appendingPathComponent("yue-transcribe") }
    private var model: URL { directory.appendingPathComponent("SheetSage2-Q8_0.gguf") }

    public var isAvailable: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: executable.path) && files.isReadableFile(atPath: model.path)
            && files.isReadableFile(atPath: directory.appendingPathComponent("MERT-v2-FullSong-Q8_0.gguf").path)
    }

    @concurrent
    public func transcribe(_ recording: URL) async throws -> YuE2Score {
        guard isAvailable else { throw YuE2ScoreError.missingTranscriber }
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("vibe-score-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }
        let wav = work.appendingPathComponent("recording.wav")
        let abc = work.appendingPathComponent("melody.abc")
        let log = work.appendingPathComponent("transcription.log")
        try Self.copyRecording(recording, to: wav)
        try Task.checkCancellation()

        try Data().write(to: log)
        let diagnostics = try FileHandle(forUpdating: log)
        defer { try? diagnostics.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--model", model.path, "--audio", wav.path, "--out", abc.path, "--melody-only", "--device", "MTL0"]
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(600)
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                throw YuE2ScoreError.transcriptionFailed("The transcription timed out.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let end = try diagnostics.seekToEnd()
            try diagnostics.seek(toOffset: end > 1_024 ? end - 1_024 : 0)
            let tail = String(decoding: try diagnostics.readToEnd() ?? Data(), as: UTF8.self)
            let detail = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Try another recording."
            throw YuE2ScoreError.transcriptionFailed(detail)
        }
        return try YuE2Score(contentsOf: abc)
    }

    private static func copyRecording(_ input: URL, to output: URL) throws {
        let scoped = input.startAccessingSecurityScopedResource()
        defer { if scoped { input.stopAccessingSecurityScopedResource() } }
        guard let source = try? AVAudioFile(forReading: input, commonFormat: .pcmFormatInt16, interleaved: true) else {
            throw YuE2ScoreError.invalidRecording
        }
        let format = source.processingFormat
        let seconds = Double(source.length) / format.sampleRate
        guard (1...300).contains(seconds), (1...2).contains(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw YuE2ScoreError.invalidRecording
        }
        let destination = try AVAudioFile(forWriting: output, settings: format.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { throw YuE2ScoreError.invalidRecording }
            try destination.write(from: buffer)
        }
    }
}
#endif
