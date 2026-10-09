import Foundation

/// Mirrors the cap applied by scripts/patches/audiocpp-weight-store-metadata-arena.patch to audio.cpp's
/// `BackendWeightStore`. That store's ggml context is created with `no_alloc = true`, so the arena only holds
/// tensor headers; weights live in a separate backend buffer. Upstream asked ggml_init() for up to 2 GiB per store.
public enum AudioCppArena {
    public static let maxMetadataBytes: UInt64 = 64 * 1024 * 1024
    /// ggml_tensor (368 bytes) + ggml_object (32 bytes), rounded up for alignment.
    public static let bytesPerTensorHeader: UInt64 = 448

    public static func bounded(requested: UInt64) -> UInt64 { min(requested, maxMetadataBytes) }

    public static func headerBytes(tensorCount: Int) -> UInt64 { UInt64(max(0, tensorCount)) * bytesPerTensorHeader }

    /// True when the bounded arena still holds every tensor header (with 2x headroom for derived tensors).
    public static func fits(tensorCount: Int) -> Bool { headerBytes(tensorCount: tensorCount) * 2 <= maxMetadataBytes }
}

/// ggml context arenas that audio.cpp's S3 flow encoder reserves up front while synthesizing (pinned revision
/// ad1473c, src/models/chatterbox/s3gen_flow.cpp). Every arena is `no_alloc = true`, i.e. headers only, but
/// `ggml_init` malloc()s the whole size and ten encoder layers (6 + 4) each hold an attention and a feed-forward one.
public enum AudioCppSynthesisArenas {
    public static let mib: UInt64 = 1024 * 1024
    public static let encoderLayers = 10
    /// Upstream request: embed/prelook 192 + layers x (attention 192 + feed-forward 128) + upsample 192 + after-norm 64 MiB.
    public static let requestedEncoderBytes: UInt64 = (192 + UInt64(encoderLayers) * (192 + 128) + 192 + 64) * mib
    /// Same arenas after scripts/patches/audiocpp-s3-flow-encoder-metadata-arena.patch (bound measured with
    /// ggml_graph_overhead_custom + 4 x nodes x ggml_tensor_overhead: 23.63 / 35.63 / 23.63 / 23.63 / 5.91 MiB per runner).
    public static let patchedEncoderBytes: UInt64 = 646 * mib
    /// The CFM flow decoder arena is created after the encoder arenas are released and is unchanged.
    public static let flowDecoderBytes: UInt64 = 512 * mib
    public static var peakReservationBytes: UInt64 { max(patchedEncoderBytes, flowDecoderBytes) }
}

/// Decides, before the uncatchable native call, whether synthesis may start.
public struct SynthesisPreflight: Equatable {
    public let canProceed: Bool
    public let message: String

    /// `availableMemory` is os_proc_available_memory() (nil/0 = unknown). Refuses only when the app is known to have
    /// less headroom than the largest arena the synthesis stage reserves.
    public static func assess(availableMemory: UInt64?) -> SynthesisPreflight {
        let need = AudioCppSynthesisArenas.peakReservationBytes
        guard let available = availableMemory, available > 0 else {
            return SynthesisPreflight(canProceed: true, message: "Synthesis preflight: available memory unknown; proceeding.")
        }
        let have = "\(available / AudioCppSynthesisArenas.mib) MiB available to the app"
        let want = "\(need / AudioCppSynthesisArenas.mib) MiB peak ggml arena reservation"
        if available < need {
            return SynthesisPreflight(canProceed: false, message: "Synthesis refused before starting: \(have), below the \(want). Starting would risk an unrecoverable GGML abort.")
        }
        return SynthesisPreflight(canProceed: true, message: "Synthesis preflight OK: \(have) vs \(want).")
    }
}

/// Freshness/labelling rules for the on-screen diagnostics so an old crash log cannot pass for the current attempt.
public enum AudioCppDiagnostics {
    public static func attemptBanner(fileName: String?, validationRan: Bool, loadAttempted: Bool) -> String {
        guard let fileName, !fileName.isEmpty, fileName != "(none)" else {
            return "CURRENT ATTEMPT: NONE. No model file is selected, so nothing was validated or loaded. Tap \"Choose GGUF…\" first. Anything labelled \"previous run\" below is NOT from this attempt."
        }
        if !validationRan { return "CURRENT ATTEMPT: \(fileName) selected; metadata validation has not finished yet." }
        if !loadAttempted { return "CURRENT ATTEMPT: \(fileName) validated; native load has not been started. Tap Load." }
        return "CURRENT ATTEMPT: \(fileName); native load was started in this run."
    }

    /// Text describing a previous run that ended without finishing, or nil when the last run ended cleanly.
    public static func previousRunNote(stage: String?, nativeLog: String) -> String? {
        guard let stage, !stage.isEmpty else { return nil }
        var note = "PREVIOUS RUN (not the current attempt) ended while in stage \"\(stage)\" without finishing."
        if stage.hasPrefix("native synthesis") {
            note += " Synthesis only starts after the native model load succeeded, so this is not a model-load failure."
        }
        if let abort = nativeAbort(in: nativeLog) {
            note += " Its native log shows an unrecoverable native abort (SIGABRT from a GGML assertion; it cannot be caught by Swift): \(abort)"
            if let mb = failedAllocationMB(in: nativeLog) {
                note += " GGML's malloc of \(mb) MB failed first (ggml_aligned_malloc: insufficient memory)."
            }
        } else {
            note += " iOS most likely terminated the app (memory pressure) or it crashed natively."
        }
        return note
    }

    /// Size in MB of the first "ggml_aligned_malloc: insufficient memory (attempted to allocate N MB)" line, if any.
    public static func failedAllocationMB(in log: String) -> String? {
        for line in log.split(whereSeparator: \.isNewline) where line.contains("insufficient memory") {
            guard let r = line.range(of: "attempted to allocate ") else { continue }
            let rest = line[r.upperBound...]
            if let end = rest.range(of: " MB") { return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// First native abort/assertion line in a log, if any.
    public static func nativeAbort(in log: String) -> String? {
        for line in log.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "KT_NATIVE_ABORT:") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
            if line.contains("GGML_ASSERT") { return String(line).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
