import Foundation
import KittenCore

/// Mono float PCM produced by the native runtime.
struct NativeAudio {
    var samples: [Float]
    var sampleRate: Int
    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
}

struct NativeEngineError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Swift wrapper over the audio.cpp C ABI bridge (`NativeAudioCpp/kt_audiocpp_bridge.c`, shared with the test app).
/// There is exactly one native engine per app process. All native calls run on one serial queue: they block (up to
/// tens of seconds), cannot be interrupted, and the underlying handles are not thread-safe.
final class Kitten2Engine: @unchecked Sendable {
    static let shared = Kitten2Engine()

    static var isLinked: Bool { kt_runtime_linked() != 0 }
    static var availableMemory: UInt64 { kt_available_memory() }
    static var runtimeInfo: String {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = kt_runtime_info(&buffer, buffer.count)
        return String(cString: buffer)
    }

    private let queue = DispatchQueue(label: "kitten2.native", qos: .userInitiated)
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var loadedFlag = false

    /// Safe to read from any thread.
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loadedFlag }
    private func setLoaded(_ value: Bool) { lock.lock(); loadedFlag = value; lock.unlock() }

    /// Memory-maps the GGUF and creates the CPU session. No-op when already loaded (the model is never loaded twice).
    func load(path: String, threads: Int) async throws -> (description: String, seconds: Double) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.handle != nil {
                    continuation.resume(returning: ("already loaded", 0))
                    return
                }
                let start = Date()
                var describe = [CChar](repeating: 0, count: 1024)
                var err = [CChar](repeating: 0, count: 8192)
                var engine: OpaquePointer?
                let rc = path.withCString { kt_load($0, Int32(threads), &engine, &describe, describe.count, &err, err.count) }
                if rc == 0, let engine {
                    self.handle = engine
                    self.setLoaded(true)
                    continuation.resume(returning: (String(cString: describe), Date().timeIntervalSince(start)))
                } else {
                    continuation.resume(throwing: NativeEngineError(message: "Could not load the model (code \(rc)). " + String(cString: err)))
                }
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let engine = self.handle { kt_unload(engine) }
                self.handle = nil
                self.setLoaded(false)
                continuation.resume()
            }
        }
    }

    func synthesize(text: String, voice: String, seed: Int64 = -1) async throws -> NativeAudio {
        try await run { engine, audio, err, cap in
            text.withCString { t in voice.withCString { v in kt_synthesize(engine, t, v, seed, &audio, err, cap) } }
        }
    }

    /// Voice cloning with a mono reference clip and its transcript (audio.cpp task `clon`).
    func clone(text: String, reference: ReferenceClip, transcript: String, seed: Int64 = -1) async throws -> NativeAudio {
        try await run { engine, audio, err, cap in
            text.withCString { t in
                transcript.withCString { tr in
                    reference.samples.withUnsafeBufferPointer { ref in
                        kt_synthesize_clone(engine, t, ref.baseAddress, ref.count, Int32(reference.sampleRate), tr, seed, &audio, err, cap)
                    }
                }
            }
        }
    }

    private func run(_ body: @escaping (OpaquePointer, inout kt_audio, UnsafeMutablePointer<CChar>, Int) -> Int32) async throws -> NativeAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let engine = self.handle else {
                    continuation.resume(throwing: NativeEngineError(message: "The model is not loaded."))
                    return
                }
                var audio = kt_audio()
                var err = [CChar](repeating: 0, count: 8192)
                let rc = err.withUnsafeMutableBufferPointer { body(engine, &audio, $0.baseAddress!, $0.count) }
                defer { kt_audio_free(&audio) }
                guard rc == 0, let pointer = audio.samples else {
                    continuation.resume(throwing: NativeEngineError(message: "Speech generation failed (code \(rc)). " + String(cString: err)))
                    return
                }
                let channels = max(1, Int(audio.channels))
                let raw = UnsafeBufferPointer(start: pointer, count: audio.frames * channels)
                let mono = channels == 1 ? Array(raw) : (0..<audio.frames).map { i in (0..<channels).reduce(Float(0)) { $0 + raw[i * channels + $1] } / Float(channels) }
                continuation.resume(returning: NativeAudio(samples: mono, sampleRate: Int(audio.sample_rate)))
            }
        }
    }
}
