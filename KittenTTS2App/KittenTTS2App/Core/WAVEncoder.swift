import Foundation

enum WAVEncoder {
    /// Encodes mono Float32 samples in [-1, 1] as 16-bit PCM WAV.
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerSample))
        append16(UInt16(bytesPerSample))
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))

        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            append16(UInt16(bitPattern: Int16(clamped * Float(Int16.max))))
        }
        return data
    }
}
