import XCTest
@testable import KittenCore

final class LegacyModelStoreTests: XCTestCase {
    var root: URL!
    var store: LegacyModelStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LegacyModelStore(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func put(_ variant: LegacyVariant, onnx: Bool = true, voices: Bool = true) throws {
        let dir = store.directory(for: variant)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if onnx { try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent(variant.onnxFileName)) }
        if voices { try Data(repeating: 2, count: 50).write(to: dir.appendingPathComponent(variant.voicesFileName)) }
    }

    func testInstalledNeedsBothNonEmptyFiles() throws {
        XCTAssertFalse(store.isInstalled(.nano))
        try put(.nano, voices: false)
        XCTAssertFalse(store.isInstalled(.nano))
        try put(.nano)
        XCTAssertTrue(store.isInstalled(.nano))
        XCTAssertEqual(store.installedBytes(.nano), 150)
        try Data().write(to: store.directory(for: .nano).appendingPathComponent(LegacyVariant.nano.voicesFileName))
        XCTAssertFalse(store.isInstalled(.nano))
    }

    func testDeleteRemovesOnlyThatVariant() throws {
        try put(.nano); try put(.mini)
        try store.delete(.nano)
        XCTAssertFalse(store.exists(.nano))
        XCTAssertTrue(store.isInstalled(.mini))
        XCTAssertNoThrow(try store.delete(.nano), "deleting a missing model is not an error")
    }

    func testDeleteIsRefusedWhileTheModelIsInUseAndKeepsFiles() throws {
        try put(.micro)
        XCTAssertThrowsError(try store.delete(.micro, inUse: true)) { XCTAssertEqual($0 as? LegacyModelError, .inUse) }
        XCTAssertTrue(store.isInstalled(.micro))
        try store.delete(.micro, inUse: false)
        XCTAssertFalse(store.exists(.micro))
    }

    func testCancelledDownloadDiscardsPartialFilesAndAllowsRetry() throws {
        try put(.nano, voices: false) // model finished, voices still missing when the user cancelled
        XCTAssertEqual(store.finishDownload(.nano, wasInstalledBefore: false, cancelled: true), .discarded)
        XCTAssertFalse(store.exists(.nano))
        try put(.nano)  // a later retry completes
        XCTAssertEqual(store.finishDownload(.nano, wasInstalledBefore: false, cancelled: false), .installed)
        XCTAssertTrue(store.isInstalled(.nano))
    }

    func testCancelAfterBothFilesArrivedStillDiscards() throws {
        try put(.nanoInt8)
        XCTAssertEqual(store.finishDownload(.nanoInt8, wasInstalledBefore: false, cancelled: true), .discarded)
        XCTAssertFalse(store.isInstalled(.nanoInt8))
    }

    func testFailedDownloadLeavesNoHalfInstalledFolder() throws {
        try put(.mini, onnx: false)
        XCTAssertEqual(store.finishDownload(.mini, wasInstalledBefore: false, cancelled: false), .incomplete)
        XCTAssertFalse(store.exists(.mini))
    }

    func testAnAlreadyInstalledModelSurvivesACancelledOrFailedDownload() throws {
        try put(.nano)
        XCTAssertEqual(store.finishDownload(.nano, wasInstalledBefore: true, cancelled: true), .installed)
        XCTAssertEqual(store.finishDownload(.nano, wasInstalledBefore: true, cancelled: false), .installed)
        XCTAssertTrue(store.isInstalled(.nano))
    }

    func testVariantsAreIndependent() throws {
        try put(.nano)
        XCTAssertEqual(store.finishDownload(.micro, wasInstalledBefore: false, cancelled: true), .discarded)
        XCTAssertTrue(store.isInstalled(.nano))
    }
}
