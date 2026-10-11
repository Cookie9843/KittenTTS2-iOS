import Foundation

public enum IncreasedMemoryLimitStatus: Equatable, Sendable {
    case notChecked
    case enabled
    case notEnabled
    case unableToCheck

    public var message: String {
        switch self {
        case .notChecked:
            return "Not checked."
        case .enabled:
            return "The app’s signed executable includes the Increased Memory Limit entitlement. This does not guarantee more memory is available or that iOS will allow every allocation."
        case .notEnabled:
            return "The app’s signed executable does not include the Increased Memory Limit entitlement."
        case .unableToCheck:
            return "Could not inspect the app’s code signature. This device or signing format may not expose the entitlement in a readable form."
        }
    }
}

/// Reads the app's signed entitlement from its Mach-O code signature without private iOS APIs.
public enum IncreasedMemoryLimitCheck {
    private static let entitlementKey = "com.apple.developer.kernel.increased-memory-limit"
    private static let codeSignatureCommand: UInt32 = 0x1d
    private static let embeddedSignatureMagic: UInt32 = 0xfade0cc0
    private static let entitlementBlobMagic: UInt32 = 0xfade7171
    private static let derEntitlementBlobMagic: UInt32 = 0xfade7172

    public static func check(executableURL: URL?) -> IncreasedMemoryLimitStatus {
        guard let executableURL,
              let handle = try? FileHandle(forReadingFrom: executableURL) else { return .unableToCheck }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 32), header.count == 32,
              littleEndianUInt32(header, at: 0) == 0xfeedfacf else { return .unableToCheck }
        let commandCount = littleEndianUInt32(header, at: 16)
        let commandsSize = littleEndianUInt32(header, at: 20)
        guard commandCount > 0, commandCount <= 10_000, commandsSize >= 8, commandsSize <= 4 * 1024 * 1024,
              let commands = try? handle.read(upToCount: Int(commandsSize)),
              commands.count == Int(commandsSize) else { return .unableToCheck }

        var offset = 0
        for _ in 0..<commandCount {
            guard offset <= commands.count - 8 else { return .unableToCheck }
            let command = littleEndianUInt32(commands, at: offset)
            let size = Int(littleEndianUInt32(commands, at: offset + 4))
            guard size >= 8, size <= commands.count - offset else { return .unableToCheck }
            if command == codeSignatureCommand {
                guard size >= 16 else { return .unableToCheck }
                let signatureOffset = UInt64(littleEndianUInt32(commands, at: offset + 8))
                let signatureSize = Int(littleEndianUInt32(commands, at: offset + 12))
                guard signatureSize > 0, signatureSize <= 64 * 1024 * 1024,
                      signatureOffset <= UInt64(Int64.max),
                      (try? handle.seek(toOffset: signatureOffset)) != nil,
                      let signature = try? handle.read(upToCount: signatureSize),
                      signature.count == signatureSize else { return .unableToCheck }
                return status(in: signature)
            }
            offset += size
        }
        return .unableToCheck
    }

    static func status(in signature: Data) -> IncreasedMemoryLimitStatus {
        guard signature.count >= 12, bigEndianUInt32(signature, at: 0) == embeddedSignatureMagic else {
            return .unableToCheck
        }
        let length = Int(bigEndianUInt32(signature, at: 4))
        let count = Int(bigEndianUInt32(signature, at: 8))
        guard length >= 12, length <= signature.count, count <= (length - 12) / 8 else { return .unableToCheck }

        var hasDEREntitlements = false
        for index in 0..<count {
            let entryOffset = 12 + index * 8
            let blobOffset = Int(bigEndianUInt32(signature, at: entryOffset + 4))
            guard blobOffset >= 12, blobOffset <= length - 8 else { return .unableToCheck }
            let magic = bigEndianUInt32(signature, at: blobOffset)
            let blobLength = Int(bigEndianUInt32(signature, at: blobOffset + 4))
            guard blobLength >= 8, blobLength <= length - blobOffset else { return .unableToCheck }
            if magic == derEntitlementBlobMagic { hasDEREntitlements = true }
            guard magic == entitlementBlobMagic else { continue }
            let plistData = signature.subdata(in: (blobOffset + 8)..<(blobOffset + blobLength))
            guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
                  let entitlements = plist as? [String: Any] else { return .unableToCheck }
            return (entitlements[entitlementKey] as? Bool == true) ? .enabled : .notEnabled
        }
        return hasDEREntitlements ? .unableToCheck : .notEnabled
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
