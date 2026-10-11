import XCTest
@testable import KittenCore

final class IncreasedMemoryLimitCheckTests: XCTestCase {
    private let entitlementKey = "com.apple.developer.kernel.increased-memory-limit"

    private func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private func signature(entitlementValue: Any) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: [entitlementKey: entitlementValue],
                                                       format: .xml, options: 0)
        let blob = be(0xfade7171) + be(UInt32(plist.count + 8)) + plist
        let length = UInt32(20 + blob.count)
        return Data(be(0xfade0cc0) + be(length) + be(1) + be(0) + be(20) + blob)
    }

    func testDetectsEnabledEntitlement() throws {
        XCTAssertEqual(IncreasedMemoryLimitCheck.status(in: signature(entitlementValue: true)), .enabled)
    }

    func testDetectsMissingEntitlement() throws {
        XCTAssertEqual(IncreasedMemoryLimitCheck.status(in: signature(entitlementValue: false)), .notEnabled)
    }

    func testDoesNotTreatDEROnlySignatureAsEntitlementAbsent() {
        let derBlob = be(0xfade7172) + be(8)
        let signature = Data(be(0xfade0cc0) + be(28) + be(1) + be(0) + be(20) + derBlob)
        XCTAssertEqual(IncreasedMemoryLimitCheck.status(in: signature), .unableToCheck)
    }

    func testRejectsMalformedSignature() {
        XCTAssertEqual(IncreasedMemoryLimitCheck.status(in: Data([1, 2, 3])), .unableToCheck)
    }
}
