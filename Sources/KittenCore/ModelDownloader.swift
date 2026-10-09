import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Resumable, verified download of one large model file (the KittenTTS 2 package is 3.28 GB).
// Bytes are streamed to a `.partial` file (never held in memory), resumed with HTTP Range after
// pause/cancel/relaunch, then size + SHA-256 are verified before an atomic move into the install folder.

public struct DownloadResponse: Sendable {
    public var statusCode: Int
    /// Parsed from `Content-Range: bytes START-END/TOTAL` (206 responses).
    public var contentRangeStart: Int64?
    public var body: AsyncThrowingStream<Data, Error>
    public init(statusCode: Int, contentRangeStart: Int64? = nil, body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode; self.contentRangeStart = contentRangeStart; self.body = body
    }
}

public protocol DownloadTransport: Sendable {
    func request(url: URL, rangeStart: Int64?) async throws -> DownloadResponse
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case invalidManifest(String)
    case insufficientDisk(needed: Int64, available: Int64)
    case http(Int)
    case network(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case fileSystem(String)
    case cancelled

    public var errorDescription: String? {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case .invalidManifest(let m): return m
        case .insufficientDisk(let need, let have):
            return "Not enough free storage: about \(fmt(need)) is needed, but only \(fmt(have)) is available. Free up space and try again."
        case .http(let code): return "The server answered with HTTP \(code). Please try again later."
        case .network(let m): return "Network problem: \(m). Your progress is kept; tap Resume to continue."
        case .sizeMismatch(let e, let a): return "The downloaded file has the wrong size (\(fmt(a)) instead of \(fmt(e))); it was discarded. Please download again."
        case .checksumMismatch: return "The downloaded file failed its integrity check (SHA-256) and was discarded. Please download again."
        case .fileSystem(let m): return "Could not write the file: \(m)"
        case .cancelled: return "Download paused. Your progress is kept."
        }
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case checkingSpace, downloading, verifying, installing }
    public var stage: Stage
    public var bytes: Int64
    public var total: Int64
    public var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }

    public init(stage: Stage, bytes: Int64, total: Int64) {
        self.stage = stage
        self.bytes = bytes
        self.total = total
    }
}

public final class ModelDownloader: @unchecked Sendable {
    /// Free space kept beyond the file itself (hashing, filesystem metadata).
    public static let diskMargin: Int64 = 128 * 1024 * 1024

    private let transport: DownloadTransport
    private let availableDisk: @Sendable (URL) -> Int64?
    private let fileManager = FileManager.default

    public init(transport: DownloadTransport, availableDisk: @escaping @Sendable (URL) -> Int64?) {
        self.transport = transport
        self.availableDisk = availableDisk
    }

    public static func partialURL(for file: RemoteModelFile, in directory: URL) -> URL {
        directory.appendingPathComponent(file.name + ".partial")
    }

    public func partialBytes(for file: RemoteModelFile, in directory: URL) -> Int64 {
        let attrs = try? fileManager.attributesOfItem(atPath: Self.partialURL(for: file, in: directory).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func discardPartial(for file: RemoteModelFile, in directory: URL) {
        try? fileManager.removeItem(at: Self.partialURL(for: file, in: directory))
    }

    /// Downloads (or resumes) `file` into `stagingDirectory`, verifies it and atomically installs it as
    /// `installDirectory/file.name`. Cancel the surrounding Task to pause; the partial file is kept.
    @discardableResult
    public func download(_ file: RemoteModelFile, stagingDirectory: URL, installDirectory: URL,
                         progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        if let problem = file.validationProblem { throw DownloadError.invalidManifest(problem) }
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        } catch { throw DownloadError.fileSystem(error.localizedDescription) }

        let partial = Self.partialURL(for: file, in: stagingDirectory)
        var have = partialBytes(for: file, in: stagingDirectory)
        if have > file.size { discardPartial(for: file, in: stagingDirectory); have = 0 }

        progress(DownloadProgress(stage: .checkingSpace, bytes: have, total: file.size))
        if let free = availableDisk(stagingDirectory) {
            let needed = file.size - have + Self.diskMargin
            if free < needed { throw DownloadError.insufficientDisk(needed: needed, available: free) }
        }

        if have < file.size {
            try await fetch(file, partial: partial, have: have, progress: progress, allowRestart: true)
        }
        if Task.isCancelled { throw DownloadError.cancelled }

        let actual = partialBytes(for: file, in: stagingDirectory)
        guard actual == file.size else {
            discardPartial(for: file, in: stagingDirectory)
            throw DownloadError.sizeMismatch(expected: file.size, actual: actual)
        }

        progress(DownloadProgress(stage: .verifying, bytes: 0, total: file.size))
        let digest: String?
        do {
            digest = try SHA256Hasher.hashFile(at: partial, progress: { progress(DownloadProgress(stage: .verifying, bytes: $0, total: file.size)) },
                                               isCancelled: { Task.isCancelled })
        } catch { throw DownloadError.fileSystem(error.localizedDescription) }
        guard let digest else { throw DownloadError.cancelled }
        guard digest == file.sha256 else {
            discardPartial(for: file, in: stagingDirectory)
            throw DownloadError.checksumMismatch(expected: file.sha256, actual: digest)
        }

        progress(DownloadProgress(stage: .installing, bytes: file.size, total: file.size))
        return try install(partial, as: file, into: installDirectory)
    }

    private func install(_ partial: URL, as file: RemoteModelFile, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(file.name)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = destination
            try? mutable.setResourceValues(values)
        } catch { throw DownloadError.fileSystem(error.localizedDescription) }
        return destination
    }

    private func fetch(_ file: RemoteModelFile, partial: URL, have: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void,
                       allowRestart: Bool) async throws {
        let response: DownloadResponse
        do { response = try await transport.request(url: file.url, rangeStart: have > 0 ? have : nil) }
        catch is CancellationError { throw DownloadError.cancelled }
        catch { throw DownloadError.network(error.localizedDescription) }

        var offset = have
        switch response.statusCode {
        case 206:
            guard response.contentRangeStart == have else {
                if allowRestart { removePartial(partial); return try await fetch(file, partial: partial, have: 0, progress: progress, allowRestart: false) }
                throw DownloadError.http(206)
            }
        case 200:
            offset = 0 // server ignored Range: start over
        case 416:
            if allowRestart && have > 0 { removePartial(partial); return try await fetch(file, partial: partial, have: 0, progress: progress, allowRestart: false) }
            throw DownloadError.http(416)
        default:
            throw DownloadError.http(response.statusCode)
        }

        let handle: FileHandle
        do {
            if !fileManager.fileExists(atPath: partial.path) { _ = fileManager.createFile(atPath: partial.path, contents: nil) }
            handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
        } catch { throw DownloadError.fileSystem(error.localizedDescription) }
        defer { try? handle.close() }

        var lastReported: Int64 = -1
        do {
            for try await chunk in response.body {
                if Task.isCancelled { throw DownloadError.cancelled }
                offset += Int64(chunk.count)
                if offset > file.size { throw DownloadError.sizeMismatch(expected: file.size, actual: offset) }
                do { try handle.write(contentsOf: chunk) } catch { throw DownloadError.fileSystem(error.localizedDescription) }
                if offset - lastReported >= 1 << 20 || offset == file.size {
                    lastReported = offset
                    progress(DownloadProgress(stage: .downloading, bytes: offset, total: file.size))
                }
            }
        } catch let error as DownloadError {
            if case .sizeMismatch = error { try? handle.close(); removePartial(partial) }
            throw error
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch {
            if Task.isCancelled { throw DownloadError.cancelled }
            throw DownloadError.network(error.localizedDescription)
        }
        if Task.isCancelled { throw DownloadError.cancelled }
        // A stream that ends early (dropped connection) leaves a shorter partial: report it as resumable.
        if offset < file.size { throw DownloadError.network("the connection ended after \(offset) of \(file.size) bytes") }
    }

    private func removePartial(_ url: URL) { try? fileManager.removeItem(at: url) }
}

// MARK: - installed state

public struct InstalledModelRecord: Codable, Equatable, Sendable {
    public var fileName: String
    public var size: Int64
    public var sha256: String
    public var source: String
    public var installedAt: Date
}

public enum InstalledModels {
    public static func fileURL(_ file: RemoteModelFile, in installDirectory: URL) -> URL {
        installDirectory.appendingPathComponent(file.name)
    }

    /// Cheap check (existence + exact size). The SHA-256 was verified at install time; use `verify` to re-hash.
    public static func isInstalled(_ file: RemoteModelFile, in installDirectory: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(file, in: installDirectory).path)
        return (attrs?[.size] as? NSNumber)?.int64Value == file.size
    }

    public static func verify(_ file: RemoteModelFile, in installDirectory: URL, progress: ((Int64) -> Void)? = nil) throws -> Bool {
        guard isInstalled(file, in: installDirectory) else { return false }
        return try SHA256Hasher.hashFile(at: fileURL(file, in: installDirectory), progress: progress) == file.sha256
    }

    public static func delete(_ file: RemoteModelFile, installDirectory: URL, stagingDirectory: URL) {
        try? FileManager.default.removeItem(at: fileURL(file, in: installDirectory))
        try? FileManager.default.removeItem(at: ModelDownloader.partialURL(for: file, in: stagingDirectory))
    }
}

// MARK: - URLSession transport

/// Streams a GET (optionally with a Range header) from URLSession. Cancelling the Task cancels the request.
public struct URLSessionTransport: DownloadTransport {
    public var allowsCellular: Bool
    public init(allowsCellular: Bool) { self.allowsCellular = allowsCellular }

    public func request(url: URL, rangeStart: Int64?) async throws -> DownloadResponse {
        let handler = StreamingHandler()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: handler, delegateQueue: nil)
        var request = URLRequest(url: url)
        if let rangeStart, rangeStart > 0 { request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        handler.attach(task: task, session: session)
        return try await withTaskCancellationHandler {
            try await handler.start(task)
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}

private final class StreamingHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<DownloadResponse, Error>?
    private var responded = false
    private var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>!
    private var task: URLSessionTask?
    private var session: URLSession?

    override init() {
        super.init()
        stream = AsyncThrowingStream<Data, Error> { [weak self] continuation in
            self?.bodyContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.task?.cancel()
                self?.session?.finishTasksAndInvalidate()
            }
        }
    }

    func attach(task: URLSessionTask, session: URLSession) { self.task = task; self.session = session }

    func start(_ task: URLSessionTask) async throws -> DownloadResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); responseContinuation = continuation; lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        var start: Int64?
        if let range = http?.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes ") {
            start = Int64(range.dropFirst(6).prefix { $0.isNumber })
        }
        lock.lock()
        responded = true
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: DownloadResponse(statusCode: http?.statusCode ?? 0, contentRangeStart: start, body: stream))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodyContinuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        let didRespond = responded
        lock.unlock()
        if !didRespond, let continuation {
            continuation.resume(throwing: error ?? URLError(.badServerResponse))
        }
        bodyContinuation?.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
