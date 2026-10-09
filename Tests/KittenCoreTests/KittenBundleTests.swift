import XCTest
@testable import KittenCore

private struct MockRuntime: KittenRuntime {
    var capabilities: RuntimeCapabilities
    var samples: [Float] = []
    func generate(modelDirectory: URL, text: String) throws -> [Float] {
        guard capabilities.isComplete else { throw KittenRuntimeError.unavailable(missing: capabilities.missing) }
        return samples
    }
}

final class KittenBundleTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func le(_ v: UInt64, _ w: Int) -> [UInt8] { (0..<w).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    func str(_ s: String) -> [UInt8] { le(UInt64(s.utf8.count), 8) + Array(s.utf8) }

    func writeGGUF(arch: String = "qwen3", fileType: UInt32 = 42) throws {
        var b: [UInt8] = Array("GGUF".utf8) + le(3, 4) + le(7, 8) + le(2, 8)
        b += str("general.architecture") + le(8, 4) + str(arch)
        b += str("general.file_type") + le(4, 4) + le(UInt64(fileType), 4)
        b += [UInt8](repeating: 0, count: 64)
        try Data(b).write(to: dir.appendingPathComponent("model.gguf"))
    }

    func writeDecoder() throws {
        let name = "archive/version"
        var out: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 26) + Array(name.utf8)
        let cdOff = out.count
        let cd: [UInt8] = [0x50, 0x4B, 0x01, 0x02] + [UInt8](repeating: 0, count: 24) + le(UInt64(name.utf8.count), 2) + [UInt8](repeating: 0, count: 12) + le(0, 4) + Array(name.utf8)
        out += cd + [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0] + le(1, 2) + le(1, 2) + le(UInt64(cd.count), 4) + le(UInt64(cdOff), 4) + [0, 0]
        try Data(out).write(to: dir.appendingPathComponent("decoder.pt"))
    }

    func write(_ name: String, _ json: String) throws { try Data(json.utf8).write(to: dir.appendingPathComponent(name)) }
    func size(_ name: String) -> Int { (try? Data(contentsOf: dir.appendingPathComponent(name)).count) ?? 0 }

    func writeFullBundle() throws {
        try writeGGUF(); try writeDecoder(); try write("voices.json", "{\"voice\":{}}")
        try write("config.json", "{\"type\":\"KITTEN2\"}")
    }

    func status(_ r: BundleReport, _ name: String) -> CheckStatus? { r.checks.first { $0.name == name }?.status }

    func testFullBundlePassesMetadataChecks() throws {
        try writeFullBundle()
        let r = BundleVerifier.verify(directory: dir)
        XCTAssertTrue(r.isComplete, r.summary)
        XCTAssertEqual(status(r, "Architecture"), .pass)
        XCTAssertEqual(status(r, "Quantization"), .pass)
        XCTAssertEqual(status(r, "Decoder"), .pass)
        XCTAssertEqual(r.quantization, "TQ2_1 (KittenTTS 2 fork)")
    }

    func testMissingAssetsAndWrongArchitectureFail() throws {
        XCTAssertFalse(BundleVerifier.verify(directory: dir).isComplete)
        try writeFullBundle(); try writeGGUF(arch: "llama")
        let r = BundleVerifier.verify(directory: dir)
        XCTAssertEqual(status(r, "Architecture"), .fail)
        XCTAssertFalse(r.isComplete)
    }

    func testWrongConfigTypeFails() throws {
        try writeFullBundle(); try write("config.json", "{\"type\":\"OTHER\"}")
        XCTAssertEqual(status(BundleVerifier.verify(directory: dir), "Config"), .fail)
    }

    func testManifestSizeMismatchDetected() throws {
        try writeFullBundle()
        let good = "{\"type\":\"KITTEN2\",\"cpp\":{\"version\":1,\"gguf\":{\"file\":\"x\",\"size\":\(size("model.gguf"))},\"decoders\":{\"default\":{\"torchscript\":{\"file\":\"d\",\"size\":\(size("decoder.pt"))},\"voices\":{\"file\":\"v\",\"size\":\(size("voices.json"))}}}}}"
        try write("config.json", good)
        var r = BundleVerifier.verify(directory: dir)
        XCTAssertTrue(r.isComplete, r.summary)
        XCTAssertEqual(status(r, "Manifest: GGUF size"), .pass)
        try write("config.json", good.replacingOccurrences(of: "\"size\":\(size("model.gguf"))", with: "\"size\":1"))
        r = BundleVerifier.verify(directory: dir)
        XCTAssertEqual(status(r, "Manifest: GGUF size"), .fail)
        try write("config.json", "{\"type\":\"KITTEN2\",\"cpp\":{\"version\":2}}")
        XCTAssertEqual(status(BundleVerifier.verify(directory: dir), "Manifest"), .fail)
    }

    func testFP16GuidanceIsActionable() {
        let g = BundleVerifier.quantizationGuidance(fileType: 1, bytes: 3_470_000_000)
        XCTAssertEqual(g.status, .warn)
        XCTAssertTrue(g.text.contains("model-tq2_1.gguf"))
        XCTAssertEqual(BundleVerifier.quantizationGuidance(fileType: nil, bytes: 3_500_000_000).status, .warn)
        XCTAssertEqual(BundleVerifier.quantizationGuidance(fileType: 42, bytes: 1_030_000_000).status, .pass)
        XCTAssertEqual(BundleVerifier.quantizationGuidance(fileType: 99, bytes: 1).status, .warn)
    }

    func testDeviceBudget() {
        let gb: UInt64 = 1_000_000_000
        XCTAssertEqual(DeviceBudget.assess(modelBytes: 1_030_000_000, physicalMemory: 8 * gb).verdict, .pass)
        XCTAssertEqual(DeviceBudget.assess(modelBytes: 3_470_000_000, physicalMemory: 8 * gb).verdict, .warn)
        XCTAssertEqual(DeviceBudget.assess(modelBytes: 3_470_000_000, physicalMemory: 16 * gb).verdict, .pass)
        XCTAssertEqual(DeviceBudget.assess(modelBytes: 3_000_000_000, physicalMemory: 6 * gb).verdict, .warn)
        XCTAssertEqual(DeviceBudget.assess(modelBytes: 3_600_000_000, physicalMemory: 6 * gb, hasIncreasedMemoryEntitlement: true).verdict, .fail)
    }

    // MARK: bridge

    func testNativeBridgeIsHonestlyUnavailable() throws {
        let runtime = NativeKittenRuntime()
        XCTAssertEqual(NativeKittenRuntime.abiVersion, 1)
        XCTAssertFalse(runtime.capabilities.isComplete)
        XCTAssertEqual(runtime.capabilities.missing.count, 4)
        XCTAssertThrowsError(try runtime.generate(modelDirectory: dir, text: "Hello")) { error in
            guard case KittenRuntimeError.unavailable(let missing) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(missing.count, 4)
        }
    }

    func testGenerationGate() throws {
        try writeFullBundle()
        let report = BundleVerifier.verify(directory: dir)
        let native = GenerationGate.evaluate(report: report, runtime: NativeKittenRuntime())
        XCTAssertFalse(native.enabled)
        XCTAssertEqual(native.reasons.count, 4)
        let full = MockRuntime(capabilities: .init(llamaForkLinked: true, tq2_1Supported: true, decoderLinked: true, textNormalizerLinked: true), samples: [0.1])
        XCTAssertTrue(GenerationGate.evaluate(report: report, runtime: full).enabled)
        XCTAssertEqual(try full.generate(modelDirectory: dir, text: "x"), [0.1])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("decoder.pt"))
        XCTAssertFalse(GenerationGate.evaluate(report: BundleVerifier.verify(directory: dir), runtime: full).enabled)
    }
}
