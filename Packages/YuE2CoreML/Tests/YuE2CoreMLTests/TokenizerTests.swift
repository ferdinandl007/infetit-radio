import Foundation
import Testing
@testable import YuE2CoreML

@Test func tokenizerCoversUnicodeAndMergesByRank() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var ranks = (0...255).map { "\(Data([UInt8($0)]).base64EncodedString()) \($0)" }
    ranks.append("\(Data("ab".utf8).base64EncodedString()) 256")
    try ranks.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let encoder = try Tokenizer(url: url)
    #expect(try encoder.encode("ab") == [256])
    let text = "e\u{0301} 🎧\n"
    #expect(try encoder.encode(text) == text.utf8.map(Int.init))
}

@Test func melodyScoreConditionsBothGuidanceBranches() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let ranks = (0...255).map { "\(Data([UInt8($0)]).base64EncodedString()) \($0)" }
    try ranks.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let encoder = try Tokenizer(url: url)
    let abc = "X:1\nK:C\nC E G |\n"
    var request = SongRequest(lyrics: "Morning light", style: "Folk", seed: 1)
    let direct = try encoder.prompt(request)
    #expect(direct[0].suffix(3) == [151847, 151848, 151851])
    #expect(!direct[1].contains(151847))
    request.scoreABC = abc
    let scored = try encoder.prompt(request)
    let scoreSuffix = [151847] + abc.utf8.map(Int.init) + [151848, 151851]
    #expect(scored.allSatisfy { $0.suffix(scoreSuffix.count).elementsEqual(scoreSuffix) })
}
