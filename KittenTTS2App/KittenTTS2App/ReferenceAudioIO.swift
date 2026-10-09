import AVFoundation
import Foundation
import KittenCore

/// Turns user-selected audio files (WAV, M4A, MP3, CAF, …) into a mono `ReferenceClip` without loading more than
/// ~31 seconds of audio, and records new clips from the microphone.
enum ReferenceAudioIO {
    static func loadClip(from url: URL) throws -> ReferenceClip {
        if url.pathExtension.lowercased() == "wav", let clip = try? WAVDecoder.decode(url: url) { return clip }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { throw WAVDecodeError.empty }
        let seconds = Double(file.length) / rate
        if seconds > CloneInput.maxSeconds { throw CloneInput.Problem.tooLong(seconds) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw WAVDecodeError.truncated }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw WAVDecodeError.unsupportedFormat("not float PCM") }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let source = channels[c]
            for i in 0..<count { mono[i] += source[i] / Float(channelCount) }
        }
        return ReferenceClip(samples: mono, sampleRate: Int(rate.rounded()))
    }

    static func previewURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kitten-reference-preview.wav")
    }

    /// Writes the normalized (mono 16-bit WAV) clip used for preview playback.
    static func writePreview(_ clip: ReferenceClip) throws -> URL {
        let url = previewURL()
        try WAVEncoder.encode(samples: clip.samples, sampleRate: clip.sampleRate).write(to: url, options: .atomic)
        return url
    }
}

enum MicrophoneAccess {
    static func request() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}

/// Records a mono 24 kHz 16-bit WAV (stops itself after the 30 s maximum the cloning task accepts).
final class ReferenceRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kitten-reference-recording.wav")

    var isRecording: Bool { recorder?.isRecording ?? false }
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: CloneInput.maxSeconds) else {
            throw NativeEngineError(message: "The microphone could not start recording.")
        }
        self.recorder = recorder
    }

    /// Stops and returns the file URL, or nil when nothing was recorded.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
