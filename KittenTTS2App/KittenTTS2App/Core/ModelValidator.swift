import Foundation

struct ModelValidationResult: Equatable {
    /// Voice IDs (npz keys) found in the voices file.
    let voiceIDs: [String]
}

enum ModelValidationError: LocalizedError, Equatable {
    case missing(String)
    case wrongExtension(file: String, expected: String)
    case onnxTooSmall(file: String)
    case voicesNotNPZ(file: String)
    case noSupportedVoices

    var errorDescription: String? {
        switch self {
        case .missing(let file):
            return "\(file) could not be found."
        case .wrongExtension(let file, let expected):
            return "\(file) is not a \(expected) file."
        case .onnxTooSmall(let file):
            return "\(file) is too small to be a KittenTTS model (it may be an incomplete download or a Git LFS pointer)."
        case .voicesNotNPZ(let file):
            return "\(file) is not a valid voices.npz archive."
        case .noSupportedVoices:
            return "The voices file does not contain any voices supported by the KittenTTS SDK."
        }
    }
}

enum ModelValidator {
    /// Smallest official model (nano int8) is ~25 MB; anything under 1 MB cannot be a real model.
    static let minimumOnnxBytes: Int64 = 1_000_000

    static func validate(onnxURL: URL, voicesURL: URL) throws -> ModelValidationResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: onnxURL.path) else { throw ModelValidationError.missing(onnxURL.lastPathComponent) }
        guard fm.fileExists(atPath: voicesURL.path) else { throw ModelValidationError.missing(voicesURL.lastPathComponent) }

        guard onnxURL.pathExtension.lowercased() == "onnx" else {
            throw ModelValidationError.wrongExtension(file: onnxURL.lastPathComponent, expected: ".onnx")
        }
        guard voicesURL.pathExtension.lowercased() == "npz" else {
            throw ModelValidationError.wrongExtension(file: voicesURL.lastPathComponent, expected: ".npz")
        }

        let size = (try? fm.attributesOfItem(atPath: onnxURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minimumOnnxBytes else { throw ModelValidationError.onnxTooSmall(file: onnxURL.lastPathComponent) }

        let keys: [String]
        do {
            let data = try Data(contentsOf: voicesURL, options: .mappedIfSafe)
            keys = try ZipDirectory.npzKeys(in: data)
        } catch {
            throw ModelValidationError.voicesNotNPZ(file: voicesURL.lastPathComponent)
        }
        guard !VoiceCatalog.available(in: keys).isEmpty else { throw ModelValidationError.noSupportedVoices }
        return ModelValidationResult(voiceIDs: keys)
    }
}
