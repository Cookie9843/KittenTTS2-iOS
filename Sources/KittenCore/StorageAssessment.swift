import Foundation

/// Raw capacity values reported for one volume (the `URLResourceValues` volume keys), kept as plain numbers so the
/// selection rules can be tested without a device.
public struct StorageCapacity: Equatable, Sendable {
    /// `volumeAvailableCapacityForImportantUsageKey`: free space plus purgeable space iOS will reclaim for important work.
    public var importantUsage: Int64?
    /// `volumeAvailableCapacityKey`: free space excluding purgeable data.
    public var available: Int64?

    public init(importantUsage: Int64?, available: Int64?) {
        self.importantUsage = importantUsage
        self.available = available
    }

    /// The capacity to compare against a requirement. Both values describe the same volume, so the larger positive one is
    /// the usable figure: "important usage" is normally the larger, but it is occasionally reported as 0 (or not at all),
    /// and trusting that value would claim the volume is full when it is not. Returns nil when no value is reported.
    public var usable: Int64? {
        let candidates = [importantUsage, available].compactMap { $0 }.filter { $0 > 0 }
        if let best = candidates.max() { return best }
        // Only zero/negative values were reported: the volume really can be full, so report 0 rather than "unknown".
        return [importantUsage, available].contains { $0 != nil } ? 0 : nil
    }

    public static func read(at url: URL) -> StorageCapacity {
        #if canImport(Darwin)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return StorageCapacity(importantUsage: values?.volumeAvailableCapacityForImportantUsage,
                               available: values?.volumeAvailableCapacity.map { Int64($0) })
        #else
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? NSNumber
        return StorageCapacity(importantUsage: nil, available: free?.int64Value)
        #endif
    }

    /// Usable capacity of the volume that holds `url`. A path that does not exist yet is resolved through its nearest
    /// existing parent, because resource values cannot be read from a missing item (which looked like "no space").
    public static func usableBytes(at url: URL, fileManager: FileManager = .default) -> Int64? {
        var probe = url
        while !fileManager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return read(at: probe).usable
    }
}

/// How bytes reach the install volume; decides how much space is needed.
public enum StorageOperation: Equatable, Sendable {
    /// Download `totalBytes`, of which `alreadyPresent` bytes are already in the partial file in the staging folder.
    case download(totalBytes: Int64, alreadyPresent: Int64)
    /// Copy a user-selected file of `totalBytes` into staging (the source file stays where it is) and then move it.
    case importCopy(totalBytes: Int64)
}

public struct StorageAssessment: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case sufficient
        case insufficient
        /// The volume did not report its capacity; nothing can be concluded, so callers proceed and rely on write errors.
        case unknown
    }

    /// Headroom for hashing scratch, filesystem metadata and the atomic move; only needed while bytes are still being written.
    public static let headroom: Int64 = 128 * 1024 * 1024

    public var outcome: Outcome
    public var requiredBytes: Int64
    public var availableBytes: Int64?
    /// Bytes of the model that are already on disk and therefore not required again.
    public var alreadyPresentBytes: Int64

    public var shortfall: Int64? {
        guard let availableBytes, outcome == .insufficient else { return nil }
        return requiredBytes.subtractingReportingOverflow(availableBytes).overflow ? Int64.max : requiredBytes - availableBytes
    }

    /// Bytes that still have to be written, plus headroom when anything has to be written at all.
    public static func requiredBytes(for operation: StorageOperation) -> (required: Int64, present: Int64) {
        switch operation {
        case .download(let total, let present):
            let have = min(max(present, 0), max(total, 0))
            let remaining = max(total, 0) - have
            return (saturatingAdd(remaining, remaining > 0 ? headroom : 0), have)
        case .importCopy(let total):
            return (saturatingAdd(max(total, 0), headroom), 0)
        }
    }

    public static func assess(_ operation: StorageOperation, availableBytes: Int64?) -> StorageAssessment {
        let (required, present) = requiredBytes(for: operation)
        guard let availableBytes else {
            return StorageAssessment(outcome: .unknown, requiredBytes: required, availableBytes: nil, alreadyPresentBytes: present)
        }
        // Equality is enough: the headroom already covers the margin.
        let outcome: Outcome = availableBytes >= required ? .sufficient : .insufficient
        return StorageAssessment(outcome: outcome, requiredBytes: required, availableBytes: availableBytes, alreadyPresentBytes: present)
    }

    static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }
}
