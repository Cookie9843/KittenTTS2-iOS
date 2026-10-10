import Foundation

// Inspection and validation of the community audio.cpp KittenTTS 2 single-file package
// (`dignome/kitten_tts2` -> `kitten-tts2-native-q8-multilingual.gguf`).
//
// This is NOT KittenML's `cpp/model-tq2_1.gguf` (architecture `qwen3`, TQ2_1 tensors, needs the
// custom llama.cpp fork + LibTorch). The audio.cpp package has `general.architecture = audiocpp`,
// embeds its model spec (`audiocpp.model_spec.*`) and sidecar files (`audiocpp.embedded_files.*`),
// and contains no TQ2_1 tensors. This file is intentionally self-contained (Foundation only) so the
// native test app can compile it directly with swiftc.

public enum AudioCppPackage {
    public static let publishedFileName = "kitten-tts2-native-q8-multilingual.gguf"
    public static let publishedSize: Int64 = 3_282_123_776
    public static let publishedSHA256 = "e97920ca5053f9fcd4de638dcd8114ed2510d4291a93257473a8843c3ff349ad"
    public static let family = "kitten_tts2"
    public static let architecture = "audiocpp"
    public static let sourceRepository = "https://huggingface.co/dignome/kitten_tts2"
    /// Files the model spec (`model_specs/kitten_tts2.json`, `sources[gguf]`) reads from the package.
    public static let expectedEmbeddedFiles = [
        "config.json", "lm/config.json", "lm/tokenizer_config.json", "lm/tokenizer.json", "cpp/default/voices.json",
    ]
}

public enum GGMLTensorType {
    /// Names for ggml tensor type ids (stable numbering used by GGUF).
    public static func name(_ id: UInt32) -> String {
        switch id {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 3: return "Q4_1"
        case 6: return "Q5_0"
        case 7: return "Q5_1"
        case 8: return "Q8_0"
        case 9: return "Q8_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K"
        case 12: return "Q4_K"
        case 13: return "Q5_K"
        case 14: return "Q6_K"
        case 15: return "Q8_K"
        case 24: return "I8"
        case 25: return "I16"
        case 26: return "I32"
        case 27: return "I64"
        case 28: return "F64"
        case 30: return "BF16"
        case 34: return "TQ1_0"
        case 35: return "TQ2_0"
        default: return "type\(id)"
        }
    }
}

public struct AudioCppGGUFReport: Equatable, Sendable {
    public var fileName: String
    public var fileSize: Int64
    public var version: UInt32
    public var kvCount: UInt64
    public var tensorCount: UInt64
    public var architecture: String?
    public var modelName: String?
    public var fileType: UInt32?
    public var tensorNameFormat: String?
    public var sourceFormat: String?
    public var weightType: String?
    public var specVersion: UInt32?
    public var specFamily: String?
    public var specJSONBytes: Int?
    public var embeddedFileNames: [String]
    public var embeddedDataBytes: UInt64
    /// Tensor count per ggml type name, e.g. `["Q8_0": 400, "F16": 12, "F32": 900]`.
    public var tensorTypeCounts: [String: Int]
    public var metadataKeys: [String]

    public var q8TensorCount: Int { tensorTypeCounts["Q8_0"] ?? 0 }
    /// Upstream KittenML TQ2_1 GGUFs carry `general.file_type = 42`; the audio.cpp package never does.
    public var looksLikeUpstreamTQ2_1: Bool { fileType == 42 }

    public var tensorTypeSummary: String {
        tensorTypeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}

public enum AudioCppGGUFKind: Equatable, Sendable {
    case audiocppKittenTTS2
    case audiocppOtherFamily(String?)
    case upstreamTQ2_1
    case otherGGUF(String?)
}

public enum AudioCppCheckStatus: String, Equatable, Sendable { case pass = "PASS", warn = "WARN", fail = "FAIL" }

public struct AudioCppCheck: Equatable, Sendable {
    public var name: String
    public var status: AudioCppCheckStatus
    public var detail: String
}

public struct AudioCppValidation: Equatable, Sendable {
    public var kind: AudioCppGGUFKind
    public var checks: [AudioCppCheck]
    /// Actionable text shown when the file is not the supported package.
    public var guidance: String?
    public var passed: Bool { !checks.contains { $0.status == .fail } }
    public var isPublishedFile: Bool
}

public enum AudioCppGGUFInspector {
    public enum InspectError: Error, Equatable, CustomStringConvertible {
        case notGGUF
        case truncated(String)
        public var description: String {
            switch self {
            case .notGGUF: return "Not a GGUF file (missing 'GGUF' magic)."
            case .truncated(let what): return "GGUF header is truncated or corrupt while reading \(what)."
            }
        }
    }

    private struct Reader {
        let data: Data
        var pos: Int = 0
        mutating func take(_ n: Int, _ what: String) throws -> Data {
            guard n >= 0, pos + n <= data.count else { throw InspectError.truncated(what) }
            defer { pos += n }
            return data[(data.startIndex + pos)..<(data.startIndex + pos + n)]
        }
        mutating func uint(_ width: Int, _ what: String) throws -> UInt64 {
            try take(width, what).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        mutating func string(_ what: String) throws -> String {
            let length = try uint(8, what)
            guard length < 64 * 1024 * 1024 else { throw InspectError.truncated(what) }
            return String(decoding: try take(Int(length), what), as: UTF8.self)
        }
        mutating func skip(_ n: UInt64, _ what: String) throws {
            guard n <= UInt64(data.count - pos) else { throw InspectError.truncated(what) }
            pos += Int(n)
        }
    }

    private static func scalarWidth(_ type: UInt32) -> Int? {
        switch type {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }

    private static func skipValue(_ r: inout Reader, type: UInt32, _ what: String) throws {
        if let width = scalarWidth(type) { try r.skip(UInt64(width), what); return }
        if type == 8 { try r.skip(try r.uint(8, what), what); return }
        guard type == 9 else { throw InspectError.truncated(what) }
        let elementType = UInt32(truncatingIfNeeded: try r.uint(4, what))
        let count = try r.uint(8, what)
        if let width = scalarWidth(elementType) {
            let (bytes, overflow) = count.multipliedReportingOverflow(by: UInt64(width))
            guard !overflow else { throw InspectError.truncated(what) }
            try r.skip(bytes, what)
            return
        }
        guard count < 50_000_000 else { throw InspectError.truncated(what) }
        for _ in 0..<count { try skipValue(&r, type: elementType, what) }
    }

    /// Parses the GGUF header, metadata and tensor-info table. Tensor data is never read; the file is
    /// memory-mapped so only the header pages are touched.
    public static func inspect(url: URL) throws -> AudioCppGGUFReport {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try inspect(data: data, fileName: url.lastPathComponent, fileSize: size > 0 ? size : Int64(data.count))
    }

    public static func inspect(data: Data, fileName: String, fileSize: Int64) throws -> AudioCppGGUFReport {
        var r = Reader(data: data)
        guard data.count >= 4, try r.take(4, "magic") == Data("GGUF".utf8) else { throw InspectError.notGGUF }
        let version = UInt32(truncatingIfNeeded: try r.uint(4, "version"))
        let tensorCount = try r.uint(8, "tensor count")
        let kvCount = try r.uint(8, "metadata count")
        guard kvCount < 1_000_000, tensorCount < 10_000_000 else { throw InspectError.truncated("counts") }
        var report = AudioCppGGUFReport(
            fileName: fileName, fileSize: fileSize, version: version, kvCount: kvCount, tensorCount: tensorCount,
            architecture: nil, modelName: nil, fileType: nil, tensorNameFormat: nil, sourceFormat: nil,
            weightType: nil, specVersion: nil, specFamily: nil, specJSONBytes: nil,
            embeddedFileNames: [], embeddedDataBytes: 0, tensorTypeCounts: [:], metadataKeys: [])

        for _ in 0..<kvCount {
            let key = try r.string("metadata key")
            let type = UInt32(truncatingIfNeeded: try r.uint(4, "metadata type"))
            report.metadataKeys.append(key)
            switch (key, type) {
            case ("general.architecture", 8): report.architecture = try r.string(key)
            case ("general.name", 8): report.modelName = try r.string(key)
            case ("general.file_type", 4): report.fileType = UInt32(truncatingIfNeeded: try r.uint(4, key))
            case ("audiocpp.tensor_name_format", 8): report.tensorNameFormat = try r.string(key)
            case ("audiocpp.source_format", 8): report.sourceFormat = try r.string(key)
            case ("audiocpp.weight_type", 8): report.weightType = try r.string(key)
            case ("audiocpp.model_spec.version", 4): report.specVersion = UInt32(truncatingIfNeeded: try r.uint(4, key))
            case ("audiocpp.model_spec.family", 8): report.specFamily = try r.string(key)
            case ("audiocpp.model_spec.json", 8):
                let before = r.pos
                try r.skip(try r.uint(8, key), key)
                report.specJSONBytes = r.pos - before - 8
            case ("audiocpp.embedded_files.names", 9):
                let elementType = UInt32(truncatingIfNeeded: try r.uint(4, key))
                let count = try r.uint(8, key)
                guard elementType == 8, count < 1_000_000 else { throw InspectError.truncated(key) }
                for _ in 0..<count { report.embeddedFileNames.append(try r.string(key)) }
            case ("audiocpp.embedded_files.data", 9):
                let save = r
                let elementType = UInt32(truncatingIfNeeded: try r.uint(4, key))
                let count = try r.uint(8, key)
                if elementType == 0 { report.embeddedDataBytes = count }
                r = save
                try skipValue(&r, type: type, key)
            default:
                try skipValue(&r, type: type, key)
            }
        }

        for _ in 0..<tensorCount {
            _ = try r.string("tensor name")
            let dims = try r.uint(4, "tensor dims")
            guard dims <= 8 else { throw InspectError.truncated("tensor dims") }
            try r.skip(dims * 8, "tensor shape")
            let type = UInt32(truncatingIfNeeded: try r.uint(4, "tensor type"))
            try r.skip(8, "tensor offset")
            report.tensorTypeCounts[GGMLTensorType.name(type), default: 0] += 1
        }
        return report
    }

    public static func validate(_ report: AudioCppGGUFReport, publishedSize: Int64 = AudioCppPackage.publishedSize) -> AudioCppValidation {
        var checks: [AudioCppCheck] = []
        func add(_ name: String, _ status: AudioCppCheckStatus, _ detail: String) {
            checks.append(AudioCppCheck(name: name, status: status, detail: detail))
        }

        let kind: AudioCppGGUFKind
        if report.architecture == AudioCppPackage.architecture {
            kind = report.specFamily == AudioCppPackage.family ? .audiocppKittenTTS2 : .audiocppOtherFamily(report.specFamily)
        } else if report.looksLikeUpstreamTQ2_1 {
            kind = .upstreamTQ2_1
        } else {
            kind = .otherGGUF(report.architecture)
        }

        add("GGUF container", report.version >= 2 && report.version <= 3 ? .pass : .warn,
            "GGUF v\(report.version), \(report.kvCount) metadata keys, \(report.tensorCount) tensors")
        add("general.architecture", report.architecture == AudioCppPackage.architecture ? .pass : .fail,
            "found \(report.architecture ?? "(missing)"), expected \(AudioCppPackage.architecture)")
        add("audiocpp.model_spec.family", report.specFamily == AudioCppPackage.family ? .pass : .fail,
            "found \(report.specFamily ?? "(missing)"), expected \(AudioCppPackage.family)")
        add("model spec embedded",
            (report.specVersion != nil && (report.specJSONBytes ?? 0) > 0) ? .pass : .fail,
            "version \(report.specVersion.map(String.init) ?? "(missing)"), JSON \(report.specJSONBytes.map { "\($0) bytes" } ?? "(missing)")")

        let weightLooksQ8 = (report.weightType ?? "").lowercased().contains("q8")
        let q8 = report.q8TensorCount
        let mixed = report.tensorTypeCounts.keys.filter { $0 != "Q8_0" }
        add("Q8 mixed precision", (weightLooksQ8 || q8 > 0) ? .pass : .fail,
            "weight_type \(report.weightType ?? "(missing)"); tensors: \(report.tensorTypeSummary.isEmpty ? "(none)" : report.tensorTypeSummary)")
        if q8 > 0 && mixed.isEmpty {
            add("Mixed precision shape", .warn, "all tensors are Q8_0; the published package keeps some tensors in F16/F32")
        }
        add("TQ2_1 tensors", .pass, "not applicable: the audio.cpp package has none (TQ2_1 belongs to KittenML's different runtime)")

        if report.embeddedFileNames.isEmpty {
            add("Embedded assets", .fail, "no audiocpp.embedded_files.names; this is not a standalone single-file package")
        } else {
            let missing = AudioCppPackage.expectedEmbeddedFiles.filter { expected in
                !report.embeddedFileNames.contains { $0 == expected || $0.hasSuffix("/" + expected) }
            }
            add("Embedded assets", missing.isEmpty ? .pass : .warn,
                "\(report.embeddedFileNames.count) embedded files (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: report.embeddedDataBytes), countStyle: .file)))"
                + (missing.isEmpty ? "" : "; not found by expected name: \(missing.joined(separator: ", ")); the native loader is the final judge"))
        }

        let isPublished = report.fileSize == publishedSize
        if report.fileSize < publishedSize && report.architecture == AudioCppPackage.architecture {
            add("File size", .fail, "\(report.fileSize) bytes is smaller than the published \(publishedSize); the download is probably incomplete")
        } else {
            add("File size", isPublished ? .pass : .warn,
                "\(report.fileSize) bytes; published \(publishedSize)" + (isPublished ? "" : " (different export; SHA-256 cannot match)"))
        }

        let guidance: String?
        switch kind {
        case .audiocppKittenTTS2:
            guidance = nil
        case .audiocppOtherFamily(let family):
            guidance = "This is an audio.cpp GGUF for family \(family ?? "unknown"), not kitten_tts2. This app supports the single-file \(AudioCppPackage.publishedFileName) package from \(AudioCppPackage.sourceRepository)."
        case .upstreamTQ2_1:
            guidance = "This looks like KittenML's upstream TQ2_1 GGUF (qwen3 + TQ2_1). It uses a different runtime and cannot run on audio.cpp, so this app does not support it. Choose the audio.cpp package \(AudioCppPackage.publishedFileName) from \(AudioCppPackage.sourceRepository) instead."
        case .otherGGUF(let arch):
            guidance = "This GGUF has architecture \(arch ?? "unknown") and is not an audio.cpp KittenTTS 2 package. Download \(AudioCppPackage.publishedFileName) (3.28 GB) from \(AudioCppPackage.sourceRepository) and select that single file."
        }
        return AudioCppValidation(kind: kind, checks: checks, guidance: guidance, isPublishedFile: isPublished)
    }
}

// MARK: - resource checks

public struct ResourceSnapshot: Equatable, Sendable {
    public var physicalMemory: UInt64
    /// `os_proc_available_memory()` on iOS (headroom before the per-app limit); nil where unavailable.
    public var availableMemory: UInt64?
    /// Free space where the runtime may extract embedded files (app temporary directory).
    public var freeStorage: Int64?
    public init(physicalMemory: UInt64, availableMemory: UInt64?, freeStorage: Int64?) {
        self.physicalMemory = physicalMemory; self.availableMemory = availableMemory; self.freeStorage = freeStorage
    }
}

public struct ResourceVerdict: Equatable, Sendable {
    public var refusals: [String]
    public var warnings: [String]
    public var canProceed: Bool { refusals.isEmpty }
}

public enum ResourceAdvisor {
    /// Margin added to extracted-asset estimates; empirical, not a guarantee.
    public static let storageMargin: Int64 = 256 * 1024 * 1024

    public static func assess(report: AudioCppGGUFReport, snapshot: ResourceSnapshot) -> ResourceVerdict {
        var refusals: [String] = [], warnings: [String] = []
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let size = UInt64(max(0, report.fileSize))
        let extracted = Int64(clamping: report.embeddedDataBytes)
        if let free = snapshot.freeStorage {
            let need = extracted + storageMargin
            if free < need {
                refusals.append("Only \(fmt(free)) of free storage; audio.cpp may extract the embedded files (\(fmt(extracted))) into temporary storage and needs about \(fmt(need)). Free up space and try again.")
            }
        } else {
            warnings.append("Free storage could not be determined.")
        }
        if snapshot.physicalMemory < size {
            refusals.append("This device has \(fmt(Int64(clamping: snapshot.physicalMemory))) of RAM, less than the \(fmt(report.fileSize)) model; refusing to map it.")
        }
        if let avail = snapshot.availableMemory {
            if avail < size {
                warnings.append("iOS reports \(fmt(Int64(clamping: avail))) of memory available to this app, less than the model size (\(fmt(report.fileSize))). Weights are memory-mapped and may still load, but the app can be terminated by iOS; this is empirical, not guaranteed.")
            }
        } else {
            warnings.append("Per-app memory headroom is not reported on this platform; whether the model fits is unknown until tried.")
        }
        return ResourceVerdict(refusals: refusals, warnings: warnings)
    }
}
