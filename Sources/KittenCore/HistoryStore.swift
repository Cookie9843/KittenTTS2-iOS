import Foundation

public struct GenerationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var family: ModelFamily
    public var modelName: String
    public var voice: String
    public var speed: Float
    public var duration: TimeInterval
    public var audioFileName: String
}

public final class HistoryStore {
    public let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    public private(set) var records: [GenerationRecord] = []

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = (try? decoder.decode([GenerationRecord].self, from: data)) ?? []
        }
    }

    public func audioURL(for record: GenerationRecord) -> URL {
        directory.appendingPathComponent(record.audioFileName)
    }

    @discardableResult
    public func add(samples: [Float], sampleRate: Int, text: String, family: ModelFamily, modelName: String, voice: String, speed: Float, date: Date = Date()) throws -> GenerationRecord {
        let id = UUID()
        let record = GenerationRecord(id: id, date: date, text: text, family: family, modelName: modelName, voice: voice, speed: speed,
                                      duration: Double(samples.count) / Double(sampleRate), audioFileName: "\(id.uuidString).wav")
        try WAVEncoder.encode(samples: samples, sampleRate: sampleRate).write(to: audioURL(for: record), options: .atomic)
        records.insert(record, at: 0)
        try save()
        return record
    }

    public func delete(_ record: GenerationRecord) throws {
        try? FileManager.default.removeItem(at: audioURL(for: record))
        records.removeAll { $0.id == record.id }
        try save()
    }

    public func clear() throws {
        for record in records { try? FileManager.default.removeItem(at: audioURL(for: record)) }
        records = []
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: indexURL, options: .atomic)
    }
}
