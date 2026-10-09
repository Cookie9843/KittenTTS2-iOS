import Foundation

public enum CheckStatus: String, Equatable, Sendable { case pass, warn, fail }

public struct BundleCheck: Equatable, Sendable {
    public var name: String
    public var status: CheckStatus
    public var detail: String
}

public struct BundleReport: Equatable, Sendable {
    public var checks: [BundleCheck]
    public var modelBytes: Int64
    public var quantization: String?

    /// All assets needed by upstream's runtime are present and consistent.
    public var isComplete: Bool { !checks.contains { $0.status == .fail } }

    public var summary: String {
        checks.map { check -> String in
            let mark = check.status == .pass ? "✓" : (check.status == .warn ? "!" : "✗")
            return "\(mark) \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}

/// Verifies an installed KittenTTS 2 directory (as laid out by `ImportValidator`) using metadata only.
public enum BundleVerifier {
    public static let fp16ReferenceBytes: Int64 = 3_470_000_000

    /// Actionable guidance for the quantization a GGUF declares.
    public static func quantizationGuidance(fileType: UInt32?, bytes: Int64) -> (status: CheckStatus, text: String) {
        switch fileType {
        case 42?:
            return (.pass, "TQ2_1 (~1.03 GB): the compact official export. Needs the KittenML llama.cpp fork; stock llama.cpp cannot load it.")
        case 2?:
            return (.pass, "Q4_0 (~1.45 GB): documented alternative export.")
        case 1?, 0?:
            let name = fileType == 1 ? "F16" : "F32"
            return (.warn, "\(name) reference export (\(ImportValidator.formatBytes(bytes))). This is the ~3.5 GB file, not the compact release. It is too large to run alongside the decoder on most iPads; use cpp/model-tq2_1.gguf (~1.03 GB) from KittenML/kitten-tts-2 instead.")
        case let other?:
            return (.warn, "Quantization file type \(other) is not an export documented by kitten-tts-2-cpp (TQ2_1, Q4_0, F16); it may not load.")
        case nil:
            if bytes >= 3_000_000_000 {
                return (.warn, "Quantization unreadable, but \(ImportValidator.formatBytes(bytes)) matches the ~3.5 GB FP16 reference size, not TQ2_1 (~1.03 GB). Use cpp/model-tq2_1.gguf.")
            }
            return (.warn, "Quantization could not be read from the GGUF header.")
        }
    }

    public static func verify(directory: URL) -> BundleReport {
        var checks: [BundleCheck] = []
        var modelBytes: Int64 = 0
        var quantization: String?
        func add(_ name: String, _ status: CheckStatus, _ detail: String) { checks.append(BundleCheck(name: name, status: status, detail: detail)) }
        func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func size(_ url: URL) -> Int64? {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
        }

        // Language model
        let modelURL = path(ImportValidator.kitten2ModelName)
        if let detected = try? FileFormatDetector.detect(url: modelURL) {
            modelBytes = detected.size
            if case .gguf(let info) = detected.format {
                if info.architecture == "qwen3" {
                    add("Architecture", .pass, "qwen3 (GGUF v\(info.version), \(info.tensorCount) tensors)")
                } else {
                    add("Architecture", .fail, "expected qwen3, found \(info.architecture ?? "unreadable")")
                }
                quantization = info.fileTypeName
                let g = quantizationGuidance(fileType: info.fileType, bytes: detected.size)
                add("Quantization", g.status, g.text)
            } else {
                add("Language model", .fail, "model.gguf is \(ImportValidator.describe(detected)), not a GGUF.")
            }
        } else {
            add("Language model", .fail, "model.gguf is missing. Import the GGUF (cpp/model-tq2_1.gguf).")
        }

        // Decoder
        let decoderURL = path(ImportValidator.kitten2DecoderName)
        if let detected = try? FileFormatDetector.detect(url: decoderURL) {
            if detected.format == .torchArchive {
                add("Decoder", .pass, "decoder.pt is a TorchScript archive (\(ImportValidator.formatBytes(detected.size))). Presence only; execution on iOS is unverified.")
            } else {
                add("Decoder", .fail, "decoder.pt is \(ImportValidator.describe(detected)), not a TorchScript archive.")
            }
        } else {
            add("Decoder", .fail, "decoder.pt is missing.")
        }

        // Voices
        if let data = try? Data(contentsOf: path("voices.json")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            add("Voices", .pass, "voices.json parsed (\(object.count) top-level entries)")
        } else {
            add("Voices", .fail, "voices.json missing or not a JSON object.")
        }

        // Config / tokenizer-related manifest
        if let data = try? Data(contentsOf: path("config.json")), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if config["type"] as? String == "KITTEN2" {
                add("Config", .pass, "config.json type KITTEN2")
                checks.append(contentsOf: manifestChecks(config: config, directory: directory))
            } else {
                add("Config", .fail, "config.json type is “\(config["type"] ?? "missing")”, expected KITTEN2.")
            }
        } else {
            add("Config", .fail, "config.json missing or invalid.")
        }
        add("Tokenizer", .warn, "Tokenizer data is embedded in the GGUF and the text normalizer ships with kitten-text-processing; neither is verified by this metadata check.")
        return BundleReport(checks: checks, modelBytes: modelBytes, quantization: quantization)
    }

    /// Cross-checks the upstream `cpp` manifest (size fields) against the stored files.
    private static func manifestChecks(config: [String: Any], directory: URL) -> [BundleCheck] {
        guard let cpp = config["cpp"] as? [String: Any] else {
            return [BundleCheck(name: "Manifest", status: .warn, detail: "config.json has no cpp manifest (legacy asset layout); sizes not cross-checked.")]
        }
        guard (cpp["version"] as? Int) == 1 else {
            return [BundleCheck(name: "Manifest", status: .fail, detail: "unsupported cpp manifest version \(cpp["version"] ?? "missing"); upstream runtime expects 1.")]
        }
        func actual(_ name: String) -> Int64? {
            ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value
        }
        func expected(_ entry: Any?) -> Int64? { ((entry as? [String: Any])?["size"] as? NSNumber)?.int64Value }
        let decoders = cpp["decoders"] as? [String: Any]
        let name = config["default_decoder"] as? String ?? "default"
        let decoder = decoders?[name] as? [String: Any]
        var out: [BundleCheck] = []
        let pairs: [(String, String, Int64?)] = [
            ("Manifest: GGUF size", ImportValidator.kitten2ModelName, expected(cpp["gguf"])),
            ("Manifest: decoder size", ImportValidator.kitten2DecoderName, expected(decoder?["torchscript"])),
            ("Manifest: voices size", "voices.json", expected(decoder?["voices"])),
        ]
        for (label, file, want) in pairs {
            guard let want else { out.append(BundleCheck(name: label, status: .warn, detail: "not listed in manifest for decoder “\(name)”.")); continue }
            guard let have = actual(file) else { continue }
            out.append(have == want
                ? BundleCheck(name: label, status: .pass, detail: "\(have) bytes match")
                : BundleCheck(name: label, status: .fail, detail: "\(file) is \(have) bytes, manifest says \(want); the file is truncated or from another revision."))
        }
        return out
    }
}

/// Heuristic memory/storage feasibility estimate. It cannot prove a model runs; only device testing can.
public enum DeviceBudget {
    public struct Assessment: Equatable, Sendable {
        public var verdict: CheckStatus
        public var text: String
    }

    /// - Parameters:
    ///   - modelBytes: size of the GGUF, mapped into memory.
    ///   - physicalMemory: `ProcessInfo.physicalMemory`.
    ///   - hasIncreasedMemoryEntitlement: whether `com.apple.developer.kernel.increased-memory-limit` is signed in.
    public static func assess(modelBytes: Int64, physicalMemory: UInt64, hasIncreasedMemoryEntitlement: Bool = false) -> Assessment {
        // iOS jetsam limits are not documented. Assume ~50% of RAM without the entitlement, ~75% with it.
        let fraction = hasIncreasedMemoryEntitlement ? 0.75 : 0.5
        let budget = Int64(Double(physicalMemory) * fraction)
        // Weights + decoder (~hundreds of MB, unmeasured) + KV cache/activations headroom.
        let overhead: Int64 = 1_000_000_000
        let need = modelBytes + overhead
        let gb = { (v: Int64) in String(format: "%.1f GB", Double(v) / 1_000_000_000) }
        if need <= budget {
            return Assessment(verdict: .pass, text: "Estimated need \(gb(need)) fits a heuristic budget of \(gb(budget)). Not measured: confirm on device.")
        }
        if need <= Int64(Double(physicalMemory) * 0.75) && !hasIncreasedMemoryEntitlement {
            return Assessment(verdict: .warn, text: "Estimated need \(gb(need)) exceeds the default budget of \(gb(budget)); it might fit only with the increased-memory-limit entitlement.")
        }
        return Assessment(verdict: .fail, text: "Estimated need \(gb(need)) exceeds the budget of \(gb(budget)) on this device; the model is too large to run reliably.")
    }
}

/// Single decision point for enabling KittenTTS 2 generation.
public enum GenerationGate {
    public static func evaluate(report: BundleReport, runtime: KittenRuntime) -> (enabled: Bool, reasons: [String]) {
        var reasons: [String] = []
        if !report.isComplete { reasons.append("Model bundle incomplete or inconsistent.") }
        reasons.append(contentsOf: runtime.capabilities.missing.map { "Missing native component: \($0)" })
        return (reasons.isEmpty, reasons)
    }
}
