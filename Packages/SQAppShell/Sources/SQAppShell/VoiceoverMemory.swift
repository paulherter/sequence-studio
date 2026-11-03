import Foundation
import SQCore

/// Last voice and rate used.
public enum VoiceoverMemory {
    private static let voiceKey = "sq.voiceover.voice", rateKey = "sq.voiceover.rate"
    public static func voice(_ d: UserDefaults = .standard) -> String? { d.string(forKey: voiceKey) }
    public static func rate(_ d: UserDefaults = .standard) -> Double {
        d.object(forKey: rateKey) == nil ? Voiceover.defaultRate : Voiceover.clampedRate(d.double(forKey: rateKey))
    }
    public static func remember(voice: String, rate: Double, _ d: UserDefaults = .standard) {
        d.set(voice, forKey: voiceKey); d.set(Voiceover.clampedRate(rate), forKey: rateKey)
    }
}
