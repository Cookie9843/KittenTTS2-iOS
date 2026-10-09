import Foundation

struct VoiceInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isFemale: Bool
}

/// Voices the KittenML SDK knows how to drive. A voice is only offered when the
/// model's `voices.npz` actually contains an embedding for it.
enum VoiceCatalog {
    static let known: [VoiceInfo] = [
        VoiceInfo(id: "expr-voice-2-f", displayName: "Bella", isFemale: true),
        VoiceInfo(id: "expr-voice-2-m", displayName: "Jasper", isFemale: false),
        VoiceInfo(id: "expr-voice-3-f", displayName: "Luna", isFemale: true),
        VoiceInfo(id: "expr-voice-3-m", displayName: "Bruno", isFemale: false),
        VoiceInfo(id: "expr-voice-4-f", displayName: "Rosie", isFemale: true),
        VoiceInfo(id: "expr-voice-4-m", displayName: "Hugo", isFemale: false),
        VoiceInfo(id: "expr-voice-5-f", displayName: "Kiki", isFemale: true),
        VoiceInfo(id: "expr-voice-5-m", displayName: "Leo", isFemale: false),
    ]

    static func available(in voiceIDs: [String]) -> [VoiceInfo] {
        let present = Set(voiceIDs)
        return known.filter { present.contains($0.id) }
    }
}
