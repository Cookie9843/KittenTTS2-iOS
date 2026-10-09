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
}
