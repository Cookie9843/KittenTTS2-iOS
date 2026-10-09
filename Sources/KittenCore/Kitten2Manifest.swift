import Foundation

/// One file to download: exact name, size and SHA-256 are all checked before it is installed.
public struct RemoteModelFile: Equatable, Sendable {
    public var name: String
    public var url: URL
    public var size: Int64
    public var sha256: String

    public init(name: String, url: URL, size: Int64, sha256: String) {
        self.name = name; self.url = url; self.size = size; self.sha256 = sha256.lowercased()
    }

    /// Rejects manifests that could write outside the install folder or fetch over an insecure/unknown host.
    public var validationProblem: String? {
        if name.isEmpty || name.contains("/") || name.contains("\\") || name.hasPrefix(".") { return "Unsafe file name “\(name)”." }
        if size <= 0 { return "File size must be positive." }
        if sha256.count != 64 || !sha256.allSatisfy({ $0.isHexDigit }) { return "SHA-256 must be 64 hex digits." }
        guard url.scheme == "https", let host = url.host?.lowercased(), host == "huggingface.co" || host.hasSuffix(".huggingface.co") else {
            return "Downloads are only allowed from https://huggingface.co."
        }
        return nil
    }
}

/// The KittenTTS 2 community package published at https://huggingface.co/dignome/kitten_tts2 (single GGUF with the
/// model, presets and assets embedded). This is a community conversion, NOT an official KittenML release or format.
public enum Kitten2Package {
    public static let displayName = "KittenTTS 2"
    public static let repository = "dignome/kitten_tts2"
    public static let repositoryPage = URL(string: "https://huggingface.co/dignome/kitten_tts2")!
    public static let treePage = URL(string: "https://huggingface.co/dignome/kitten_tts2/tree/main")!
    /// Revision that is downloaded. The file is pinned by size + SHA-256, so a moved `main` can never install different weights.
    public static let revision = "main"
    public static let installDirectoryName = "kitten2"
    public static let licenseName = "Stellon Labs Community License (embedded LICENSE.md / NOTICE in the model file)"
    public static let attribution = "KittenTTS 2 is a community-converted audio.cpp package (dignome/kitten_tts2) of Stellon Labs’ Kitten TTS 2. It is not an official KittenML release or format."

    public static var file: RemoteModelFile {
        RemoteModelFile(
            name: AudioCppPackage.publishedFileName,
            url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(AudioCppPackage.publishedFileName)")!,
            size: AudioCppPackage.publishedSize,
            sha256: AudioCppPackage.publishedSHA256)
    }

    /// The 48 preset voice ids declared by audio.cpp's `kitten_tts2` model spec (`voice_id` option, pinned revision ad1473c).
    /// Only "Bruno" has been synthesized on a real device by the project's maintainers (see docs); the rest are not
    /// individually verified. Voices named after a language are the multilingual presets for that language.
    public static let presetVoices: [PresetVoice] = [
        PresetVoice("Bella"),
        PresetVoice("Jasper"),
        PresetVoice("Luna"),
        PresetVoice("Bruno"),
        PresetVoice("Rosie"),
        PresetVoice("Hugo"),
        PresetVoice("Kiki"),
        PresetVoice("Leo"),
        PresetVoice("Matthew"),
        PresetVoice("Elliot"),
        PresetVoice("Willow"),
        PresetVoice("Dolores"),
        PresetVoice("Victor"),
        PresetVoice("Dante"),
        PresetVoice("Alfred"),
        PresetVoice("Saoirse"),
        PresetVoice("Claire"),
        PresetVoice("Raven"),
        PresetVoice("Marcus"),
        PresetVoice("Herbert"),
        PresetVoice("Diana"),
        PresetVoice("Laurence"),
        PresetVoice("Maeve"),
        PresetVoice("Walter"),
        PresetVoice("Edith"),
        PresetVoice("Miles"),
        PresetVoice("Grace"),
        PresetVoice("Reginald"),
        PresetVoice("Iris"),
        PresetVoice("Frank"),
        PresetVoice("Serena"),
        PresetVoice("Julian"),
        PresetVoice("Eleanor"),
        PresetVoice("Otis"),
        PresetVoice("Vincent"),
        PresetVoice("Martha"),
        PresetVoice("Sable"),
        PresetVoice("Victoria"),
        PresetVoice("PreparedBruno"),
        PresetVoice("Arabic", language: "Arabic"),
        PresetVoice("Chinese", language: "Chinese"),
        PresetVoice("French", language: "French"),
        PresetVoice("German", language: "German"),
        PresetVoice("Hindi", language: "Hindi"),
        PresetVoice("Italian", language: "Italian"),
        PresetVoice("Portuguese", language: "Portuguese"),
        PresetVoice("Russian", language: "Russian"),
        PresetVoice("Spanish", language: "Spanish"),
    ]
    public static let defaultVoice = "Bruno"
}

public struct PresetVoice: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var language: String?
    public init(_ id: String, language: String? = nil) { self.id = id; self.language = language }
    public var displayName: String { language == nil ? id : "\(id) (multilingual preset)" }
}

/// Validation of what the user typed before a request reaches the (uninterruptible) native call.
public enum SynthesisInput {
    public static let maxCharacters = 4000

    public enum Problem: Error, Equatable, LocalizedError {
        case emptyText, textTooLong(Int), unknownVoice(String)
        public var errorDescription: String? {
            switch self {
            case .emptyText: return "Type some text to speak first."
            case .textTooLong(let n): return "That text is \(n) characters; please keep it under \(SynthesisInput.maxCharacters). Long text can be split into parts."
            case .unknownVoice(let v): return "“\(v)” is not one of the available voices."
            }
        }
    }

    public static func validatePreset(text: String, voice: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Problem.emptyText }
        if trimmed.count > maxCharacters { throw Problem.textTooLong(trimmed.count) }
        if !Kitten2Package.presetVoices.contains(where: { $0.id == voice }) { throw Problem.unknownVoice(voice) }
        return trimmed
    }
}
