import Foundation

public struct GGUFInfo: Equatable, Sendable {
    public var version: UInt32
    public var tensorCount: UInt64
    public var architecture: String?
    public var fileType: UInt32?

    /// Human-readable name of `general.file_type` for the values relevant to KittenTTS 2.
    public var fileTypeName: String? {
        guard let fileType else { return nil }
        switch fileType {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 7: return "Q8_0"
        case 42: return "TQ2_1 (KittenTTS 2 fork)"
        default: return "file type \(fileType)"
        }
    }
}

public enum FileFormat: Equatable, Sendable {
    case gguf(GGUFInfo)
    case onnx
    case npz(entries: [String])
    case torchArchive
    case zipOther
    case safetensors
    case json
    case unknown
    case empty
}

public struct DetectedFile: Equatable, Sendable {
    public var url: URL
    public var size: Int64
    public var format: FileFormat
    public var name: String { url.lastPathComponent }
}

public enum FileFormatDetector {
    public static func detect(url: URL) throws -> DetectedFile {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return DetectedFile(url: url, size: 0, format: .empty) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 16) ?? Data()
        let bytes = [UInt8](head)
        let ext = url.pathExtension.lowercased()

        if bytes.count >= 4, bytes[0...3] == [0x47, 0x47, 0x55, 0x46] {
            return DetectedFile(url: url, size: size, format: .gguf(try parseGGUF(handle: handle, size: size)))
        }
        if bytes.count >= 4, bytes[0...1] == [0x50, 0x4B], [[0x03, 0x04], [0x05, 0x06]].contains(Array(bytes[2...3])) {
            let names = (try? zipEntryNames(handle: handle, size: size)) ?? []
            if names.contains(where: { $0.hasSuffix(".npy") }) {
                return DetectedFile(url: url, size: size, format: .npz(entries: names))
            }
            if names.contains(where: { $0.hasSuffix("data.pkl") || $0.hasSuffix("constants.pkl") || $0.hasSuffix("version") }) {
                return DetectedFile(url: url, size: size, format: .torchArchive)
            }
            return DetectedFile(url: url, size: size, format: .zipOther)
        }
        if bytes.count >= 9, bytes[8] == 0x7B, size > 8 {
            let headerLength = bytes[0..<8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            if headerLength > 1 && headerLength < UInt64(size) - 8 && headerLength < 100_000_000 {
                return DetectedFile(url: url, size: size, format: .safetensors)
            }
        }
        if let first = bytes.first(where: { ![0x20, 0x0A, 0x0D, 0x09].contains($0) }), first == 0x7B || first == 0x5B, ext == "json" {
            return DetectedFile(url: url, size: size, format: .json)
        }
        if ext == "onnx", bytes.count >= 2, bytes[0] == 0x08, (1...20).contains(bytes[1]) {
            return DetectedFile(url: url, size: size, format: .onnx)
        }
        return DetectedFile(url: url, size: size, format: .unknown)
    }

    // MARK: GGUF

    private struct Reader {
        let handle: FileHandle
        let limit: UInt64
        var position: UInt64 = 0

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position + UInt64(count) <= limit else { throw CocoaError(.fileReadCorruptFile) }
            try handle.seek(toOffset: position)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
            position += UInt64(count)
            return [UInt8](data)
        }
        mutating func uint(_ width: Int) throws -> UInt64 {
            try bytes(width).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        mutating func string() throws -> String {
            let length = try uint(8)
            guard length < 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            return String(decoding: try bytes(Int(length)), as: UTF8.self)
        }
        mutating func skip(_ count: UInt64) throws {
            guard position + count <= limit else { throw CocoaError(.fileReadCorruptFile) }
            position += count
        }
    }

    private static func scalarWidth(_ type: UInt32) -> Int? {
        switch type {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }

    private static func skipValue(_ r: inout Reader, type: UInt32) throws {
        if let width = scalarWidth(type) { try r.skip(UInt64(width)); return }
        if type == 8 { let length = try r.uint(8); try r.skip(length); return }
        if type == 9 {
            let elementType = UInt32(try r.uint(4))
            let count = try r.uint(8)
            if let width = scalarWidth(elementType) { try r.skip(count * UInt64(width)); return }
            guard count < 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            for _ in 0..<count { try skipValue(&r, type: elementType) }
            return
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func parseGGUF(handle: FileHandle, size: Int64) throws -> GGUFInfo {
        var r = Reader(handle: handle, limit: UInt64(size))
        try r.skip(4)
        let version = UInt32(try r.uint(4))
        let tensorCount = try r.uint(8)
        let kvCount = try r.uint(8)
        var info = GGUFInfo(version: version, tensorCount: tensorCount, architecture: nil, fileType: nil)
        // Metadata the app needs sits among the first keys; stop early rather than walking huge tokenizer arrays.
        for _ in 0..<min(kvCount, 64) {
            guard let key = try? r.string(), let type = try? r.uint(4).asUInt32 else { break }
            if key == "general.architecture", type == 8, let value = try? r.string() {
                info.architecture = value
            } else if key == "general.file_type", type == 4, let value = try? r.uint(4) {
                info.fileType = UInt32(value)
            } else if (try? skipValue(&r, type: type)) == nil {
                break
            }
            if info.architecture != nil && info.fileType != nil { break }
        }
        return info
    }

    // MARK: ZIP central directory

    static func zipEntryNames(handle: FileHandle, size: Int64) throws -> [String] {
        let tailLength = min(Int64(65_557), size)
        try handle.seek(toOffset: UInt64(size - tailLength))
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22, let eocd = (0...(tail.count - 22)).reversed().first(where: {
            tail[$0...($0 + 3)] == [0x50, 0x4B, 0x05, 0x06]
        }) else { throw CocoaError(.fileReadCorruptFile) }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) } }
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        let count = u16(tail, eocd + 10)
        let cdSize = u32(tail, eocd + 12)
        let cdOffset = u32(tail, eocd + 16)
        guard cdOffset != 0xFFFF_FFFF, cdSize < 16_000_000, cdOffset + cdSize <= UInt64(size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try handle.seek(toOffset: cdOffset)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())
        var names: [String] = []
        var i = 0
        while i + 46 <= cd.count, names.count < count, cd[i...(i + 3)] == [0x50, 0x4B, 0x01, 0x02] {
            let nameLen = u16(cd, i + 28), extraLen = u16(cd, i + 30), commentLen = u16(cd, i + 32)
            guard i + 46 + nameLen <= cd.count else { break }
            names.append(String(decoding: cd[(i + 46)..<(i + 46 + nameLen)], as: UTF8.self))
            i += 46 + nameLen + extraLen + commentLen
        }
        return names
    }
}

private extension UInt64 {
    var asUInt32: UInt32 { UInt32(truncatingIfNeeded: self) }
}
