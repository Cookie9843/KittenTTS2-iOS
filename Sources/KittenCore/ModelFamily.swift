import Foundation

/// The two model families the app can import. Names deliberately avoid the ambiguous
/// "KittenTTS 1": upstream calls the original lightweight models "KittenTTS 0.8" (ONNX).
public enum ModelFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case kitten2
    case legacy08

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kitten2: return "KittenTTS 2 (1.7B, GGUF)"
        case .legacy08: return "KittenTTS 0.8 / original (ONNX)"
        }
    }

    public var summary: String {
        switch self {
        case .kitten2:
            return "Speech language model (GGUF + TorchScript decoder). 1.03 GB (TQ2_1), 1.45 GB (Q4_0) or ~3.5 GB (FP16 reference export)."
        case .legacy08:
            return "Original lightweight models (Nano / Micro / Mini, 25–80 MB ONNX + voices.npz). This is what some people call “KittenTTS 1”; upstream names these 0.8."
        }
    }

    public var expectedFilesDescription: String {
        switch self {
        case .kitten2:
            return "A KittenTTS 2 .gguf (e.g. cpp/model-tq2_1.gguf from KittenML/kitten-tts-2) plus, for a complete install, the matching decoder.pt (TorchScript), voices.json and config.json."
        case .legacy08:
            return "One .onnx model (kitten_tts_{nano,micro,mini}_v0_8.onnx) and its voices.npz from the matching KittenML/kitten-tts-*-0.8 repository."
        }
    }

    /// True when this app can actually synthesize speech with the family on iOS.
    public var canSynthesizeOnDevice: Bool { self == .legacy08 }

    /// Verified reason on-device synthesis is not offered, if any.
    public var runtimeBlocker: String? {
        switch self {
        case .kitten2:
            return """
            KittenTTS 2 needs upstream's kitten-tts-2-cpp runtime: a custom llama.cpp fork (the TQ2_1 weight format cannot be loaded by stock llama.cpp), \
            a CPU LibTorch TorchScript waveform decoder, and the kitten-text-processing normalizer. Upstream publishes it as a desktop CPU command-line tool \
            only; no iOS build, LibTorch-for-iOS decoder path or Swift/C API is published, so this app cannot run it. Files can be validated and stored, \
            but synthesis is disabled rather than faked.
            """
        case .legacy08:
            return nil
        }
    }
}

/// The ONNX checkpoints supported by the KittenTTS-swift SDK. Raw values match the SDK's directory names.
public enum LegacyVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case nano = "kitten-tts-nano-0.8"
    case nanoInt8 = "kitten-tts-nano-0.8-int8"
    case micro = "kitten-tts-micro-0.8"
    case mini = "kitten-tts-mini-0.8"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nano: return "Nano (fp32)"
        case .nanoInt8: return "Nano (int8)"
        case .micro: return "Micro"
        case .mini: return "Mini"
        }
    }

    public var onnxFileName: String {
        switch self {
        case .nano, .nanoInt8: return "kitten_tts_nano_v0_8.onnx"
        case .micro: return "kitten_tts_micro_v0_8.onnx"
        case .mini: return "kitten_tts_mini_v0_8.onnx"
        }
    }

    public var voicesFileName: String { "voices.npz" }

    public var huggingFaceRepo: String { "KittenML/\(rawValue)" }
}
