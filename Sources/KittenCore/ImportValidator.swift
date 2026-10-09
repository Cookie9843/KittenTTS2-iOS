import Foundation

public struct ValidationIssue: Error, Equatable, Sendable {
    public var title: String
    public var explanation: String
    public var expected: String
    public var nextSteps: String

    public var message: String {
        "\(title)\n\n\(explanation)\n\nExpected: \(expected)\n\nWhat to do: \(nextSteps)"
    }
}

/// One validated file and the name it will be stored under.
public struct PlannedFile: Equatable, Sendable {
    public var source: URL
    public var storedName: String
    public var size: Int64
}

public struct ImportPlan: Equatable, Sendable {
    public var family: ModelFamily
    public var legacyVariant: LegacyVariant?
    /// Directory relative to the model root, e.g. `kitten2` or `legacy08/kitten-tts-mini-0.8`.
    public var destination: String
    public var files: [PlannedFile]
    /// Non-fatal caveats (missing optional assets, large size, quantization notes).
    public var notes: [String]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ImportValidator {
    public static let legacyMaxBytes: Int64 = 512 * 1024 * 1024
    public static let kitten2ModelName = "model.gguf"
    public static let kitten2DecoderName = "decoder.pt"

    public static func describe(_ file: DetectedFile) -> String {
        switch file.format {
        case .gguf(let info):
            return "a GGUF file (architecture: \(info.architecture ?? "unknown"), type: \(info.fileTypeName ?? "unknown"))"
        case .onnx: return "an ONNX model"
        case .npz: return "a NumPy .npz archive"
        case .torchArchive: return "a PyTorch/TorchScript archive"
        case .zipOther: return "a ZIP archive"
        case .safetensors: return "a safetensors checkpoint"
        case .json: return "a JSON file"
        case .empty: return "an empty file"
        case .unknown: return "an unrecognized binary file"
        }
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return String(format: "%.2f GB", value / 1_073_741_824) }
        return String(format: "%.0f MB", value / 1_048_576)
    }

    public static func validate(urls: [URL], family: ModelFamily, legacyVariant: LegacyVariant = .nano) -> Result<ImportPlan, ValidationIssue> {
        guard !urls.isEmpty else {
            return .failure(ValidationIssue(
                title: "No files selected",
                explanation: "Nothing was chosen to import.",
                expected: family.expectedFilesDescription,
                nextSteps: "Pick the file(s) again."))
        }
        var detected: [DetectedFile] = []
        for url in urls {
            do { detected.append(try FileFormatDetector.detect(url: url)) } catch {
                return .failure(ValidationIssue(
                    title: "Could not read \(url.lastPathComponent)",
                    explanation: error.localizedDescription,
                    expected: family.expectedFilesDescription,
                    nextSteps: "Make sure the file is fully downloaded in the Files app (not an iCloud placeholder) and try again."))
            }
        }
        switch family {
        case .kitten2: return validateKitten2(detected)
        case .legacy08: return validateLegacy(detected, variant: legacyVariant)
        }
    }

    // MARK: KittenTTS 2

    private static func validateKitten2(_ files: [DetectedFile]) -> Result<ImportPlan, ValidationIssue> {
        let family = ModelFamily.kitten2
        func fail(_ title: String, _ explanation: String, _ next: String) -> Result<ImportPlan, ValidationIssue> {
            .failure(ValidationIssue(title: title, explanation: explanation, expected: family.expectedFilesDescription, nextSteps: next))
        }
        var planned: [PlannedFile] = []
        var notes: [String] = []
        var gguf: DetectedFile?
        var haveDecoder = false, haveVoices = false, haveConfig = false

        for file in files {
            switch file.format {
            case .gguf(let info):
                if gguf != nil { return fail("More than one GGUF selected", "Only one KittenTTS 2 language-model GGUF can be installed at a time.", "Select a single .gguf.") }
                if let arch = info.architecture, arch != "qwen3" {
                    return fail("This GGUF is not a KittenTTS 2 model",
                                "\(file.name) declares architecture “\(arch)”. KittenTTS 2's language model is built on the qwen3 architecture and exported by kitten-tts-2-cpp.",
                                "Use the GGUF published under cpp/ in the KittenML/kitten-tts-2 repository (model-tq2_1.gguf, ~1.03 GB).")
                }
                gguf = file
                planned.append(PlannedFile(source: file.url, storedName: kitten2ModelName, size: file.size))
                notes.append(contentsOf: kitten2Notes(file, info))
            case .torchArchive:
                if haveDecoder { return fail("More than one decoder selected", "Only one TorchScript decoder can be installed.", "Select a single decoder.pt.") }
                haveDecoder = true
                planned.append(PlannedFile(source: file.url, storedName: kitten2DecoderName, size: file.size))
            case .json:
                guard file.size <= 64 * 1024 * 1024, let object = (try? Data(contentsOf: file.url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else {
                    return fail("Invalid JSON: \(file.name)", "The file is not a valid JSON object.", "Re-download it from the model repository.")
                }
                if object["type"] as? String == "KITTEN2" {
                    haveConfig = true
                    planned.append(PlannedFile(source: file.url, storedName: "config.json", size: file.size))
                } else if object["type"] == nil {
                    haveVoices = true
                    planned.append(PlannedFile(source: file.url, storedName: "voices.json", size: file.size))
                } else {
                    return fail("Not a KittenTTS 2 config", "\(file.name) has type “\(object["type"] ?? "")” instead of KITTEN2.", "Use config.json from KittenML/kitten-tts-2.")
                }
            case .onnx, .npz:
                return fail("This is a KittenTTS 0.8 (original) file, not KittenTTS 2",
                            "\(file.name) is \(describe(file)) (\(formatBytes(file.size))). KittenTTS 2 models are GGUF files, so this file belongs to the original 0.8 family.",
                            "Switch the family picker to “\(ModelFamily.legacy08.displayName)” to import it there, or pick the KittenTTS 2 .gguf instead.")
            case .safetensors:
                return fail("This is a Python/PyTorch checkpoint, not a GGUF",
                            "\(file.name) is a safetensors checkpoint (\(formatBytes(file.size))). The on-device-oriented KittenTTS 2 runtime reads the pre-exported GGUF, not the raw checkpoint.",
                            "Download cpp/model-tq2_1.gguf (and cpp/<decoder>/decoder.pt, voices.json) from KittenML/kitten-tts-2, or export with kitten-tts-2-cpp's tools/kitten-tts/export.py.")
            case .zipOther:
                return fail("Unsupported archive", "\(file.name) is a ZIP archive that is neither a TorchScript decoder nor an .npz.", "Unzip it and select the individual files.")
            case .empty:
                return fail("\(file.name) is empty", "The file has no data, so the download probably failed.", "Download it again.")
            case .unknown:
                return fail("Unrecognized file: \(file.name)",
                            "It is \(formatBytes(file.size)) but has no GGUF header, so it cannot be a KittenTTS 2 model. Renaming a file to .gguf does not convert it.",
                            "Confirm the file is a GGUF produced for KittenTTS 2. If you are unsure where it came from, please share its download link or filename in the project's issue tracker.")
            }
        }
        guard gguf != nil else {
            return fail("No KittenTTS 2 GGUF selected", "KittenTTS 2 cannot be installed without its language-model .gguf.", "Select the .gguf together with any decoder.pt / voices.json / config.json.")
        }
        var missing: [String] = []
        if !haveDecoder { missing.append("decoder.pt (TorchScript S3 decoder)") }
        if !haveVoices { missing.append("voices.json") }
        if !haveConfig { missing.append("config.json") }
        if !missing.isEmpty {
            notes.append("Missing optional assets: \(missing.joined(separator: ", ")). Upstream's runtime needs them for synthesis.")
        }
        notes.append("Storage: \(formatBytes(planned.reduce(0) { $0 + $1.size })) is needed while importing (the previous install is kept until the copy succeeds).")
        if let blocker = family.runtimeBlocker { notes.append(blocker) }
        return .success(ImportPlan(family: family, legacyVariant: nil, destination: "kitten2", files: planned, notes: notes))
    }

    private static func kitten2Notes(_ file: DetectedFile, _ info: GGUFInfo) -> [String] {
        var notes: [String] = []
        switch info.fileType {
        case 42: notes.append("Format: lossless TQ2_1 (~1.03 GB). Requires KittenML's llama.cpp fork; stock llama.cpp cannot load it.")
        case 2: notes.append("Format: ternary Q4_0 (~1.45 GB).")
        case 1: notes.append("Format: FP16 reference export (~3.47 GB upstream). Its size makes it impractical to run in iPhone memory alongside the decoder.")
        default: notes.append("Quantization \(info.fileTypeName ?? "unknown") is not one of the exports documented by kitten-tts-2-cpp (TQ2_1, Q4_0, F16); third-party conversions are not guaranteed to work.")
        }
        if info.architecture == nil { notes.append("The GGUF's architecture could not be read, so it could not be confirmed as KittenTTS 2.") }
        return notes
    }

    // MARK: Legacy 0.8

    private static func validateLegacy(_ files: [DetectedFile], variant: LegacyVariant) -> Result<ImportPlan, ValidationIssue> {
        let family = ModelFamily.legacy08
        func fail(_ title: String, _ explanation: String, _ next: String) -> Result<ImportPlan, ValidationIssue> {
            .failure(ValidationIssue(title: title, explanation: explanation, expected: "\(variant.onnxFileName) and \(variant.voicesFileName) for \(variant.displayName) (\(family.displayName)).", nextSteps: next))
        }
        var onnx: DetectedFile?, voices: DetectedFile?
        for file in files {
            switch file.format {
            case .onnx:
                if file.size > legacyMaxBytes {
                    return fail("ONNX file is too large for KittenTTS 0.8", "\(file.name) is \(formatBytes(file.size)); 0.8 checkpoints are 25–80 MB.", "Check you picked the right file.")
                }
                if onnx != nil { return fail("More than one .onnx selected", "Select a single model file.", "Pick one .onnx and one voices.npz.") }
                onnx = file
            case .npz(let entries):
                guard entries.contains(where: { $0.hasPrefix("expr-voice-") }) else {
                    return fail("Voices archive has no KittenTTS voices", "\(file.name) is an .npz but contains no expr-voice-* embeddings.", "Use voices.npz from the matching KittenML/\(variant.rawValue) repository.")
                }
                if voices != nil { return fail("More than one voices archive selected", "Select a single voices.npz.", "Pick one .onnx and one voices.npz.") }
                voices = file
            case .gguf:
                return fail("This is a GGUF (KittenTTS 2 format), not a KittenTTS 0.8 model",
                            "\(file.name) is \(describe(file)) at \(formatBytes(file.size)). The KittenTTS-swift ONNX SDK cannot load GGUF files, and 0.8 models are only 25–80 MB.",
                            "Switch the family picker to “\(ModelFamily.kitten2.displayName)” to validate it, or pick an ONNX + voices.npz pair.")
            case .safetensors, .torchArchive, .zipOther, .json, .unknown, .empty:
                return fail("Unsupported file: \(file.name)", "It is \(describe(file)) (\(formatBytes(file.size))), which the ONNX-based 0.8 backend cannot use.", "Pick the .onnx model and voices.npz from the matching KittenML repository.")
            }
        }
        guard let model = onnx else { return fail("Missing .onnx model", "A KittenTTS 0.8 install needs the ONNX model.", "Select the .onnx together with voices.npz.") }
        guard let voiceFile = voices else { return fail("Missing voices.npz", "A KittenTTS 0.8 install needs its voice embeddings.", "Select voices.npz together with the .onnx.") }
        let planned = [
            PlannedFile(source: model.url, storedName: variant.onnxFileName, size: model.size),
            PlannedFile(source: voiceFile.url, storedName: variant.voicesFileName, size: voiceFile.size),
        ]
        return .success(ImportPlan(family: family, legacyVariant: variant, destination: "legacy08/\(variant.rawValue)", files: planned, notes: []))
    }
}
