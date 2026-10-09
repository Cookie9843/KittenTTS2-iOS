import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: SpeechViewModel
    @State private var showImporter = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                textSection
                voiceSection
                generateSection
                if let record = model.currentRecord {
                    playerSection(record)
                }
                historySection
            }
            .navigationTitle("KittenTTS 2")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importModelFiles(from: urls)
                case .failure(let error): model.importMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $model.variant) {
                ForEach(ModelVariant.allCases) { variant in
                    Text("\(variant.displayName) (~\(variant.approximateDownloadMB) MB)").tag(variant)
                }
            }

            modelStatusRow

            switch model.modelState {
            case .preparing: EmptyView()
            case .ready: EmptyView()
            default:
                Button {
                    model.prepareModel()
                } label: {
                    Label(model.modelState == .notInstalled ? "Download and load model" : "Load model",
                          systemImage: model.modelState == .notInstalled ? "arrow.down.circle" : "play.circle")
                }
                .accessibilityHint(model.modelState == .notInstalled
                                   ? "Downloads the model from Hugging Face once, then runs it offline."
                                   : "Loads the installed model into memory.")
            }

            Button {
                showImporter = true
            } label: {
                Label("Import model files…", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint("Choose the model .onnx file and voices.npz together for the selected model.")

            if model.usingImportedFiles {
                Button(role: .destructive) {
                    model.removeImportedFiles()
                } label: {
                    Label("Remove imported files", systemImage: "trash")
                }
            }

            if let message = model.importMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Speech is generated on this device with ONNX Runtime. The first load needs internet to fetch the model (unless you import it) and the English phonemizer data; after that it works offline.")
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        switch model.modelState {
        case .notInstalled:
            Label("Model not installed", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        case .installed:
            Label(model.usingImportedFiles ? "Imported files validated — not loaded" : "Downloaded files validated — not loaded",
                  systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .preparing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.map { $0 < 1 ? "Downloading / loading… \(Int($0 * 100))%" : "Loading model…" } ?? "Preparing…")
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .accessibilityElement(children: .combine)
        case .ready:
            Label(model.usingImportedFiles ? "Ready (imported files)" : "Ready", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    // MARK: Text & voice

    private var textSection: some View {
        Section {
            TextEditor(text: $model.inputText)
                .frame(minHeight: 120)
                .accessibilityLabel("Text to speak")
            Text("\(model.inputText.count) / \(TextInput.maxCharacters) characters")
                .font(.footnote)
                .foregroundStyle(model.inputText.count > TextInput.maxCharacters ? .red : .secondary)
        } header: {
            Text("Text")
        }
    }

    private var voiceSection: some View {
        Section {
            if model.availableVoices.isEmpty {
                Text("Voices appear once a valid model is installed.").foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: $model.selectedVoiceID) {
                    ForEach(model.availableVoices) { voice in
                        Text("\(voice.displayName) (\(voice.isFemale ? "female" : "male"))").tag(voice.id)
                    }
                }
            }
            VStack(alignment: .leading) {
                Text("Speed: \(model.speed, specifier: "%.1f")×")
                Slider(value: $model.speed, in: 0.5...2.0, step: 0.1)
                    .accessibilityLabel("Speech speed")
                    .accessibilityValue(String(format: "%.1f times", model.speed))
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Only voices contained in the model's voices.npz that the KittenTTS SDK supports are listed.")
        }
    }

    // MARK: Generate

    private var generateSection: some View {
        Section {
            switch model.generationState {
            case .generating(let done):
                HStack {
                    ProgressView()
                    Text(done == 0 ? "Generating…" : "Generated \(done) sentence\(done == 1 ? "" : "s")…")
                }
                .accessibilityElement(children: .combine)
                Button(role: .cancel) {
                    model.cancelGeneration()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            default:
                Button {
                    model.generate()
                } label: {
                    Label("Generate speech", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canGenerate)
                .accessibilityHint(model.canGenerate ? "Creates audio from the text on this device." : "Load a model first.")
            }

            if case .failed(let message) = model.generationState {
                HStack(alignment: .top) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Player

    private func playerSection(_ record: GenerationRecord) -> some View {
        Section("Latest audio") {
            Text(record.text).lineLimit(3)
            Text("\(record.voiceName) · \(format(record.duration))").font(.footnote).foregroundStyle(.secondary)
            HStack {
                if model.playingRecordID == record.id {
                    Button { model.stopPlayback() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { model.play(record) } label: { Label("Play", systemImage: "play.fill") }
                }
                Spacer()
                ShareLink(item: model.audioURL(for: record)) {
                    Label("Share / Export", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            if model.history.isEmpty {
                Text("No recent generations yet.").foregroundStyle(.secondary)
            }
            ForEach(model.history) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.text).lineLimit(2)
                        Text("\(record.voiceName) · \(record.modelName) · \(format(record.duration)) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.playingRecordID == record.id ? model.stopPlayback() : model.play(record)
                    } label: {
                        Image(systemName: model.playingRecordID == record.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.playingRecordID == record.id ? "Stop" : "Play")
                    ShareLink(item: model.audioURL(for: record)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Share")
                }
                .swipeActions {
                    Button(role: .destructive) { model.delete(record) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if !model.history.isEmpty {
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Delete all recent generations?", isPresented: $confirmClear) {
                        Button("Delete all", role: .destructive) { model.clearHistory() }
                    }
            }
        } header: {
            Text("Recent generations")
        }
    }

    private func format(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }
}

#Preview {
    ContentView().environmentObject(SpeechViewModel())
}
