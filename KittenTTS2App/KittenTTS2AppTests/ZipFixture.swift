import Foundation

/// Builds minimal "stored" ZIP archives so tests do not need proprietary model assets.
enum ZipFixture {
    static func make(names: [String], zip64: Bool = false) -> Data {
        var out = Data()
        var central = Data()
        for name in names {
            let offset = UInt32(out.count)
            let nameBytes = Array(name.utf8)
            let payload = Data([1, 2, 3])
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            out += le32(0) + le32(UInt32(payload.count)) + le32(UInt32(payload.count))
            out += le16(UInt16(nameBytes.count)) + le16(0) + Data(nameBytes) + payload

            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(payload.count)) + le32(UInt32(payload.count))
            central += le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            central += Data(nameBytes)
        }
        let centralOffset = out.count
        out += central
        if zip64 {
            let recordOffset = out.count
            out += le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            out += le64(UInt64(names.count)) + le64(UInt64(names.count)) + le64(UInt64(central.count)) + le64(UInt64(centralOffset))
            out += le32(0x0706_4B50) + le32(0) + le64(UInt64(recordOffset)) + le32(1)
            out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF)
            out += le32(UInt32(central.count)) + le32(0xFFFF_FFFF) + le16(0)
        } else {
            out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(names.count)) + le16(UInt16(names.count))
            out += le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0)
        }
        return out
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
