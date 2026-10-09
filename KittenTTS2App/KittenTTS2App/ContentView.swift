import KittenCore
import KittenTTS
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            SynthesizeView().tabItem { Label("Speak", systemImage: "waveform") }
            ModelsView().tabItem { Label("Models", systemImage: "shippingbox") }
            HistoryView().tabItem { Label("History", systemImage: "clock") }
        }
    }
}

struct FamilyPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Model family", selection: $model.family) {
            ForEach(ModelFamily.allCases) { Text($0.displayName).tag($0) }
        }
        Text(model.family.summary).font(.footnote).foregroundStyle(.secondary)
    }
}

struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .importing(let p): ProgressView("Importing…", value: p)
        case .downloading(let p): ProgressView("Downloading…", value: p)
        case .loading: ProgressView("Loading model…")
        case .generating: ProgressView("Generating speech…")
        }
        if let message = model.message {
            Text(message).font(.footnote).foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
        }
    }
}

struct SynthesizeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Model family") { FamilyPicker() }
                if let blocker = model.family.runtimeBlocker {
                    Section("KittenTTS 2 on iOS") {
                        Text(blocker).font(.footnote)
                    }
                } else {
                    Section("Model") {
                        Picker("Variant", selection: $model.legacyVariant) {
                            ForEach(LegacyVariant.allCases) { Text($0.displayName + (model.isInstalled($0) ? " ✓" : "")).tag($0) }
                        }
                        Picker("Voice", selection: $model.voice) {
                            ForEach(KittenVoice.allCases) { Text($0.displayName).tag($0) }
                        }
                        HStack {
                            Text("Speed")
                            Slider(value: $model.speed, in: 0.5...2.0, step: 0.1)
                            Text(String(format: "%.1f×", model.speed)).monospacedDigit()
                        }
                    }
                }
                Section("Text") {
                    TextEditor(text: $model.text).frame(minHeight: 120)
                }
                Section {
                    Button("Generate speech") { model.generate() }
                        .disabled(model.family != .legacy08 || model.busy || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    StatusView()
                }
            }
            .navigationTitle("KittenTTS")
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Model family") { FamilyPicker() }
                Section("Expected files") {
                    Text(model.family.expectedFilesDescription).font(.footnote)
                }
                if model.family == .legacy08 {
                    Section("Variant") {
                        Picker("Variant", selection: $model.legacyVariant) {
                            ForEach(LegacyVariant.allCases) { Text($0.displayName).tag($0) }
                        }
                        Text(model.isInstalled(model.legacyVariant) ? "Installed" : "Not installed").font(.footnote)
                        Button("Download from Hugging Face (\(model.legacyVariant.huggingFaceRepo))") { model.downloadLegacy() }
                            .disabled(model.busy)
                    }
                } else {
                    Section("Installed files") {
                        let files = model.kitten2Files()
                        Text(files.isEmpty ? "None" : files.joined(separator: ", ")).font(.footnote)
                        Text("KittenTTS 2 cannot synthesize on iOS yet (see Speak tab). There is no download button: official assets are large (≥1 GB), so import a file you already have.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Import from Files") {
                    Button("Choose file(s)…") { picking = true }.disabled(model.busy)
                    if case .importing = model.phase {
                        Button("Cancel import", role: .destructive) { model.cancelCurrentImport() }
                    }
                    StatusView()
                }
            }
            .navigationTitle("Models")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importFiles(urls)
                case .failure(let error): model.show("Could not open files: \(error.localizedDescription)", error: true)
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.history.isEmpty { Text("No generated audio yet.").foregroundStyle(.secondary) }
                ForEach(model.history) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text).lineLimit(3)
                        Text("\(record.modelName) · \(record.voice) · \(String(format: "%.1f", record.duration)) s · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if model.playingID == record.id {
                                Button("Stop") { model.stopPlayback() }
                            } else {
                                Button("Play") { model.play(record) }
                            }
                            Spacer()
                            if let url = model.audioURL(record) { ShareLink("Export WAV", item: url) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { model.delete(record) } }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !model.history.isEmpty {
                    Button("Clear", role: .destructive) { model.clearHistory() }
                }
            }
        }
    }
}
