import AVFoundation
import Foundation
import KittenCore
import UIKit

/// State and actions for KittenTTS 2: download/install, native load, preset synthesis and voice cloning.
/// Native calls and network I/O run off the main actor; this object only publishes results.
@MainActor
final class Kitten2Model: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        case downloading(DownloadProgress)
        case importing(Double)
        case loading
        case generating
        case recording
        case removing
    }

    static let licenseKey = "kt.kitten2.licenseAcknowledged"
    static let breadcrumbKey = "kt.lastStage"
    static let crashNoteKey = "kt.previousRunNote"

    @Published var phase: Phase = .idle
    /// One independent message slot per operation (download, import, synthesis, reference audio, playback).
    @Published private(set) var status = OperationStatus<Kitten2Operation>()
    @Published var installRevision = 0
    @Published var isLoaded = false
    @Published var voice = Kitten2Package.defaultVoice
    @Published var useClonedVoice = false
    @Published var licenseAcknowledged = UserDefaults.standard.bool(forKey: Kitten2Model.licenseKey) {
        didSet { UserDefaults.standard.set(licenseAcknowledged, forKey: Self.licenseKey) }
    }
    @Published var showDownloadConfirmation = false

    // voice cloning
    @Published var reference: ReferenceClip?
    @Published var referenceName = ""
    @Published var transcriptDraft = TranscriptDraft()
    @Published var isTranscribing = false
    @Published var transcriptionNote: String?
    @Published var recordingSeconds: TimeInterval = 0
    @Published var previewing = false

    // diagnostics
    @Published var lastLoadSeconds: Double?
    @Published var lastSynthesisNote: String?
    @Published var previousRunNote: String?

    private unowned let app: AppModel
    private let engine = Kitten2Engine.shared
    private let downloader: ModelDownloader
    private var downloadTask: Task<Void, Never>?
    private var recorder = ReferenceRecorder()
    private var recordingTimer: Task<Void, Never>?
    private var previewPlayer: AVAudioPlayer?
    private var transcriptionTask: Task<Void, Never>?
    private let stderrPath = NSTemporaryDirectory() + "kt-native-stderr.log"

    let installDirectory: URL
    let stagingDirectory: URL
    let modelFile = Kitten2Package.file

    init(app: AppModel) {
        self.app = app
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        installDirectory = support.appendingPathComponent("KittenModels/\(Kitten2Package.installDirectoryName)", isDirectory: true)
        stagingDirectory = support.appendingPathComponent("KittenModels/.downloads", isDirectory: true)
        downloader = ModelDownloader(transport: URLSessionTransport(allowsCellular: false), availableDisk: Kitten2Model.freeDisk)
        super.init()
        let old = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
        if let note = AudioCppDiagnostics.previousRunNote(stage: UserDefaults.standard.string(forKey: Self.breadcrumbKey), nativeLog: String(old.suffix(4000))) {
            previousRunNote = note
            UserDefaults.standard.set(note, forKey: Self.crashNoteKey)
        } else {
            previousRunNote = UserDefaults.standard.string(forKey: Self.crashNoteKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        _ = kt_redirect_stderr(stderrPath)
        kt_install_abort_hook()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        }
    }

    nonisolated static func freeDisk(_ url: URL) -> Int64? { StorageCapacity.usableBytes(at: url) }

    // MARK: State

    var runtimeLinked: Bool { Kitten2Engine.isLinked }
    var activeModel: Kitten2InstalledModel? { _ = installRevision; return Kitten2Library.active(in: installDirectory) }
    var isInstalled: Bool { activeModel != nil }
    var partialBytes: Int64 { _ = installRevision; return downloader.partialBytes(for: modelFile, in: stagingDirectory) }
    var busy: Bool { phase != .idle }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }
    var modelURL: URL { activeModel?.url ?? InstalledModels.fileURL(modelFile, in: installDirectory) }
    var isImporting: Bool { if case .importing = phase { return true }; return false }
    var transcript: String { transcriptDraft.text }
    var canSpeakWithCloneVoice: Bool { reference != nil && transcriptDraft.isUsable }

    /// Posts or (with nil) clears the message of one operation; other operations' messages are untouched.
    func post(_ text: String?, for operation: Kitten2Operation, error: Bool = false) {
        guard let text else { status.clear(operation); return }
        if error { status.error(text, for: operation) } else { status.info(text, for: operation) }
    }

    private func crumb(_ stage: String?) {
        if let stage { UserDefaults.standard.set("\(stage) (\(ISO8601DateFormatter().string(from: Date())))", forKey: Self.breadcrumbKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey) }
    }

    func clearPreviousRunNote() {
        previousRunNote = nil
        UserDefaults.standard.removeObject(forKey: Self.crashNoteKey)
    }

    // MARK: Download

    /// Capacity of the volume that receives the staged file and the installed model (same volume, Application Support).
    var freeDiskBytes: Int64? { Self.freeDisk(stagingDirectory) }

    /// Storage still needed to download (or resume) the model, for the confirmation sheet.
    var downloadStorage: StorageAssessment {
        StorageAssessment.assess(.download(totalBytes: modelFile.size, alreadyPresent: partialBytes), availableBytes: freeDiskBytes)
    }

    /// Called after the user confirmed size / network / license in the dialog.
    func startDownload(allowCellular: Bool) {
        guard !busy, !isInstalled else { return }
        licenseAcknowledged = true
        let file = modelFile
        let staging = stagingDirectory, install = installDirectory
        let loader = ModelDownloader(transport: URLSessionTransport(allowsCellular: allowCellular), availableDisk: Self.freeDisk)
        phase = .downloading(DownloadProgress(stage: .checkingSpace, bytes: loader.partialBytes(for: file, in: staging), total: file.size))
        post(nil, for: .modelDownload)
        let report: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.applyProgress(progress) }
        }
        downloadTask = Task { [weak self] in
            do {
                try await loader.download(file, stagingDirectory: staging, installDirectory: install, progress: report)
                self?.phase = .idle
                self?.installRevision += 1
                self?.post("KittenTTS 2 was downloaded and verified against its published checksum.", for: .modelDownload)
            } catch let error as DownloadError {
                self?.phase = .idle
                self?.installRevision += 1
                if error == .cancelled { self?.post("Download paused. Tap Resume to continue where it stopped.", for: .modelDownload) }
                else { self?.post(error.localizedDescription, for: .modelDownload, error: true) }
            } catch {
                self?.phase = .idle
                self?.installRevision += 1
                self?.post(error.localizedDescription, for: .modelDownload, error: true)
            }
        }
    }

    private func applyProgress(_ progress: DownloadProgress) {
        if case .downloading = phase { phase = .downloading(progress) }
    }

    /// Stops the transfer but keeps the partial file so Resume continues from the same byte.
    func pauseDownload() { downloadTask?.cancel() }

    func cancelDownloadAndDiscard() {
        downloadTask?.cancel()
        let file = modelFile, staging = stagingDirectory
        Task { [weak self] in
            await self?.downloadTask?.value
            self?.downloader.discardPartial(for: file, in: staging)
            self?.installRevision += 1
            self?.post("Download cancelled and the partial file was removed.", for: .modelDownload)
        }
    }

    // MARK: Import from Files

    private var importCancel: CancelFlag?

    /// Installs a KittenTTS 2 package the user picked in Files. The file is validated and streamed into the staging folder
    /// first, so an invalid, failed or cancelled import never touches the model that is already installed.
    func importModel(from url: URL) {
        guard !busy else {
            post("Another task is running (\(busyDescription)). Wait for it to finish or cancel it, then pick the file again.", for: .modelImport, error: true)
            return
        }
        post(nil, for: .modelImport)
        phase = .importing(0)
        let flag = CancelFlag()
        importCancel = flag
        let install = installDirectory, staging = stagingDirectory
        let importer = Kitten2Importer(availableDisk: Self.freeDisk)
        Task { [weak self] in
            // Security-scoped access must span the whole validation and copy, and is released afterwards.
            let result: Result<Kitten2ImportRecord, Error> = await Task.detached(priority: .userInitiated) { () -> Result<Kitten2ImportRecord, Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    var last = -1
                    let record = try importer.install(source: url, installDirectory: install, stagingDirectory: staging, progress: { value in
                        let percent = Int(value * 100)
                        guard percent != last else { return }
                        last = percent
                        Task { @MainActor in
                            // Only the import that is still current may move the progress bar.
                            guard let self, self.importCancel === flag else { return }
                            if case .importing(let current) = self.phase, value > current { self.phase = .importing(value) }
                        }
                    }, isCancelled: { flag.isCancelled })
                    return .success(record)
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            if importCancel === flag { importCancel = nil }
            switch result {
            case .success(let record):
                await engine.unload()
                isLoaded = false
                phase = .idle
                installRevision += 1
                let fmt = ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)
                post("Imported “\(record.originalName)” (\(fmt)). " + (record.checksumVerified
                     ? "It matches the published KittenTTS 2 checksum."
                     : "It is a different export from the published package, so its checksum could not be compared; the model is checked again when it loads."),
                     for: .modelImport)
            case .failure(let error):
                // Back to idle with the installed model untouched, so the next attempt starts from a clean state without a relaunch.
                phase = .idle
                post(importFailureText(error), for: .modelImport, error: true)
            }
        }
    }

    /// The error's own explanation, plus the current free storage and memory when the failure was an I/O problem, so a one-off
    /// failure (for example under memory pressure) can be told apart from a bad file.
    private func importFailureText(_ error: Error) -> String {
        var text = error.localizedDescription
        switch error as? Kitten2ImportError {
        case .fileSystem?, .unreadable?, nil:
            let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            let free = freeDiskBytes.map(fmt) ?? "unknown"
            let memory = fmt(Int64(clamping: Kitten2Engine.availableMemory))
            text += " (Free storage: \(free); memory available to the app: \(memory)\(isLoaded ? "; KittenTTS 2 is loaded, “Free memory” in Models releases it" : "").)"
        default: break
        }
        return text
    }

    private var busyDescription: String {
        switch phase {
        case .idle: return "idle"
        case .downloading: return "a download"
        case .importing: return "an import"
        case .loading: return "loading the model"
        case .generating: return "generating speech"
        case .recording: return "recording"
        case .removing: return "removing the model"
        }
    }

    func cancelImport() { importCancel?.cancel() }

    func importFailed(_ message: String) { post(message, for: .modelImport, error: true) }

    /// Releases the native engine first (it has the file memory-mapped), and holds `busy` for the whole removal so that no import,
    /// download or synthesis can start in between and have files removed under it.
    func deleteModel() {
        guard !busy else { return }
        phase = .removing
        Task { [weak self] in
            guard let self else { return }
            await engine.unload()
            isLoaded = false
            Kitten2Library.deleteAll(installDirectory: installDirectory, stagingDirectory: stagingDirectory)
            phase = .idle
            installRevision += 1
            post("KittenTTS 2 was removed from this device.", for: .modelDownload)
            post(nil, for: .modelImport)
        }
    }

    // MARK: Load / memory

    private func handleMemoryWarning() {
        guard isLoaded, !busy else { return }
        Task { await unload(reason: "iOS reported low memory, so KittenTTS 2 was released. It reloads on the next use.") }
    }

    func unload(reason: String? = nil) async {
        guard !busy else { return }
        await engine.unload()
        isLoaded = false
        if let reason { post(reason, for: .synthesis) }
    }

    /// Verifies the file header, checks storage/memory, then memory-maps the model (once).
    private func ensureLoaded() async throws {
        if engine.isLoaded { isLoaded = true; return }
        guard runtimeLinked else { throw NativeEngineError(message: "This build does not include the KittenTTS 2 speech engine.") }
        guard isInstalled else { throw NativeEngineError(message: "Download KittenTTS 2 first (Models tab).") }
        phase = .loading
        post("Preparing KittenTTS 2… the first start can take around 10–30 seconds.", for: .synthesis)
        let url = modelURL
        let report = try await Task.detached(priority: .userInitiated) { try AudioCppGGUFInspector.inspect(url: url) }.value
        let validation = AudioCppGGUFInspector.validate(report)
        guard validation.passed else { throw NativeEngineError(message: "The installed file is not a valid KittenTTS 2 package. Remove it in the Models tab and download or import a compatible file.") }
        let available = Kitten2Engine.availableMemory
        let snapshot = ResourceSnapshot(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                        availableMemory: available > 0 ? available : nil,
                                        freeStorage: Self.freeDisk(FileManager.default.temporaryDirectory))
        let verdict = ResourceAdvisor.assess(report: report, snapshot: snapshot)
        guard verdict.canProceed else { throw NativeEngineError(message: verdict.refusals.joined(separator: "\n")) }
        _ = kt_redirect_stderr(stderrPath)
        crumb("native model load")
        defer { crumb(nil) }
        let threads = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 6)
        let result = try await engine.load(path: url.path, threads: threads)
        lastLoadSeconds = result.seconds
        isLoaded = true
        if !verdict.warnings.isEmpty { post("Heads up: " + verdict.warnings.joined(separator: " "), for: .synthesis) }
    }

    // MARK: Synthesis

    private func preflight() throws {
        let check = SynthesisPreflight.assess(availableMemory: Kitten2Engine.availableMemory)
        guard check.canProceed else { throw NativeEngineError(message: check.message + " Close other apps and try again.") }
    }

    func speak(_ rawText: String) {
        guard !busy else { return }
        let useClone = useClonedVoice
        let selectedVoice = voice
        let reference = self.reference, transcript = self.transcript
        phase = .loading
        post(nil, for: .synthesis)
        Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                if useClone {
                    guard let reference else { throw NativeEngineError(message: "Record or choose a reference clip in Voices first.") }
                    if transcriptDraft.needsReview {
                        throw NativeEngineError(message: "Review the automatic transcript in Voices first: listen to the clip, correct any wrong words and punctuation, then confirm it.")
                    }
                    let checked = try CloneInput.validate(clip: reference, transcript: transcript)
                    let text = try SynthesisInput.validatePreset(text: rawText, voice: Kitten2Package.defaultVoice)
                    try await ensureLoaded()
                    try preflight()
                    phase = .generating
                    post("Cloning the voice and generating speech… this can't be interrupted, but you can keep using the app.", for: .synthesis)
                    crumb("native synthesis (clone)")
                    let audio = try await engine.clone(text: text, reference: checked.clip, transcript: checked.transcript)
                    try finish(audio, text: text, voice: "Cloned voice", started: started)
                } else {
                    let text = try SynthesisInput.validatePreset(text: rawText, voice: selectedVoice)
                    try await ensureLoaded()
                    try preflight()
                    phase = .generating
                    post("Generating speech… this can't be interrupted, but you can keep using the app.", for: .synthesis)
                    crumb("native synthesis")
                    let audio = try await engine.synthesize(text: text, voice: selectedVoice)
                    try finish(audio, text: text, voice: selectedVoice, started: started)
                }
            } catch {
                crumb(nil)
                phase = .idle
                post(error.localizedDescription, for: .synthesis, error: true)
            }
        }
    }

    private func finish(_ audio: NativeAudio, text: String, voice: String, started: Date) throws {
        crumb(nil)
        phase = .idle
        guard CloneInput.isUsableOutput(samples: audio.samples, sampleRate: audio.sampleRate) else {
            throw NativeEngineError(message: "The engine returned silent audio, so nothing was saved. Please try again.")
        }
        let elapsed = Date().timeIntervalSince(started)
        lastSynthesisNote = String(format: "Last: %.1f s of audio, %d Hz, generated in %.1f s", audio.duration, audio.sampleRate, elapsed)
        post(String(format: "Done: %.1f s of audio.", audio.duration), for: .synthesis)
        app.addRecord(samples: audio.samples, sampleRate: audio.sampleRate, text: text, family: .kitten2, modelName: Kitten2Package.displayName, voice: voice, speed: 1.0)
    }

    // MARK: Voice cloning reference

    func importReference(_ url: URL) {
        post(nil, for: .referenceAudio)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let clip = try ReferenceAudioIO.loadClip(from: url)
            try acceptReference(clip, name: url.lastPathComponent)
        } catch {
            post(error.localizedDescription, for: .referenceAudio, error: true)
        }
    }

    private func acceptReference(_ clip: ReferenceClip, name: String) throws {
        if clip.duration < CloneInput.minSeconds { throw CloneInput.Problem.tooShort(clip.duration) }
        if clip.duration > CloneInput.maxSeconds { throw CloneInput.Problem.tooLong(clip.duration) }
        if clip.peak < 0.001 { throw CloneInput.Problem.silent }
        _ = try ReferenceAudioIO.writePreview(clip)
        reference = clip
        referenceName = name
        transcriptionTask?.cancel()
        isTranscribing = false
        transcriptDraft.clipChanged()
        transcriptionNote = nil
        post(String(format: "Reference ready (%.1f s). Transcribe it or type exactly what is said in it.", clip.duration), for: .referenceAudio)
        if transcriptDraft.isEmpty { transcribeReference() }
    }

    func clearReference() {
        stopPreview()
        transcriptionTask?.cancel()
        isTranscribing = false
        transcriptionNote = nil
        transcriptDraft.clipChanged()
        reference = nil; referenceName = ""; useClonedVoice = false
    }

    // MARK: Automatic transcript

    /// Drafts the transcript with on-device speech recognition. The result is only a draft the person must review.
    /// `replacingTyped` is true when the person explicitly asks to transcribe again.
    func transcribeReference(replacingTyped: Bool = false) {
        guard reference != nil, !isTranscribing else { return }
        isTranscribing = true
        transcriptionNote = nil
        let url = ReferenceAudioIO.previewURL()
        transcriptionTask = Task { [weak self] in
            let outcome: ReferenceTranscriber.Outcome?
            var failure: String?
            do { outcome = try await ReferenceTranscriber.transcribe(fileAt: url) }
            catch is CancellationError { outcome = nil }
            catch { outcome = nil; failure = "Automatic transcription failed (\(error.localizedDescription)). Type the transcript yourself." }
            guard let self, !Task.isCancelled else { return }
            isTranscribing = false
            if let failure { transcriptionNote = failure; return }
            switch outcome {
            case .text(let text)?:
                if !transcriptDraft.applyRecognized(text, replacingTyped: replacingTyped) {
                    transcriptionNote = "Automatic transcription finished, but your own text was kept. Tap Transcribe again to replace it."
                }
            case .unavailable(let why)?: transcriptionNote = why.message
            case .nothingRecognized?: transcriptionNote = "No speech was recognized in the clip. Type the transcript yourself."
            case nil: break
            }
        }
    }

    func confirmTranscript() { transcriptDraft.confirm() }

    func startRecording() {
        guard !busy else { return }
        Task { [weak self] in
            guard let self else { return }
            post(nil, for: .referenceAudio)
            guard await MicrophoneAccess.request() else {
                post("Microphone access is off. Enable it in Settings > Privacy > Microphone, or choose an audio file instead.", for: .referenceAudio, error: true)
                return
            }
            stopPreview()
            do {
                try recorder.start()
                phase = .recording
                recordingSeconds = 0
                recordingTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.recorder.isRecording else { break }
                        self.recordingSeconds = self.recorder.elapsed
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if let self, !Task.isCancelled, self.phase == .recording { self.stopRecording() }
                }
            } catch {
                post("Could not record: \(error.localizedDescription)", for: .referenceAudio, error: true)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        recordingTimer?.cancel()
        let url = recorder.stop()
        phase = .idle
        guard let url else { post("Nothing was recorded.", for: .referenceAudio, error: true); return }
        do {
            let clip = try WAVDecoder.decode(url: url)
            try acceptReference(clip, name: "Recording")
        } catch {
            post(error.localizedDescription, for: .referenceAudio, error: true)
        }
    }

    func togglePreview() {
        if previewing { stopPreview(); return }
        guard reference != nil else { return }
        post(nil, for: .playback)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: ReferenceAudioIO.previewURL())
            player.delegate = self
            previewPlayer = player
            previewing = true
            player.play()
        } catch {
            post("Preview failed: \(error.localizedDescription)", for: .playback, error: true)
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.previewing = false }
    }

    /// Validation shown live under the clone form.
    var cloneStatus: (ok: Bool, text: String)? {
        guard let reference else { return nil }
        if transcriptDraft.needsReview { return (false, "Review the transcript below: fix any misheard words and punctuation, then tap “Words and punctuation are correct” (or edit it) to use this voice.") }
        do {
            let checked = try CloneInput.validate(clip: reference, transcript: transcript)
            return (true, checked.warnings.isEmpty ? "Ready to use." : checked.warnings.joined(separator: " "))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Diagnostics

    var sourceDescription: String {
        switch activeModel?.source {
        case .downloaded?: return "downloaded"
        case .imported?: return "imported from Files"
        case nil: return "none"
        }
    }

    func diagnosticsText() -> String {
        let fmt = { (b: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file) }
        var lines = [
            "KittenTTS app diagnostics",
            "runtime linked: \(runtimeLinked ? "yes" : "NO (UI-only build)")",
            "runtime: \(Kitten2Engine.runtimeInfo)",
            "device OS: \(ProcessInfo.processInfo.operatingSystemVersionString); physical memory: \(fmt(ProcessInfo.processInfo.physicalMemory))",
            "available to app: \(fmt(Kitten2Engine.availableMemory)); free storage: \(freeDiskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown")",
            "KittenTTS 2 installed: \(isInstalled) (\(sourceDescription)); partial download: \(partialBytes) bytes; loaded: \(isLoaded)",
        ]
        if let s = lastLoadSeconds { lines.append(String(format: "last model load: %.1f s", s)) }
        if let n = lastSynthesisNote { lines.append(n) }
        if let stats = engine.stats {
            lines.append("native sessions created: \(stats.sessions_created); reset after a failed request: \(stats.sessions_reset); failed requests: \(stats.failures); completed: \(stats.completed)")
        }
        if let p = previousRunNote { lines.append(p) }
        return lines.joined(separator: "\n")
    }
}
