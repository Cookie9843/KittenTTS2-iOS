import Foundation

public enum LegacyDownloadOutcome: Equatable, Sendable {
    /// Both files are in place.
    case installed
    /// The user cancelled; anything the download wrote was removed.
    case discarded
    /// The transfer ended without a usable model; leftovers were removed.
    case incomplete
}

public enum LegacyModelError: Error, Equatable, LocalizedError {
    case inUse
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .inUse: return "The model is being used right now. Wait for it to finish, then remove it."
        case .fileSystem(let m): return "Could not remove the model files: \(m). Nothing else was changed; you can try again."
        }
    }
}

/// On-disk state of the original KittenTTS 0.8 models (`<root>/legacy08/<variant>/{model.onnx, voices.npz}`).
/// A variant counts as installed only when both files exist and are not empty, so a half-written download never looks installed.
public struct LegacyModelStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func directory(for variant: LegacyVariant) -> URL {
        root.appendingPathComponent("legacy08/\(variant.rawValue)", isDirectory: true)
    }

    private func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func isInstalled(_ variant: LegacyVariant) -> Bool {
        let dir = directory(for: variant)
        return size(dir.appendingPathComponent(variant.onnxFileName)) > 0 && size(dir.appendingPathComponent(variant.voicesFileName)) > 0
    }

    public func installedBytes(_ variant: LegacyVariant) -> Int64 {
        let dir = directory(for: variant)
        return size(dir.appendingPathComponent(variant.onnxFileName)) + size(dir.appendingPathComponent(variant.voicesFileName))
    }

    public func exists(_ variant: LegacyVariant) -> Bool { FileManager.default.fileExists(atPath: directory(for: variant).path) }

    /// Removes the model's folder. Callers must release any engine that has the files open first; `inUse` makes that explicit.
    public func delete(_ variant: LegacyVariant, inUse: Bool = false) throws {
        if inUse { throw LegacyModelError.inUse }
        guard exists(variant) else { return }
        do { try FileManager.default.removeItem(at: directory(for: variant)) }
        catch { throw LegacyModelError.fileSystem(Kitten2ImportError.detail(error)) }
    }

    /// Removes what a finished, failed or cancelled download left behind when it is not a complete model.
    /// A complete model that was installed before the download started is never touched.
    @discardableResult
    public func finishDownload(_ variant: LegacyVariant, wasInstalledBefore: Bool, cancelled: Bool) -> LegacyDownloadOutcome {
        if wasInstalledBefore { return isInstalled(variant) ? .installed : .incomplete }
        if cancelled {
            try? FileManager.default.removeItem(at: directory(for: variant))
            return .discarded
        }
        if isInstalled(variant) { return .installed }
        try? FileManager.default.removeItem(at: directory(for: variant))
        return .incomplete
    }
}
