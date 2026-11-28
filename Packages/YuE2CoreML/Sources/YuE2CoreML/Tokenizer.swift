import Foundation

struct Tokenizer {
    private let ranks: [Data: Int]
    private let pattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    init(url: URL) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [Data: Int] = [:]
        entries.reserveCapacity(152_000)
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])),
                  let rank = Int(parts[1]), (0..<151643).contains(rank),
                  entries.updateValue(rank, forKey: bytes) == nil else {
                throw YuE2Failure.assets("Malformed tokenizer ranks.")
            }
        }
        guard (0...255).allSatisfy({ entries[Data([UInt8($0)])] != nil }) else {
            throw YuE2Failure.assets("The tokenizer is missing bytes.")
        }
        ranks = entries
    }

    func prompt(_ request: SongRequest) throws -> [[Int]] {
        let instruction = request.scoreABC == nil
            ? "Generate music with codec tokens from the given conditions."
            : "Generate a melody-only ABC transcription without chord symbols, then generate music with codec tokens from the given conditions."
        let style = trimmingNewlines(request.style)
        let lyrics = trimmingNewlines(request.lyrics)
        let text = "\(instruction)\n[Tags]\n\(style)\n[Lyrics]\n\(lyrics)\n"
        let scoreTokens = try request.scoreABC.map { try encode($0.precomposedStringWithCanonicalMapping) }
        let scoreSlot = [151847] + (scoreTokens ?? []) + [151848]
        return [[151643] + (try encode(text)) + scoreSlot + [TensorSpec.musicStart],
                [151643] + (try encode(instruction)) + (scoreTokens == nil ? [] : scoreSlot) + [TensorSpec.musicStart]]
    }

    private func trimmingNewlines(_ value: String) -> String {
        String(value.reversed().drop(while: { $0 == "\n" }).reversed())
    }

    func encode(_ text: String) throws -> [Int] {
        let expression = try NSRegularExpression(pattern: pattern)
        var result = [Int]()
        var covered = 0
        let source = text as NSString
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard match.range.location == covered, match.range.length <= 4096 else {
                throw YuE2Failure.request("The tokenizer could not cover the supplied text.")
            }
            covered += match.range.length
            let bytes = Data(source.substring(with: match.range).utf8)
            if let rank = ranks[bytes] {
                result.append(rank)
                continue
            }
            var parts = bytes.map { Data([$0]) }
            while parts.count > 1 {
                var best: (index: Int, rank: Int, bytes: Data)?
                for i in 0 ..< parts.count - 1 {
                    let combined = parts[i] + parts[i + 1]
                    if let rank = ranks[combined], rank < (best?.rank ?? Int.max) {
                        best = (i, rank, combined)
                    }
                }
                guard let best else { break }
                parts.replaceSubrange(best.index ... best.index + 1, with: [best.bytes])
            }
            for part in parts {
                guard let rank = ranks[part] else { throw YuE2Failure.assets("Missing tokenizer piece.") }
                result.append(rank)
            }
        }
        guard covered == text.utf16.count else { throw YuE2Failure.request("Incomplete tokenization.") }
        return result
    }
}
