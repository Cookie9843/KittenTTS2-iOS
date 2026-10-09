import XCTest
@testable import KittenCore

final class KittenCoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: fixtures

    func le(_ v: UInt64, _ w: Int) -> [UInt8] { (0..<w).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    func ggufString(_ s: String) -> [UInt8] { le(UInt64(s.utf8.count), 8) + Array(s.utf8) }

    func makeGGUF(_ name: String, arch: String = "qwen3", fileType: UInt32? = 42, padding: Int = 100) throws -> URL {
        var b: [UInt8] = Array("GGUF".utf8) + le(3, 4) + le(0, 8) + le(fileType == nil ? 1 : 2, 8)
        b += ggufString("general.architecture") + le(8, 4) + ggufString(arch)
        if let fileType { b += ggufString("general.file_type") + le(4, 4) + le(UInt64(fileType), 4) }
        b += [UInt8](repeating: 0, count: padding)
        let url = dir.appendingPathComponent(name)
        try Data(b).write(to: url)
        return url
    }

    func makeZip(_ name: String, entries: [String]) throws -> URL {
        var out: [UInt8] = [], cd: [UInt8] = []
        for e in entries {
            let off = out.count
            out += [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 26) + Array(e.utf8)
            cd += [0x50, 0x4B, 0x01, 0x02] + [UInt8](repeating: 0, count: 24) + le(UInt64(e.utf8.count), 2) + [UInt8](repeating: 0, count: 12) + le(UInt64(off), 4) + Array(e.utf8)
        }
        let cdOff = out.count
        out += cd + [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0] + le(UInt64(entries.count), 2) + le(UInt64(entries.count), 2) + le(UInt64(cd.count), 4) + le(UInt64(cdOff), 4) + [0, 0]
        let url = dir.appendingPathComponent(name)
        try Data(out).write(to: url)
        return url
    }

    func makeONNX(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x08, 0x08, 0x12, 0x04] + [UInt8](repeating: 1, count: 64)).write(to: url)
        return url
    }

    func makeFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: detection

    func testDetectsGGUFMetadata() throws {
        let f = try FileFormatDetector.detect(url: try makeGGUF("a.gguf"))
        guard case .gguf(let info) = f.format else { return XCTFail("\(f.format)") }
        XCTAssertEqual(info.architecture, "qwen3")
        XCTAssertEqual(info.fileType, 42)
        XCTAssertEqual(info.version, 3)
    }

    func testDetectsOtherFormats() throws {
        XCTAssertEqual(try FileFormatDetector.detect(url: makeONNX("m.onnx")).format, .onnx)
        guard case .npz = try FileFormatDetector.detect(url: makeZip("v.npz", entries: ["expr-voice-2-f.npy"])).format else { return XCTFail() }
        XCTAssertEqual(try FileFormatDetector.detect(url: makeZip("d.pt", entries: ["d/data.pkl", "d/version"])).format, .torchArchive)
        XCTAssertEqual(try FileFormatDetector.detect(url: makeFile("x.bin", [1, 2, 3, 4, 5])).format, .unknown)
        XCTAssertEqual(try FileFormatDetector.detect(url: makeFile("e.bin", [])).format, .empty)
        let header = "{\"a\":1}"
        XCTAssertEqual(try FileFormatDetector.detect(url: makeFile("m.safetensors", le(UInt64(header.utf8.count), 8) + Array(header.utf8) + [0, 0])).format, .safetensors)
        XCTAssertEqual(try FileFormatDetector.detect(url: makeFile("c.json", Array("{\"type\":\"KITTEN2\"}".utf8))).format, .json)
    }

    // MARK: validation

    func testKitten2AcceptsGGUFAndNotesMissingAssets() throws {
        let plan = try ImportValidator.validate(urls: [makeGGUF("model-tq2_1.gguf")], family: .kitten2).get()
        XCTAssertEqual(plan.destination, "kitten2")
        XCTAssertEqual(plan.files.map(\.storedName), ["model.gguf"])
        XCTAssertTrue(plan.notes.contains { $0.contains("Missing optional assets") })
        XCTAssertTrue(plan.notes.contains { $0.contains("TQ2_1") })
    }

    func testKitten2FullSet() throws {
        let urls = [try makeGGUF("m.gguf"), try makeZip("decoder.pt", entries: ["x/data.pkl"]),
                    try makeFile("voices.json", Array("{\"Bruno\":[1]}".utf8)), try makeFile("config.json", Array("{\"type\":\"KITTEN2\"}".utf8))]
        let plan = try ImportValidator.validate(urls: urls, family: .kitten2).get()
        XCTAssertEqual(Set(plan.files.map(\.storedName)), ["model.gguf", "decoder.pt", "voices.json", "config.json"])
        XCTAssertFalse(plan.notes.contains { $0.contains("Missing optional") })
    }

    func testKitten2FP16Note() throws {
        let plan = try ImportValidator.validate(urls: [makeGGUF("f.gguf", fileType: 1)], family: .kitten2).get()
        XCTAssertTrue(plan.notes.contains { $0.contains("FP16") })
    }

    func testKitten2RejectsWrongFamilyAndFormats() throws {
        func issue(_ urls: [URL]) -> ValidationIssue? {
            if case .failure(let i) = ImportValidator.validate(urls: urls, family: .kitten2) { return i }
            return nil
        }
        XCTAssertTrue(issue([try makeONNX("m.onnx")])!.title.contains("0.8"))
        XCTAssertTrue(issue([try makeGGUF("llama.gguf", arch: "llama")])!.title.contains("not a KittenTTS 2"))
        XCTAssertTrue(issue([try makeFile("big.gguf", [9, 9, 9, 9, 9])])!.message.contains("Renaming"))
        XCTAssertTrue(issue([try makeZip("d.pt", entries: ["x/data.pkl"])])!.title.contains("No KittenTTS 2 GGUF"))
        XCTAssertNotNil(issue([]))
        XCTAssertNotNil(issue([try makeFile("c.json", Array("{\"type\":\"OTHER\"}".utf8))]))
    }

    func testLegacyAcceptsPairAndMapsSDKNames() throws {
        let plan = try ImportValidator.validate(urls: [makeONNX("any.onnx"), makeZip("v.npz", entries: ["expr-voice-2-f.npy"])], family: .legacy08, legacyVariant: .mini).get()
        XCTAssertEqual(plan.destination, "legacy08/kitten-tts-mini-0.8")
        XCTAssertEqual(Set(plan.files.map(\.storedName)), ["kitten_tts_mini_v0_8.onnx", "voices.npz"])
    }

    func testLegacyRejections() throws {
        func issue(_ urls: [URL]) -> ValidationIssue? {
            if case .failure(let i) = ImportValidator.validate(urls: urls, family: .legacy08) { return i }
            return nil
        }
        XCTAssertTrue(issue([try makeGGUF("k2.gguf")])!.title.contains("GGUF"))
        XCTAssertTrue(issue([try makeGGUF("k2.gguf")])!.nextSteps.contains(ModelFamily.kitten2.displayName))
        XCTAssertTrue(issue([try makeONNX("m.onnx")])!.title.contains("voices"))
        XCTAssertTrue(issue([try makeZip("v.npz", entries: ["expr-voice-2-f.npy"])])!.title.contains("onnx"))
        XCTAssertTrue(issue([try makeONNX("m.onnx"), try makeZip("v.npz", entries: ["other.npy"])])!.title.contains("no KittenTTS voices"))
    }

    // MARK: import

    func testImportPreservesExistingOnFailureAndReplacesOnSuccess() throws {
        let root = dir.appendingPathComponent("models")
        let importer = ModelImporter(root: root, availableBytes: { Int64.max })
        let v1 = try makeGGUF("a.gguf", padding: 10)
        let plan1 = try ImportValidator.validate(urls: [v1], family: .kitten2).get()
        let installed = try importer.install(plan1)
        let old = try Data(contentsOf: installed.appendingPathComponent("model.gguf"))

        let v2 = try makeGGUF("b.gguf", padding: 500)
        let plan2 = try ImportValidator.validate(urls: [v2], family: .kitten2).get()
        XCTAssertThrowsError(try importer.install(plan2, isCancelled: { true })) { XCTAssertEqual($0 as? ImportError, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("model.gguf")), old)

        let small = ModelImporter(root: root, availableBytes: { 10 })
        XCTAssertThrowsError(try small.install(plan2))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("model.gguf")), old)

        var last = 0.0
        try importer.install(plan2, progress: { last = $0 })
        XCTAssertEqual(last, 1)
        XCTAssertGreaterThan(try Data(contentsOf: installed.appendingPathComponent("model.gguf")).count, old.count)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testImportFailsWhenSourceMissingAndKeepsOld() throws {
        let root = dir.appendingPathComponent("models")
        let importer = ModelImporter(root: root, availableBytes: { Int64.max })
        let installed = try importer.install(ImportValidator.validate(urls: [makeGGUF("a.gguf")], family: .kitten2).get())
        let ghost = ImportPlan(family: .kitten2, legacyVariant: nil, destination: "kitten2", files: [PlannedFile(source: dir.appendingPathComponent("nope"), storedName: "model.gguf", size: 1)], notes: [])
        XCTAssertThrowsError(try importer.install(ghost))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("model.gguf").path))
    }

    // MARK: history / WAV / family

    func testWAVHeader() {
        let d = WAVEncoder.encode(samples: [0, 1, -1, 2], sampleRate: 24000)
        XCTAssertEqual(d.count, 44 + 8)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(d[22], 1)
        XCTAssertEqual(Int16(littleEndian: d.subdata(in: 46..<48).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }), 32767)
    }

    func testHistoryRoundTrip() throws {
        let store = try HistoryStore(directory: dir.appendingPathComponent("h"))
        let r = try store.add(samples: [Float](repeating: 0.1, count: 24000), sampleRate: 24000, text: "hi", family: .legacy08, modelName: "Mini", voice: "Luna", speed: 1)
        XCTAssertEqual(r.duration, 1, accuracy: 0.001)
        let reloaded = try HistoryStore(directory: dir.appendingPathComponent("h"))
        XCTAssertEqual(reloaded.records.map(\.id), [r.id])
        try reloaded.delete(r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.audioURL(for: r).path))
        XCTAssertTrue(try HistoryStore(directory: dir.appendingPathComponent("h")).records.isEmpty)
    }

    func testFamilyLabelsAndBlocker() {
        XCTAssertTrue(ModelFamily.legacy08.displayName.contains("0.8"))
        XCTAssertFalse(ModelFamily.kitten2.canSynthesizeOnDevice)
        XCTAssertNotNil(ModelFamily.kitten2.runtimeBlocker)
        XCTAssertNil(ModelFamily.legacy08.runtimeBlocker)
    }
}
