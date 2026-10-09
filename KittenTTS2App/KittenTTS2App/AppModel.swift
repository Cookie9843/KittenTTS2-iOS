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
    }

    @Published var family: ModelFamily = .legacy08
    @Published var legacyVariant: LegacyVariant = .nano
    @Published var voice: KittenVoice = .bella
    @Published var speed: Float = 1.0
    @Published var text: String = ""
    @Published var phase: Phase = .idle
    @Published var message: String?
    @Published var messageIsError = false
    @Published var history: [GenerationRecord] = []
    @Published var playingID: UUID?
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
            show("History is unavailable: \(error.localizedDescription)", error: true)
        }
    }

    var busy: Bool { phase != .idle }

    // MARK: Install state

    func isInstalled(_ variant: LegacyVariant) -> Bool {
        _ = installRevision
        let dir = modelRoot.appendingPathComponent("legacy08/\(variant.rawValue)")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(variant.onnxFileName).path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent(variant.voicesFileName).path)
    }

    func kitten2Files() -> [String] {
        _ = installRevision
        let dir = modelRoot.appendingPathComponent("kitten2")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    var canGenerate: Bool { family == .legacy08 && isInstalled(legacyVariant) && !busy }

    func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        let family = self.family
        let variant = self.legacyVariant
        let root = modelRoot
        phase = .importing(0)
        show("Validating…")
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
        show(error, error: true)
    }

    private func finishImport(success plan: ImportPlan) {
        phase = .idle
        installRevision += 1
        if let variant = plan.legacyVariant { engines[variant] = nil }
        let notes = plan.notes.isEmpty ? "" : "\n\n" + plan.notes.joined(separator: "\n")
        show("Imported \(plan.family.displayName) (\(ImportValidator.formatBytes(plan.totalBytes))).\(notes)")
    }

    // MARK: Download (legacy only, explicit user action)

    func downloadLegacy() {
        guard !busy, family == .legacy08 else { return }
        let variant = legacyVariant
        phase = .downloading(0)
        show("Downloading \(variant.huggingFaceRepo) from Hugging Face…")
        Task {
            do {
                _ = try await engine(for: variant) { value in
                    Task { @MainActor in self.phase = .downloading(value) }
                }
                phase = .idle
                installRevision += 1
                show("\(variant.displayName) is ready.")
            } catch {
                phase = .idle
                show("Download failed: \(error.localizedDescription)", error: true)
            }
        }
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
        guard !trimmed.isEmpty else { show("Enter some text first.", error: true); return }
        guard family == .legacy08 else {
            show(ModelFamily.kitten2.runtimeBlocker ?? "Unavailable.", error: true)
            return
        }
        guard isInstalled(legacyVariant) else {
            show("Import or download a \(legacyVariant.displayName) model first (Models tab).", error: true)
            return
        }
        guard !busy else { return }
        let variant = legacyVariant, selectedVoice = voice, selectedSpeed = speed
        phase = .loading
        show("Loading model (the first run also fetches small phonemizer data files if they are missing)…")
        Task {
            do {
                let tts = try await engine(for: variant)
                phase = .generating
                show("Generating… (cannot be cancelled once started)")
                let result = try await tts.generate(trimmed, voice: selectedVoice, speed: selectedSpeed)
                let record = try store?.add(samples: result.samples, sampleRate: result.sampleRate, text: trimmed, family: .legacy08,
                                            modelName: variant.displayName, voice: selectedVoice.displayName, speed: selectedSpeed)
                history = store?.records ?? []
                phase = .idle
                show("Done: \(String(format: "%.1f", result.duration)) s of audio.")
                if let record { play(record) }
            } catch {
                phase = .idle
                show("Generation failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    // MARK: Playback / history

    func audioURL(_ record: GenerationRecord) -> URL? { store?.audioURL(for: record) }

    func play(_ record: GenerationRecord) {
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
            show("Playback failed: \(error.localizedDescription)", error: true)
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
    }

    func clearHistory() {
        stopPlayback()
        try? store?.clear()
        history = store?.records ?? []
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
