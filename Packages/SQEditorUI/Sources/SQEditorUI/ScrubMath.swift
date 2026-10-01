import Foundation

/// Pure math behind `ScrubField`: drag delta to value, clamping, grid rounding, text parsing/formatting.
public enum ScrubMath {
    /// Shift = coarse x10, Option = fine x0.1, both cancel out.
    public static func multiplier(shift: Bool, option: Bool) -> Double {
        switch (shift, option) {
        case (true, false): 10
        case (false, true): 0.1
        default: 1
        }
    }

    public static func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return min(max(0, range.lowerBound), range.upperBound) }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// Removes binary noise (0.30000000000000004 -> 0.3) relative to a grid size.
    static func clean(_ v: Double, grid: Double) -> Double {
        guard grid > 0, v.isFinite else { return v }
        let decimals = max(0, min(10, Int((-log10(grid)).rounded(.up)) + 2))
        let f = pow(10.0, Double(decimals))
        return (v * f).rounded() / f
    }

    /// `start + round(deltaPixels) * step * multiplier`, clamped. Fractional pixel deltas (trackpad)
    /// snap to whole steps of the effective grid; an off-grid start stays stable at delta 0.
    public static func value(start: Double, deltaPixels: Double, step: Double,
                             shift: Bool, option: Bool, range: ClosedRange<Double>) -> Double {
        let grid = step * multiplier(shift: shift, option: option)
        guard grid > 0, deltaPixels.isFinite else { return clamp(start, to: range) }
        let result = start + deltaPixels.rounded(.toNearestOrAwayFromZero) * grid
        return clean(clamp(result, to: range), grid: grid)
    }

    /// One arrow-key step (direction +1 / -1) with the same modifiers.
    public static func stepped(_ v: Double, direction: Int, step: Double,
                               shift: Bool, option: Bool, range: ClosedRange<Double>) -> Double {
        value(start: v, deltaPixels: Double(direction), step: step, shift: shift, option: option, range: range)
    }

    /// Parses user text: optional sign (also U+2212), comma or dot decimal, optional unit suffix (case-insensitive).
    /// Returns nil for anything else (including nan/inf and foreign units).
    public static func parse(_ text: String, unit: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = unit.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty, s.lowercased().hasSuffix(u.lowercased()) {
            s = String(s.dropLast(u.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: ",", with: ".")
        let body = s.hasPrefix("-") || s.hasPrefix("+") ? String(s.dropFirst()) : s
        // Only digits and at most one dot: rejects "nan", "inf", "1e5", "1.2.3".
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              body.filter({ $0 == "." }).count <= 1, body.contains(where: \.isNumber),
              let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// Fixed decimals plus unit. Degree sign hugs the number (90°), other units get a space (42 %, 3 dB).
    public static func format(_ v: Double, decimals: Int, unit: String) -> String {
        var s = String(format: "%.\(max(0, decimals))f", v)
        if Double(s) == 0 { s = String(s.drop(while: { $0 == "-" })) }  // no "-0.0"
        guard !unit.isEmpty else { return s }
        return unit == "°" ? s + unit : s + " " + unit
    }
}
