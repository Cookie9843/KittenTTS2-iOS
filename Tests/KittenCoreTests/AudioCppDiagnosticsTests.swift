import XCTest
@testable import KittenCore

final class AudioCppDiagnosticsTests: XCTestCase {
    func testUpstreamTwoGiBRequestIsBoundedToMetadataSize() {
        let requested: UInt64 = 2048 * 1024 * 1024
        XCTAssertEqual(AudioCppArena.bounded(requested: requested), AudioCppArena.maxMetadataBytes)
        XCTAssertEqual(AudioCppArena.bounded(requested: 4 * 1024 * 1024), 4 * 1024 * 1024)
    }

    func testWholeModelTensorHeadersFitBoundedArena() {
        // The published GGUF has 2856 tensors in total, so every store (a subset) fits.
        XCTAssertLessThan(AudioCppArena.headerBytes(tensorCount: 2856), 2 * 1024 * 1024)
        XCTAssertTrue(AudioCppArena.fits(tensorCount: 2856))
        XCTAssertFalse(AudioCppArena.fits(tensorCount: 200_000))
    }

    func testNoFileBannerIsActionableAndDisownsOldLogs() {
        let b = AudioCppDiagnostics.attemptBanner(fileName: "(none)", validationRan: false, loadAttempted: false)
        XCTAssertTrue(b.contains("NO") || b.contains("NONE"))
        XCTAssertTrue(b.contains("Choose GGUF"))
        XCTAssertTrue(b.contains("NOT from this attempt"))
        XCTAssertEqual(b, AudioCppDiagnostics.attemptBanner(fileName: nil, validationRan: false, loadAttempted: false))
    }

    func testBannerProgressesWithAttempt() {
        XCTAssertTrue(AudioCppDiagnostics.attemptBanner(fileName: "m.gguf", validationRan: false, loadAttempted: false).contains("not finished"))
        XCTAssertTrue(AudioCppDiagnostics.attemptBanner(fileName: "m.gguf", validationRan: true, loadAttempted: false).contains("not been started"))
        XCTAssertTrue(AudioCppDiagnostics.attemptBanner(fileName: "m.gguf", validationRan: true, loadAttempted: true).contains("was started"))
    }

    func testPreviousRunNoteLabelsAbortAndCleanExit() {
        XCTAssertNil(AudioCppDiagnostics.previousRunNote(stage: nil, nativeLog: "stale GGML_ASSERT"))
        let log = "ggml_aligned_malloc: insufficient memory\nKT_NATIVE_ABORT: ggml.c:1685: GGML_ASSERT(ctx->mem_buffer != NULL) failed\n"
        let note = AudioCppDiagnostics.previousRunNote(stage: "native model load", nativeLog: log)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.hasPrefix("PREVIOUS RUN (not the current attempt)"))
        XCTAssertTrue(note!.contains("cannot be caught by Swift"))
        XCTAssertTrue(note!.contains("GGML_ASSERT(ctx->mem_buffer != NULL)"))
        let silent = AudioCppDiagnostics.previousRunNote(stage: "native model load", nativeLog: "")
        XCTAssertTrue(silent!.contains("memory pressure"))
    }

    func testEncoderArenaReservationWasThreeAndAHalfGiBAndIsNowBounded() {
        XCTAssertEqual(AudioCppSynthesisArenas.requestedEncoderBytes, 3648 * AudioCppSynthesisArenas.mib)
        XCTAssertLessThan(AudioCppSynthesisArenas.patchedEncoderBytes * 5, AudioCppSynthesisArenas.requestedEncoderBytes)
        XCTAssertEqual(AudioCppSynthesisArenas.peakReservationBytes, 646 * AudioCppSynthesisArenas.mib)
    }

    func testSynthesisPreflightRefusesOnlyWhenKnownHeadroomIsTooSmall() {
        let mib = AudioCppSynthesisArenas.mib
        XCTAssertFalse(SynthesisPreflight.assess(availableMemory: 100 * mib).canProceed)
        XCTAssertTrue(SynthesisPreflight.assess(availableMemory: 100 * mib).message.contains("refused"))
        XCTAssertTrue(SynthesisPreflight.assess(availableMemory: 2048 * mib).canProceed)
        XCTAssertTrue(SynthesisPreflight.assess(availableMemory: nil).canProceed)
        XCTAssertTrue(SynthesisPreflight.assess(availableMemory: 0).canProceed)
    }

    func testFailedAllocationSizeIsParsedFromUserLog() {
        let log = "ggml_aligned_malloc: insufficient memory (attempted to allocate 128.00 MB)\nKT_NATIVE_ABORT: /x/ggml.c:1685: GGML_ASSERT(ctx->mem_buffer != NULL) failed\n"
        XCTAssertEqual(AudioCppDiagnostics.failedAllocationMB(in: log), "128.00")
        XCTAssertNil(AudioCppDiagnostics.failedAllocationMB(in: "all fine"))
    }

    func testSynthesisStageCrashIsNotDescribedAsLoadFailure() {
        let log = "ggml_aligned_malloc: insufficient memory (attempted to allocate 128.00 MB)\nKT_NATIVE_ABORT: ggml.c:1685: GGML_ASSERT(ctx->mem_buffer != NULL) failed\n"
        let note = AudioCppDiagnostics.previousRunNote(stage: "native synthesis (2026-10-09T19:09:24Z)", nativeLog: log)!
        XCTAssertTrue(note.hasPrefix("PREVIOUS RUN (not the current attempt)"))
        XCTAssertTrue(note.contains("not a model-load failure"))
        XCTAssertTrue(note.contains("malloc of 128.00 MB failed"))
        let load = AudioCppDiagnostics.previousRunNote(stage: "native model load (x)", nativeLog: log)!
        XCTAssertFalse(load.contains("not a model-load failure"))
    }

    func testHiftArenaRequestScaledWithTextLengthAndIsNowCapped() {
        let mib = AudioCppSynthesisArenas.mib
        let tenSeconds = AudioCppHiftArena.frames(forSeconds: 10)
        XCTAssertEqual(tenSeconds, 500)
        // upstream: 512 MiB + 4 MiB x 500 frames = 2.5 GiB malloc for a ~10 s utterance
        XCTAssertEqual(AudioCppHiftArena.upstreamBytes(frames: tenSeconds), (512 + 2000) * mib)
        XCTAssertEqual(AudioCppHiftArena.patchedBytes(frames: tenSeconds), 128 * mib)
        XCTAssertEqual(AudioCppHiftArena.patchedBytes(frames: 1), 128 * mib)
        // the patched request never depends on the text length
        XCTAssertEqual(AudioCppHiftArena.patchedBytes(frames: 50), AudioCppHiftArena.patchedBytes(frames: 5000))
        XCTAssertLessThanOrEqual(AudioCppHiftArena.patchedBytes(frames: 5000), AudioCppHiftArena.patchedCapBytes)
    }
}
