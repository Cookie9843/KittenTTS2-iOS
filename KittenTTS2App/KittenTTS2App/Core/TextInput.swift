import Foundation

enum TextInputError: LocalizedError, Equatable {
    case empty
    case tooLong(limit: Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter some text to speak."
        case .tooLong(let limit): return "The text is too long. Please keep it under \(limit) characters."
        }
    }
}

enum TextInput {
    static let maxCharacters = 5000

    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextInputError.empty }
        guard trimmed.count <= maxCharacters else { throw TextInputError.tooLong(limit: maxCharacters) }
        return trimmed
    }

    /// Splits text into sentences so they can be synthesized one at a time (SDK 0.1.0 has no streaming API).
    /// Terminators stay attached to their sentence; sentences with no letters or digits are merged into the previous one.
    static func sentences(from text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "\n", "。", "！", "？"]
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !piece.isEmpty else { return }
            if piece.contains(where: { $0.isLetter || $0.isNumber }) || result.isEmpty {
                result.append(piece)
            } else {
                result[result.count - 1] += piece
            }
        }
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard terminators.contains(ch) else { continue }
            // Keep consecutive terminators ("?!", "...") together and don't split "3.14".
            if i + 1 < chars.count {
                let next = chars[i + 1]
                if terminators.contains(next) && next != "\n" { continue }
                if ch == ".", next.isNumber, i > 0, chars[i - 1].isNumber { continue }
            }
            flush()
        }
        flush()
        return result
    }
}
