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
        if let abort = nativeAbort(in: nativeLog) {
            note += " Its native log shows an unrecoverable native abort (SIGABRT from a GGML assertion; it cannot be caught by Swift): \(abort)"
        } else {
            note += " iOS most likely terminated the app (memory pressure) or it crashed natively."
        }
        return note
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
