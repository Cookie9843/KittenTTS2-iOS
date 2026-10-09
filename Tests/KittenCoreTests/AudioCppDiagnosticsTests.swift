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
}
