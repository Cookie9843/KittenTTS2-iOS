import AVFoundation
import Foundation
import KittenCore
import KittenTTS

@MainActor
final class AppModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        case importing(Double)
        case downloading(Double)
        case loading
        case generating
        case removing
    }

    /// Files imported through the Models tab belong to the original 0.8 family (KittenTTS 2 is downloaded, not imported).
    let family: ModelFamily = .legacy08
    @Published var legacyVariant: LegacyVariant = .nano
    @Published var voice: KittenVoice = .bella
    @Published var speed: Float = 1.0
    @Published var text: String = ""
    @Published var phase: Phase = .idle
    /// One independent message slot per operation (model setup, synthesis, playback, history).
    @Published private(set) var status = OperationStatus<LegacyOperation>()
    @Published var history: [GenerationRecord] = []
    @Published var playingID: UUID?
    @Published var latest: GenerationRecord?
    @Published var installRevision = 0

    private var store: HistoryStore?
    private var engines: [LegacyVariant: KittenTTS] = [:]
    private var player: AVAudioPlayer?

    let modelRoot: URL

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        modelRoot = support.appendingPathComponent("KittenModels", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        do {
            store = try HistoryStore(directory: support.appendingPathComponent("History", isDirectory: true))
            history = store?.records ?? []
        } catch {
            post("History is unavailable: \(error.localizedDescription)", for: .history, error: true)
        }
    }

    var busy: Bool { phase != .idle }

    // MARK: Install state

    private var legacyStore: LegacyModelStore { LegacyModelStore(root: modelRoot) }

    func isInstalled(_ variant: LegacyVariant) -> Bool {
        _ = installRevision
        return legacyStore.isInstalled(variant)
    }

    func installedBytes(_ variant: LegacyVariant) -> Int64 {
        _ = installRevision
        return legacyStore.installedBytes(variant)
    }

    var canGenerate: Bool { isInstalled(legacyVariant) && !busy }

    func post(_ text: String?, for operation: LegacyOperation, error: Bool = false) {
        guard let text else { status.clear(operation); return }
        if error { status.error(text, for: operation) } else { status.info(text, for: operation) }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        let family = self.family
        let variant = self.legacyVariant
        let root = modelRoot
        phase = .importing(0)
        post("Validating…", for: .modelSetup)
        let flag = CancelFlag()
        cancelToken = flag
        Task.detached { [weak self] in
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { zip(urls, scoped).forEach { if $1 { $0.stopAccessingSecurityScopedResource() } } }
            let result = ImportValidator.validate(urls: urls, family: family, legacyVariant: variant)
            switch result {
            case .failure(let issue):
                await self?.finishImport(error: issue.message)
            case .success(let plan):
                do {
                    let importer = ModelImporter(root: root)
                    var lastPercent = -1
                    try importer.install(plan, progress: { value in
                        let percent = Int(value * 100)
                        guard percent != lastPercent else { return }
                        lastPercent = percent
                        Task { @MainActor in self?.phase = .importing(value) }
                    }, isCancelled: { flag.isCancelled })
                    await self?.finishImport(success: plan)
                } catch {
                    await self?.finishImport(error: error.localizedDescription)
                }
            }
        }
    }

    private var cancelToken: CancelFlag?

    func cancelCurrentImport() { cancelToken?.cancel() }

    private func finishImport(error: String) {
        phase = .idle
        post(error, for: .modelSetup, error: true)
    }

    private func finishImport(success plan: ImportPlan) {
        phase = .idle
        installRevision += 1
        if let variant = plan.legacyVariant { engines[variant] = nil }
        let notes = plan.notes.isEmpty ? "" : "\n\n" + plan.notes.joined(separator: "\n")
        post("Imported \(plan.family.displayName) (\(ImportValidator.formatBytes(plan.totalBytes))).\(notes)", for: .modelSetup)
    }

    // MARK: Download (legacy only, explicit user action)

    /// The original downloader cannot pause or resume (it restarts a file from byte 0 and ignores task cancellation), so only
    /// cancel is offered. A cancelled download lets the file already in flight finish (they are 25–80 MB), then removes
    /// everything that download wrote. A model that was installed before is never touched.
    @Published private(set) var legacyCancelling = false
    private var downloadCancel: CancelFlag?

    func downloadLegacy() {
        guard !busy else { return }
        let variant = legacyVariant
        let store = legacyStore
        let wasInstalled = store.isInstalled(variant)
        let flag = CancelFlag()
        downloadCancel = flag
        legacyCancelling = false
        phase = .downloading(0)
        post("Downloading \(variant.huggingFaceRepo) from Hugging Face…", for: .modelSetup)
        Task {
            var failure: Error?
            do {
                _ = try await engine(for: variant) { value in
                    Task { @MainActor in
                        guard self.downloadCancel === flag, !flag.isCancelled, case .downloading = self.phase else { return }
                        self.phase = .downloading(value)
                    }
                }
            } catch { failure = error }
            // The engine of a cancelled or failed download must not stay cached: its files are about to be removed.
            if failure != nil || flag.isCancelled { engines[variant] = nil }
            let outcome = store.finishDownload(variant, wasInstalledBefore: wasInstalled, cancelled: flag.isCancelled)
            if downloadCancel === flag { downloadCancel = nil }
            legacyCancelling = false
            phase = .idle
            installRevision += 1
            switch outcome {
            case _ where flag.isCancelled && outcome != .discarded:
                post("Download cancelled. Your installed model was kept.", for: .modelSetup)
            case .discarded: post("Download cancelled. The partial files were removed.", for: .modelSetup)
            case .installed:
                if let failure { post("The files were downloaded, but the model could not be loaded: \(failure.localizedDescription)", for: .modelSetup, error: true) }
                else { post("\(variant.displayName) is ready.", for: .modelSetup) }
            default:
                let reason = failure?.localizedDescription ?? "the files are incomplete"
                post("Download failed: \(reason). Partial files were removed; you can try again.", for: .modelSetup, error: true)
            }
        }
    }

    func cancelLegacyDownload() {
        guard case .downloading = phase, let flag = downloadCancel, !flag.isCancelled else { return }
        flag.cancel()
        legacyCancelling = true
        post("Cancelling… the file that is already transferring finishes first, then everything from this download is removed.", for: .modelSetup)
    }

    /// Releases the cached engine (it has the ONNX file open) before the files are removed, and blocks every other action meanwhile.
    func deleteLegacy(_ variant: LegacyVariant) {
        guard !busy else { return }
        phase = .removing
        engines[variant] = nil
        do {
            try legacyStore.delete(variant)
            post("\(variant.displayName) was removed from this device.", for: .modelSetup)
        } catch {
            post(error.localizedDescription, for: .modelSetup, error: true)
        }
        phase = .idle
        installRevision += 1
    }

    private func engine(for variant: LegacyVariant, progress: ((Double) -> Void)? = nil) async throws -> KittenTTS {
        if let existing = engines[variant] { return existing }
        guard let sdkModel = KittenModel(rawValue: variant.rawValue) else {
            throw NSError(domain: "KittenTTS2App", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported model \(variant.rawValue)"])
        }
        let config = KittenTTSConfig(model: sdkModel, defaultVoice: voice, speed: 1.0,
                                     storageDirectory: modelRoot.appendingPathComponent("legacy08", isDirectory: true))
        let created = try await KittenTTS(config, downloadProgressHandler: progress)
        engines[variant] = created
        return created
    }

    // MARK: Generate

    func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        post(nil, for: .synthesis)
        guard !trimmed.isEmpty else { post("Enter some text first.", for: .synthesis, error: true); return }
        guard isInstalled(legacyVariant) else {
            post("Import or download a \(legacyVariant.displayName) model first (Models tab).", for: .synthesis, error: true)
            return
        }
        guard !busy else { return }
        let variant = legacyVariant, selectedVoice = voice, selectedSpeed = speed
        phase = .loading
        post("Loading model (the first run also fetches small phonemizer data files if they are missing)…", for: .synthesis)
        Task {
            do {
                let tts = try await engine(for: variant)
                phase = .generating
                post("Generating… (cannot be cancelled once started)", for: .synthesis)
                let result = try await tts.generate(trimmed, voice: selectedVoice, speed: selectedSpeed)
                let record = try store?.add(samples: result.samples, sampleRate: result.sampleRate, text: trimmed, family: .legacy08,
                                            modelName: variant.displayName, voice: selectedVoice.displayName, speed: selectedSpeed)
                history = store?.records ?? []
                latest = record
                phase = .idle
                post("Done: \(String(format: "%.1f", result.duration)) s of audio.", for: .synthesis)
                if let record { play(record) }
            } catch {
                phase = .idle
                post("Generation failed: \(error.localizedDescription)", for: .synthesis, error: true)
            }
        }
    }

    // MARK: Playback / history

    /// Saves generated PCM as a WAV in the history and starts playback. Used by the KittenTTS 2 path.
    @discardableResult
    func addRecord(samples: [Float], sampleRate: Int, text: String, family: ModelFamily, modelName: String, voice: String, speed: Float) -> GenerationRecord? {
        do {
            guard let record = try store?.add(samples: samples, sampleRate: sampleRate, text: text, family: family,
                                              modelName: modelName, voice: voice, speed: speed) else { return nil }
            history = store?.records ?? []
            latest = record
            play(record)
            return record
        } catch {
            post("Could not save the audio: \(error.localizedDescription)", for: .history, error: true)
            return nil
        }
    }

    func audioURL(_ record: GenerationRecord) -> URL? { store?.audioURL(for: record) }

    func play(_ record: GenerationRecord) {
        post(nil, for: .playback)
        guard let url = audioURL(record) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            player = newPlayer
            playingID = record.id
            newPlayer.play()
        } catch {
            post("Playback failed: \(error.localizedDescription)", for: .playback, error: true)
        }
    }

    func stopPlayback() {
        player?.stop()
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }

    func delete(_ record: GenerationRecord) {
        if playingID == record.id { stopPlayback() }
        try? store?.delete(record)
        history = store?.records ?? []
        if latest?.id == record.id { latest = nil }
    }

    func clearHistory() {
        stopPlayback()
        try? store?.clear()
        history = store?.records ?? []
        latest = nil
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
