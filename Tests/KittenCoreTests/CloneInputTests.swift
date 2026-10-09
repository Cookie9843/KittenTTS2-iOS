import XCTest
@testable import KittenCore

final class CloneInputTests: XCTestCase {
    func wav(samples: [Int16], rate: Int = 24000, channels: Int = 1) -> Data {
        var d = WAVEncoder.encode(samples: samples.map { Float($0) / 32767 }, sampleRate: rate)
        if channels == 2 { // rebuild as stereo with identical channels
            var s = [Int16](); for v in samples { s.append(v); s.append(v) }
            d = Self.build(tag: 1, channels: 2, rate: rate, bits: 16, payload: s.flatMap { v in [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] })
        }
        return d
    }
    static func build(tag: Int, channels: Int, rate: Int, bits: Int, payload: [UInt8], dataSize: Int? = nil) -> Data {
        var d = Data()
        func u32(_ v: Int) { d.append(contentsOf: [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 255), UInt8((v >> 8) & 255)]) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + payload.count); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(tag); u16(channels); u32(rate); u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize ?? payload.count); d.append(contentsOf: payload)
        return d
    }

    func testRoundTripWithOurEncoder() throws {
        let src: [Float] = (0..<2400).map { sin(Float($0) / 10) * 0.5 }
        let clip = try WAVDecoder.decode(data: WAVEncoder.encode(samples: src, sampleRate: 24000))
        XCTAssertEqual(clip.sampleRate, 24000)
        XCTAssertEqual(clip.samples.count, 2400)
        XCTAssertEqual(clip.samples[100], src[100], accuracy: 0.001)
        XCTAssertEqual(clip.duration, 0.1, accuracy: 1e-6)
    }

    func testStereoMixesToMonoAndFloatAndBogusSize() throws {
        let stereo = try WAVDecoder.decode(data: wav(samples: [1000, 2000, 3000], channels: 2))
        XCTAssertEqual(stereo.samples.count, 3)
        XCTAssertEqual(stereo.samples[1], 2000.0 / 32768, accuracy: 1e-4)
        var f = [UInt8](); for v in [Float(0.25), -0.5] { let b = v.bitPattern; f += [UInt8(b & 255), UInt8((b >> 8) & 255), UInt8((b >> 16) & 255), UInt8(b >> 24)] }
        let flt = try WAVDecoder.decode(data: Self.build(tag: 3, channels: 1, rate: 16000, bits: 32, payload: f))
        XCTAssertEqual(flt.samples, [0.25, -0.5])
        // streaming writers declare 0xFFFFFFFF; the decoder clamps to the real data
        let streaming = try WAVDecoder.decode(data: Self.build(tag: 1, channels: 1, rate: 16000, bits: 16, payload: [0, 0x40, 0, 0xC0], dataSize: 0xFFFFFFFF))
        XCTAssertEqual(streaming.samples.count, 2)
    }

    func testBadFilesAreRejectedWithoutCrashing() {
        XCTAssertThrowsError(try WAVDecoder.decode(data: Data("hello world".utf8))) { XCTAssertEqual($0 as? WAVDecodeError, .notWAV) }
        XCTAssertThrowsError(try WAVDecoder.decode(data: Data("RIFF".utf8)))
        XCTAssertThrowsError(try WAVDecoder.decode(data: Self.build(tag: 85, channels: 1, rate: 16000, bits: 16, payload: [0, 0]))) { // MP3-in-WAV
            guard case .unsupportedFormat = $0 as? WAVDecodeError else { return XCTFail() }
        }
        XCTAssertThrowsError(try WAVDecoder.decode(data: Self.build(tag: 1, channels: 1, rate: 16000, bits: 16, payload: [])))
        let truncatedHeader = Data(Self.build(tag: 1, channels: 1, rate: 16000, bits: 16, payload: [1, 2]).prefix(20))
        XCTAssertThrowsError(try WAVDecoder.decode(data: truncatedHeader))
    }

    func clip(seconds: Double, amplitude: Float = 0.3) -> ReferenceClip {
        ReferenceClip(samples: (0..<Int(seconds * 24000)).map { sin(Float($0) / 7) * amplitude }, sampleRate: 24000)
    }

    func testDurationBoundsMatchRuntime() throws {
        XCTAssertThrowsError(try CloneInput.validate(clip: clip(seconds: 0.5), transcript: "hello there")) { XCTAssertEqual($0 as? CloneInput.Problem, .tooShort(0.5)) }
        XCTAssertNoThrow(try CloneInput.validate(clip: clip(seconds: 1), transcript: "hello there"))
        XCTAssertNoThrow(try CloneInput.validate(clip: clip(seconds: 30), transcript: String(repeating: "word ", count: 60)))
        XCTAssertThrowsError(try CloneInput.validate(clip: clip(seconds: 30.5), transcript: "hello")) { guard case .tooLong = $0 as? CloneInput.Problem else { return XCTFail() } }
    }

    func testTranscriptAndSilenceRules() throws {
        XCTAssertThrowsError(try CloneInput.validate(clip: clip(seconds: 3), transcript: "  \n ")) { XCTAssertEqual($0 as? CloneInput.Problem, .emptyTranscript) }
        XCTAssertThrowsError(try CloneInput.validate(clip: clip(seconds: 3, amplitude: 0), transcript: "hi there")) { XCTAssertEqual($0 as? CloneInput.Problem, .silent) }
        XCTAssertThrowsError(try CloneInput.validate(clip: clip(seconds: 3), transcript: String(repeating: "a", count: 1001))) { guard case .transcriptTooLong = $0 as? CloneInput.Problem else { return XCTFail() } }
        let v = try CloneInput.validate(clip: clip(seconds: 3), transcript: "  Hello there friend.  ")
        XCTAssertEqual(v.transcript, "Hello there friend.")
        let mismatch = try CloneInput.validate(clip: clip(seconds: 3), transcript: "hi")
        XCTAssertFalse(mismatch.warnings.isEmpty)
    }

    func testPresetValidationAndOutputCheck() throws {
        XCTAssertEqual(try SynthesisInput.validatePreset(text: "  Hi  ", voice: "Bruno"), "Hi")
        XCTAssertThrowsError(try SynthesisInput.validatePreset(text: " ", voice: "Bruno")) { XCTAssertEqual($0 as? SynthesisInput.Problem, .emptyText) }
        XCTAssertThrowsError(try SynthesisInput.validatePreset(text: "x", voice: "Nobody")) { XCTAssertEqual($0 as? SynthesisInput.Problem, .unknownVoice("Nobody")) }
        XCTAssertThrowsError(try SynthesisInput.validatePreset(text: String(repeating: "x", count: 4001), voice: "Bruno"))
        XCTAssertTrue(Kitten2Package.presetVoices.contains { $0.id == Kitten2Package.defaultVoice })
        XCTAssertFalse(CloneInput.isUsableOutput(samples: [0, 0, 0], sampleRate: 24000))
        XCTAssertFalse(CloneInput.isUsableOutput(samples: [], sampleRate: 24000))
        XCTAssertTrue(CloneInput.isUsableOutput(samples: [0, 0.2], sampleRate: 24000))
    }

    func testSavedOutputIsValidRIFF() throws {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5], sampleRate: 24000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data.count, 44 + 6)
    }
}
