import Foundation
import KittenCore
import Speech

/// On-device draft transcription of the reference clip with Apple's Speech framework. Recognition is forced on-device
/// (`requiresOnDeviceRecognition`), so the recording is never sent to a server; when a language has no on-device model the
/// feature reports itself unavailable instead of falling back to the network.
enum ReferenceTranscriber {
    enum Outcome {
        case text(String)
        case unavailable(TranscriptionAvailability)
        case nothingRecognized
    }

    private static func recognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    private static var languageName: String {
        let id = Locale.current.identifier
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Cheap checks that need no permission prompt.
    static func availability() -> TranscriptionAvailability {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied: return .permissionDenied
        case .restricted: return .permissionRestricted
        default: break
        }
        guard let recognizer = recognizer() else { return .recognizerUnavailable(language: languageName) }
        guard recognizer.supportsOnDeviceRecognition else { return .notOnDevice(language: languageName) }
        guard recognizer.isAvailable else { return .recognizerUnavailable(language: languageName) }
        return .available
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Transcribes the normalized preview WAV of the reference clip. Throws only for unexpected recognizer errors.
    static func transcribe(fileAt url: URL) async throws -> Outcome {
        let status = SFSpeechRecognizer.authorizationStatus() == .notDetermined
            ? await requestAuthorization() : SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized: break
        case .denied: return .unavailable(.permissionDenied)
        default: return .unavailable(.permissionRestricted)
        }
        guard let recognizer = recognizer(), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            return .unavailable(availability())
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let job = RecognitionJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                job.start(recognizer: recognizer, request: request, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// Owns one recognition task and guarantees its continuation is resumed exactly once.
private final class RecognitionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<ReferenceTranscriber.Outcome, Error>?
    private var cancelled = false

    func start(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest,
               continuation: CheckedContinuation<ReferenceTranscriber.Outcome, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString
                self.finish(.success(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingRecognized : .text(text)))
            } else if let error {
                self.finish(.failure(error))
            }
        }
        lock.lock(); self.task = task; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ReferenceTranscriber.Outcome, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
