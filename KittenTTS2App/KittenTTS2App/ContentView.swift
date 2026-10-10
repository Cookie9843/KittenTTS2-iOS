import KittenCore
import KittenTTS
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable { case speak, voices, models, history }

/// Which speech engine the Speak tab uses.
enum EngineChoice: String, CaseIterable, Identifiable {
    case kitten2, legacy08
    var id: String { rawValue }
    var title: String { self == .kitten2 ? "KittenTTS 2" : "KittenTTS 0.8" }
    var subtitle: String {
        self == .kitten2
            ? "Best quality, many voices, voice cloning. Large one-time download (about 3.3 GB)."
            : "The original small, fast model (often called “KittenTTS 1”; upstream names it 0.8). 8 voices, 25–80 MB."
    }
}

struct ContentView: View {
    @State private var tab: AppTab = .speak

    var body: some View {
        TabView(selection: $tab) {
            SpeakView(tab: $tab).tabItem { Label("Speak", systemImage: "waveform") }.tag(AppTab.speak)
            VoicesView().tabItem { Label("Voices", systemImage: "person.wave.2") }.tag(AppTab.voices)
            ModelsView().tabItem { Label("Models", systemImage: "gearshape") }.tag(AppTab.models)
            HistoryView().tabItem { Label("History", systemImage: "clock") }.tag(AppTab.history)
        }
    }
}

// MARK: - Shared pieces

struct MessageView: View {
    let message: StatusMessage?

    init(_ message: StatusMessage?) { self.message = message }

    var body: some View {
        if let message {
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(message.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message.isError ? "Error: \(message.text)" : message.text)
        }
    }
}

struct EngineSwitcher: View {
    @Binding var engine: EngineChoice

    var body: some View {
        Picker("Engine", selection: $engine) {
            ForEach(EngineChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Text(engine.subtitle).font(.footnote).foregroundStyle(.secondary)
    }
}

// MARK: - Speak

struct SpeakView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var k2: Kitten2Model
    @Binding var tab: AppTab
    @AppStorage("kt.engine") private var engineRaw = EngineChoice.kitten2.rawValue
    @State private var text = ""
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 140

    private var engine: Binding<EngineChoice> {
        Binding(get: { EngineChoice(rawValue: engineRaw) ?? .kitten2 }, set: { engineRaw = $0.rawValue })
    }
    private var choice: EngineChoice { engine.wrappedValue }
    private var ready: Bool { choice == .kitten2 ? (k2.isInstalled && k2.runtimeLinked) : app.isInstalled(app.legacyVariant) }
    private var busy: Bool { app.busy || k2.busy }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section { EngineSwitcher(engine: engine) }
                if !ready { setupSection }
                Section("What should it say?") {
                    TextEditor(text: $text)
                        .frame(minHeight: editorHeight)
                        .accessibilityLabel("Text to speak")
                    if text.isEmpty {
                        Text("Type or paste some text, then tap Speak.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Voice") {
                    LabeledContent("Using", value: voiceName)
                    Button("Change voice…") { tab = .voices }
                }
                Section {
                    Button { speak() } label: {
                        Label("Speak", systemImage: "play.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!ready || busy || trimmed.isEmpty)
                    progressView
                    if choice == .kitten2 { MessageView(k2.status[.synthesis]) }
                    else { MessageView(app.status[.synthesis]) }
                    MessageView(app.status[.history])
                }
                if let latest = app.latest { resultSection(latest) }
            }
            .navigationTitle("KittenTTS")
        }
    }

    private var voiceName: String {
        if choice == .kitten2 { return k2.useClonedVoice ? "My cloned voice" : k2.voice }
        return app.voice.displayName
    }

    @ViewBuilder private var setupSection: some View {
        Section("Get started") {
            VStack(alignment: .leading, spacing: 8) {
                Text(choice == .kitten2 ? "KittenTTS 2 is not on this device yet." : "KittenTTS 0.8 is not on this device yet.").font(.headline)
                Text(choice == .kitten2
                     ? (k2.runtimeLinked ? "Download it once in the Models tab. Everything afterwards runs on your device, offline."
                                         : "This build of the app does not include the KittenTTS 2 speech engine, so it can’t be used here.")
                     : "Download the small model in the Models tab (or switch to KittenTTS 2 above). Everything afterwards runs on your device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Open Models") { tab = .models }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var progressView: some View {
        if choice == .kitten2 {
            switch k2.phase {
            case .loading: ProgressView("Preparing KittenTTS 2…")
            case .generating: ProgressView("Generating speech…")
            default: EmptyView()
            }
        } else {
            switch app.phase {
            case .loading: ProgressView("Loading model…")
            case .generating: ProgressView("Generating speech…")
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func resultSection(_ record: GenerationRecord) -> some View {
        Section("Latest result") {
            Text(record.text).lineLimit(3)
            Text("\(record.modelName) · \(record.voice) · \(String(format: "%.1f", record.duration)) s")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if app.playingID == record.id {
                    Button("Stop") { app.stopPlayback() }
                } else {
                    Button("Play again") { app.play(record) }
                }
                Spacer()
                if let url = app.audioURL(record) { ShareLink("Save or share WAV", item: url) }
            }
            .buttonStyle(.bordered)
            MessageView(app.status[.playback])
        }
    }

    private func speak() {
        switch choice {
        case .kitten2: k2.speak(trimmed)
        case .legacy08:
            app.text = trimmed
            app.generate()
        }
    }
}

// MARK: - Voices

struct VoicesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var k2: Kitten2Model
    @AppStorage("kt.engine") private var engineRaw = EngineChoice.kitten2.rawValue

    private var engine: Binding<EngineChoice> {
        Binding(get: { EngineChoice(rawValue: engineRaw) ?? .kitten2 }, set: { engineRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { EngineSwitcher(engine: engine) }
                if engine.wrappedValue == .kitten2 { kitten2Voices } else { legacyVoices }
            }
            .navigationTitle("Voices")
        }
    }

    @ViewBuilder private var legacyVoices: some View {
        Section("Voice") {
            Picker("Voice", selection: $app.voice) {
                ForEach(KittenVoice.allCases) { Text($0.displayName).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("Speed: \(String(format: "%.1f", app.speed))×")
                Slider(value: $app.speed, in: 0.5...2.0, step: 0.1).accessibilityLabel("Speaking speed")
            }
        }
        Section {
            Text("KittenTTS 0.8 has 8 built-in voices. It cannot clone voices; switch to KittenTTS 2 for that.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var presetSelection: Binding<String> {
        Binding(get: { k2.voice }, set: { k2.voice = $0; k2.useClonedVoice = false })
    }

    @ViewBuilder private var kitten2Voices: some View {
        Section("Preset voice") {
            Picker("Voice", selection: presetSelection) {
                ForEach(Kitten2Package.presetVoices) { Text($0.displayName).tag($0.id) }
            }
            Text("Voices named after a language are the multilingual presets. Only “Bruno” has been confirmed on a real device by the project; others come from the model’s preset list.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Voice cloning (separate from the presets)") {
            NavigationLink {
                CloneVoiceView()
            } label: {
                Label(k2.reference == nil ? "Clone a voice…" : "Edit cloned voice…", systemImage: "person.crop.circle.badge.plus")
            }
            Toggle("Speak with my cloned voice", isOn: $k2.useClonedVoice)
                .disabled(!(k2.cloneStatus?.ok ?? false))
            Text(k2.useClonedVoice ? "Speak uses your cloned voice." : "Speak uses the preset voice “\(k2.voice)”.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct CloneVoiceView: View {
    @EnvironmentObject var k2: Kitten2Model
    @State private var pickingAudio = false

    var body: some View {
        Form { cloneSection }
            .navigationTitle("Clone a voice")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $pickingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { k2.importReference(url) }
                case .failure(let error): k2.post("Could not open the file: \(error.localizedDescription)", for: .referenceAudio, error: true)
                }
            }
    }

    @ViewBuilder private var cloneSection: some View {
        Section {
            Text("Record or choose 1–30 seconds of one person speaking clearly, then type exactly what they say. Only clone voices you have the right to use. The app does not transcribe audio for you.")
                .font(.footnote).foregroundStyle(.secondary)
            if k2.phase == .recording {
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text(String(format: "Recording… %.0f s (stops at 30 s)", k2.recordingSeconds)).monospacedDigit()
                }
                Button("Stop recording") { k2.stopRecording() }.buttonStyle(.borderedProminent)
            } else {
                Button { k2.startRecording() } label: { Label(k2.reference == nil ? "Record with microphone" : "Record again", systemImage: "mic.fill") }
                    .disabled(k2.busy)
                Button { pickingAudio = true } label: { Label("Choose an audio file…", systemImage: "folder") }
                    .disabled(k2.busy)
            }
            MessageView(k2.status[.referenceAudio])
        }
        if let clip = k2.reference {
            Section("Reference clip") {
                LabeledContent(k2.referenceName, value: String(format: "%.1f", clip.duration) + " s")
                HStack {
                    Button(k2.previewing ? "Stop preview" : "Preview clip") { k2.togglePreview() }
                    Spacer()
                    Button("Remove", role: .destructive) { k2.clearReference() }
                }
                .buttonStyle(.bordered)
                MessageView(k2.status[.playback])
                Text("What is said in the clip").font(.subheadline)
                TextEditor(text: $k2.transcript)
                    .frame(minHeight: 80)
                    .accessibilityLabel("Transcript of the reference clip")
                if let status = k2.cloneStatus {
                    Text(status.text).font(.footnote).foregroundStyle(status.ok ? Color.secondary : Color.red)
                }
                Toggle("Speak with my cloned voice", isOn: $k2.useClonedVoice)
                    .disabled(!(k2.cloneStatus?.ok ?? false))
            }
        }
    }
}

// MARK: - Models & settings

struct ModelsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var k2: Kitten2Model
    @State private var pickingLegacy = false
    @State private var pickingKitten2 = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false

    private static let ggufType = UTType(filenameExtension: "gguf") ?? .data

    var body: some View {
        NavigationStack {
            Form {
                kitten2Section
                legacySection
                settingsSection
            }
            .navigationTitle("Models")
            .sheet(isPresented: $k2.showDownloadConfirmation) { DownloadConsentView() }
            .confirmationDialog("Remove KittenTTS 2 from this device?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { k2.deleteModel() }
                Button("Keep", role: .cancel) {}
            } message: { Text("You can download or import it again later.") }
            .confirmationDialog("Remove the partial download?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { k2.cancelDownloadAndDiscard() }
                Button("Keep", role: .cancel) {}
            }
            .fileImporter(isPresented: $pickingLegacy, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): app.importFiles(urls)
                case .failure(let error): app.post("Could not open files: \(error.localizedDescription)", for: .modelSetup, error: true)
                }
            }
            .fileImporter(isPresented: $pickingKitten2, allowedContentTypes: [Self.ggufType, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { k2.importModel(from: url) }
                case .failure(let error): k2.importFailed("Could not open the file: \(error.localizedDescription)")
                }
            }
        }
    }

    private var sizeText: String { ByteCountFormatter.string(fromByteCount: k2.modelFile.size, countStyle: .file) }

    @ViewBuilder private var kitten2Section: some View {
        Section("KittenTTS 2 – best quality") {
            if !k2.runtimeLinked {
                Text("This build of the app does not include the KittenTTS 2 speech engine, so downloading or importing a model would not be useful. Install the full-app build instead.")
                    .font(.footnote).foregroundStyle(.red)
            }
            if let model = k2.activeModel {
                installedRows(model)
            } else if case .downloading(let progress) = k2.phase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                    Text(progressText(progress)).font(.footnote).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Button("Pause") { k2.pauseDownload() }
                if progress.stage == .downloading {
                    Button("Cancel and remove partial download", role: .destructive) { confirmDiscard = true }
                }
            } else if case .importing(let fraction) = k2.phase {
                ProgressView("Importing…", value: fraction)
                Button("Cancel import", role: .destructive) { k2.cancelImport() }
            } else {
                Label("Not on this device yet", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                let partial = k2.partialBytes
                if partial > 0 {
                    Text("Paused at \(ByteCountFormatter.string(fromByteCount: partial, countStyle: .file)) of \(sizeText).").font(.footnote)
                    Button("Resume download") { k2.showDownloadConfirmation = true }.disabled(k2.busy || !k2.runtimeLinked)
                    Button("Discard partial download", role: .destructive) { confirmDiscard = true }
                } else {
                    Button("Download from Hugging Face (\(sizeText))") { k2.showDownloadConfirmation = true }
                        .disabled(k2.busy || !k2.runtimeLinked)
                }
            }
            if !k2.isInstalled && !k2.isImporting && !k2.isDownloading {
                Button("Import a KittenTTS 2 file from Files…") { pickingKitten2 = true }.disabled(k2.busy || !k2.runtimeLinked)
            }
            MessageView(k2.status[.modelDownload])
            MessageView(k2.status[.modelImport])
            Text("Compatible file: the audio.cpp single-file KittenTTS 2 package (\(AudioCppPackage.publishedFileName)). Other GGUF files are not supported. KittenML’s own TQ2_1 GGUF uses a different runtime and cannot be imported here.")
                .font(.footnote).foregroundStyle(.secondary)
            Link("Model page on Hugging Face", destination: Kitten2Package.repositoryPage)
        }
    }

    @ViewBuilder private func installedRows(_ model: Kitten2InstalledModel) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
        switch model.source {
        case .downloaded:
            Label("Downloaded from Hugging Face (\(size))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Verified against the published checksum.").font(.footnote).foregroundStyle(.secondary)
        case .imported(let record):
            Label("Imported from Files (\(size))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let record {
                Text("“\(record.originalName)” · " + (record.checksumVerified ? "matches the published checksum." : "different export; checksum not comparable."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if k2.isLoaded {
            Button("Free memory") { Task { await k2.unload(reason: "KittenTTS 2 was released from memory. It reloads on the next use.") } }
                .disabled(k2.busy)
        }
        Button("Import a different file from Files…") { pickingKitten2 = true }.disabled(k2.busy || !k2.runtimeLinked)
        Button("Remove from this device", role: .destructive) { confirmDelete = true }.disabled(k2.busy)
    }

    private func progressText(_ p: DownloadProgress) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch p.stage {
        case .checkingSpace: return "Checking free storage…"
        case .downloading: return "Downloading \(fmt(p.bytes)) of \(fmt(p.total)) (\(Int(p.fraction * 100))%)"
        case .verifying: return "Verifying the download… \(Int(p.fraction * 100))%"
        case .installing: return "Installing…"
        }
    }

    @ViewBuilder private var legacySection: some View {
        Section("KittenTTS 0.8 – original, small and fast") {
            Picker("Size", selection: $app.legacyVariant) {
                ForEach(LegacyVariant.allCases) { Text($0.displayName).tag($0) }
            }
            if app.isInstalled(app.legacyVariant) {
                Label("Ready on this device", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Download \(app.legacyVariant.displayName)") { app.downloadLegacy() }.disabled(app.busy)
                Text("Downloaded from huggingface.co/\(app.legacyVariant.huggingFaceRepo).").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Import files you already have…") { pickingLegacy = true }.disabled(app.busy)
            switch app.phase {
            case .importing(let p): ProgressView("Importing…", value: p)
            case .downloading(let p): ProgressView("Downloading…", value: p)
            default: EmptyView()
            }
            if case .importing = app.phase { Button("Cancel import", role: .destructive) { app.cancelCurrentImport() } }
            MessageView(app.status[.modelSetup])
            Text("Pick the .onnx model and its voices.npz together from the matching KittenML/kitten-tts-*-0.8 repository.")
                .font(.footnote).foregroundStyle(.secondary)
            Link("\(app.legacyVariant.displayName) on Hugging Face", destination: app.legacyVariant.repositoryPage)
            Menu("All original KittenTTS 0.8 models") {
                ForEach(LegacyVariant.allCases) { variant in
                    Link(variant.displayName, destination: variant.repositoryPage)
                }
                Link("KittenML on Hugging Face", destination: LegacyVariant.organizationPage)
            }
            Text("The original lightweight family is KittenTTS 0.8 (often called “KittenTTS 1”).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var settingsSection: some View {
        Section("About this app") {
            NavigationLink("Licenses and credits") { LicensesView() }
            NavigationLink("Advanced: memory and diagnostics") { DiagnosticsView() }
            Text("Runs on iPhone and iPad (iOS 16.4 or later). Memory, storage and speed vary by device, and iOS may close the app when memory runs out. A native Mac version, Android and other platforms are not available.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Short consent shown before the multi-GB download; the full license text lives in Licenses.
struct DownloadConsentView: View {
    @EnvironmentObject var k2: Kitten2Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let storage = k2.downloadStorage
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        NavigationStack {
            Form {
                Section {
                    Text("This is a one-time download from huggingface.co/\(Kitten2Package.repository). You can pause and resume it. Mobile data charges may apply if you allow mobile data.")
                    LabeledContent("Still to download", value: fmt(k2.modelFile.size - storage.alreadyPresentBytes))
                    LabeledContent("Free on this device", value: storage.availableBytes.map(fmt) ?? "unknown")
                    if storage.outcome == .insufficient, let shortfall = storage.shortfall {
                        Text("About \(fmt(shortfall)) more storage is needed (including working space). Free up space, then try again.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("By downloading you agree to the model’s license terms.")
                    NavigationLink("Read the full license") { LicensesView() }
                }
                Section {
                    Button("Download on Wi-Fi only") { start(cellular: false) }
                    Button("Allow mobile data too") { start(cellular: true) }
                }
                .disabled(storage.outcome == .insufficient)
            }
            .navigationTitle("Download KittenTTS 2?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
    }

    private func start(cellular: Bool) {
        dismiss()
        k2.startDownload(allowCellular: cellular)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var k2: Kitten2Model

    var body: some View {
        let report = k2.diagnosticsText()
        List {
            Section {
                Text(report).font(.footnote.monospaced()).textSelection(.enabled)
                ShareLink("Share diagnostics", item: report)
            }
            if k2.previousRunNote != nil {
                Section("Last session ended unexpectedly") {
                    Button("Clear this note", role: .destructive) { k2.clearPreviousRunNote() }
                }
            }
            Section {
                Text("KittenTTS 2 needs a lot of memory. Your device’s limits vary, and iOS may close the app if memory runs out. The app checks free memory first and refuses to start when it is clearly too low.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
    }
}

struct LicensesView: View {
    private var notices: String {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return "See THIRD_PARTY_NOTICES.md in the project repository."
    }

    var body: some View {
        List {
            Section("In plain language") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This app").font(.headline)
                    Text("The app’s own code is open source under the MIT license.").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("KittenTTS 2 model").font(.headline)
                    Text("\(Kitten2Package.attribution) Its license is the \(Kitten2Package.licenseName). The complete license and NOTICE are embedded in the model file and published with the model. Downloading or importing the model means you agree to follow them.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Model page on Hugging Face", destination: Kitten2Package.repositoryPage)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("KittenTTS 0.8 (original) models").font(.headline)
                    Text("Each original model is published by KittenML on Hugging Face under the terms stated on its page.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("KittenML on Hugging Face", destination: LegacyVariant.organizationPage)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech engines and libraries").font(.headline)
                    Text("KittenTTS 2 runs on audio.cpp and ggml; KittenTTS 0.8 uses the KittenTTS Swift SDK and ONNX Runtime. Their notices are listed below and in the app bundle.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Full notices") {
                Text(notices).font(.footnote).textSelection(.enabled)
            }
        }
        .navigationTitle("Licenses")
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                MessageView(app.status[.playback])
                MessageView(app.status[.history])
                if app.history.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing here yet").font(.headline)
                        Text("Speech you generate is saved here so you can play it again or save the WAV file.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(app.history) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text).lineLimit(3)
                        Text("\(record.modelName) · \(record.voice) · \(String(format: "%.1f", record.duration)) s · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if app.playingID == record.id {
                                Button("Stop") { app.stopPlayback() }
                            } else {
                                Button("Play") { app.play(record) }
                            }
                            Spacer()
                            if let url = app.audioURL(record) { ShareLink("Export WAV", item: url) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { app.delete(record) } }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !app.history.isEmpty {
                    Button("Clear all", role: .destructive) { app.clearHistory() }
                }
            }
        }
    }
}
