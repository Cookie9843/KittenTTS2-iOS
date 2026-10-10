import Foundation

/// Details stored next to a GGUF the user imported from Files (the downloaded package needs no record: it is pinned by name, size and SHA-256).
public struct Kitten2ImportRecord: Codable, Equatable, Sendable {
    public var originalName: String
    public var size: Int64
    public var sha256: String
    /// True only when the file has the published size and its SHA-256 matched the published checksum.
    public var checksumVerified: Bool
    public var importedAt: Date
}

public enum Kitten2ModelSource: Equatable, Sendable {
    case downloaded
    case imported(Kitten2ImportRecord?)
}

public struct Kitten2InstalledModel: Equatable, Sendable {
    public var url: URL
    public var size: Int64
    public var source: Kitten2ModelSource
}

public enum Kitten2Library {
    public static let importedFileName = "imported-kitten-tts2.gguf"
    public static let importedRecordName = "imported-kitten-tts2.json"

    /// The model the app would load. An imported file wins over the downloaded one because the user chose it explicitly.
    public static func active(in installDirectory: URL) -> Kitten2InstalledModel? {
        if let imported = imported(in: installDirectory) { return imported }
        return downloaded(in: installDirectory)
    }

    public static func downloaded(in installDirectory: URL) -> Kitten2InstalledModel? {
        let file = Kitten2Package.file
        guard InstalledModels.isInstalled(file, in: installDirectory) else { return nil }
        return Kitten2InstalledModel(url: InstalledModels.fileURL(file, in: installDirectory), size: file.size, source: .downloaded)
    }

    public static func imported(in installDirectory: URL) -> Kitten2InstalledModel? {
        let url = installDirectory.appendingPathComponent(importedFileName)
        guard let size = fileSize(url), size > 0 else { return nil }
        let data = try? Data(contentsOf: installDirectory.appendingPathComponent(importedRecordName))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = data.flatMap { try? decoder.decode(Kitten2ImportRecord.self, from: $0) }
        if record?.size != size { record = nil }
        return Kitten2InstalledModel(url: url, size: size, source: .imported(record))
    }

    public static func deleteImported(in installDirectory: URL) {
        try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(importedFileName))
        try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(importedRecordName))
    }

    static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }
}

public enum Kitten2ImportError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notGGUF(String)
    /// A GGUF (or other file) the audio.cpp `kitten_tts2` runtime cannot load; the text says what it was and what is supported.
    case unsupported(String)
    case insufficientDisk(needed: Int64, available: Int64)
    case checksumMismatch
    case fileSystem(String)
    case cancelled

    public var errorDescription: String? {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case .unreadable(let m): return "Could not read the selected file: \(m)"
        case .notGGUF(let m): return "The selected file is not a GGUF model. \(m)"
        case .unsupported(let m): return m
        case .insufficientDisk(let need, let have):
            return "Not enough free storage to import: \(fmt(need)) is needed (a copy of the file plus working space), but only \(fmt(have)) is available. Free up at least \(fmt(max(0, need - have))) and try again. Your current model was not changed."
        case .checksumMismatch: return "The file has the size of the published KittenTTS 2 package but its SHA-256 does not match, so it is damaged or modified and was not imported."
        case .fileSystem(let m): return "Could not import the file: \(m). Your current model was not changed."
        case .cancelled: return "Import cancelled. Your current model was not changed."
        }
    }
}

/// Validates a user-owned KittenTTS 2 package (audio.cpp `audiocpp` architecture, `kitten_tts2` family), copies it in chunks into a
/// staging folder on the install volume, and only then moves it into place. Nothing is changed unless every step succeeds.
public struct Kitten2Importer: Sendable {
    public static let chunkSize = 4 << 20

    private let availableDisk: @Sendable (URL) -> Int64?
    private let published: RemoteModelFile

    /// `published` is the package whose size and SHA-256 are known; a different export is accepted without a checksum.
    public init(availableDisk: @escaping @Sendable (URL) -> Int64?, published: RemoteModelFile = Kitten2Package.file) {
        self.availableDisk = availableDisk
        self.published = published
    }

    /// Caller must hold security-scoped access to `source` for the whole call.
    @discardableResult
    public func install(source: URL, installDirectory: URL, stagingDirectory: URL,
                        progress: @escaping @Sendable (Double) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Kitten2ImportRecord {
        let fm = FileManager.default
        guard let size = Kitten2Library.fileSize(source) else { throw Kitten2ImportError.unreadable("it is not available (is it still in iCloud and not downloaded?)") }
        guard size > 0 else { throw Kitten2ImportError.notGGUF("The file is empty.") }

        let report: AudioCppGGUFReport
        do { report = try AudioCppGGUFInspector.inspect(url: source) }
        catch let error as AudioCppGGUFInspector.InspectError {
            if error == .notGGUF { throw Kitten2ImportError.notGGUF("KittenTTS 2 needs the single .gguf package \(AudioCppPackage.publishedFileName) from \(AudioCppPackage.sourceRepository).") }
            throw Kitten2ImportError.unsupported(error.description)
        } catch { throw Kitten2ImportError.unreadable(error.localizedDescription) }

        let validation = AudioCppGGUFInspector.validate(report, publishedSize: published.size)
        guard validation.kind == .audiocppKittenTTS2, validation.passed else {
            let failed = validation.checks.filter { $0.status == .fail }.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")
            throw Kitten2ImportError.unsupported(validation.guidance ?? "This file is not a compatible KittenTTS 2 package (\(failed)).")
        }

        let space = StorageAssessment.assess(.importCopy(totalBytes: size), availableBytes: availableDisk(stagingDirectory))
        if space.outcome == .insufficient, let free = space.availableBytes {
            throw Kitten2ImportError.insufficientDisk(needed: space.requiredBytes, available: free)
        }

        let partial = stagingDirectory.appendingPathComponent("import.partial")
        do {
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw Kitten2ImportError.fileSystem("the staging file could not be created") }
        } catch let error as Kitten2ImportError { throw error }
        catch { throw Kitten2ImportError.fileSystem(error.localizedDescription) }

        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: partial) } }

        var hasher = SHA256Hasher()
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                if isCancelled() { throw Kitten2ImportError.cancelled }
                try output.write(contentsOf: chunk)
                hasher.update(chunk)
                copied += Int64(chunk.count)
                progress(min(1, Double(copied) / Double(size)))
            }
            guard copied == size else { throw Kitten2ImportError.fileSystem("the file changed while it was being copied") }
        } catch let error as Kitten2ImportError { throw error }
        catch { throw Kitten2ImportError.fileSystem(error.localizedDescription) }

        let digest = hasher.finalizeHex()
        let verified = size == published.size && digest == published.sha256
        if size == published.size && !verified { throw Kitten2ImportError.checksumMismatch }

        let record = Kitten2ImportRecord(originalName: source.lastPathComponent, size: size, sha256: digest, checksumVerified: verified, importedAt: Date())
        let destination = installDirectory.appendingPathComponent(Kitten2Library.importedFileName)
        // A record that no longer describes the file must never outlive the replacement.
        try? fm.removeItem(at: installDirectory.appendingPathComponent(Kitten2Library.importedRecordName))
        do {
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: partial) }
            else { try fm.moveItem(at: partial, to: destination) }
            succeeded = true
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutable = destination
            try? mutable.setResourceValues(values)
        } catch { throw Kitten2ImportError.fileSystem(error.localizedDescription) }

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: installDirectory.appendingPathComponent(Kitten2Library.importedRecordName), options: .atomic)
        }
        return record
    }
}
