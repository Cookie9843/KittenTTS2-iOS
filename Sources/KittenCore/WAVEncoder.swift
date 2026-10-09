import Foundation

public enum WAVEncoder {
    /// Encodes mono Float samples (−1…1) as 16-bit PCM WAV.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample.isNaN ? 0 : sample))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
