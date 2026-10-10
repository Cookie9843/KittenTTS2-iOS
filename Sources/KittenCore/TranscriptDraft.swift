import Foundation

/// The transcript that goes with a cloning reference clip. Text produced by speech recognition is only a draft: it can be
/// wrong, and a wrong transcript degrades the cloned voice, so it never counts as usable until the person has either edited
/// it or explicitly confirmed it. Text the person typed themselves is never overwritten by a recognition result.
public struct TranscriptDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Nothing yet, or typed by the person.
        case typed
        /// Filled in by on-device speech recognition and not changed since.
        case recognized
    }

    public private(set) var text: String
    public private(set) var source: Source
    public private(set) var confirmed: Bool

    public init(text: String = "") {
        self.text = text
        source = .typed
        confirmed = true
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isEmpty: Bool { trimmed.isEmpty }
    /// Recognized text the person has neither edited nor confirmed yet.
    public var needsReview: Bool { source == .recognized && !confirmed && !isEmpty }
    /// May be sent to the cloning engine.
    public var isUsable: Bool { !isEmpty && !needsReview }

    /// The person typed or changed text (including deleting it). Editing recognized text counts as reviewing it.
    public mutating func userEdited(_ newText: String) {
        guard newText != text else { return }
        text = newText
        source = .typed
        confirmed = true
    }

    /// The person read the recognized text and says it matches the clip.
    public mutating func confirm() { confirmed = true }

    /// Stores a recognition result. Returns false (and changes nothing) when the person already typed text and did not ask
    /// to replace it, or when the result is blank.
    @discardableResult
    public mutating func applyRecognized(_ recognized: String, replacingTyped: Bool = false) -> Bool {
        let clean = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if source == .typed && !isEmpty && !replacingTyped { return false }
        text = clean
        source = .recognized
        confirmed = false
        return true
    }

    /// The clip changed: a recognized draft belongs to the old clip and is dropped; typed text is kept.
    public mutating func clipChanged() {
        if source == .recognized { self = TranscriptDraft() }
    }
}

/// Why on-device recognition cannot run, in words for the screen. `nil` means it can.
public enum TranscriptionAvailability: Equatable, Sendable {
    case available
    case permissionDenied
    case permissionRestricted
    case recognizerUnavailable(language: String)
    case notOnDevice(language: String)

    public var message: String? {
        switch self {
        case .available: return nil
        case .permissionDenied:
            return "Speech recognition is turned off for this app. Enable it in Settings > Privacy > Speech Recognition, or type the transcript yourself."
        case .permissionRestricted:
            return "Speech recognition is restricted on this device. Type the transcript yourself."
        case .recognizerUnavailable(let language):
            return "Speech recognition is not available right now for \(language). Type the transcript yourself."
        case .notOnDevice(let language):
            return "On-device speech recognition is not available for \(language) on this device, and the app never sends your recording to a server. Type the transcript yourself."
        }
    }
}

/// Fixed wording for the review cue so the screen and tests agree.
public enum TranscriptCopy {
    public static let reviewCue = "Review the transcript before generating. Automatic recognition can mishear words and often leaves out or misplaces punctuation. Listen to the reference clip and correct both the wording and the punctuation before you confirm it or generate speech; a wrong transcript makes the cloned voice worse."
    public static let privacyNote = "Automatic transcription runs on this device with Apple’s speech recognition and is only used when you tap Transcribe. Your recording is not uploaded."
}
