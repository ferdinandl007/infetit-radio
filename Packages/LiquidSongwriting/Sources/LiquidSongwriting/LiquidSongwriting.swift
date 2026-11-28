import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

public actor LiquidSongwriting {
    public static let shared = LiquidSongwriting()
    public static let repository = "https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-4bit"
    private static let revision = "91f34088d6946482cbcae11b85d4657093618c34"

    private static let files = [
        "chat_template.jinja": "306497f109439afcfa248f4ef5800601de24942e2981d632ae63fc5c070ceb12",
        "config.json": "7df2ea819f9a31b770192a0a9dc1b7953a7dd8c41b816cc3905bbec99ef332bd",
        "generation_config.json": "0095ba7158e938b1e2d3082d412f00d8be85e42cbbd7608b63866f7a081cf270",
        "model.safetensors": "1be5bf672013cd91aa62148f77c5eea8d2784a95845d5fe826e08c7b84823815",
        "model.safetensors.index.json": "2c8b88e25f6a1055164dd051436b170872200047bce4b3ec5f2a58f6ef929a75",
        "special_tokens_map.json": "7946f864cbfb62a1b041bda937244210a1a87f4a6cab3a48b791131b2cd57f88",
        "tokenizer.json": "41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44",
        "tokenizer_config.json": "b77214b9f12be74b9e5e1dab35d7dace077a31be969314bf38866fd6c8163853"
    ]

    public static var isSupported: Bool {
        #if arch(arm64) && !targetEnvironment(simulator)
        ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
        #else
        false
        #endif
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "VibePlayer/Songwriting/\(revision)", directoryHint: .isDirectory)
    }

    public static var isInstalled: Bool {
        files.keys.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    private var downloading = false
    private var generating = false

    public func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        guard Self.isSupported else { throw ModelError.unsupported }
        guard !downloading, !generating else { throw ModelError.busy }
        guard !Self.isInstalled else { return }
        downloading = true
        defer { downloading = false }

        let destination = Self.directory
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let parameters = URLSessionConfiguration.ephemeral
        parameters.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: parameters)
        defer { session.finishTasksAndInvalidate() }

        let smallFiles = Self.files.keys.filter { $0 != "model.safetensors" }.sorted()
        for name in smallFiles + ["model.safetensors"] {
            let url = URL(string: "\(Self.repository)/resolve/\(Self.revision)/\(name)")!
            let (temporary, response): (URL, URLResponse)
            if name == "model.safetensors" {
                (temporary, response) = try await ProgressReporter(report: progress).download(url)
            } else {
                (temporary, response) = try await session.download(from: url)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try Self.digest(of: temporary) == Self.files[name] else {
                throw ModelError.invalidDownload
            }
            try FileManager.default.moveItem(at: temporary, to: staging.appending(path: name))
        }
        try Task.checkCancellation()
        var installed = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try installed.setResourceValues(values)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        progress(1)
    }

    public func removeDownload() throws {
        guard !downloading, !generating else { throw ModelError.busy }
        if FileManager.default.fileExists(atPath: Self.directory.path) {
            try FileManager.default.removeItem(at: Self.directory)
        }
    }

    public func complete(_ instruction: String, limit: Int) async throws -> String? {
        guard Self.isSupported, Self.isInstalled else { return nil }
        while generating { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        guard Self.isInstalled else { return nil }
        generating = true
        defer { generating = false; Memory.clearCache() }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: Self.directory, using: LiquidTokenizerLoader())
        let session = ChatSession(container,
                                  instructions: "Write concise original songs. Follow the requested output format and return only the requested text.",
                                  generateParameters: .init(maxTokens: limit, temperature: 0.65),
                                  additionalContext: ["enable_thinking": false])
        let text = try await session.respond(to: instruction).trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return text.isEmpty ? nil : text
    }

    private static func digest(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var task: URLSessionDownloadTask?
        private var session: URLSession?
        private var result: Result<(URL, URLResponse), Error>?
        private var cancelled = false
        private var lastUpdate = Date.distantPast

        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func download(_ url: URL) async throws -> (URL, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
                    let task = session.downloadTask(with: url)
                    let shouldCancel = lock.withLock {
                        self.continuation = continuation
                        self.session = session
                        self.task = task
                        return cancelled
                    }
                    task.resume()
                    if shouldCancel { task.cancel() }
                }
            } onCancel: {
                let task = self.lock.withLock {
                    self.cancelled = true
                    return self.task
                }
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let shouldReport = lock.withLock {
                let now = Date()
                guard now.timeIntervalSince(lastUpdate) >= 0.25 else { return false }
                lastUpdate = now
                return true
            }
            if shouldReport && totalBytesExpectedToWrite > 0 {
                report(min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
                let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: location, to: saved)
                lock.withLock { result = .success((saved, response)) }
            } catch { lock.withLock { result = .failure(error) } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let state = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, Result<(URL, URLResponse), Error>?) in
                let continuation = self.continuation
                self.continuation = nil
                self.task = nil
                self.session = nil
                if let error { return (continuation, .failure(error)) }
                return (continuation, result ?? .failure(URLError(.unknown)))
            }
            if let continuation = state.0, let result = state.1 { continuation.resume(with: result) }
            session.finishTasksAndInvalidate()
        }
    }

    private enum ModelError: LocalizedError {
        case unsupported, busy, invalidDownload
        var errorDescription: String? {
            switch self {
            case .unsupported: "This device doesn’t meet the requirements for the local songwriting model."
            case .busy: "The local songwriting model is already in use."
            case .invalidDownload: "The songwriting model download failed verification. Please try again."
            }
        }
    }
}

private struct LiquidTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try LiquidTokenizer(tokenizer: await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct LiquidTokenizer: MLXLMCommon.Tokenizer {
    let tokenizer: any Tokenizers.Tokenizer
    var bosToken: String? { tokenizer.bosToken }
    var eosToken: String? { tokenizer.eosToken }
    var unknownToken: String? { tokenizer.unknownToken }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
