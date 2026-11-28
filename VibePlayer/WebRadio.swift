#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import Network
import SwiftUI

struct WebRadioTrack: Equatable {
    let id: UUID
    let url: URL
}

struct WebRadioSnapshot: Encodable {
    let station: String
    let description: String
    let title: String?
    var state: String
    let position: Double
    let duration: Double
    var audio: String? = nil
    var suggestionToken: String? = nil
}

struct WebRadioSuggestion: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor @Observable
final class WebRadio {
    static let port: UInt16 = 7787
    static let localURL = URL(string: "http://127.0.0.1:7787/")!
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var suggestions: [WebRadioSuggestion] = []
    private(set) var suggestionInProgress: UUID?
    var acceptsSuggestions = true

    @ObservationIgnored private weak var player: PlayerStore?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cachedTracks: [UUID: URL] = [:]
    @ObservationIgnored private var encodingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedTracks: Set<UUID> = []
    @ObservationIgnored private var token = UUID().uuidString
    @ObservationIgnored private var recentSuggestions: [(text: String, time: ContinuousClock.Instant)] = []
    @ObservationIgnored private var lastStation: UUID?
    @ObservationIgnored private lazy var record = NSImage(named: "DesktopRecord")?.tiffRepresentation
        .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) }

    func start(player: PlayerStore) {
        guard listener == nil else { return }
        guard player.canGenerate else {
            error = "Install or enable the Radio music model first."
            return
        }
        error = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.port)!)
        do {
            let server = try NWListener(using: parameters)
            listener = server
            self.player = player
            server.stateUpdateHandler = { [weak self, weak server, weak player] state in
                Task { @MainActor in
                    guard let self, let server, let player, self.listener === server else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        if !player.radioMode { player.select(player.selected) }
                        if !player.wantsPlayback { player.play() }
                        self.watchRadio()
                    case .failed(let failure):
                        self.stop()
                        self.error = "Web Radio couldn't start. \(failure.localizedDescription)"
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.isRunning else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            server.start(queue: .main)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for task in encodingTasks.values { task.cancel() }
        encodingTasks.removeAll()
        for url in cachedTracks.values { try? FileManager.default.removeItem(at: url) }
        cachedTracks.removeAll()
        failedTracks.removeAll()
        suggestions.removeAll()
        suggestionInProgress = nil
        recentSuggestions.removeAll()
        lastStation = nil
        token = UUID().uuidString
        player = nil
    }

    func nextSuggestion(for station: UUID) -> WebRadioSuggestion? {
        updateStation(station)
        guard isRunning, let suggestion = suggestions.first else { return nil }
        suggestionInProgress = suggestion.id
        return suggestion
    }

    func finishSuggestion(_ id: UUID) {
        suggestions.removeAll { $0.id == id }
        if suggestionInProgress == id { suggestionInProgress = nil }
    }

    func removeSuggestion(_ id: UUID) {
        guard id != suggestionInProgress else { return }
        suggestions.removeAll { $0.id == id }
    }

    private func updateStation(_ id: UUID) {
        guard lastStation != id else { return }
        lastStation = id
        suggestions.removeAll()
        suggestionInProgress = nil
        token = UUID().uuidString
    }

    private func watchRadio() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.updateStation(player.selected.id)
                self.refreshAudio(player.webRadioTracks)
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private func refreshAudio(_ tracks: [WebRadioTrack]) {
        let wanted = Set(tracks.map(\.id))
        failedTracks.formIntersection(wanted)
        for (id, url) in cachedTracks where !wanted.contains(id) {
            cachedTracks[id] = nil
            try? FileManager.default.removeItem(at: url)
        }
        for (id, task) in encodingTasks where !wanted.contains(id) {
            task.cancel()
            encodingTasks[id] = nil
        }
        for track in tracks where cachedTracks[track.id] == nil && encodingTasks[track.id] == nil
            && !failedTracks.contains(track.id) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-broadcast-\(UUID()).m4a")
            encodingTasks[track.id] = Task { [weak self] in
                let asset = AVURLAsset(url: track.url)
                do {
                    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await exporter.export(to: url, as: .m4a)
                    try Task.checkCancellation()
                    self?.cachedTracks[track.id] = url
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    if !Task.isCancelled { self?.failedTracks.insert(track.id) }
                }
                if !Task.isCancelled { self?.encodingTasks[track.id] = nil }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.close(id) }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(connection, id: id, bytes: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.close(id)
        }
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] block, _, complete, failure in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                guard failure == nil, let block else { self.close(id); return }
                let request = bytes + block
                guard request.count <= 12_288 else {
                    self.send(.error("413 Payload Too Large"), to: connection, id: id)
                    return
                }
                if let boundary = request.range(of: Data("\r\n\r\n".utf8)) {
                    guard let headers = HTTPRequest(header: Data(request[..<boundary.lowerBound])) else {
                        self.send(.error("400 Bad Request"), to: connection, id: id)
                        return
                    }
                    let body = Data(request[boundary.upperBound...])
                    if body.count >= headers.contentLength {
                        let response = self.respond(headers, body: Data(body.prefix(headers.contentLength)))
                        self.send(response, to: connection, id: id, headOnly: headers.method == "HEAD")
                        return
                    }
                }
                if complete { self.close(id) }
                else { self.receive(connection, id: id, bytes: request) }
            }
        }
    }

    private func respond(_ request: HTTPRequest, body: Data) -> HTTPResponse {
        guard let player, isRunning else { return .error("503 Service Unavailable") }
        guard request.method == "GET" || request.method == "HEAD" || request.method == "POST" else {
            return .error("405 Method Not Allowed")
        }
        updateStation(player.selected.id)
        if request.method == "POST" {
            guard request.path == "/idea" else { return .error("404 Not Found") }
            return submit(request, body: body)
        }

        switch request.path {
        case "/": return resource("index", ext: "html", mime: "text/html; charset=utf-8")
        case "/radio.css": return resource("radio", ext: "css", mime: "text/css; charset=utf-8")
        case "/radio.js": return resource("radio", ext: "js", mime: "text/javascript; charset=utf-8")
        case "/record.jpg":
            guard let record else { return .error("404 Not Found") }
            return HTTPResponse(mime: "image/jpeg", body: record, headers: ["Cache-Control": "public, max-age=3600"])
        case "/state":
            var snapshot = player.webRadioSnapshot
            snapshot.suggestionToken = acceptsSuggestions && player.radioMode && player.wantsPlayback ? token : nil
            if let track = player.webRadioTracks.first, snapshot.state == "live", cachedTracks[track.id] != nil {
                snapshot.audio = "/audio/\(track.id).m4a"
            } else if snapshot.state == "live" {
                snapshot.state = "preparing"
            }
            guard let data = try? JSONEncoder().encode(snapshot) else { return .error("500 Internal Server Error") }
            return HTTPResponse(mime: "application/json", body: data)
        default:
            guard request.path.hasPrefix("/audio/"), request.path.hasSuffix(".m4a"),
                  let id = UUID(uuidString: String(request.path.dropFirst(7).dropLast(4))),
                  let url = cachedTracks[id], let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty else { return .error("404 Not Found") }
            return audioResponse(data, range: request.range)
        }
    }

    private func resource(_ name: String, ext: String, mime: String) -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "RadioWeb"),
              let data = try? Data(contentsOf: url) else { return .error("404 Not Found") }
        return HTTPResponse(mime: mime, body: data)
    }

    private func submit(_ request: HTTPRequest, body: Data) -> HTTPResponse {
        guard acceptsSuggestions, player?.radioMode == true, player?.wantsPlayback == true else {
            return .error("403 Forbidden", "Ideas are closed for now.")
        }
        guard request.suggestionToken == token, request.contentType == "application/json",
              let value = try? JSONDecoder().decode(Submission.self, from: body) else {
            return .error("400 Bad Request", "Reload the station and try again.")
        }
        let idea = value.idea.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (3...160).contains(idea.count), idea.utf8.count <= 640,
              idea.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              idea.rangeOfCharacter(from: .letters) != nil else {
            return .error("422 Unprocessable Content", "Describe an idea in 3–160 characters.")
        }

        let now = ContinuousClock.now
        recentSuggestions.removeAll { $0.time.duration(to: now) > .seconds(120) }
        guard suggestions.count < 12 else {
            return .error("429 Too Many Requests", "The suggestion queue is full. Try again later.")
        }
        guard !recentSuggestions.contains(where: { $0.text.caseInsensitiveCompare(idea) == .orderedSame }),
              !suggestions.contains(where: { $0.text.caseInsensitiveCompare(idea) == .orderedSame }) else {
            return .error("409 Conflict", "That idea is already in the queue.")
        }
        guard recentSuggestions.count < 8 else {
            return .error("429 Too Many Requests", "Too many ideas just came in. Try again in a minute.")
        }
        recentSuggestions.append((idea, now))
        suggestions.append(WebRadioSuggestion(text: idea))
        return HTTPResponse(status: "202 Accepted", mime: "text/plain; charset=utf-8",
                            body: Data("Added to this station’s suggestion queue.".utf8))
    }

    private func audioResponse(_ data: Data, range: String?) -> HTTPResponse {
        var headers = ["Accept-Ranges": "bytes"]
        guard let range else { return HTTPResponse(mime: "audio/mp4", body: data, headers: headers) }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let start: Int
        let end: Int
        if range.hasPrefix("bytes="), parts.count == 2 {
            if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
                start = max(0, data.count - suffix)
                end = data.count - 1
            } else {
                start = Int(parts[0]) ?? -1
                end = parts[1].isEmpty ? data.count - 1 : min(Int(parts[1]) ?? -1, data.count - 1)
            }
        } else {
            start = -1
            end = -1
        }
        guard start >= 0, start <= end else {
            headers["Content-Range"] = "bytes */\(data.count)"
            return HTTPResponse(status: "416 Range Not Satisfiable", mime: "audio/mp4", body: Data(), headers: headers)
        }
        headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        return HTTPResponse(status: "206 Partial Content", mime: "audio/mp4",
                            body: data[start...end], headers: headers)
    }

    private func send(_ response: HTTPResponse, to connection: NWConnection, id: UUID, headOnly: Bool = false) {
        var header = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.mime)\r\n"
        header += "Content-Length: \(response.body.count)\r\nConnection: close\r\n"
        header += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        header += "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'\r\n"
        if response.headers["Cache-Control"] == nil { header += "Cache-Control: no-store\r\n" }
        for (key, value) in response.headers { header += "\(key): \(value)\r\n" }
        connection.batch {
            connection.send(content: Data((header + "\r\n").utf8), completion: .idempotent)
            connection.send(content: headOnly ? nil : response.body, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close(id) }
            })
        }
    }

    private struct Submission: Decodable { let idea: String }
}

private struct HTTPRequest {
    let method: String
    let path: String
    var range: String?
    var contentType: String?
    var suggestionToken: String?
    var contentLength = 0

    init?(header: Data) {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        method = String(parts[0])
        path = String(parts[1].prefix { $0 != "?" })
        var host: String?
        for line in lines.dropFirst() {
            let keyValue = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { return nil }
            let value = keyValue[1].trimmingCharacters(in: .whitespaces)
            switch keyValue[0].lowercased() {
            case "host":
                guard host == nil else { return nil }
                host = value.lowercased()
            case "range": range = value
            case "content-type": contentType = value
            case "x-radio-token": suggestionToken = value
            case "content-length":
                guard let length = Int(value), (0...1024).contains(length) else { return nil }
                contentLength = length
            case "transfer-encoding": return nil
            default: break
            }
        }
        guard let name = host?.split(separator: ":").first,
              name == "127.0.0.1" || name == "localhost" || name.hasSuffix(".ts.net") else { return nil }
    }
}

private struct HTTPResponse {
    var status = "200 OK"
    let mime: String
    let body: Data
    var headers: [String: String] = [:]

    static func error(_ status: String, _ message: String = "") -> Self {
        Self(status: status, mime: "text/plain; charset=utf-8", body: Data(message.utf8))
    }
}

struct WebRadioPanel: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        @Bindable var radio = player.webRadio
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("Web Radio", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Host \(player.selected.name) from this Mac. Keep the app open while listeners tune in.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if radio.isRunning {
                    Button("Stop hosting") { radio.stop() }
                    Link("Open web player", destination: WebRadio.localURL)
                } else {
                    Button("Start hosting") { radio.start(player: player) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = radio.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            if radio.isRunning {
                Divider()
                Text("Public link").font(.headline)
                Text("1. Connect Tailscale on this Mac.\n2. Copy and run the command in Terminal.\n3. Share the HTTPS link it prints with listeners.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(copied ? "Copied" : "Copy Funnel command") {
                        let bundled = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
                        let command = FileManager.default.isExecutableFile(atPath: bundled)
                            ? "TAILSCALE_BE_CLI=1 \(bundled)" : "tailscale"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(command) funnel --https=10000 127.0.0.1:\(WebRadio.port)", forType: .string)
                        copied = true
                    }
                    Link("Tailscale setup", destination: URL(string: "https://tailscale.com/docs/features/tailscale-funnel")!)
                }
                Divider()
                Toggle("Accept listener ideas", isOn: $radio.acceptsSuggestions)
                if radio.suggestions.isEmpty {
                    Text("New ideas wait here until the next render starts.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(radio.suggestions) { suggestion in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(suggestion.text).lineLimit(2)
                                    Spacer()
                                    if radio.suggestionInProgress == suggestion.id {
                                        Text("Rendering").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Button("Remove") { radio.removeSuggestion(suggestion.id) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 132)
                }
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}
#endif
