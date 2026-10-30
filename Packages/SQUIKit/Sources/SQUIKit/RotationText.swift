import Foundation

/// Rotation as Premiere shows it: whole turns plus degrees ("1x 30.0°") from 360° up, plain degrees below.
/// The stored value stays plain degrees (unbounded). Typing "1x30", "1x 30", "-1x30" or any plain number or sum works;
/// the sign of the turns applies to the whole angle ("-1x30" = -390°).
public enum RotationText {
    public static func format(_ degrees: Double) -> String {
        guard degrees.isFinite else { return "0.0\u{00B0}" }
        let rounded = (abs(degrees) * 10).rounded() / 10
        let sign = degrees < 0 && rounded > 0 ? "-" : ""
        let turns = (rounded / 360).rounded(.down)      // Double: huge values must not trap an Int conversion
        let rest = max(rounded - turns * 360, 0)
        let r = String(format: "%.1f", rest)
        return turns == 0 ? "\(sign)\(r)\u{00B0}" : "\(sign)\(String(format: "%.0f", turns))x \(r)\u{00B0}"
    }

    /// nil for text that is neither a turns form nor valid maths. `current` serves relative input (`+10`, `*2`).
    public static func parse(_ text: String, current: Double) -> Double? {
        let cleaned = text.replacingOccurrences(of: "\u{00B0}", with: "").replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace }.lowercased()
        let parts = cleaned.split(separator: "x", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty {
            let head = String(parts[0]), tail = parts[1].isEmpty ? "0" : String(parts[1])
            guard let t = Double(head), t.isFinite, t == t.rounded(), let d = Double(tail), d.isFinite else { return nil }
            let sign: Double = head.hasPrefix("-") ? -1 : 1
            let v = sign * (abs(t) * 360 + abs(d))
            return v.isFinite ? v : nil
        }
        return ScrubMath.evaluate(text, unit: "\u{00B0}", current: current)
    }
}
