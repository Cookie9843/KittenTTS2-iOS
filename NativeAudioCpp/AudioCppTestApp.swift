import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// audio.cpp KittenTTS 2 single-GGUF test app.
// Calls the real audio.cpp native CPU runtime (pinned, linked statically). Nothing here fakes audio:
// if loading or synthesis fails the full native error text is shown and copied into the diagnostics.

@main
struct AudioCppTestApp: App {
    var body: some Scene { WindowGroup { TestView() } }
}

// MARK: - diagnostics model
// All @Published state is only touched on the main thread; native calls run on one serial queue.

enum Step: String { case idle = "not attempted", running = "running", ok = "OK", failed = "FAILED" }

final class TestModel: ObservableObject {
    static let voices = ["Bruno", "Bella", "Luna", "Jasper", "Kiki", "Leo", "Rosie", "Hugo", "German", "French", "Spanish", "Italian", "Portuguese", "Russian", "Chinese", "Arabic", "Hindi"]
    static let breadcrumbKey = "kt.lastStage"

    @Published var fileName = "(none)"
    @Published var fileSize: Int64 = 0
    @Published var report: AudioCppGGUFReport?
    @Published var validation: AudioCppValidation?
    @Published var inspectError: String?
    @Published var verdict: ResourceVerdict?
    @Published var snapshot: ResourceSnapshot?
    @Published var sha: String = "not computed"
    @Published var shaProgress: Double?
    @Published var loadStep = Step.idle
    @Published var loadElapsed: Double?
    @Published var loadDescribe = ""
    @Published var loadError = ""
    @Published var synthStep = Step.idle
    @Published var synthElapsed: Double?
    @Published var synthError = ""
    @Published var synthDetail = ""
    @Published var audioURL: URL?
    @Published var text = "Hello there. This is native Kitten speech running on this device."
    @Published var voice = "Bruno"
    @Published var threads = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 6)
    @Published var seed = 1234
    @Published var previousRun = ""
    @Published var stderrTail = ""
    @Published var previousStderr = ""
    @Published var loadAttempted = false
    @Published var cancelNote = ""
    @Published var busy = false

    private let queue = DispatchQueue(label: "kt.native", qos: .userInitiated)
    private var url: URL?
    private var scoped = false
    private var engine: OpaquePointer?
    private var cancelRequested = false
    private var player: AVAudioPlayer?
    private let stderrPath = NSTemporaryDirectory() + "kt-native-stderr.log"
    let runtimeInfo: String

    init() {
        var buf = [CChar](repeating: 0, count: 256)
        _ = kt_runtime_info(&buf, buf.count)
        runtimeInfo = String(cString: buf)
        let oldLog = Self.tail(of: stderrPath)
        if let note = AudioCppDiagnostics.previousRunNote(stage: UserDefaults.standard.string(forKey: Self.breadcrumbKey), nativeLog: oldLog) {
            previousRun = note
            previousStderr = oldLog
        }
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        // Truncates the log file: stderrTail only ever holds output of THIS run.
        _ = kt_redirect_stderr(stderrPath)
        kt_install_abort_hook()
    }

    // MARK: file selection + validation

    /// A new attempt discards the previous run's stage note and native log so they cannot be mistaken for it.
    private func startNewAttempt() {
        previousRun = ""; previousStderr = ""; stderrTail = ""; loadAttempted = false
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey)
        _ = kt_redirect_stderr(stderrPath)
    }

    func select(_ picked: URL) {
        releaseFile()
        unload()
        startNewAttempt()
        scoped = picked.startAccessingSecurityScopedResource()
        url = picked
        fileName = picked.lastPathComponent
        report = nil; validation = nil; inspectError = nil; verdict = nil
        sha = "not computed"; loadStep = .idle; synthStep = .idle; audioURL = nil
        loadError = ""; synthError = ""; loadElapsed = nil; synthElapsed = nil; synthDetail = ""
        fileSize = ((try? FileManager.default.attributesOfItem(atPath: picked.path)[.size]) as? NSNumber)?.int64Value ?? 0
        busy = true
        queue.async { [weak self] in
            let result = Result { try AudioCppGGUFInspector.inspect(url: picked) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let r):
                    self.report = r
                    self.validation = AudioCppGGUFInspector.validate(r)
                    self.refreshResources()
                case .failure(let e):
                    self.inspectError = "\(e)"
                }
            }
        }
    }

    private func releaseFile() {
        if scoped, let url { url.stopAccessingSecurityScopedResource() }
        scoped = false
    }

    func refreshResources() {
        guard let report else { return }
        let free = (try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let avail = kt_available_memory()
        let snap = ResourceSnapshot(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                    availableMemory: avail > 0 ? avail : nil, freeStorage: free)
        snapshot = snap
        verdict = ResourceAdvisor.assess(report: report, snapshot: snap)
    }

    var canLoad: Bool {
        validation?.passed == true && verdict?.canProceed == true && engine == nil && !busy
    }

    // MARK: optional SHA-256 (3.28 GB read; cancellable)

    private var shaTask: Task<Void, Never>?

    func computeSHA() {
        guard let url, shaTask == nil else { return }
        shaProgress = 0
        sha = "computing…"
        let total = max(fileSize, 1)
        shaTask = Task.detached(priority: .utility) { [weak self] in
            var result = "cancelled"
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                var hasher = SHA256()
                var done: Int64 = 0
                var lastUI: Int64 = 0
                while !Task.isCancelled, let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    done += Int64(chunk.count)
                    if done - lastUI > (64 << 20) {
                        lastUI = done
                        let p = Double(done) / Double(total)
                        await MainActor.run { self?.shaProgress = p }
                    }
                }
                if !Task.isCancelled {
                    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    result = hex == AudioCppPackage.publishedSHA256
                        ? "\(hex) MATCHES the published SHA-256"
                        : "\(hex) does NOT match the published \(AudioCppPackage.publishedSHA256)"
                }
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            let final = result
            await MainActor.run { self?.sha = final; self?.shaProgress = nil; self?.shaTask = nil }
        }
    }

    func cancelSHA() { shaTask?.cancel() }

    // MARK: native load / synthesize / unload

    private func crumb(_ stage: String?) {
        if let stage { UserDefaults.standard.set("\(stage) (\(ISO8601DateFormatter().string(from: Date())))", forKey: Self.breadcrumbKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.breadcrumbKey) }
        UserDefaults.standard.synchronize()
    }

    func load() {
        guard let url, canLoad else { return }
        refreshResources()
        guard verdict?.canProceed == true else { return }
        busy = true
        loadStep = .running; loadError = ""; loadDescribe = ""; loadElapsed = nil
        loadAttempted = true
        stderrTail = ""
        _ = kt_redirect_stderr(stderrPath)
        let threads = self.threads
        crumb("native model load")
        queue.async { [weak self] in
            let start = Date()
            var describe = [CChar](repeating: 0, count: 1024)
            var err = [CChar](repeating: 0, count: 8192)
            var handle: OpaquePointer?
            var rc: Int32 = -1
            url.path.withCString { rc = kt_load($0, Int32(threads), &handle, &describe, describe.count, &err, err.count) }
            let elapsed = Date().timeIntervalSince(start)
            let describeText = String(cString: describe), errText = String(cString: err)
            DispatchQueue.main.async {
                guard let self else { return }
                self.crumb(nil)
                self.loadElapsed = elapsed
                self.busy = false
                if rc == 0, let handle {
                    self.engine = handle
                    self.loadStep = .ok
                    self.loadDescribe = describeText
                } else {
                    self.loadStep = .failed
                    self.loadError = "exit code \(rc)\n" + errText
                }
                self.stderrTail = Self.tail(of: self.stderrPath)
                self.refreshResources()
            }
        }
    }

    func synthesize() {
        guard let engine, !busy else { return }
        busy = true; cancelRequested = false; cancelNote = ""
        synthStep = .running; synthError = ""; synthDetail = ""; synthElapsed = nil; audioURL = nil
        let text = self.text, voice = self.voice, seed = Int64(self.seed)
        crumb("native synthesis")
        queue.async { [weak self] in
            let start = Date()
            var audio = kt_audio()
            var err = [CChar](repeating: 0, count: 8192)
            let rc = text.withCString { t in voice.withCString { v in kt_synthesize(engine, t, v, seed, &audio, &err, err.count) } }
            let elapsed = Date().timeIntervalSince(start)
            var samples: [Float] = []
            if rc == 0, let p = audio.samples {
                let ch = Int(audio.channels)
                let raw = UnsafeBufferPointer(start: p, count: audio.frames * ch)
                samples = ch == 1 ? Array(raw) : (0..<audio.frames).map { i in (0..<ch).reduce(Float(0)) { $0 + raw[i * ch + $1] } / Float(ch) }
            }
            let rate = Int(audio.sample_rate), channels = Int(audio.channels)
            kt_audio_free(&audio)
            let errText = String(cString: err)
            DispatchQueue.main.async {
                guard let self else { return }
                self.crumb(nil)
                self.synthElapsed = elapsed
                self.busy = false
                self.stderrTail = Self.tail(of: self.stderrPath)
                if self.cancelRequested {
                    self.synthStep = .idle
                    self.cancelNote = "Cancelled: the native call cannot be interrupted, so it ran to completion (\(String(format: "%.1f", elapsed)) s) and its result was discarded."
                    return
                }
                guard rc == 0, !samples.isEmpty else {
                    self.synthStep = .failed
                    self.synthError = "exit code \(rc)\n" + errText
                    return
                }
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
                let seconds = Double(samples.count) / Double(rate)
                self.synthDetail = String(format: "samples=%d, sample_rate=%d Hz, channels(native)=%d, duration=%.2f s, peak=%.4f, rms=%.4f, real-time factor=%.2fx",
                                          samples.count, rate, channels, seconds, peak, rms, elapsed / max(seconds, 0.001))
                if peak < 1e-4 {
                    self.synthStep = .failed
                    self.synthError = "Native synthesis returned audio, but it is silent (peak \(peak)). Not counted as success."
                    return
                }
                let wav = WAVEncoder.encode(samples: samples, sampleRate: rate)
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitten-audiocpp-\(voice).wav")
                do {
                    try wav.write(to: out)
                    self.audioURL = out
                    self.synthStep = .ok
                } catch {
                    self.synthStep = .failed
                    self.synthError = "Could not write WAV: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() {
        cancelRequested = true
        cancelNote = "Cancel requested. The native call can't be interrupted; the result will be discarded when it finishes."
        shaTask?.cancel()
    }

    func unload() {
        guard let e = engine else { return }
        engine = nil
        loadStep = .idle
        queue.async { kt_unload(e) }
    }

    func play() {
        guard let audioURL else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: audioURL)
        player?.play()
    }

    // MARK: diagnostics

    static func tail(of path: String, bytes: Int = 6000) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    var summary: String {
        let meta: String
        if let v = validation { meta = v.passed ? "PASS" : "FAIL" } else if inspectError != nil { meta = "FAIL" } else { meta = "not run" }
        let audio = synthStep == .ok ? "YES (real audio generated by audio.cpp on this device)" : "NO"
        let banner = AudioCppDiagnostics.attemptBanner(fileName: url == nil ? nil : fileName, validationRan: validation != nil || inspectError != nil, loadAttempted: loadAttempted)
        return "\(banner)\nMETADATA VALIDATION: \(meta)\nNATIVE RUNTIME LINKED: yes (\(runtimeInfo))\nNATIVE MODEL LOAD: \(loadStep.rawValue)\nAUDIO GENERATED: \(audio)"
    }

    var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var machine = [CChar](repeating: 0, count: 64)
        var len = machine.count
        sysctlbyname("hw.machine", &machine, &len, nil, 0)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "other"
        #endif
        let fmt = { (b: Int64) in "\(b) bytes (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)))" }
        var l: [String] = []
        l.append("== KittenTTS 2 audio.cpp single-GGUF test ==")
        l.append(summary)
        l.append("")
        l.append("-- app / runtime --")
        l.append("app: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        l.append("audio.cpp source: dignome/audio.cpp-custom @ \(info["KTAudioCppRevision"] ?? "unknown"), AUDIOCPP_MODELS=kitten_tts2, CPU only")
        l.append("runtime: \(runtimeInfo)")
        l.append("architecture: \(arch); device: \(String(cString: machine)); OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        l.append("physical memory: \(fmt(Int64(ProcessInfo.processInfo.physicalMemory)))")
        if let s = snapshot {
            l.append("available to app (os_proc_available_memory): \(s.availableMemory.map { fmt(Int64($0)) } ?? "unknown")")
            l.append("free temp storage: \(s.freeStorage.map(fmt) ?? "unknown")")
        }
        l.append("")
        l.append("-- model file --")
        l.append("filename: \(fileName)")
        l.append("size: \(fmt(fileSize)); published: \(AudioCppPackage.publishedSize) bytes")
        l.append("sha256: \(sha)")
        if let e = inspectError { l.append("GGUF read error: \(e)") }
        if let r = report {
            l.append("GGUF version: \(r.version); metadata keys: \(r.kvCount); tensors: \(r.tensorCount)")
            l.append("general.architecture: \(r.architecture ?? "-"); general.name: \(r.modelName ?? "-")")
            l.append("audiocpp.model_spec.family: \(r.specFamily ?? "-"); weight_type: \(r.weightType ?? "-"); source_format: \(r.sourceFormat ?? "-"); tensor_name_format: \(r.tensorNameFormat ?? "-")")
            l.append("quantization (tensor types): \(r.tensorTypeSummary)")
            l.append("TQ2_1 tensors: none expected for this package (general.file_type: \(r.fileType.map(String.init) ?? "absent"))")
            l.append("embedded files (\(r.embeddedFileNames.count), \(r.embeddedDataBytes) bytes): \(r.embeddedFileNames.joined(separator: ", "))")
        }
        if let v = validation {
            l.append("")
            l.append("-- validation: \(v.passed ? "PASS" : "FAIL") --")
            for c in v.checks { l.append("[\(c.status.rawValue)] \(c.name): \(c.detail)") }
            if let g = v.guidance { l.append("ACTION: \(g)") }
        }
        if let v = verdict {
            l.append("")
            l.append("-- resource check --")
            l.append(v.canProceed ? "proceed allowed" : "REFUSED")
            v.refusals.forEach { l.append("REFUSE: \($0)") }
            v.warnings.forEach { l.append("WARN: \($0)") }
        }
        l.append("")
        l.append("-- native load --")
        l.append("status: \(loadStep.rawValue); elapsed: \(loadElapsed.map { String(format: "%.2f s", $0) } ?? "-"); threads: \(threads)")
        if !loadDescribe.isEmpty { l.append(loadDescribe) }
        if !loadError.isEmpty { l.append("error: \(loadError)") }
        l.append("")
        l.append("-- inference --")
        l.append("status: \(synthStep.rawValue); voice: \(voice); seed: \(seed); text chars: \(text.count); elapsed: \(synthElapsed.map { String(format: "%.2f s", $0) } ?? "-")")
        if !synthDetail.isEmpty { l.append("output: \(synthDetail)") }
        if !synthError.isEmpty { l.append("error: \(synthError)") }
        if !cancelNote.isEmpty { l.append(cancelNote) }
        if !previousRun.isEmpty {
            l.append(""); l.append("-- PREVIOUS RUN (not the current attempt) --"); l.append(previousRun)
            if !previousStderr.isEmpty { l.append("-- previous run native stderr (tail) --"); l.append(previousStderr) }
        }
        l.append(""); l.append("-- native stderr of THIS run (tail) --")
        l.append(stderrTail.isEmpty ? "(empty)" : stderrTail)
        return l.joined(separator: "\n")
    }
}

// MARK: - UI

struct TestView: View {
    @StateObject private var m = TestModel()
    @State private var importing = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tests the audio.cpp KittenTTS 2 runtime with one user-supplied GGUF: kitten-tts2-native-q8-multilingual.gguf (dignome/kitten_tts2). It is NOT for KittenML's model-tq2_1.gguf. The model is never bundled or downloaded.")
                        .font(.footnote).foregroundColor(.secondary)
                    Text(m.summary).font(.system(.footnote, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.12)).cornerRadius(8)
                    if !m.previousRun.isEmpty { Text(m.previousRun).font(.footnote).foregroundColor(.orange) }

                    Text("File: \(m.fileName)")
                    Button("Choose GGUF…") { importing = true }.buttonStyle(.borderedProminent).disabled(m.busy)
                    if let g = m.validation?.guidance { Text(g).foregroundColor(.red).font(.footnote) }
                    if let e = m.inspectError { Text(e).foregroundColor(.red).font(.footnote) }
                    if let v = m.verdict {
                        ForEach(v.refusals, id: \.self) { Text("Refused: \($0)").foregroundColor(.red).font(.footnote) }
                        ForEach(v.warnings, id: \.self) { Text("Warning: \($0)").foregroundColor(.orange).font(.footnote) }
                    }

                    GroupBox("1. Verify checksum (optional, reads 3.28 GB)") {
                        HStack {
                            Button("SHA-256") { m.computeSHA() }.disabled(m.report == nil || m.shaProgress != nil)
                            if let p = m.shaProgress { ProgressView(value: p); Button("Stop") { m.cancelSHA() } }
                        }
                    }
                    GroupBox("2. Load model (native, may take a while)") {
                        HStack {
                            Stepper("Threads: \(m.threads)", value: $m.threads, in: 1...12)
                            Button("Load") { m.load() }.disabled(!m.canLoad)
                            Button("Unload") { m.unload() }.disabled(m.loadStep != .ok || m.busy)
                        }
                    }
                    GroupBox("3. Synthesize") {
                        VStack(alignment: .leading) {
                            TextField("Text", text: $m.text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                            Picker("Voice", selection: $m.voice) { ForEach(TestModel.voices, id: \.self) { Text($0) } }
                            Stepper("Seed: \(m.seed)", value: $m.seed, in: 0...999_999)
                            HStack {
                                Button("Synthesize") { m.synthesize() }.buttonStyle(.borderedProminent).disabled(m.loadStep != .ok || m.busy)
                                Button("Cancel") { m.cancel() }.disabled(!m.busy)
                                if m.busy { ProgressView() }
                            }
                            if m.synthStep == .ok, let url = m.audioURL {
                                HStack {
                                    Button("Play") { m.play() }
                                    ShareLink("Export WAV", item: url)
                                }
                            }
                        }
                    }
                    GroupBox("Diagnostics (copy and send this)") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = m.diagnostics; copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false } }
                                ShareLink("Export", item: m.diagnostics)
                                Button("Refresh log") { m.stderrTail = TestModel.tail(of: NSTemporaryDirectory() + "kt-native-stderr.log") }
                            }
                            Text(m.diagnostics).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Text("Licenses: the model is under the Stellon Labs Community License (see the LICENSE/NOTICE in dignome/kitten_tts2 and inside the GGUF); audio.cpp, ggml and Chatterbox S3 components keep their own licenses. See THIRD_PARTY_NOTICES in this app's repository.")
                        .font(.caption2).foregroundColor(.secondary)
                }.padding()
            }
            .navigationTitle("KittenTTS2 audio.cpp test")
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let u): m.select(u)
            case .failure(let e): m.inspectError = "File picker error: \(e.localizedDescription)"
            }
        }
    }
}
