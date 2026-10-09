import Foundation
import KittenTTS
import SwiftUI

@MainActor
final class SpeechViewModel: ObservableObject {
    enum ModelState: Equatable {
        case notInstalled
        case installed
        case preparing(progress: Double?)
        case ready
        case failed(String)
    }

    enum GenerationState: Equatable {
        case idle
        case generating(sentencesDone: Int)
        case failed(String)
    }

    // MARK: Published state

    @Published var variant: ModelVariant {
        didSet {
            guard variant != oldValue else { return }
            defaults.set(variant.rawValue, forKey: Keys.variant)
            engine = nil
            refreshInstallation()
        }
    }
    @Published private(set) var modelState: ModelState = .notInstalled
    @Published private(set) var usingImportedFiles = false
    @Published private(set) var availableVoices: [VoiceInfo] = []
    @Published var selectedVoiceID: String {
        didSet { defaults.set(selectedVoiceID, forKey: Keys.voice) }
    }
    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: Keys.speed) }
    }
    @Published var inputText: String = "Hello! This speech was generated entirely on your device."
    @Published private(set) var generationState: GenerationState = .idle
    @Published private(set) var history: [GenerationRecord] = []
    @Published private(set) var currentRecord: GenerationRecord?
    @Published private(set) var playingRecordID: UUID?
    @Published var importMessage: String?

    // MARK: Private

    private enum Keys {
        static let variant = "modelVariant"
        static let voice = "voiceID"
        static let speed = "speed"
    }

    private let defaults = UserDefaults.standard
    private var engine: KittenTTS?
    private var historyStore: GenerationHistory
    private var generationTask: Task<Void, Never>?
    private var generationToken = UUID()
    private let player = AudioPlayer()

    init() {
        let saved = UserDefaults.standard.string(forKey: Keys.variant).flatMap(ModelVariant.init(rawValue:))
        variant = saved ?? .nano
        selectedVoiceID = UserDefaults.standard.string(forKey: Keys.voice) ?? VoiceCatalog.known[0].id
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.speed)
        speed = savedSpeed == 0 ? 1.0 : min(max(savedSpeed, 0.5), 2.0)
        historyStore = GenerationHistory(directory: Self.supportDirectory.appendingPathComponent("History", isDirectory: true))
        history = historyStore.records
        player.onFinish = { [weak self] in
            Task { @MainActor in self?.playingRecordID = nil }
        }
        refreshInstallation()
    }

    // MARK: Locations

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KittenTTS2App", isDirectory: true)
    }

    private func importedDirectory(for variant: ModelVariant) -> URL {
        Self.supportDirectory.appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    /// Where the KittenML SDK caches downloaded models (its default storage directory).
    private func sdkDirectory(for variant: ModelVariant) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KittenTTS", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    private func modelFileURLs() -> (onnx: URL, voices: URL, imported: Bool)? {
        let fm = FileManager.default
        let importedDir = importedDirectory(for: variant)
        let importedOnnx = importedDir.appendingPathComponent(variant.onnxFileName)
        let importedVoices = importedDir.appendingPathComponent(ModelVariant.voicesFileName)
        if fm.fileExists(atPath: importedOnnx.path), fm.fileExists(atPath: importedVoices.path) {
            return (importedOnnx, importedVoices, true)
        }
        let sdkDir = sdkDirectory(for: variant)
        let onnx = sdkDir.appendingPathComponent(variant.onnxFileName)
        let voices = sdkDir.appendingPathComponent(ModelVariant.voicesFileName)
        if fm.fileExists(atPath: onnx.path), fm.fileExists(atPath: voices.path) {
            return (onnx, voices, false)
        }
        return nil
    }

    // MARK: Model readiness

    func refreshInstallation() {
        guard let files = modelFileURLs() else {
            usingImportedFiles = false
            availableVoices = []
            modelState = .notInstalled
            return
        }
        usingImportedFiles = files.imported
        do {
            let result = try ModelValidator.validate(onnxURL: files.onnx, voicesURL: files.voices)
            updateVoices(from: result)
            modelState = engine == nil ? .installed : .ready
        } catch {
            availableVoices = []
            modelState = .failed(error.localizedDescription)
        }
    }

    private func updateVoices(from result: ModelValidationResult) {
        availableVoices = VoiceCatalog.available(in: result.voiceIDs)
        if !availableVoices.contains(where: { $0.id == selectedVoiceID }), let first = availableVoices.first {
            selectedVoiceID = first.id
        }
    }

    /// Downloads the model from Hugging Face if missing (via the SDK) and loads it into ONNX Runtime.
    /// Imported files are used instead of downloading when present.
    func prepareModel() {
        if case .preparing = modelState { return }
        modelState = .preparing(progress: nil)
        let variant = self.variant
        let files = modelFileURLs()

        Task {
            do {
                guard let kittenModel = KittenModel(rawValue: variant.rawValue) else {
                    throw ModelValidationError.missing(variant.displayName + " (unsupported by the SDK)")
                }
                var config = KittenTTSConfig(model: kittenModel)
                if let files, files.imported {
                    config.modelFiles = KittenTTSModelFiles(onnxURL: files.onnx, voicesURL: files.voices)
                }
                let loaded = try await KittenTTS(config) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.variant == variant, case .preparing = self.modelState else { return }
                        self.modelState = .preparing(progress: progress)
                    }
                }
                guard self.variant == variant else { return }
                engine = loaded
                refreshInstallation()
                if modelState != .ready { engine = nil }
            } catch {
                guard self.variant == variant else { return }
                refreshInstallation()
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Import

    /// Imports a user-supplied `.onnx` model and `voices.npz`. The files are validated before being copied.
    func importModelFiles(from urls: [URL]) {
        importMessage = nil
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        guard let onnx = urls.first(where: { $0.pathExtension.lowercased() == "onnx" }),
              let voices = urls.first(where: { $0.pathExtension.lowercased() == "npz" }) else {
            importMessage = "Select both the model (.onnx) and voices.npz files together."
            return
        }
        do {
            _ = try ModelValidator.validate(onnxURL: onnx, voicesURL: voices)
            let destination = importedDirectory(for: variant)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: onnx, to: staging.appendingPathComponent(variant.onnxFileName))
            try fm.copyItem(at: voices, to: staging.appendingPathComponent(ModelVariant.voicesFileName))
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            engine = nil
            refreshInstallation()
            importMessage = "Imported files for \(variant.displayName)."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func removeImportedFiles() {
        try? FileManager.default.removeItem(at: importedDirectory(for: variant))
        engine = nil
        importMessage = nil
        refreshInstallation()
    }

    // MARK: Generation

    var canGenerate: Bool {
        guard engine != nil else { return false }
        if case .generating = generationState { return false }
        return true
    }

    var isGenerating: Bool {
        if case .generating = generationState { return true }
        return false
    }

    func generate() {
        guard let engine, !isGenerating else { return }
        let text: String
        do {
            text = try TextInput.validate(inputText)
        } catch {
            generationState = .failed(error.localizedDescription)
            return
        }
        guard let voice = availableVoices.first(where: { $0.id == selectedVoiceID }),
              let kittenVoice = KittenVoice(rawValue: voice.id) else {
            generationState = .failed("The selected voice is not available in this model.")
            return
        }

        stopPlayback()
        generationState = .generating(sentencesDone: 0)
        let token = UUID()
        generationToken = token
        let speedValue = Float(speed)
        let sampleRate = KittenTTSConfig.outputSampleRate
        let modelName = variant.displayName
        let speedUsed = speed

        generationTask = Task {
            defer { if generationToken == token { generationTask = nil } }
            do {
                var samples: [Float] = []
                var done = 0
                let stream = await engine.generateStreaming(text, voice: kittenVoice, speed: speedValue)
                for try await part in stream {
                    try Task.checkCancellation()
                    if !samples.isEmpty { samples += [Float](repeating: 0, count: sampleRate / 8) }
                    samples += part.samples
                    done += 1
                    if generationToken == token { generationState = .generating(sentencesDone: done) }
                }
                try Task.checkCancellation()
                guard generationToken == token else { return }
                guard !samples.isEmpty else { throw KittenTTSError.emptyOutput }

                let wav = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
                let record = try historyStore.add(
                    text: text, voiceID: voice.id, voiceName: voice.displayName, modelName: modelName,
                    speed: speedUsed, duration: Double(samples.count) / Double(sampleRate), wavData: wav)
                history = historyStore.records
                currentRecord = record
                generationState = .idle
                play(record)
            } catch is CancellationError {
                if generationToken == token { generationState = .idle }
            } catch {
                if generationToken == token { generationState = .failed(error.localizedDescription) }
            }
        }
    }

    /// Stops waiting for the current generation. The SDK finishes the sentence it is already
    /// synthesizing in the background, but its output is discarded.
    func cancelGeneration() {
        generationToken = UUID()
        generationTask?.cancel()
        generationTask = nil
        generationState = .idle
    }

    func dismissError() {
        if case .failed = generationState { generationState = .idle }
    }

    // MARK: Playback & history

    func audioURL(for record: GenerationRecord) -> URL {
        historyStore.audioURL(for: record)
    }

    func play(_ record: GenerationRecord) {
        do {
            try player.play(url: audioURL(for: record))
            currentRecord = record
            playingRecordID = record.id
        } catch {
            playingRecordID = nil
            generationState = .failed("Playback failed: \(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        player.stop()
        playingRecordID = nil
    }

    func delete(_ record: GenerationRecord) {
        if playingRecordID == record.id { stopPlayback() }
        if currentRecord?.id == record.id { currentRecord = nil }
        try? historyStore.remove(id: record.id)
        history = historyStore.records
    }

    func clearHistory() {
        stopPlayback()
        currentRecord = nil
        try? historyStore.removeAll()
        history = historyStore.records
    }
}
