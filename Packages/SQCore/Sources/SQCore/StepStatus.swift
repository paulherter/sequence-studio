import Foundation

/// The one-line status text for a key-driven frame step (trim, nudge, slip, slide). Every such key shows what it did,
/// so Opt+Arrow never looks like a silent slip.
public enum StepStatus {
    /// Frames moved by the plain arrow key variant and by the Shift variant. The command ids ending in "5" are legacy names.
    public static let small = 1, large = 10

    /// "Trim: 1 frame earlier", "Slip: 10 frames later".
    public static func line(_ verb: String, frames: Int) -> String {
        let n = abs(frames)
        return "\(verb): \(n) frame\(n == 1 ? "" : "s") \(frames < 0 ? "earlier" : "later")"
    }
}
