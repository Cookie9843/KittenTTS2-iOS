import XCTest
@testable import KittenCore

final class StorageAssessmentTests: XCTestCase {
    let gb: Int64 = 1_000_000_000
    let headroom = StorageAssessment.headroom

    // MARK: capacity semantics

    func testUsableIsLargerPositiveValue() {
        XCTAssertEqual(StorageCapacity(importantUsage: 5 * gb, available: 2 * gb).usable, 5 * gb)
        XCTAssertEqual(StorageCapacity(importantUsage: 2 * gb, available: 5 * gb).usable, 5 * gb)
    }

    /// Previously the "important usage" value was trusted even when it was 0, which reported a roomy volume as full.
    func testZeroImportantUsageFallsBackToAvailable() {
        XCTAssertEqual(StorageCapacity(importantUsage: 0, available: 9 * gb).usable, 9 * gb)
        XCTAssertEqual(StorageCapacity(importantUsage: nil, available: 9 * gb).usable, 9 * gb)
        XCTAssertEqual(StorageCapacity(importantUsage: -1, available: 9 * gb).usable, 9 * gb)
    }

    func testUnavailableVersusTrulyFull() {
        XCTAssertNil(StorageCapacity(importantUsage: nil, available: nil).usable)
        XCTAssertEqual(StorageCapacity(importantUsage: 0, available: 0).usable, 0)
        XCTAssertEqual(StorageCapacity(importantUsage: nil, available: 0).usable, 0)
    }

    func testMissingPathUsesNearestExistingParent() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)/a/b", isDirectory: true)
        XCTAssertNotNil(StorageCapacity.usableBytes(at: missing))
    }

    // MARK: requirements

    func testFullDownloadNeedsSizePlusHeadroom() {
        let r = StorageAssessment.requiredBytes(for: .download(totalBytes: 3 * gb, alreadyPresent: 0))
        XCTAssertEqual(r.required, 3 * gb + headroom)
        XCTAssertEqual(r.present, 0)
    }

    func testResumeOnlyCountsRemainingBytes() {
        let r = StorageAssessment.requiredBytes(for: .download(totalBytes: 3 * gb, alreadyPresent: 2 * gb))
        XCTAssertEqual(r.required, gb + headroom)
        XCTAssertEqual(r.present, 2 * gb)
    }

    /// A 2.9 GB partial with 1 GB free: the old arithmetic agreed, but a complete partial must need nothing at all.
    func testCompletePartialNeedsNoSpace() {
        XCTAssertEqual(StorageAssessment.requiredBytes(for: .download(totalBytes: gb, alreadyPresent: gb)).required, 0)
        XCTAssertEqual(StorageAssessment.assess(.download(totalBytes: gb, alreadyPresent: gb), availableBytes: 0).outcome, .sufficient)
    }

    func testPartialLargerThanFileIsClamped() {
        let r = StorageAssessment.requiredBytes(for: .download(totalBytes: gb, alreadyPresent: 5 * gb))
        XCTAssertEqual(r.required, 0)
        XCTAssertEqual(r.present, gb)
    }

    func testImportNeedsFullCopyPlusHeadroom() {
        XCTAssertEqual(StorageAssessment.requiredBytes(for: .importCopy(totalBytes: 3 * gb)).required, 3 * gb + headroom)
    }

    func testOverflowSaturates() {
        let r = StorageAssessment.requiredBytes(for: .importCopy(totalBytes: Int64.max))
        XCTAssertEqual(r.required, Int64.max)
        let a = StorageAssessment.assess(.importCopy(totalBytes: Int64.max), availableBytes: 1)
        XCTAssertEqual(a.outcome, .insufficient)
        XCTAssertEqual(a.shortfall, Int64.max - 1)
    }

    // MARK: outcomes

    func testBoundaryEquality() {
        let op = StorageOperation.download(totalBytes: gb, alreadyPresent: 0)
        let need = gb + headroom
        XCTAssertEqual(StorageAssessment.assess(op, availableBytes: need).outcome, .sufficient)
        let short = StorageAssessment.assess(op, availableBytes: need - 1)
        XCTAssertEqual(short.outcome, .insufficient)
        XCTAssertEqual(short.shortfall, 1)
        XCTAssertEqual(short.requiredBytes, need)
        XCTAssertEqual(short.availableBytes, need - 1)
    }

    func testUnavailableCapacityIsUnknownNotInsufficient() {
        let a = StorageAssessment.assess(.importCopy(totalBytes: gb), availableBytes: nil)
        XCTAssertEqual(a.outcome, .unknown)
        XCTAssertNil(a.shortfall)
    }

    /// Resuming with enough space for the remainder must pass even though the full size would not fit.
    func testResumeFitsWhereFullDownloadWouldNot() {
        let available = 1 * gb // 0.5 GB remaining + headroom fits; 3 GB does not
        XCTAssertEqual(StorageAssessment.assess(.download(totalBytes: 3 * gb, alreadyPresent: 0), availableBytes: available).outcome, .insufficient)
        XCTAssertEqual(StorageAssessment.assess(.download(totalBytes: 3 * gb, alreadyPresent: 2_500_000_000), availableBytes: available).outcome, .sufficient)
    }

    // MARK: downloader integration (path choice, resume accounting, message numbers)

    func testDownloaderChecksStagingDirectoryAndResumeBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appendingPathComponent("staging"), install = dir.appendingPathComponent("install")
        let payload = Data(repeating: 1, count: 1000)
        var h = SHA256Hasher(); h.update(payload)
        let file = RemoteModelFile(name: "m.gguf", url: URL(string: "https://huggingface.co/x/y/resolve/main/m.gguf")!, size: 1000, sha256: h.finalizeHex())
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 600).write(to: ModelDownloader.partialURL(for: file, in: staging))

        let asked = LockedBox<[String]>([])
        let d = ModelDownloader(transport: MockTransport { _ in (206, 600, [Data(repeating: 1, count: 400)], false) },
                                availableDisk: { url in asked.value.append(url.lastPathComponent); return 400 + StorageAssessment.headroom })
        _ = try await d.download(file, stagingDirectory: staging, installDirectory: install) { _ in }
        XCTAssertEqual(asked.value, ["staging"])
    }

    func testInsufficientMessageShowsMeasuredNumbers() {
        let text = DownloadError.insufficientDisk(needed: 3_000_000_000, available: 1_000_000_000, alreadyDownloaded: 500_000_000).localizedDescription
        XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)), text)
        XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 1_000_000_000, countStyle: .file)), text)
        XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 500_000_000, countStyle: .file)), text)
    }
}
