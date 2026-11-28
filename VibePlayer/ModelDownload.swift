import CryptoKit
import Foundation
import SwiftUI

private struct MusicModelManifest: Decodable {
    struct Release: Decodable { let repo: String; let revision: String }
    struct File: Decodable { let sha256: String; let size: Int64 }
    let release: Release
    let coreml: [String: [String: File]]
}

@MainActor @Observable
final class MusicModelDownload {
    private(set) var isActive = false
    private(set) var downloaded: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var status = "Ready to download"
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var completedBytes: Int64 = 0
    private var transferID: UUID?
    private var activity: NSObjectProtocol?

    init() {
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        if let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(MusicModelManifest.self, from: data),
           let entries = manifest.coreml[platform] {
            total = entries.values.reduce(0) { $0 + $1.size }
        }
    }

    var remaining: TimeInterval? {
        guard bytesPerSecond > 10_000, total > downloaded else { return nil }
        return Double(total - downloaded) / bytesPerSecond
    }

    func start(onInstalled: @escaping @MainActor () -> Bool) {
        guard task == nil else { return }
        isActive = true
        error = nil
        status = "Preparing download…"
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Downloading music models")
        #endif
        task = Task {
            defer {
                #if os(macOS)
                if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
                #endif
                isActive = false
                task = nil
            }
            do {
                try await download()
                status = "Preparing the music model…"
                guard onInstalled() else { throw DownloadFailure.activation }
                status = "Ready"
            } catch is CancellationError {
                downloaded = completedBytes
                bytesPerSecond = 0
                status = "Download paused. Completed files are saved."
            } catch {
                downloaded = completedBytes
                bytesPerSecond = 0
                if Task.isCancelled {
                    status = "Download paused. Completed files are saved."
                } else {
                    self.error = error.localizedDescription
                    status = "Download interrupted"
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    private func download() async throws {
        guard let manifestURL = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else { throw DownloadFailure.manifest }
        let manifest = try JSONDecoder().decode(MusicModelManifest.self, from: Data(contentsOf: manifestURL))
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        guard let entries = manifest.coreml[platform], !entries.isEmpty else { throw DownloadFailure.manifest }
        total = entries.values.reduce(0) { $0 + $1.size }
        downloaded = 0
        completedBytes = 0
        bytesPerSecond = 0
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let staging = support.appendingPathComponent("YuE2MetalAssets-download", isDirectory: true)
        let destination = support.appendingPathComponent("YuE2MetalAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var stagingURL = staging; try stagingURL.setResourceValues(excluded)
        let started = Date()
        var completed: Int64 = 0
        var networkBytes: Int64 = 0
        let files = entries.sorted { $0.value.size < $1.value.size }
        for (name, entry) in files {
            try Task.checkCancellation()
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw DownloadFailure.manifest }
            let target = staging.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                if (try? await Self.digest(target)) == entry.sha256 {
                    completed += entry.size
                    completedBytes = completed
                    downloaded = completed
                    continue
                }
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let url = URL(string: "https://huggingface.co/\(manifest.release.repo)/resolve/\(manifest.release.revision)/\(platform)/YuE2MetalAssets/\(name)") else { throw DownloadFailure.manifest }
            status = "Downloading music model…"
            let baseline = completed
            let priorNetworkBytes = networkBytes
            let currentTransfer = UUID()
            transferID = currentTransfer
            let transfer = ModelTransfer { [weak self] count in
                Task { @MainActor in
                    guard let self, self.isActive, self.transferID == currentTransfer else { return }
                    self.downloaded = max(self.downloaded, min(self.total, baseline + count))
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 1 { self.bytesPerSecond = Double(priorNetworkBytes + count) / elapsed }
                }
            }
            let (temporary, response) = try await transfer.download(url)
            transferID = nil
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw DownloadFailure.network }
            status = "Verifying downloaded files…"
            guard try await Self.digest(temporary) == entry.sha256 else { throw DownloadFailure.verification(name) }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += entry.size
            completedBytes = completed
            networkBytes += entry.size
            downloaded = completed
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = support.appendingPathComponent("YuE2MetalAssets-previous-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: destination, to: backup)
            do { try FileManager.default.moveItem(at: staging, to: destination); try? FileManager.default.removeItem(at: backup) }
            catch { try? FileManager.default.moveItem(at: backup, to: destination); throw error }
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private nonisolated static func digest(_ url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private enum DownloadFailure: LocalizedError {
        case manifest, network, verification(String), activation
        var errorDescription: String? {
            switch self {
            case .manifest: "The music model download information is unavailable."
            case .network: "The model could not be downloaded. Check your connection and try again."
            case .verification(let name): "Could not verify \(name). Try the download again."
            case .activation: "The downloaded music model could not be loaded on this device."
            }
        }
    }
}

private final class ModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var result: Result<(URL, URLResponse), Error>?
    private var cancelled = false
    private var lastUpdate = Date.distantPast

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

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
        if shouldReport { report(totalBytesWritten) }
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

struct MusicModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerStore.self) private var player
    @Bindable var download: MusicModelDownload
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 58)).foregroundStyle(.purple)
            VStack(spacing: 8) {
                Text("Get ready to make music").font(.title2.bold())
                Text("Download the music model once to create songs and play Radio on this device. The download comes from Hugging Face and needs several GB of storage.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if !download.isActive && download.downloaded == 0 && download.total > 0 {
                Text("Download size: \(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))")
                    .font(.subheadline.weight(.medium))
            }
            if download.isActive || download.downloaded > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(download.status).font(.headline)
                    if download.total > 0 {
                        ProgressView(value: Double(download.downloaded), total: Double(download.total))
                            .accessibilityIdentifier("music-model-progress")
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: download.downloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))")
                            Spacer()
                            if let remaining = download.remaining {
                                Text(remaining < 60 ? "Less than a minute left" : "About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))) left")
                            } else if download.isActive { Text("Estimating time…") }
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("music-model-estimate")
                        if download.bytesPerSecond > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(download.bytesPerSecond), countStyle: .file))/s")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("music-model-speed")
                        }
                    } else { ProgressView() }
                }
            }
            if let error = download.error { Text(error).font(.callout).foregroundStyle(.red) }
            if download.isActive {
                Button("Pause download") { download.cancel() }
                Text("Keep the app open until the download finishes.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(download.downloaded > 0 || download.error != nil ? "Continue download" : "Download music model") {
                    download.start { player.reloadMusicModel() }
                }.buttonStyle(.borderedProminent)
                Button("Not now") { dismiss() }.buttonStyle(.plain)
            }
            Link("YuE2 model and license", destination: URL(string: "https://huggingface.co/m-a-p/YuE2-3B/blob/main/LICENSE")!).font(.caption)
        }
        .padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(download.isActive)
        .onChange(of: player.canGenerate) { _, ready in if ready { dismiss() } }
        #if os(macOS)
        .frame(minWidth: 470, minHeight: 410)
        #endif
    }
}
