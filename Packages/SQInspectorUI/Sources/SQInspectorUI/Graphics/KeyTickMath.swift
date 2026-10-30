import Foundation
import SQCore

/// The geometry of the layer list's key strip (`KeyTickStrip`), portable so the shared-toolkit Graphics panel draws the
/// same ticks: positions of keys across the clip, the clip-local time under x, the item's range bar.
public enum KeyTickMath {
    /// Fraction 0...1 of `t` in `duration` (exact integer ratio first, one division at the end).
    public static func fraction(_ t: Time, in duration: Time) -> Double {
        guard duration.value > 0 else { return 0 }
        let num = Double(Int128(t.value) * Int128(duration.timescale)), den = Double(Int128(duration.value) * Int128(t.timescale))
        return min(max(num / den, 0), 1)
    }

    /// x of each tick (center) inside `width`; keys past the clip are clamped to its ends.
    public static func positions(times: [Time], duration: Time, width: CGFloat) -> [CGFloat] {
        guard width > 0 else { return [] }
        return times.map { CGFloat(fraction($0, in: duration)) * width }
    }

    /// The clip-local time at x (clamped to the clip), on the clip's own timescale.
    public static func time(atX x: CGFloat, width: CGFloat, duration: Time) -> Time {
        guard width > 0, duration.value > 0 else { return .zero }
        let f = Double(min(max(x / width, 0), 1))
        return Time(Int64((Double(duration.value) * f).rounded()), duration.timescale)
    }

    /// The range bar inside `width` (never thinner than 2 pt, so an item cut down to nothing still shows where it is).
    public static func rangeSpan(_ r: TimeRange, duration: Time, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let a = CGFloat(fraction(r.start, in: duration)) * width, b = CGFloat(fraction(r.end, in: duration)) * width
        let w = min(max(b - a, 2), max(width, 0))
        return (min(a, max(width - w, 0)), w)
    }
}
