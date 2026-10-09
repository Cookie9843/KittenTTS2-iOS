import Foundation

public enum ImportError: LocalizedError, Equatable {
    case cancelled
    case insufficientStorage(required: Int64, available: Int64)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Import cancelled. Any previously installed model was left untouched."
        case .insufficientStorage(let required, let available):
            return "Not enough free storage: \(ImportValidator.formatBytes(required)) needed (plus headroom), \(ImportValidator.formatBytes(available)) available. Free some space and try again; the existing model was not changed."
        case .io(let message): return "Import failed: \(message). The existing model was not changed."
        }
    }
}

/// Copies validated files into the model root. The previous install of the same destination
/// is only replaced after the new copy is complete, and is restored on any failure.
public struct ModelImporter {
    public let root: URL
    public var availableBytes: () -> Int64
    private let chunkSize = 4 * 1024 * 1024

    public init(root: URL, availableBytes: (() -> Int64)? = nil) {
        self.root = root
        self.availableBytes = availableBytes ?? {
            #if canImport(Darwin)
            let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
            #else
            return Int64.max
            #endif
        }
    }

    public func installedDirectory(for plan: ImportPlan) -> URL {
        root.appendingPathComponent(plan.destination, isDirectory: true)
    }

    @discardableResult
    public func install(_ plan: ImportPlan, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        let total = plan.totalBytes
        let available = availableBytes()
        guard available >= total + total / 20 else { throw ImportError.insufficientStorage(required: total, available: available) }

        let destination = installedDirectory(for: plan)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var done: Int64 = 0
            for file in plan.files {
                #if canImport(Darwin)
                let scoped = file.source.startAccessingSecurityScopedResource()
                defer { if scoped { file.source.stopAccessingSecurityScopedResource() } }
                #endif
                try copy(file.source, to: staging.appendingPathComponent(file.storedName), done: &done, total: total, progress: progress, isCancelled: isCancelled)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error as? ImportError ?? ImportError.io(error.localizedDescription)
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hadOld = fm.fileExists(atPath: destination.path)
            if hadOld { try fm.moveItem(at: destination, to: backup) }
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                if hadOld { try? fm.moveItem(at: backup, to: destination) }
                throw error
            }
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.io(error.localizedDescription)
        }
        progress(1)
        return destination
    }

    private func copy(_ source: URL, to target: URL, done: inout Int64, total: Int64, progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ImportError.io("cannot create \(target.lastPathComponent)") }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while true {
            if isCancelled() { throw ImportError.cancelled }
            let chunk = try autoreleasingRead(input)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            done += Int64(chunk.count)
            progress(total > 0 ? Double(done) / Double(total) : 1)
        }
    }

    private func autoreleasingRead(_ handle: FileHandle) throws -> Data {
        try handle.read(upToCount: chunkSize) ?? Data()
    }
}
