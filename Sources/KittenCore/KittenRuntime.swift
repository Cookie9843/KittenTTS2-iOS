import Foundation
import CKittenBridge

/// Which native components of the KittenTTS 2 pipeline are actually linked into this build.
public struct RuntimeCapabilities: Equatable, Sendable {
    public var llamaForkLinked: Bool
    public var tq2_1Supported: Bool
    public var decoderLinked: Bool
    public var textNormalizerLinked: Bool

    public init(llamaForkLinked: Bool, tq2_1Supported: Bool, decoderLinked: Bool, textNormalizerLinked: Bool) {
        self.llamaForkLinked = llamaForkLinked
        self.tq2_1Supported = tq2_1Supported
        self.decoderLinked = decoderLinked
        self.textNormalizerLinked = textNormalizerLinked
    }

    public var isComplete: Bool { llamaForkLinked && tq2_1Supported && decoderLinked && textNormalizerLinked }

    /// Components that are still missing, in pipeline order.
    public var missing: [String] {
        var out: [String] = []
        if !llamaForkLinked { out.append("custom llama.cpp fork (iOS arm64 build)") }
        if !tq2_1Supported { out.append("TQ2_1 tensor support") }
        if !textNormalizerLinked { out.append("kitten-text-processing normalizer") }
        if !decoderLinked { out.append("decoder.pt executor (no supported iOS LibTorch/ExecuTorch path verified)") }
        return out
    }
}

public enum KittenRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(missing: [String])
    case invalidArgument
    case bridgeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let missing):
            return "KittenTTS 2 generation is disabled: unverified native components: \(missing.joined(separator: "; "))."
        case .invalidArgument: return "Invalid argument passed to the native bridge."
        case .bridgeFailure(let message): return message
        }
    }
}

/// Mockable seam over the native runtime.
public protocol KittenRuntime {
    var capabilities: RuntimeCapabilities { get }
    /// Returns mono float PCM or throws. Implementations must never return fabricated audio.
    func generate(modelDirectory: URL, text: String) throws -> [Float]
}

/// Swift wrapper over the C bridge (`CKittenBridge`). In this prototype it reports every component as unlinked.
public struct NativeKittenRuntime: KittenRuntime {
    public static let maxSamples = 24_000 * 60

    public init() {}

    public static var abiVersion: Int { Int(kitten_bridge_abi_version()) }

    public var capabilities: RuntimeCapabilities {
        let caps = kitten_bridge_get_capabilities()
        return RuntimeCapabilities(llamaForkLinked: caps.llama_fork_linked != 0, tq2_1Supported: caps.tq2_1_supported != 0,
                                   decoderLinked: caps.decoder_linked != 0, textNormalizerLinked: caps.text_normalizer_linked != 0)
    }

    public func generate(modelDirectory: URL, text: String) throws -> [Float] {
        var samples = [Float](repeating: 0, count: Self.maxSamples)
        var count = 0
        let status = samples.withUnsafeMutableBufferPointer { buffer in
            kitten_bridge_generate(modelDirectory.path, text, buffer.baseAddress, buffer.count, &count)
        }
        switch status {
        case KITTEN_BRIDGE_OK:
            guard count <= samples.count else { throw KittenRuntimeError.bridgeFailure("Bridge reported more samples than capacity.") }
            return Array(samples.prefix(count))
        case KITTEN_BRIDGE_ERR_INVALID_ARGUMENT: throw KittenRuntimeError.invalidArgument
        case KITTEN_BRIDGE_ERR_UNAVAILABLE: throw KittenRuntimeError.unavailable(missing: capabilities.missing)
        default: throw KittenRuntimeError.bridgeFailure(String(cString: kitten_bridge_status_message(status)))
        }
    }
}
