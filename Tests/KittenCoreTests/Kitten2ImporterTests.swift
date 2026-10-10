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

    // MARK: Failure recovery (no relaunch)

    func testRetryAfterCancelOnTheSameImporterSucceedsAndLeavesNoPartial() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        let sut = importer(published: published(data))
        XCTAssertThrowsError(try sut.install(source: src, installDirectory: install, stagingDirectory: staging, isCancelled: { true })) {
            XCTAssertEqual($0 as? Kitten2ImportError, .cancelled)
        }
        XCTAssertNil(Kitten2Library.active(in: install))
        let record = try sut.install(source: src, installDirectory: install, stagingDirectory: staging)
        XCTAssertTrue(record.checksumVerified)
        XCTAssertEqual(try Data(contentsOf: install.appendingPathComponent(Kitten2Library.importedFileName)), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testRetryAfterSourceDisappearedSucceeds() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        let sut = importer(published: published(data))
        try FileManager.default.removeItem(at: src)
        XCTAssertThrowsError(try sut.install(source: src, installDirectory: install, stagingDirectory: staging)) {
            guard case .unreadable? = $0 as? Kitten2ImportError else { return XCTFail("\($0)") }
        }
        _ = try write(data)
        XCTAssertNoThrow(try sut.install(source: src, installDirectory: install, stagingDirectory: staging))
        XCTAssertNotNil(Kitten2Library.imported(in: install))
    }

    func testStagingProblemIsReportedWithDetailAndRetrySucceedsOnceFixed() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        let sut = importer(published: published(data))
        // a plain file where the staging folder must be makes the failure deterministic
        try Data("x".utf8).write(to: staging)
        XCTAssertThrowsError(try sut.install(source: src, installDirectory: install, stagingDirectory: staging)) {
            guard case .fileSystem(let text)? = $0 as? Kitten2ImportError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("staging folder"), text)
            XCTAssertTrue(text.contains("["), "domain and code are included: \(text)")
            XCTAssertTrue(($0 as NSError).localizedDescription.contains("try again"))
        }
        XCTAssertNil(Kitten2Library.active(in: install))
        try FileManager.default.removeItem(at: staging)
        XCTAssertNoThrow(try sut.install(source: src, installDirectory: install, stagingDirectory: staging))
        XCTAssertNotNil(Kitten2Library.imported(in: install))
    }

    func testStalePartialFromACrashedAttemptDoesNotBreakTheNextImport() throws {
        let data = fixtures.audiocppFixture()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 4096).write(to: staging.appendingPathComponent("import.partial"))
        _ = try importer(published: published(data)).install(source: try write(data), installDirectory: install, stagingDirectory: staging)
        XCTAssertEqual(try Data(contentsOf: install.appendingPathComponent(Kitten2Library.importedFileName)), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testFailedReplacementKeepsExistingFileAndItsRecord() throws {
        let good = fixtures.audiocppFixture()
        let file = published(good)
        let original = try importer(published: file).install(source: try write(good, "first.gguf"), installDirectory: install, stagingDirectory: staging)
        var wrong = file
        wrong.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try importer(published: wrong).install(source: try write(good, "second.gguf"), installDirectory: install, stagingDirectory: staging))
        XCTAssertThrowsError(try importer(published: file).install(source: try write(good, "third.gguf"), installDirectory: install, stagingDirectory: staging, isCancelled: { true }))
        guard case .imported(let record?)? = Kitten2Library.active(in: install)?.source else { return XCTFail("record lost") }
        XCTAssertEqual(record.originalName, "first.gguf")
        XCTAssertEqual(record.sha256, original.sha256)
        XCTAssertEqual(try Data(contentsOf: install.appendingPathComponent(Kitten2Library.importedFileName)), good)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("import.partial").path))
    }

    func testCancelRequestedAfterTheLastChunkStillDiscardsTheImport() throws {
        let data = fixtures.audiocppFixture()
        let src = try write(data)
        let flag = Flag()
        XCTAssertThrowsError(try importer(published: published(data)).install(source: src, installDirectory: install, stagingDirectory: staging,
                                                                              progress: { if $0 >= 1 { flag.set() } }, isCancelled: { flag.value })) {
            XCTAssertEqual($0 as? Kitten2ImportError, .cancelled)
        }
        XCTAssertNil(Kitten2Library.active(in: install))
    }

    func testErrorDetailNamesDomainAndCode() {
        let text = Kitten2ImportError.detail(NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        XCTAssertEqual(text, "boom [\(NSCocoaErrorDomain) 256]")
    }

    // MARK: Header inspection does not read or map the whole file

    func testInspectReadsOnlyAHeaderWindowOfALargeFile() throws {
        let header = fixtures.audiocppFixture()
        let big = header + Data(repeating: 0, count: 3 << 20)
        let url = try write(big, "big.gguf")
        let report = try AudioCppGGUFInspector.inspect(url: url, initialWindow: 4096)
        XCTAssertEqual(report.fileSize, Int64(big.count))
        XCTAssertEqual(report.architecture, "audiocpp")
    }

    func testInspectGrowsTheWindowWhenTheHeaderIsLonger() throws {
        let header = fixtures.audiocppFixture()
        let url = try write(header + Data(repeating: 0, count: 100_000), "grow.gguf")
        // header is ~1.3 KB, first window is 1 KB: needs one growth step
        XCTAssertEqual(try AudioCppGGUFInspector.inspect(url: url, initialWindow: 1024, maxWindow: 1 << 20).architecture, "audiocpp")
        // header longer than the largest window falls back to mapping and still works
        XCTAssertEqual(try AudioCppGGUFInspector.inspect(url: url, initialWindow: 1024, maxWindow: 1024).architecture, "audiocpp")
    }

    func testInspectStillRejectsNonGGUFAndTruncatedFiles() throws {
        XCTAssertThrowsError(try AudioCppGGUFInspector.inspect(url: try write(Data(repeating: 1, count: 5000), "x.gguf"), initialWindow: 1024)) {
            XCTAssertEqual($0 as? AudioCppGGUFInspector.InspectError, .notGGUF)
        }
        let cut = fixtures.audiocppFixture().prefix(200)
        XCTAssertThrowsError(try AudioCppGGUFInspector.inspect(url: try write(Data(cut), "cut.gguf"), initialWindow: 64))
    }

    func testDeleteAllRemovesInstalledPartialAndImportStagingFiles() throws {
        let data = fixtures.audiocppFixture()
        _ = try importer(published: published(data)).install(source: try write(data), installDirectory: install, stagingDirectory: staging)
        let file = Kitten2Package.file
        try Data(repeating: 1, count: 10).write(to: ModelDownloader.partialURL(for: file, in: staging))
        try Data(repeating: 1, count: 10).write(to: staging.appendingPathComponent("import.partial"))
        try Data(repeating: 1, count: 10).write(to: InstalledModels.fileURL(file, in: install))
        Kitten2Library.deleteAll(installDirectory: install, stagingDirectory: staging)
        XCTAssertNil(Kitten2Library.active(in: install))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: install.path), [])
        // a fresh import works right after the delete
        XCTAssertNoThrow(try importer(published: published(data)).install(source: try write(data), installDirectory: install, stagingDirectory: staging))
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
