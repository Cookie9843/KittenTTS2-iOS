import XCTest
@testable import KittenCore

struct MockTransport: DownloadTransport {
    /// Called with (rangeStart); returns the response plan.
    var handler: @Sendable (Int64?) throws -> (status: Int, rangeStart: Int64?, chunks: [Data], failAfter: Bool)
    func request(url: URL, rangeStart: Int64?) async throws -> DownloadResponse {
        let plan = try handler(rangeStart)
        let stream = AsyncThrowingStream<Data, Error> { c in
            for chunk in plan.chunks { c.yield(chunk) }
            if plan.failAfter { c.finish(throwing: URLError(.networkConnectionLost)) } else { c.finish() }
        }
        return DownloadResponse(statusCode: plan.status, contentRangeStart: plan.rangeStart, body: stream)
    }
}

final class ModelDownloaderTests: XCTestCase {
    var dir: URL!
    let payload = Data((0..<5000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var staging: URL { dir.appendingPathComponent("staging") }
    var install: URL { dir.appendingPathComponent("kitten2") }

    func file(_ data: Data? = nil, sha: String? = nil) -> RemoteModelFile {
        let d = data ?? payload
        var h = SHA256Hasher(); h.update(d)
        return RemoteModelFile(name: "m.gguf", url: URL(string: "https://huggingface.co/x/y/resolve/main/m.gguf")!, size: Int64(d.count), sha256: sha ?? h.finalizeHex())
    }
    func chunks(_ d: Data, from: Int = 0, size: Int = 700) -> [Data] {
        stride(from: from, to: d.count, by: size).map { d.subdata(in: $0..<min($0 + size, d.count)) }
    }
    func downloader(disk: Int64? = nil, _ transport: MockTransport) -> ModelDownloader {
        ModelDownloader(transport: transport, availableDisk: { _ in disk })
    }

    func testSHA256KnownVectors() {
        var h = PortableSHA256(); h.update(Data("abc".utf8))
        XCTAssertEqual(h.finalizeHex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var e = PortableSHA256()
        XCTAssertEqual(e.finalizeHex(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // multi-block input split at awkward boundaries must match a single update (and the platform hasher)
        let big = Data((0..<1000).map { UInt8($0 & 0xff) })
        var a = PortableSHA256(); a.update(big)
        var b = PortableSHA256(); b.update(big.prefix(63)); b.update(big.dropFirst(63).prefix(130)); b.update(big.dropFirst(193))
        var c = SHA256Hasher(); c.update(big)
        let ha = a.finalizeHex()
        XCTAssertEqual(ha, b.finalizeHex())
        XCTAssertEqual(ha, c.finalizeHex())
    }

    func testPublishedManifestIsPinned() {
        let f = Kitten2Package.file
        XCTAssertNil(f.validationProblem)
        XCTAssertEqual(f.name, "kitten-tts2-native-q8-multilingual.gguf")
        XCTAssertEqual(f.size, 3_282_123_776)
        XCTAssertEqual(f.sha256, "e97920ca5053f9fcd4de638dcd8114ed2510d4291a93257473a8843c3ff349ad")
        XCTAssertEqual(f.url.absoluteString, "https://huggingface.co/dignome/kitten_tts2/resolve/main/kitten-tts2-native-q8-multilingual.gguf")
    }

    func testManifestRejectsUnsafeEntries() {
        let ok = file()
        var bad = ok; bad.name = "../evil"
        XCTAssertNotNil(bad.validationProblem)
        bad = ok; bad.url = URL(string: "http://huggingface.co/a")!
        XCTAssertNotNil(bad.validationProblem)
        bad = ok; bad.url = URL(string: "https://evil.example/a")!
        XCTAssertNotNil(bad.validationProblem)
        bad = ok; bad.sha256 = "zz"
        XCTAssertNotNil(bad.validationProblem)
    }

    func testFreshDownloadVerifiesAndInstallsAtomically() async throws {
        let d = downloader(MockTransport { range in
            XCTAssertNil(range)
            return (200, nil, self.chunks(self.payload), false)
        })
        let last = LockedBox<DownloadProgress?>(nil)
        let url = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { last.value = $0 }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.partialURL(for: file(), in: staging).path))
        XCTAssertEqual(last.value?.stage, .installing)
        XCTAssertTrue(InstalledModels.isInstalled(file(), in: install))
        XCTAssertTrue(try InstalledModels.verify(file(), in: install))
    }

    func testResumeUsesRangeAndAppends() async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try payload.prefix(1800).write(to: ModelDownloader.partialURL(for: file(), in: staging))
        let d = downloader(MockTransport { range in
            XCTAssertEqual(range, 1800)
            return (206, 1800, self.chunks(self.payload, from: 1800), false)
        })
        let url = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1000).write(to: ModelDownloader.partialURL(for: file(), in: staging))
        let d = downloader(MockTransport { _ in (200, nil, self.chunks(self.payload), false) })
        let url = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testRange416DiscardsPartialAndRestarts() async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1000).write(to: ModelDownloader.partialURL(for: file(), in: staging))
        let calls = LockedBox<[Int64?]>([])
        let d = downloader(MockTransport { range in
            calls.value.append(range)
            return range == nil ? (200, nil, self.chunks(self.payload), false) : (416, nil, [], false)
        })
        let url = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(calls.value, [1000, nil])
    }

    func testDroppedConnectionKeepsPartialAndCanResume() async throws {
        let flag = LockedBox(true)
        let d = downloader(MockTransport { range in
            if flag.value { flag.value = false; return (200, nil, self.chunks(Data(self.payload.prefix(2100))), true) }
            return (206, range, self.chunks(self.payload, from: Int(range ?? 0)), false)
        })
        do {
            _ = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
            XCTFail("expected network error")
        } catch let error as DownloadError {
            guard case .network = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(d.partialBytes(for: file(), in: staging), 2100)
        let url = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testChecksumMismatchDiscardsAndLeavesExistingInstallUntouched() async throws {
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: install.appendingPathComponent("m.gguf"))
        let wrong = file(sha: String(repeating: "0", count: 64))
        let d = downloader(MockTransport { _ in (200, nil, self.chunks(self.payload), false) })
        do {
            _ = try await d.download(wrong, stagingDirectory: staging, installDirectory: install) { _ in }
            XCTFail("expected checksum error")
        } catch let error as DownloadError {
            guard case .checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: install.appendingPathComponent("m.gguf")), Data("old".utf8))
        XCTAssertEqual(d.partialBytes(for: wrong, in: staging), 0)
    }

    func testTooManyBytesIsSizeMismatch() async throws {
        let d = downloader(MockTransport { _ in (200, nil, self.chunks(self.payload + Data(repeating: 1, count: 10)), false) })
        do {
            _ = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
            XCTFail("expected size error")
        } catch let error as DownloadError {
            guard case .sizeMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(d.partialBytes(for: file(), in: staging), 0)
    }

    func testInsufficientDiskFailsBeforeAnyRequest() async throws {
        let called = LockedBox(false)
        let d = downloader(disk: 1000, MockTransport { _ in called.value = true; return (200, nil, [], false) })
        do {
            _ = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }
            XCTFail("expected disk error")
        } catch let error as DownloadError {
            guard case .insufficientDisk = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(called.value)
    }

    func testHTTPErrorsAndInvalidManifest() async throws {
        let d = downloader(MockTransport { _ in (503, nil, [], false) })
        do { _ = try await d.download(file(), stagingDirectory: staging, installDirectory: install) { _ in }; XCTFail() }
        catch let error as DownloadError { XCTAssertEqual(error, .http(503)) }
        var bad = file(); bad.name = "a/b"
        do { _ = try await d.download(bad, stagingDirectory: staging, installDirectory: install) { _ in }; XCTFail() }
        catch let error as DownloadError { guard case .invalidManifest = error else { return XCTFail("\(error)") } }
    }

    func testCancellationKeepsPartialForResume() async throws {
        let started = LockedBox(false)
        let transport = MockTransport { _ in
            started.value = true
            return (200, nil, self.chunks(Data(self.payload.prefix(3000))), false) // then stream ends early
        }
        let d = downloader(transport)
        let task = Task { try await d.download(self.file(), stagingDirectory: self.staging, installDirectory: self.install) { _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancel/network error") } catch is DownloadError {}
        XCTAssertFalse(InstalledModels.isInstalled(file(), in: install))
    }

    func testDeleteRemovesInstalledAndPartial() throws {
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try payload.write(to: install.appendingPathComponent("m.gguf"))
        try payload.write(to: ModelDownloader.partialURL(for: file(), in: staging))
        XCTAssertTrue(InstalledModels.isInstalled(file(), in: install))
        InstalledModels.delete(file(), installDirectory: install, stagingDirectory: staging)
        XCTAssertFalse(InstalledModels.isInstalled(file(), in: install))
        XCTAssertEqual(ModelDownloader(transport: MockTransport { _ in (200, nil, [], false) }, availableDisk: { _ in nil }).partialBytes(for: file(), in: staging), 0)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
