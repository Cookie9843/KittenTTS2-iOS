import XCTest
@testable import KittenCore

/// Fixtures mimic the key layout written by audio.cpp's `audiocpp_gguf` converter
/// (app/gguf/main.cpp @ dignome/audio.cpp-custom ad1473c); they contain no model data.
final class AudioCppGGUFTests: XCTestCase {
    func le(_ v: UInt64, _ w: Int) -> [UInt8] { (0..<w).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    func str(_ s: String) -> [UInt8] { le(UInt64(s.utf8.count), 8) + Array(s.utf8) }
    func kvString(_ k: String, _ v: String) -> [UInt8] { str(k) + le(8, 4) + str(v) }
    func kvU32(_ k: String, _ v: UInt32) -> [UInt8] { str(k) + le(4, 4) + le(UInt64(v), 4) }
    func kvStringArray(_ k: String, _ v: [String]) -> [UInt8] {
        str(k) + le(9, 4) + le(8, 4) + le(UInt64(v.count), 8) + v.flatMap { str($0) }
    }
    func kvBytes(_ k: String, count: Int) -> [UInt8] {
        str(k) + le(9, 4) + le(0, 4) + le(UInt64(count), 8) + [UInt8](repeating: 7, count: count)
    }
    func tensor(_ name: String, type: UInt32) -> [UInt8] {
        str(name) + le(2, 4) + le(8, 8) + le(4, 8) + le(UInt64(type), 4) + le(0, 8)
    }

    func audiocppFixture(family: String = "kitten_tts2", weightType: String = "q8_0", tensorTypes: [UInt32] = [8, 8, 1, 0],
                         embedded: [String] = AudioCppPackage.expectedEmbeddedFiles, arch: String = "audiocpp") -> Data {
        var kv: [UInt8] = []
        kv += kvString("general.architecture", arch)
        kv += kvString("general.name", "kitten-tts2")
        kv += kvString("audiocpp.tensor_name_format", "native")
        kv += kvString("audiocpp.source_format", "safetensors")
        kv += kvString("audiocpp.weight_type", weightType)
        kv += kvU32("audiocpp.model_spec.version", 1)
        kv += kvString("audiocpp.model_spec.family", family)
        kv += kvString("audiocpp.model_spec.json", "{\"family\":\"\(family)\"}")
        kv += kvStringArray("audiocpp.tensor_sources.names", ["language_model", "s3gen"])
        kv += kvStringArray("audiocpp.tensor_names", tensorTypes.indices.map { "t\($0)" })
        if !embedded.isEmpty {
            kv += kvStringArray("audiocpp.embedded_files.names", embedded)
            kv += kvBytes("audiocpp.embedded_files.data", count: 1000)
        }
        let kvCount: UInt64 = embedded.isEmpty ? 10 : 12
        var b: [UInt8] = Array("GGUF".utf8) + le(3, 4) + le(UInt64(tensorTypes.count), 8) + le(kvCount, 8) + kv
        for (i, t) in tensorTypes.enumerated() { b += tensor("t\(i)", type: t) }
        return Data(b)
    }

    func inspect(_ d: Data, size: Int64 = AudioCppPackage.publishedSize) throws -> AudioCppGGUFReport {
        try AudioCppGGUFInspector.inspect(data: d, fileName: AudioCppPackage.publishedFileName, fileSize: size)
    }

    func testParsesAudioCppMetadata() throws {
        let r = try inspect(audiocppFixture())
        XCTAssertEqual(r.architecture, "audiocpp")
        XCTAssertEqual(r.specFamily, "kitten_tts2")
        XCTAssertEqual(r.weightType, "q8_0")
        XCTAssertEqual(r.specVersion, 1)
        XCTAssertGreaterThan(r.specJSONBytes ?? 0, 0)
        XCTAssertEqual(r.tensorCount, 4)
        XCTAssertEqual(r.tensorTypeCounts, ["Q8_0": 2, "F16": 1, "F32": 1])
        XCTAssertEqual(r.embeddedFileNames, AudioCppPackage.expectedEmbeddedFiles)
        XCTAssertEqual(r.embeddedDataBytes, 1000)
        XCTAssertFalse(r.looksLikeUpstreamTQ2_1)
    }

    func testAcceptsExpectedPackage() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture()))
        XCTAssertEqual(v.kind, .audiocppKittenTTS2)
        XCTAssertTrue(v.passed, "\(v.checks)")
        XCTAssertTrue(v.isPublishedFile)
        XCTAssertNil(v.guidance)
        XCTAssertEqual(v.checks.first { $0.name == "TQ2_1 tensors" }?.status, .pass)
    }

    func testZeroTQ2_1TensorsIsNotAFailure() throws {
        let r = try inspect(audiocppFixture())
        XCTAssertNil(r.tensorTypeCounts.keys.first { $0.hasPrefix("TQ2") })
        XCTAssertTrue(AudioCppGGUFInspector.validate(r).passed)
    }

    func testRejectsOtherAudioCppFamily() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(family: "kokoro_tts")))
        XCTAssertEqual(v.kind, .audiocppOtherFamily("kokoro_tts"))
        XCTAssertFalse(v.passed)
        XCTAssertNotNil(v.guidance)
    }

    func testRejectsNonQ8() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(weightType: "f16", tensorTypes: [1, 0, 1])))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.checks.first { $0.name == "Q8 mixed precision" }?.status, .fail)
    }

    func testRejectsMissingEmbeddedAssets() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(embedded: [])))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.checks.first { $0.name == "Embedded assets" }?.status, .fail)
    }

    func testWarnsOnUnexpectedEmbeddedNames() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(embedded: ["other.bin"])))
        XCTAssertTrue(v.passed)
        XCTAssertEqual(v.checks.first { $0.name == "Embedded assets" }?.status, .warn)
    }

    func testTruncatedDownloadFails() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(), size: 1_000_000_000))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.checks.first { $0.name == "File size" }?.status, .fail)
    }

    func testUpstreamTQ2_1IsDistinguished() throws {
        var b: [UInt8] = Array("GGUF".utf8) + le(3, 4) + le(0, 8) + le(2, 8)
        b += kvString("general.architecture", "qwen3") + str("general.file_type") + le(4, 4) + le(42, 4)
        let r = try inspect(Data(b), size: 1_030_000_000)
        let v = AudioCppGGUFInspector.validate(r)
        XCTAssertEqual(v.kind, .upstreamTQ2_1)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.guidance?.contains("TQ2_1") ?? false)
    }

    func testOtherGGUFGetsActionableGuidance() throws {
        let v = AudioCppGGUFInspector.validate(try inspect(audiocppFixture(arch: "llama")))
        XCTAssertEqual(v.kind, .otherGGUF("llama"))
        XCTAssertTrue(v.guidance?.contains(AudioCppPackage.publishedFileName) ?? false)
    }

    func testNonGGUFAndTruncatedHeaderThrow() {
        XCTAssertThrowsError(try inspect(Data([1, 2, 3, 4, 5])))
        XCTAssertThrowsError(try inspect(audiocppFixture().prefix(60)))
    }

    func testInspectFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try audiocppFixture().write(to: url)
        let r = try AudioCppGGUFInspector.inspect(url: url)
        XCTAssertEqual(r.specFamily, "kitten_tts2")
        XCTAssertEqual(r.fileName, url.lastPathComponent)
    }

    func testExistingDetectorStillReadsAudioCppArchitecture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try audiocppFixture().write(to: url)
        guard case .gguf(let info) = try FileFormatDetector.detect(url: url).format else { return XCTFail() }
        XCTAssertEqual(info.architecture, "audiocpp")
        XCTAssertNil(info.fileType)
    }

    func testResourceAdvisor() throws {
        let r = try inspect(audiocppFixture())
        let gib: UInt64 = 1 << 30
        let ok = ResourceAdvisor.assess(report: r, snapshot: ResourceSnapshot(physicalMemory: 8 * gib, availableMemory: 6 * gib, freeStorage: 10 << 30))
        XCTAssertTrue(ok.canProceed); XCTAssertTrue(ok.warnings.isEmpty)
        let lowStorage = ResourceAdvisor.assess(report: r, snapshot: ResourceSnapshot(physicalMemory: 8 * gib, availableMemory: 6 * gib, freeStorage: 1000))
        XCTAssertFalse(lowStorage.canProceed)
        let lowRAM = ResourceAdvisor.assess(report: r, snapshot: ResourceSnapshot(physicalMemory: 2 * gib, availableMemory: nil, freeStorage: 10 << 30))
        XCTAssertFalse(lowRAM.canProceed)
        let headroom = ResourceAdvisor.assess(report: r, snapshot: ResourceSnapshot(physicalMemory: 8 * gib, availableMemory: 1 * gib, freeStorage: 10 << 30))
        XCTAssertTrue(headroom.canProceed); XCTAssertEqual(headroom.warnings.count, 1)
    }
}
