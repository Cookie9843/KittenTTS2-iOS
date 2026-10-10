import XCTest
@testable import KittenCore

final class Kitten2ImporterTests: XCTestCase {
    let fixtures = GGUFFixtures()
    var dir: URL!
    var staging: URL { dir.appendingPathComponent("staging") }
    var install: URL { dir.appendingPathComponent("kitten2") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ data: Data, _ name: String = "mine.gguf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Fixture "package" standing in for the published file so the size/checksum rules run on small data.
    func published(_ data: Data) -> RemoteModelFile {
        var h = SHA256Hasher(); h.update(data)
        return RemoteModelFile(name: "p.gguf", url: URL(string: "https://huggingface.co/x/y/resolve/main/p.gguf")!, size: Int64(data.count), sha256: h.finalizeHex())
    }

    func importer(disk: Int64? = Int64.max, published file: RemoteModelFile) -> Kitten2Importer {
        Kitten2Importer(availableDisk: { _ in disk }, published: file)
    }

    func testImportsPublishedSizeFileAndVerifiesChecksum() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        let record = try importer(published: published(data)).install(source: src, installDirectory: install, stagingDirectory: staging)
        XCTAssertTrue(record.checksumVerified)
        XCTAssertEqual(record.originalName, "mine.gguf")
        let active = try XCTUnwrap(Kitten2Library.active(in: install))
        guard case .imported(let stored?) = active.source else { return XCTFail("record missing") }
        XCTAssertEqual(stored.sha256, record.sha256)
        XCTAssertTrue(stored.checksumVerified)
        XCTAssertEqual(try Data(contentsOf: active.url), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testDifferentExportIsAcceptedWithoutChecksumClaim() throws {
        let data = fixtures.audiocppFixture()
        let other = published(data + Data(repeating: 0, count: 10))
        // smaller than the published size is rejected as probably incomplete…
        XCTAssertThrowsError(try importer(published: other).install(source: try write(data), installDirectory: install, stagingDirectory: staging))
        // …a larger different export installs but is never labelled as checksum-verified
        let smaller = published(Data(repeating: 0, count: 100))
        let record = try importer(published: smaller).install(source: try write(data), installDirectory: install, stagingDirectory: staging)
        XCTAssertFalse(record.checksumVerified)
    }

    func testPublishedSizeWithWrongChecksumIsRejected() throws {
        let data = fixtures.audiocppFixture()
        var expected = published(data)
        expected.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try importer(published: expected).install(source: try write(data), installDirectory: install, stagingDirectory: staging)) {
            XCTAssertEqual($0 as? Kitten2ImportError, .checksumMismatch)
        }
        XCTAssertNil(Kitten2Library.active(in: install))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testInvalidImportsKeepExistingInstall() throws {
        let good = fixtures.audiocppFixture()
        let file = published(good)
        _ = try importer(published: file).install(source: try write(good), installDirectory: install, stagingDirectory: staging)
        let before = try Data(contentsOf: install.appendingPathComponent(Kitten2Library.importedFileName))

        let bad: [(String, Data)] = [
            ("notgguf.gguf", Data("hello world".utf8)),
            ("empty.gguf", Data()),
            ("otherfamily.gguf", fixtures.audiocppFixture(family: "other_family")),
            ("llama.gguf", fixtures.audiocppFixture(arch: "llama")),
        ]
        for (name, data) in bad {
            XCTAssertThrowsError(try importer(published: file).install(source: try write(data, name), installDirectory: install, stagingDirectory: staging), name)
        }
        XCTAssertEqual(try Data(contentsOf: install.appendingPathComponent(Kitten2Library.importedFileName)), before)
    }

    func testUnsupportedErrorExplainsFamily() throws {
        let data = fixtures.audiocppFixture(arch: "qwen3")
        XCTAssertThrowsError(try importer(published: published(data)).install(source: try write(data), installDirectory: install, stagingDirectory: staging)) {
            guard case .unsupported(let text)? = $0 as? Kitten2ImportError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("audio.cpp"), text)
        }
    }

    func testInsufficientStorageIsReportedBeforeCopying() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        XCTAssertThrowsError(try importer(disk: 10, published: published(data)).install(source: src, installDirectory: install, stagingDirectory: staging)) {
            guard case .insufficientDisk(let need, let have)? = $0 as? Kitten2ImportError else { return XCTFail("\($0)") }
            XCTAssertEqual(need, Int64(data.count) + StorageAssessment.headroom)
            XCTAssertEqual(have, 10)
        }
        XCTAssertNil(Kitten2Library.active(in: install))
    }

    func testUnknownCapacityProceeds() throws {
        let data = fixtures.audiocppFixture()
        _ = try importer(disk: nil, published: published(data)).install(source: try write(data), installDirectory: install, stagingDirectory: staging)
        XCTAssertNotNil(Kitten2Library.imported(in: install))
    }

    func testCancelledImportLeavesNothingBehind() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        XCTAssertThrowsError(try importer(published: published(data)).install(source: src, installDirectory: install, stagingDirectory: staging, isCancelled: { true })) {
            XCTAssertEqual($0 as? Kitten2ImportError, .cancelled)
        }
        XCTAssertNil(Kitten2Library.active(in: install))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testReimportReplacesAndDeleteRemovesOnlyImported() throws {
        let data = fixtures.audiocppFixture()
        let file = published(data)
        _ = try importer(published: file).install(source: try write(data), installDirectory: install, stagingDirectory: staging)
        _ = try importer(published: file).install(source: try write(data, "again.gguf"), installDirectory: install, stagingDirectory: staging)
        guard case .imported(let record)? = Kitten2Library.active(in: install)?.source else { return XCTFail() }
        XCTAssertEqual(record?.originalName, "again.gguf")
        Kitten2Library.deleteImported(in: install)
        XCTAssertNil(Kitten2Library.active(in: install))
    }

    func testStatusIsIndependentPerOperation() {
        var s = OperationStatus<Kitten2Operation>()
        s.error("Not enough free storage", for: .modelDownload)
        s.error("Microphone access is off", for: .referenceAudio)
        XCTAssertEqual(s[.modelDownload]?.text, "Not enough free storage")
        XCTAssertEqual(s[.referenceAudio]?.text, "Microphone access is off")
        s.info("Done", for: .synthesis)
        XCTAssertEqual(s[.modelDownload]?.isError, true)
        s.clear(.referenceAudio)
        XCTAssertNil(s[.referenceAudio])
        XCTAssertEqual(s[.modelDownload]?.text, "Not enough free storage")
        XCTAssertNil(s[.playback])
        XCTAssertEqual(s[.synthesis], StatusMessage("Done"))
        // beginning a new download clears only the download message
        s.clear(.modelDownload)
        XCTAssertNil(s[.modelDownload])
        XCTAssertEqual(s[.synthesis]?.text, "Done")
    }

    func testLegacyStatusIndependentOfKitten2() {
        var legacy = OperationStatus<LegacyOperation>()
        legacy.error("Playback failed", for: .playback)
        legacy.info("Imported", for: .modelSetup)
        XCTAssertEqual(legacy[.playback]?.text, "Playback failed")
        XCTAssertNil(legacy[.synthesis])
    }

    func testLegacyRepositoryLinks() {
        XCTAssertEqual(LegacyVariant.nano.repositoryPage.absoluteString, "https://huggingface.co/KittenML/kitten-tts-nano-0.8")
        XCTAssertEqual(LegacyVariant.nanoInt8.repositoryPage.absoluteString, "https://huggingface.co/KittenML/kitten-tts-nano-0.8-int8")
        XCTAssertEqual(LegacyVariant.micro.repositoryPage.absoluteString, "https://huggingface.co/KittenML/kitten-tts-micro-0.8")
        XCTAssertEqual(LegacyVariant.mini.repositoryPage.absoluteString, "https://huggingface.co/KittenML/kitten-tts-mini-0.8")
    }
}
