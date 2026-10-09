import SwiftUI
import UniformTypeIdentifiers

@main
struct NativeProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @State private var importing = false
    @State private var fileName = "(none)"
    @State private var report = "Pick a real KittenTTS 2 TQ2_1 GGUF (e.g. model-tq2_1.gguf)."
    @State private var url: URL?
    @State private var busy = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Native runtime load probe. This is NOT text-to-speech: the decoder.pt and text normalizer are not linked, no audio is generated, and there is no Generate action.")
                        .font(.footnote).foregroundColor(.orange)
                    Text("File: \(fileName)")
                    Button("Choose GGUF…") { importing = true }
                    HStack {
                        Button("1. Read header") { run { kp_read_header($0, $1, $2) } }
                        Button("2. Load model") { run { kp_load_model($0, $1, $2) } }
                    }
                    .disabled(url == nil || busy)
                    Text(report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("TQ2_1 load probe")
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let u) = result { url = u; fileName = u.lastPathComponent; report = "Selected \(u.lastPathComponent)." }
        }
    }

    private func run(_ fn: @escaping (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int) -> Int32) {
        guard let url else { return }
        busy = true
        report = "Running…"
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = url.path.withCString { fn($0, &buf, buf.count) }
            let text = "exit code \(rc)\n" + String(cString: buf)
            DispatchQueue.main.async { report = text; busy = false }
        }
    }
}
