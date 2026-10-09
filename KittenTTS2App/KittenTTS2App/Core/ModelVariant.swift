import Foundation

/// The official KittenTTS 0.8 checkpoints supported by the KittenML Swift SDK.
/// Raw values match `KittenModel` in `KittenML/KittenTTS-swift` (also the Hugging Face repo names under `KittenML/`).
enum ModelVariant: String, CaseIterable, Identifiable, Codable {
    case nano = "kitten-tts-nano-0.8"
    case nanoInt8 = "kitten-tts-nano-0.8-int8"
    case micro = "kitten-tts-micro-0.8"
    case mini = "kitten-tts-mini-0.8"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nano: return "Nano (fp32)"
        case .nanoInt8: return "Nano (int8)"
        case .micro: return "Micro"
        case .mini: return "Mini"
        }
    }

    /// Approximate download size (ONNX file plus voices) in megabytes, as documented by the SDK.
    var approximateDownloadMB: Int {
        switch self {
        case .nano: return 59
        case .nanoInt8: return 28
        case .micro: return 44
        case .mini: return 83
        }
    }

    var onnxFileName: String {
        switch self {
        case .nano, .nanoInt8: return "kitten_tts_nano_v0_8.onnx"
        case .micro: return "kitten_tts_micro_v0_8.onnx"
        case .mini: return "kitten_tts_mini_v0_8.onnx"
        }
    }

    static let voicesFileName = "voices.npz"

    var huggingFaceRepo: String { "KittenML/\(rawValue)" }
}
