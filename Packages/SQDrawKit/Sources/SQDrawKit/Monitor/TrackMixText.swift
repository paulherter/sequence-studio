import Foundation
import SQCore

/// Text and parse rules of the track Volume and Pan form (moved from the Mac `TrackMixDialog`): the fader level in dB
/// ("-inf" at the floor) and the pan as "L 30" / "Center" / "R 20" over -100...100.
public enum TrackMixText {
    /// "-6", "-6 dB", "-inf" -> dB; nil when it is not a level.
    public static func parse(volumeDB text: String) -> Double? {
        let t = text.lowercased().replacingOccurrences(of: "db", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-inf") || t.hasPrefix("-∞") { return TrackPan.minVolumeDB }
        return Double(t)
    }

    /// "L 30", "R 20", "center", "-30", "20" -> pan -100...100; nil when it is not a pan.
    public static func parse(pan text: String) -> Double? {
        let t = text.lowercased().replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if t == "center" || t == "centre" || t == "c" { return 0 }
        if t.hasPrefix("l"), let v = Double(t.dropFirst().trimmingCharacters(in: .whitespaces)) { return -abs(v) }
        if t.hasPrefix("r"), let v = Double(t.dropFirst().trimmingCharacters(in: .whitespaces)) { return abs(v) }
        return Double(t)
    }

    public static func text(volumeDB: Double) -> String {
        volumeDB <= TrackPan.minVolumeDB ? "-inf dB" : String(format: "%+.1f dB", volumeDB)
    }

    /// The number in the capsule: the unit "dB" sits after the capsule (dialog rule), so it is not part of the text.
    public static func capsuleText(volumeDB: Double) -> String {
        volumeDB <= TrackPan.minVolumeDB ? "-inf" : String(format: "%+.1f", volumeDB)
    }

    public static func text(pan: Double) -> String {
        let p = Int(pan.rounded())
        return p == 0 ? "Center" : (p < 0 ? "L \(-p)" : "R \(p)")
    }

}
