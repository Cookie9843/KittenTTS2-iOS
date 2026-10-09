import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Streaming SHA-256 used to verify downloaded model files. Uses CryptoKit where available (Apple platforms) and
/// falls back to a portable implementation elsewhere; `PortableSHA256` is always compiled so tests can check it.
public struct SHA256Hasher {
    #if canImport(CryptoKit)
    private var inner = SHA256()
    #else
    private var inner = PortableSHA256()
    #endif

    public init() {}

    public mutating func update(_ data: Data) {
        #if canImport(CryptoKit)
        inner.update(data: data)
        #else
        inner.update(data)
        #endif
    }

    public mutating func finalizeHex() -> String {
        #if canImport(CryptoKit)
        return inner.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return inner.finalizeHex()
        #endif
    }

    /// Hashes a file in `chunkSize` pieces (never loads the whole file). `isCancelled` is polled between chunks.
    public static func hashFile(at url: URL, chunkSize: Int = 4 << 20, progress: ((Int64) -> Void)? = nil,
                                isCancelled: () -> Bool = { false }) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        var done: Int64 = 0
        while true {
            if isCancelled() { return nil }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return hasher.finalizeHex()
    }
}

/// Dependency-free SHA-256 (FIPS 180-4).
public struct PortableSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    public init() { buffer.reserveCapacity(64) }

    public mutating func update(_ data: Data) {
        length += UInt64(data.count)
        var bytes = [UInt8](data)
        if !buffer.isEmpty {
            let need = 64 - buffer.count
            let take = min(need, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            bytes.removeFirst(take)
            if buffer.count == 64 { process(buffer, 0); buffer.removeAll(keepingCapacity: true) }
        }
        var offset = 0
        while bytes.count - offset >= 64 { process(bytes, offset); offset += 64 }
        if offset < bytes.count { buffer.append(contentsOf: bytes[offset...]) }
    }

    public mutating func finalizeHex() -> String {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        var offset = 0
        while offset < tail.count { process(tail, offset); offset += 64 }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func process(_ block: [UInt8], _ offset: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
}
