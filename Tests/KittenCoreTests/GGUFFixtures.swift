import Foundation
@testable import KittenCore

/// Small synthetic audio.cpp GGUF headers (no model data) shared by importer tests.
struct GGUFFixtures {
    func le(_ v: UInt64, _ w: Int) -> [UInt8] { (0..<w).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    func str(_ s: String) -> [UInt8] { le(UInt64(s.utf8.count), 8) + Array(s.utf8) }
    func kvString(_ k: String, _ v: String) -> [UInt8] { str(k) + le(8, 4) + str(v) }
    func kvU32(_ k: String, _ v: UInt32) -> [UInt8] { str(k) + le(4, 4) + le(UInt64(v), 4) }
    func kvStringArray(_ k: String, _ v: [String]) -> [UInt8] {
        str(k) + le(9, 4) + le(8, 4) + le(UInt64(v.count), 8) + v.flatMap { str($0) }
    }
    func kvBytes(_ k: String, count: Int) -> [UInt8] {
        str(k) + le(9, 4) + le(0, 4) + le(UInt64(count), 8) + [UInt8](repeating: 7, count: count)
    }
    func tensor(_ name: String, type: UInt32) -> [UInt8] {
        str(name) + le(2, 4) + le(8, 8) + le(4, 8) + le(UInt64(type), 4) + le(0, 8)
    }

    func audiocppFixture(family: String = "kitten_tts2", weightType: String = "q8_0", tensorTypes: [UInt32] = [8, 8, 1, 0],
                         embedded: [String] = AudioCppPackage.expectedEmbeddedFiles, arch: String = "audiocpp") -> Data {
        var kv: [UInt8] = []
        kv += kvString("general.architecture", arch)
        kv += kvString("general.name", "kitten-tts2")
        kv += kvString("audiocpp.tensor_name_format", "native")
        kv += kvString("audiocpp.source_format", "safetensors")
        kv += kvString("audiocpp.weight_type", weightType)
        kv += kvU32("audiocpp.model_spec.version", 1)
        kv += kvString("audiocpp.model_spec.family", family)
        kv += kvString("audiocpp.model_spec.json", "{\"family\":\"\(family)\"}")
        kv += kvStringArray("audiocpp.tensor_sources.names", ["language_model", "s3gen"])
        kv += kvStringArray("audiocpp.tensor_names", tensorTypes.indices.map { "t\($0)" })
        if !embedded.isEmpty {
            kv += kvStringArray("audiocpp.embedded_files.names", embedded)
            kv += kvBytes("audiocpp.embedded_files.data", count: 1000)
        }
        let kvCount: UInt64 = embedded.isEmpty ? 10 : 12
        var b: [UInt8] = Array("GGUF".utf8) + le(3, 4) + le(UInt64(tensorTypes.count), 8) + le(kvCount, 8) + kv
        for (i, t) in tensorTypes.enumerated() { b += tensor("t\(i)", type: t) }
        return Data(b)
    }
}
