import Foundation
import SQCore

/// Named loudness targets of audio delivery (streaming services and broadcast). The numbers are the services'
/// published normalization levels; the true-peak ceiling is -1 dBTP for all of them (EBU R128 s1 and the streaming
/// recommendations agree on it).
public enum AudioDeliveryTarget: String, Sendable, Codable, CaseIterable, Identifiable {
    case spotify, appleMusic, youtube, ebuR128
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spotify: "Spotify (-14 LUFS)"
        case .appleMusic: "Apple Music (-16 LUFS)"
        case .youtube: "YouTube (-14 LUFS)"
        case .ebuR128: "EBU R128 (-23 LUFS)"
        }
    }

    public var targetLUFS: Double {
        switch self { case .spotify, .youtube: -14; case .appleMusic: -16; case .ebuR128: -23 }
    }

    public var truePeakCeilingDB: Double { -1 }

    /// Allowed deviation of the integrated loudness. EBU R128 is +/-0.5 LU; the streaming services normalize
    /// themselves, so the pre-flight keeps its general +/-1 LU there.
    public var toleranceLU: Double { self == .ebuR128 ? 0.5 : AudioPreflight.loudnessToleranceLU }

    public var normalization: LoudnessNormalization {
        LoudnessNormalization(targetLUFS: targetLUFS, truePeakCeilingDB: truePeakCeilingDB)
    }

    /// The named target a normalization setting matches (same LUFS and ceiling), nil for a custom value.
    public static func matching(_ n: LoudnessNormalization) -> AudioDeliveryTarget? {
        allCases.first { $0.targetLUFS == n.targetLUFS && $0.truePeakCeilingDB == n.truePeakCeilingDB }
    }

    /// Loudness range (EBU Tech 3342) needs a program of at least this long to mean anything.
    public static let minimumLoudnessRangeSeconds = 60.0

    /// Whether the Loudness Range readout is offered for a program of this length (greyed out under 60 s).
    public static func loudnessRangeAvailable(durationSeconds: Double) -> Bool {
        durationSeconds >= minimumLoudnessRangeSeconds
    }
}
