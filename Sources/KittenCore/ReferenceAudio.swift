import Foundation

/// A mono reference clip for voice cloning, decoded from a RIFF/WAVE file.
public struct ReferenceClip: Equatable, Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
    public var peak: Float { samples.reduce(0) { max($0, abs($1)) } }
    public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
}

public enum WAVDecodeError: Error, Equatable, LocalizedError {
    case notWAV, truncated, unsupportedFormat(String), tooLarge(Int64), empty
    public var errorDescription: String? {
        switch self {
        case .notWAV: return "That file is not a WAV recording."
        case .truncated: return "The WAV file is damaged or cut off."
        case .unsupportedFormat(let m): return "Unsupported WAV format (\(m)). Use 8/16/24/32-bit PCM or 32/64-bit float."
        case .tooLarge(let n): return "That file is too large for a short reference clip (\(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)))."
        case .empty: return "The WAV file contains no audio."
        }
    }
}

/// Minimal, bounds-checked RIFF/WAVE reader (PCM 8/16/24/32, IEEE float 32/64, WAVE_FORMAT_EXTENSIBLE) that mixes to mono.
public enum WAVDecoder {
    public static let maxFileBytes: Int64 = 64 * 1024 * 1024

    public static func decode(url: URL) throws -> ReferenceClip {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxFileBytes { throw WAVDecodeError.tooLarge(size) }
        return try decode(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func decode(data: Data) throws -> ReferenceClip {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else { throw WAVDecodeError.notWAV }

        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var pcm: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let declared = u32(offset + 4)
            let start = offset + 8
            let end = min(start + declared, bytes.count) // tolerate writers that left a bogus/streaming size
            if id == "fmt " {
                guard end - start >= 16 else { throw WAVDecodeError.truncated }
                var tag = u16(start)
                if tag == 0xFFFE, end - start >= 26 { tag = u16(start + 24) }
                format = (tag, u16(start + 2), u32(start + 4), u16(start + 14))
            } else if id == "data" {
                pcm = bytes[start..<end]
                break
            }
            offset = start + declared + (declared & 1)
        }
        guard let format else { throw WAVDecodeError.truncated }
        guard let pcm else { throw WAVDecodeError.empty }
        guard format.channels >= 1, format.channels <= 8, format.rate >= 8000, format.rate <= 192_000 else {
            throw WAVDecodeError.unsupportedFormat("\(format.channels) ch @ \(format.rate) Hz")
        }
        let width = format.bits / 8
        let isFloat = format.tag == 3
        guard (format.tag == 1 && [1, 2, 3, 4].contains(width) && format.bits % 8 == 0) || (isFloat && (width == 4 || width == 8)) else {
            throw WAVDecodeError.unsupportedFormat("format tag \(format.tag), \(format.bits)-bit")
        }
        let frameBytes = width * format.channels
        let frames = pcm.count / frameBytes
        if frames == 0 { throw WAVDecodeError.empty }
        let base = pcm.startIndex
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for ch in 0..<format.channels {
                let o = base + frame * frameBytes + ch * width
                sum += sample(bytes, o, width: width, isFloat: isFloat)
            }
            mono[frame] = sum / Float(format.channels)
        }
        return ReferenceClip(samples: mono, sampleRate: format.rate)
    }

    private static func sample(_ b: [UInt8], _ o: Int, width: Int, isFloat: Bool) -> Float {
        let value: Float
        switch (isFloat, width) {
        case (false, 1): value = (Float(b[o]) - 128) / 128
        case (false, 2): value = Float(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) / 32768
        case (false, 3):
            var v = Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(b[o + 2]) << 16
            if v & 0x800000 != 0 { v -= 0x1000000 }
            value = Float(v) / 8_388_608
        case (false, _):
            let v = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            value = Float(Int32(bitPattern: v)) / 2_147_483_648
        case (true, 4):
            let v = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            value = Float(bitPattern: v)
        default:
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << UInt64(8 * i) }
            value = Float(Double(bitPattern: v))
        }
        return value.isFinite ? max(-1, min(1, value)) : 0
    }
}

/// Input rules of the audio.cpp `kitten_tts2` cloning task: 1–30 s of reference audio plus a matching transcript.
/// The runtime does not transcribe, so the transcript always comes from the user.
public enum CloneInput {
    public static let minSeconds: Double = 1
    public static let maxSeconds: Double = 30
    public static let maxTranscriptCharacters = 1000

    public enum Problem: Error, Equatable, LocalizedError {
        case tooShort(Double), tooLong(Double), silent, emptyTranscript, transcriptTooLong(Int)
        public var errorDescription: String? {
            switch self {
            case .tooShort(let s): return String(format: "The clip is %.1f s long; it needs to be at least 1 second.", s)
            case .tooLong(let s): return String(format: "The clip is %.1f s long; it can be at most 30 seconds. Trim it or record a shorter one.", s)
            case .silent: return "The clip seems to be silent. Check the microphone or pick another file."
            case .emptyTranscript: return "Type exactly what is said in the clip. It cannot be left empty because the app does not transcribe audio automatically."
            case .transcriptTooLong(let n): return "The transcript is \(n) characters; please keep it under \(CloneInput.maxTranscriptCharacters)."
            }
        }
    }

    public struct Validated: Equatable, Sendable {
        public var clip: ReferenceClip
        public var transcript: String
        public var warnings: [String]
    }

    public static func validate(clip: ReferenceClip, transcript: String) throws -> Validated {
        let seconds = clip.duration
        if seconds < minSeconds { throw Problem.tooShort(seconds) }
        if seconds > maxSeconds { throw Problem.tooLong(seconds) }
        if clip.peak < 0.001 { throw Problem.silent }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw Problem.emptyTranscript }
        if text.count > maxTranscriptCharacters { throw Problem.transcriptTooLong(text.count) }
        var warnings: [String] = []
        let rate = Double(text.count) / seconds
        if rate > 30 { warnings.append("The transcript looks much longer than the clip; make sure it matches what is said.") }
        if rate < 1.5 { warnings.append("The transcript looks much shorter than the clip; make sure it matches what is said.") }
        if clip.peak > 0.999 { warnings.append("The clip may be clipped/distorted; a quieter recording usually clones better.") }
        return Validated(clip: clip, transcript: text, warnings: warnings)
    }

    /// Native text-to-speech output validation (what audio.cpp must hand back before the app saves/plays it).
    public static func isUsableOutput(samples: [Float], sampleRate: Int) -> Bool {
        sampleRate > 0 && !samples.isEmpty && samples.contains { $0.isFinite && abs($0) > 1e-4 }
    }
}
