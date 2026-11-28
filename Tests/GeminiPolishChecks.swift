import Foundation

private final class GeminiStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let url = request.url, url.path.contains("gemini-4-neon"),
              let key = request.value(forHTTPHeaderField: "x-goog-api-key") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if key == "offline-key" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        guard
              let body, let contents = String(data: body, encoding: .utf8),
              (contents.contains("Polish the following lyrics") && contents.contains("original line")) ||
                contents.contains("Reply with one short word") || contents.contains("Invent one original song title") ||
                contents.contains("Write original lyrics") || contents.contains("Plan a short song") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: key == "bad-key" ? 403 : 200, httpVersion: nil, headerFields: nil)!
        let result = key == "empty-key" ? "" : contents.contains("Invent one original song title") ? "Under the Lanterns" : "Polished line"
        let data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(result)\"}]},\"finishReason\":\"STOP\"}]}".data(using: .utf8)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct GeminiPolishChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStub.self]
        let writer = GeminiLyricsWriter(session: URLSession(configuration: configuration))
        let result = try await writer.polish("original line", kind: "lyrics", idea: "midnight", styles: "mellow", apiKey: "test-key")
        precondition(result == "Polished line")
        try await writer.testKey("  test-key  ")
        do {
            try await writer.testKey("bad-key")
            preconditionFailure("Rejected keys must fail verification")
        } catch GeminiLyricsError.rejected(403) { }
        do {
            try await writer.testKey("empty-key")
            preconditionFailure("Empty Gemini responses must fail verification")
        } catch GeminiLyricsError.empty { }

        let offline = GeminiLyricsWriter(session: URLSession(configuration: configuration), readKey: { "offline-key" },
                                        localCompletion: { prompt, _ in
            precondition(prompt.contains("original line"))
            return "Polished offline"
        })
        let fallback = try await offline.polish("original line", kind: "lyrics", idea: "midnight", styles: "mellow")
        precondition(fallback == "Polished offline")
        do {
            try await offline.testKey("offline-key")
            preconditionFailure("Key verification must require a real Gemini connection")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }

        let missingKey = GeminiLyricsWriter(readKey: { nil }, localCompletion: { prompt, _ in
            precondition(prompt.contains("Write original lyrics"))
            precondition(prompt.contains("one coherent story") && prompt.contains("chorus wording identical"))
            return "[Verse]\nA local melody"
        })
        let request = MusicPromptBuilder().makeCreateRequest(idea: "the moon", styles: "folk", instrumental: false, seed: 1)
        let localLyrics = try await missingKey.writeLyrics(for: request)
        precondition(localLyrics == "[Verse]\nA local melody")

        let radioDraft = """
        [Verse 1]
        Un matin de mai
        Le vent court dehors
        Je cherche la clé
        Du vieux coffre en or

        [Chorus]
        Viens marcher près de moi
        Le chemin sent le bois
        Un oiseau chante là
        Et le jour nous verra

        [Verse 2]
        Le coffre est ouvert
        Une lettre est là
        Je reconnais hier
        Le tracé de tes pas

        [Outro]
        Demain je t’écrirai
        Et tu me répondras
        """
        let radioWriter = GeminiLyricsWriter(readKey: { nil }, localCompletion: { prompt, _ in
            if prompt.contains("Plan a short song") {
                return "A morning walk leads to a letter in an old chest."
            }
            precondition(prompt.contains("Language: French"))
            precondition(prompt.contains("[Verse 1], [Chorus], [Verse 2], [Outro]") && prompt.contains("natural pronunciation"))
            precondition(prompt.contains("A morning walk leads to a letter in an old chest."))
            return prompt.contains("previous draft was incomplete") ? radioDraft : "An incomplete draft"
        })
        let french = MusicProfile(name: "French Radio", traits: [.init(name: "French", category: .language, intensity: 1)], tempo: 90)
        let radioRequest = MusicPromptBuilder().makeRadioPlaybackRequest(profile: french, seed: 1, idea: "", voiceOverride: nil, arrangement: 0)
        let radioLyrics = try await radioWriter.writeLyrics(for: radioRequest)
        precondition(radioLyrics.components(separatedBy: "Viens marcher près de moi").count == 3)
        precondition(radioLyrics.hasSuffix("Et tu me répondras"))
        precondition(RadioLyricSheet(longer: false).render(radioLyrics) == radioLyrics)
        precondition(RadioLyricSheet(longer: true).render(radioLyrics) == nil)

        let rejectedRadioWriter = GeminiLyricsWriter(session: URLSession(configuration: configuration), readKey: { "bad-key" },
                                                      localCompletion: { _, _ in radioLyrics })
        let recoveredRadioLyrics = try await rejectedRadioWriter.writeLyrics(for: radioRequest)
        precondition(recoveredRadioLyrics == radioLyrics)
        let unavailableRadioWriter = GeminiLyricsWriter(session: URLSession(configuration: configuration), readKey: { "bad-key" },
                                                         localCompletion: { _, _ in nil })
        do {
            _ = try await unavailableRadioWriter.writeLyrics(for: radioRequest)
            preconditionFailure("Radio must surface the provider error if local songwriting is unavailable")
        } catch GeminiLyricsError.rejected(403) { }

        let localTitleWriter = GeminiLyricsWriter(readKey: { nil }, localCompletion: { prompt, _ in
            precondition(prompt.contains("Invent one original song title") && prompt.contains("folk"))
            return "Blue Porch Light"
        })
        let localTitle = try await localTitleWriter.suggestRadioTitle(for: request)
        precondition(localTitle == "Blue Porch Light")

        let cloudTitleWriter = GeminiLyricsWriter(session: URLSession(configuration: configuration),
                                                  readKey: { "test-key" }, localCompletion: { _, _ in nil })
        let cloudTitle = try await cloudTitleWriter.suggestRadioTitle(for: request)
        precondition(cloudTitle == "Under the Lanterns")

        let noTitleWriter = GeminiLyricsWriter(readKey: { nil }, localCompletion: { _, _ in nil })
        let noTitle = try await noTitleWriter.suggestRadioTitle(for: request)
        precondition(noTitle == nil)
        print("Gemini, offline songwriting, and key verification checks passed")
    }
}
