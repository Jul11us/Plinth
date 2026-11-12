import Foundation

/// The tokenizer of CLIP's text encoder: lower-cased words split into the byte pairs listed in `merges.txt`.
/// Prompts here are short English descriptions of a haircut, so there is no clean-up beyond lower-casing.
struct ClipTokenizer {
    static let length = 77
    private static let start = 49406, end = 49407

    /// The vocabulary is spelled in bytes, each written as one character: printable ones as themselves, the rest
    /// moved above 255, so "–" is three letters.
    private static let letters: [String] = {
        let printable = Array(33...126) + Array(161...172) + Array(174...255)
        var next = 256
        return (0..<256).map { byte in
            if printable.contains(byte) { return String(UnicodeScalar(UInt32(byte))!) }
            defer { next += 1 }
            return String(UnicodeScalar(UInt32(next))!)
        }
    }()

    private let vocabulary: [String: Int]
    private let ranks: [String: Int]
    private let words = try! NSRegularExpression(pattern: #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#)

    init(vocabulary vocabularyURL: URL, merges mergesURL: URL) throws {
        vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabularyURL))
        var ranks: [String: Int] = [:]
        // The first line is a version header.
        for (rank, line) in try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n").dropFirst().enumerated() {
            ranks[String(line)] = rank
        }
        self.ranks = ranks
    }

    /// Token ids padded to the 77 the encoder takes; a longer prompt loses its end.
    func encode(_ text: String) -> [Int] {
        let plain = text.lowercased()
        var ids: [Int] = []
        for match in words.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(match.range, in: plain) else { continue }
            ids += pieces(of: String(plain[range])).compactMap { vocabulary[$0] }
        }
        ids = [Self.start] + ids.prefix(Self.length - 2) + [Self.end]
        return ids + Array(repeating: Self.end, count: Self.length - ids.count)
    }

    /// One word as vocabulary pieces: start from single characters and keep joining the pair that was learned first.
    private func pieces(of word: String) -> [String] {
        var parts = word.utf8.map { Self.letters[Int($0)] }
        guard !parts.isEmpty else { return [] }
        parts[parts.count - 1] += "</w>"
        while parts.count > 1 {
            var best: (rank: Int, first: String, second: String)?
            for i in 0..<(parts.count - 1) {
                if let rank = ranks[parts[i] + " " + parts[i + 1]], rank < (best?.rank ?? .max) { best = (rank, parts[i], parts[i + 1]) }
            }
            guard let best else { break }
            var joined: [String] = []
            var i = 0
            while i < parts.count {
                if i < parts.count - 1, parts[i] == best.first, parts[i + 1] == best.second {
                    joined.append(best.first + best.second); i += 2
                } else {
                    joined.append(parts[i]); i += 1
                }
            }
            parts = joined
        }
        return parts
    }
}
