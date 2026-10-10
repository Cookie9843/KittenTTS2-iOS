import XCTest
@testable import KittenCore

final class TranscriptDraftTests: XCTestCase {
    func testRecognizedTextNeedsReviewBeforeItIsUsable() {
        var draft = TranscriptDraft()
        XCTAssertFalse(draft.isUsable)
        XCTAssertTrue(draft.applyRecognized("  hello there  "))
        XCTAssertEqual(draft.text, "hello there")
        XCTAssertEqual(draft.source, .recognized)
        XCTAssertTrue(draft.needsReview)
        XCTAssertFalse(draft.isUsable, "an unreviewed ASR result must not be treated as ground truth")
        draft.confirm()
        XCTAssertFalse(draft.needsReview)
        XCTAssertTrue(draft.isUsable)
    }

    func testEditingRecognizedTextCountsAsReview() {
        var draft = TranscriptDraft()
        draft.applyRecognized("helo there")
        draft.userEdited("hello there")
        XCTAssertEqual(draft.source, .typed)
        XCTAssertFalse(draft.needsReview)
        XCTAssertTrue(draft.isUsable)
    }

    func testRecognitionNeverOverwritesTypedTextUnlessAskedTo() {
        var draft = TranscriptDraft()
        draft.userEdited("what I typed")
        XCTAssertFalse(draft.applyRecognized("something else"))
        XCTAssertEqual(draft.text, "what I typed")
        XCTAssertTrue(draft.applyRecognized("something else", replacingTyped: true))
        XCTAssertEqual(draft.text, "something else")
        XCTAssertTrue(draft.needsReview)
    }

    func testBlankRecognitionChangesNothingAndLeavesManualEntryOpen() {
        var draft = TranscriptDraft()
        XCTAssertFalse(draft.applyRecognized("   \n"))
        XCTAssertTrue(draft.isEmpty)
        XCTAssertFalse(draft.needsReview)
        draft.userEdited("typed by hand")
        XCTAssertTrue(draft.isUsable)
    }

    func testRecognizedDraftIsDroppedWhenTheClipChangesButTypedTextIsKept() {
        var recognized = TranscriptDraft()
        recognized.applyRecognized("old clip")
        recognized.clipChanged()
        XCTAssertTrue(recognized.isEmpty)
        XCTAssertFalse(recognized.needsReview)

        var typed = TranscriptDraft(text: "mine")
        typed.clipChanged()
        XCTAssertEqual(typed.text, "mine")
    }

    func testClearingRecognizedTextByHandLeavesNothingToReview() {
        var draft = TranscriptDraft()
        draft.applyRecognized("wrong")
        draft.userEdited("")
        XCTAssertTrue(draft.isEmpty)
        XCTAssertFalse(draft.needsReview)
        XCTAssertFalse(draft.isUsable)
    }

    func testAvailabilityMessagesExplainTheFallback() {
        XCTAssertNil(TranscriptionAvailability.available.message)
        for state in [TranscriptionAvailability.permissionDenied, .permissionRestricted,
                      .recognizerUnavailable(language: "French"), .notOnDevice(language: "French")] {
            XCTAssertTrue(state.message?.contains("transcript yourself") ?? false, "\(state)")
        }
        XCTAssertTrue(TranscriptionAvailability.notOnDevice(language: "French").message!.contains("never sends"))
    }

    func testReviewCueIsExplicit() {
        XCTAssertTrue(TranscriptCopy.reviewCue.contains("Review the transcript before generating"))
        XCTAssertTrue(TranscriptCopy.reviewCue.contains("can be wrong"))
        XCTAssertTrue(TranscriptCopy.privacyNote.contains("on this device"))
    }
}
