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
        case loading
        case generating
        case recording
    }

    static let licenseKey = "kt.kitten2.licenseAcknowledged"
    static let breadcrumbKey = "kt.lastStage"
    static let crashNoteKey = "kt.previousRunNote"

    @Published var phase: Phase = .idle
    @Published var message: String?
    @Published var messageIsError = false
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
    @Published var transcript = ""
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

    nonisolated static func freeDisk(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return values?.volumeAvailableCapacity.map { Int64($0) }
    }

    // MARK: State

    var runtimeLinked: Bool { Kitten2Engine.isLinked }
    var isInstalled: Bool { _ = installRevision; return InstalledModels.isInstalled(modelFile, in: installDirectory) }
    var partialBytes: Int64 { _ = installRevision; return downloader.partialBytes(for: modelFile, in: stagingDirectory) }
    var busy: Bool { phase != .idle }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }
    var modelURL: URL { InstalledModels.fileURL(modelFile, in: installDirectory) }
    var canSpeakWithCloneVoice: Bool { reference != nil && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func show(_ text: String?, error: Bool = false) { message = text; messageIsError = error }

    private func crumb(_ stage: String?) {
        if let stage { UserDefaults.standard.set("\(stage) (\(ISO8601DateFormatter().string(from: Date())))", forKey: Self.breadcrumbKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey) }
    }

    func clearPreviousRunNote() {
        previousRunNote = nil
        UserDefaults.standard.removeObject(forKey: Self.crashNoteKey)
    }

    // MARK: Download

    var freeDiskBytes: Int64? { Self.freeDisk(installDirectory.deletingLastPathComponent()) ?? Self.freeDisk(FileManager.default.temporaryDirectory) }

    /// Called after the user confirmed size / network / license in the dialog.
    func startDownload(allowCellular: Bool) {
        guard !busy, !isInstalled else { return }
        licenseAcknowledged = true
        let file = modelFile
        let staging = stagingDirectory, install = installDirectory
        let loader = ModelDownloader(transport: URLSessionTransport(allowsCellular: allowCellular), availableDisk: Self.freeDisk)
        phase = .downloading(DownloadProgress(stage: .checkingSpace, bytes: loader.partialBytes(for: file, in: staging), total: file.size))
        show(nil)
        let report: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.applyProgress(progress) }
        }
        downloadTask = Task { [weak self] in
            do {
                try await loader.download(file, stagingDirectory: staging, installDirectory: install, progress: report)
                self?.phase = .idle
                self?.installRevision += 1
                self?.show("KittenTTS 2 is ready. It was verified against its published checksum.")
            } catch let error as DownloadError {
                self?.phase = .idle
                self?.installRevision += 1
                if error == .cancelled { self?.show("Download paused. Tap Resume to continue where it stopped.") }
                else { self?.show(error.localizedDescription, error: true) }
            } catch {
                self?.phase = .idle
                self?.installRevision += 1
                self?.show(error.localizedDescription, error: true)
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
            self?.show("Download cancelled and the partial file was removed.")
        }
    }

    func deleteModel() {
        guard !busy else { return }
        Task { [weak self] in
            guard let self else { return }
            await engine.unload()
            isLoaded = false
            InstalledModels.delete(modelFile, installDirectory: installDirectory, stagingDirectory: stagingDirectory)
            installRevision += 1
            show("KittenTTS 2 was removed from this device.")
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
        if let reason { show(reason) }
    }

    /// Verifies the file header, checks storage/memory, then memory-maps the model (once).
    private func ensureLoaded() async throws {
        if engine.isLoaded { isLoaded = true; return }
        guard runtimeLinked else { throw NativeEngineError(message: "This build does not include the KittenTTS 2 speech engine.") }
        guard isInstalled else { throw NativeEngineError(message: "Download KittenTTS 2 first (Models tab).") }
        phase = .loading
        show("Preparing KittenTTS 2… the first start can take around 10–30 seconds.")
        let url = modelURL
        let report = try await Task.detached(priority: .userInitiated) { try AudioCppGGUFInspector.inspect(url: url) }.value
        let validation = AudioCppGGUFInspector.validate(report)
        guard validation.passed else { throw NativeEngineError(message: "The installed file is not a valid KittenTTS 2 package. Delete it and download again.") }
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
        if !verdict.warnings.isEmpty { show("Heads up: " + verdict.warnings.joined(separator: " ")) }
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
        show(nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                if useClone {
                    guard let reference else { throw NativeEngineError(message: "Record or choose a reference clip in Voices first.") }
                    let checked = try CloneInput.validate(clip: reference, transcript: transcript)
                    let text = try SynthesisInput.validatePreset(text: rawText, voice: Kitten2Package.defaultVoice)
                    try await ensureLoaded()
                    try preflight()
                    phase = .generating
                    show("Cloning the voice and generating speech… this can't be interrupted, but you can keep using the app.")
                    crumb("native synthesis (clone)")
                    let audio = try await engine.clone(text: text, reference: checked.clip, transcript: checked.transcript)
                    try finish(audio, text: text, voice: "Cloned voice", started: started)
                } else {
                    let text = try SynthesisInput.validatePreset(text: rawText, voice: selectedVoice)
                    try await ensureLoaded()
                    try preflight()
                    phase = .generating
                    show("Generating speech… this can't be interrupted, but you can keep using the app.")
                    crumb("native synthesis")
                    let audio = try await engine.synthesize(text: text, voice: selectedVoice)
                    try finish(audio, text: text, voice: selectedVoice, started: started)
                }
            } catch {
                crumb(nil)
                phase = .idle
                show(error.localizedDescription, error: true)
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
        show(String(format: "Done: %.1f s of audio.", audio.duration))
        app.addRecord(samples: audio.samples, sampleRate: audio.sampleRate, text: text, family: .kitten2, modelName: Kitten2Package.displayName, voice: voice, speed: 1.0)
    }

    // MARK: Voice cloning reference

    func importReference(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let clip = try ReferenceAudioIO.loadClip(from: url)
            try acceptReference(clip, name: url.lastPathComponent)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func acceptReference(_ clip: ReferenceClip, name: String) throws {
        if clip.duration < CloneInput.minSeconds { throw CloneInput.Problem.tooShort(clip.duration) }
        if clip.duration > CloneInput.maxSeconds { throw CloneInput.Problem.tooLong(clip.duration) }
        if clip.peak < 0.001 { throw CloneInput.Problem.silent }
        _ = try ReferenceAudioIO.writePreview(clip)
        reference = clip
        referenceName = name
        show(String(format: "Reference ready (%.1f s). Now type exactly what is said in it.", clip.duration))
    }

    func clearReference() {
        stopPreview()
        reference = nil; referenceName = ""; useClonedVoice = false
    }

    func startRecording() {
        guard !busy else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await MicrophoneAccess.request() else {
                show("Microphone access is off. Enable it in Settings > Privacy > Microphone, or choose an audio file instead.", error: true)
                return
            }
            stopPreview()
            do {
                try recorder.start()
                phase = .recording
                recordingSeconds = 0
                show(nil)
                recordingTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.recorder.isRecording else { break }
                        self.recordingSeconds = self.recorder.elapsed
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if let self, !Task.isCancelled, self.phase == .recording { self.stopRecording() }
                }
            } catch {
                show("Could not record: \(error.localizedDescription)", error: true)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        recordingTimer?.cancel()
        let url = recorder.stop()
        phase = .idle
        guard let url else { show("Nothing was recorded.", error: true); return }
        do {
            let clip = try WAVDecoder.decode(url: url)
            try acceptReference(clip, name: "Recording")
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func togglePreview() {
        if previewing { stopPreview(); return }
        guard reference != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: ReferenceAudioIO.previewURL())
            player.delegate = self
            previewPlayer = player
            previewing = true
            player.play()
        } catch {
            show("Preview failed: \(error.localizedDescription)", error: true)
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
        do {
            let checked = try CloneInput.validate(clip: reference, transcript: transcript)
            return (true, checked.warnings.isEmpty ? "Ready to use." : checked.warnings.joined(separator: " "))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        let fmt = { (b: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file) }
        var lines = [
            "KittenTTS app diagnostics",
            "runtime linked: \(runtimeLinked ? "yes" : "NO (UI-only build)")",
            "runtime: \(Kitten2Engine.runtimeInfo)",
            "device OS: \(ProcessInfo.processInfo.operatingSystemVersionString); physical memory: \(fmt(ProcessInfo.processInfo.physicalMemory))",
            "available to app: \(fmt(Kitten2Engine.availableMemory)); free storage: \(freeDiskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown")",
            "KittenTTS 2 installed: \(isInstalled); partial download: \(partialBytes) bytes; loaded: \(isLoaded)",
        ]
        if let s = lastLoadSeconds { lines.append(String(format: "last model load: %.1f s", s)) }
        if let n = lastSynthesisNote { lines.append(n) }
        if let p = previousRunNote { lines.append(p) }
        return lines.joined(separator: "\n")
    }
}
