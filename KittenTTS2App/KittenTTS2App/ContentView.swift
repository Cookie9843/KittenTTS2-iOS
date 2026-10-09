import SwiftUI

struct ContentView: View {
    @State private var modelPath: String = "~/Documents/KittenTTS2"
    @State private var selectedVoice: String = "default"
    @State private var statusText: String = "Ready"

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    TextField("Model directory", text: $modelPath)
                    Button("Choose model folder") {
                        statusText = "Model selection is a future step for the full port."
                    }
                }

                Section("Voice") {
                    Picker("Voice", selection: $selectedVoice) {
                        Text("Default").tag("default")
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Status") {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("KittenTTS 2")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Generate") {
                        statusText = "Local inference pipeline is not implemented yet."
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
