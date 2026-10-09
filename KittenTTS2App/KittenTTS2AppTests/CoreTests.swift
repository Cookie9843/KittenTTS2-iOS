import XCTest
@testable import KittenCore

final class ZipDirectoryTests: XCTestCase {
    func testListsEntryNames() throws {
        let zip = ZipFixture.make(names: ["expr-voice-2-f.npy", "expr-voice-2-m.npy"])
        XCTAssertEqual(try ZipDirectory.entryNames(in: zip), ["expr-voice-2-f.npy", "expr-voice-2-m.npy"])
        XCTAssertEqual(try ZipDirectory.npzKeys(in: zip), ["expr-voice-2-f", "expr-voice-2-m"])
    }

    func testZip64() throws {
        let zip = ZipFixture.make(names: ["a.npy", "b.npy", "readme.txt"], zip64: true)
        XCTAssertEqual(try ZipDirectory.npzKeys(in: zip), ["a", "b"])
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ZipDirectory.entryNames(in: Data(repeating: 0x41, count: 200))) {
            XCTAssertEqual($0 as? ZipDirectoryError, .notAZip)
        }
        XCTAssertThrowsError(try ZipDirectory.entryNames(in: Data()))
    }
}

final class VoiceCatalogTests: XCTestCase {
    func testOnlyVoicesPresentInModelAreOffered() {
        let voices = VoiceCatalog.available(in: ["expr-voice-3-m", "expr-voice-2-f", "something-else"])
        XCTAssertEqual(voices.map(\.displayName), ["Bella", "Bruno"])
        XCTAssertEqual(voices.map(\.isFemale), [true, false])
    }

    func testEmpty() {
        XCTAssertTrue(VoiceCatalog.available(in: []).isEmpty)
    }
}

final class ModelValidatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private var bigOnnx: Data { Data(count: Int(ModelValidator.minimumOnnxBytes)) }

    func testValidModel() throws {
        let onnx = try write("m.onnx", bigOnnx)
        let voices = try write("voices.npz", ZipFixture.make(names: ["expr-voice-2-f.npy", "expr-voice-5-m.npy"]))
        let result = try ModelValidator.validate(onnxURL: onnx, voicesURL: voices)
        XCTAssertEqual(result.voiceIDs, ["expr-voice-2-f", "expr-voice-5-m"])
    }

    func testMissingFile() throws {
        let voices = try write("voices.npz", ZipFixture.make(names: ["expr-voice-2-f.npy"]))
        XCTAssertThrowsError(try ModelValidator.validate(onnxURL: dir.appendingPathComponent("x.onnx"), voicesURL: voices)) {
            XCTAssertEqual($0 as? ModelValidationError, .missing("x.onnx"))
        }
    }

    func testTinyOnnxRejected() throws {
        let onnx = try write("m.onnx", Data("version https://git-lfs".utf8))
        let voices = try write("voices.npz", ZipFixture.make(names: ["expr-voice-2-f.npy"]))
        XCTAssertThrowsError(try ModelValidator.validate(onnxURL: onnx, voicesURL: voices)) {
            XCTAssertEqual($0 as? ModelValidationError, .onnxTooSmall(file: "m.onnx"))
        }
    }

    func testWrongExtension() throws {
        let onnx = try write("m.bin", bigOnnx)
        let voices = try write("voices.npz", ZipFixture.make(names: ["expr-voice-2-f.npy"]))
        XCTAssertThrowsError(try ModelValidator.validate(onnxURL: onnx, voicesURL: voices))
    }

    func testBadVoicesArchive() throws {
        let onnx = try write("m.onnx", bigOnnx)
        let voices = try write("voices.npz", Data(repeating: 1, count: 100))
        XCTAssertThrowsError(try ModelValidator.validate(onnxURL: onnx, voicesURL: voices)) {
            XCTAssertEqual($0 as? ModelValidationError, .voicesNotNPZ(file: "voices.npz"))
        }
    }

    func testNoSupportedVoices() throws {
        let onnx = try write("m.onnx", bigOnnx)
        let voices = try write("voices.npz", ZipFixture.make(names: ["other.npy"]))
        XCTAssertThrowsError(try ModelValidator.validate(onnxURL: onnx, voicesURL: voices)) {
            XCTAssertEqual($0 as? ModelValidationError, .noSupportedVoices)
        }
    }
}

final class WAVEncoderTests: XCTestCase {
    func testHeaderAndSamples() {
        let wav = WAVEncoder.encode(samples: [0, 1, -1, 2, .nan], sampleRate: 24_000)
        XCTAssertEqual(wav.count, 44 + 10)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let bytes = [UInt8](wav)
        XCTAssertEqual(UInt32(bytes[24]) | UInt32(bytes[25]) << 8 | UInt32(bytes[26]) << 16, 24_000)
        let samples = stride(from: 44, to: bytes.count, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
        XCTAssertEqual(samples, [0, Int16.max, -Int16.max, Int16.max, 0])
    }
}

final class TextInputTests: XCTestCase {
    func testTrimsAndValidates() throws {
        XCTAssertEqual(try TextInput.validate("  hello \n"), "hello")
    }

    func testEmptyAndTooLong() {
        XCTAssertThrowsError(try TextInput.validate("  \n ")) { XCTAssertEqual($0 as? TextInputError, .empty) }
        let long = String(repeating: "a", count: TextInput.maxCharacters + 1)
        XCTAssertThrowsError(try TextInput.validate(long)) {
            XCTAssertEqual($0 as? TextInputError, .tooLong(limit: TextInput.maxCharacters))
        }
    }
}

final class GenerationHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func add(_ history: inout GenerationHistory, _ text: String) throws -> GenerationRecord {
        try history.add(text: text, voiceID: "expr-voice-2-f", voiceName: "Bella", modelName: "Nano",
                        speed: 1, duration: 1.5, wavData: Data([1, 2, 3]))
    }

    func testPersistsAcrossInstancesNewestFirst() throws {
        var history = GenerationHistory(directory: dir)
        _ = try add(&history, "one")
        _ = try add(&history, "two")
        let reloaded = GenerationHistory(directory: dir)
        XCTAssertEqual(reloaded.records.map(\.text), ["two", "one"])
        XCTAssertEqual(try Data(contentsOf: reloaded.audioURL(for: reloaded.records[0])), Data([1, 2, 3]))
    }

    func testLimitEvictsOldestAndDeletesFile() throws {
        var history = GenerationHistory(directory: dir, limit: 2)
        let first = try add(&history, "one")
        _ = try add(&history, "two")
        _ = try add(&history, "three")
        XCTAssertEqual(history.records.map(\.text), ["three", "two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.audioURL(for: first).path))
    }

    func testRemoveAndClear() throws {
        var history = GenerationHistory(directory: dir)
        let a = try add(&history, "a")
        _ = try add(&history, "b")
        try history.remove(id: a.id)
        XCTAssertEqual(history.records.map(\.text), ["b"])
        try history.removeAll()
        XCTAssertTrue(GenerationHistory(directory: dir).records.isEmpty)
    }

    func testMissingAudioDropsRecord() throws {
        var history = GenerationHistory(directory: dir)
        let record = try add(&history, "gone")
        try FileManager.default.removeItem(at: history.audioURL(for: record))
        XCTAssertTrue(GenerationHistory(directory: dir).records.isEmpty)
    }
}

final class ModelVariantTests: XCTestCase {
    func testMatchesSDKIdentifiers() {
        XCTAssertEqual(ModelVariant.allCases.map(\.rawValue),
                       ["kitten-tts-nano-0.8", "kitten-tts-nano-0.8-int8", "kitten-tts-micro-0.8", "kitten-tts-mini-0.8"])
        XCTAssertEqual(ModelVariant.mini.huggingFaceRepo, "KittenML/kitten-tts-mini-0.8")
        XCTAssertEqual(ModelVariant.nanoInt8.onnxFileName, "kitten_tts_nano_v0_8.onnx")
    }
}

final class SentenceSplitTests: XCTestCase {
    func testSplitsOnTerminators() {
        XCTAssertEqual(TextInput.sentences(from: "Hello there. How are you?! Fine\nOk"),
                       ["Hello there.", "How are you?!", "Fine", "Ok"])
    }

    func testKeepsDecimalsAndTrailingText() {
        XCTAssertEqual(TextInput.sentences(from: "Pi is 3.14 roughly. Yes"), ["Pi is 3.14 roughly.", "Yes"])
    }

    func testSingleSentenceAndPunctuationOnly() {
        XCTAssertEqual(TextInput.sentences(from: "No terminator"), ["No terminator"])
        XCTAssertEqual(TextInput.sentences(from: "Wait. ..."), ["Wait...."])
    }
}
