import Foundation

struct GenerationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let voiceID: String
    let voiceName: String
    let modelName: String
    let speed: Double
    let duration: TimeInterval
    let createdAt: Date
    let fileName: String
}

/// Persists recent generations as a JSON index plus one WAV file per entry.
struct GenerationHistory {
    let directory: URL
    let limit: Int
    private(set) var records: [GenerationRecord] = []

    private var indexURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL, limit: Int = 25) {
        self.directory = directory
        self.limit = max(1, limit)
        load()
    }

    func audioURL(for record: GenerationRecord) -> URL {
        directory.appendingPathComponent(record.fileName)
    }

    /// Newest-first. Entries whose audio file has disappeared are dropped.
    mutating func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([GenerationRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.filter { FileManager.default.fileExists(atPath: audioURL(for: $0).path) }
    }

    @discardableResult
    mutating func add(text: String, voiceID: String, voiceName: String, modelName: String,
                      speed: Double, duration: TimeInterval, wavData: Data, date: Date = Date()) throws -> GenerationRecord {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let record = GenerationRecord(id: id, text: text, voiceID: voiceID, voiceName: voiceName, modelName: modelName,
                                      speed: speed, duration: duration, createdAt: date, fileName: "\(id.uuidString).wav")
        try wavData.write(to: audioURL(for: record), options: .atomic)
        records.insert(record, at: 0)
        while records.count > limit {
            removeFile(of: records.removeLast())
        }
        try save()
        return record
    }

    mutating func remove(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        removeFile(of: records.remove(at: index))
        try save()
    }

    mutating func removeAll() throws {
        records.forEach(removeFile(of:))
        records = []
        try save()
    }

    private func removeFile(of record: GenerationRecord) {
        try? FileManager.default.removeItem(at: audioURL(for: record))
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
    }
}
