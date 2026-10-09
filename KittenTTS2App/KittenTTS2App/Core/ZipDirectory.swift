import Foundation

enum ZipDirectoryError: Error, Equatable {
    case notAZip
    case corrupt
}

/// Reads entry names from a ZIP central directory (including ZIP64) without decompressing anything.
enum ZipDirectory {
    static func entryNames(in data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipDirectoryError.notAZip }

        guard let eocd = findEndOfCentralDirectory(bytes) else { throw ZipDirectoryError.notAZip }

        var entryCount = Int(u16(bytes, eocd + 10))
        var directoryOffset = Int(u32(bytes, eocd + 16))

        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, u32(bytes, locator) == 0x0706_4B50 else { throw ZipDirectoryError.corrupt }
            let recordOffset = Int(truncatingIfNeeded: u64(bytes, locator + 8))
            guard recordOffset >= 0, recordOffset + 56 <= bytes.count,
                  u32(bytes, recordOffset) == 0x0606_4B50 else { throw ZipDirectoryError.corrupt }
            entryCount = Int(truncatingIfNeeded: u64(bytes, recordOffset + 32))
            directoryOffset = Int(truncatingIfNeeded: u64(bytes, recordOffset + 48))
        }

        guard entryCount >= 0, directoryOffset >= 0, directoryOffset <= bytes.count,
              entryCount <= bytes.count / 46 else { throw ZipDirectoryError.corrupt }

        var names: [String] = []
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard cursor >= 0, cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4B50 else {
                throw ZipDirectoryError.corrupt
            }
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipDirectoryError.corrupt }
            names.append(String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return names
    }

    /// Names of `.npy` members with the extension removed (NumPy `.npz` keys).
    static func npzKeys(in data: Data) throws -> [String] {
        try entryNames(in: data).compactMap { name in
            name.hasSuffix(".npy") ? String(name.dropLast(4)) : nil
        }
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var index = bytes.count - 22
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(u16(b, o)) | UInt32(u16(b, o + 2)) << 16
    }

    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }
}
