import Foundation

/// Tracks one burst of arrow-key steps so a run of presses (auto-repeat included) is one gesture, hence one undo step.
/// `step()` is true when the press opens a new burst, `end()` is true when it closed an open one.
public struct StepBurst: Sendable {
    public init() {}
    /// Idle time after which a burst ends without a key-up (seconds).
    public static let idle: TimeInterval = 0.5
    public private(set) var isOpen = false
    public mutating func step() -> Bool { defer { isOpen = true }; return !isOpen }
    public mutating func end() -> Bool { defer { isOpen = false }; return isOpen }
}

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

    /// Double-click reset: the clamped default, or nil when there is none or the value is already there (no undo step).
    public static func resetTarget(current: Double, default d: Double?, range: ClosedRange<Double>) -> Double? {
        guard let d else { return nil }
        let v = clamp(d, to: range)
        return v == current ? nil : v
    }

    // MARK: Scroll wheel (DECISIONS 2026-10-03 "Interaction rules": only with Option held, so panels still scroll)

    /// The wheel changes the value only with Option held while the field is hovered or focused.
    public static func wheelAccepts(option: Bool, hovered: Bool, focused: Bool) -> Bool { option && (hovered || focused) }

    /// Option is the gate, so the wheel's own modifiers are Shift = coarse x10, Command = fine x0.1.
    public static func wheelMultiplier(shift: Bool, command: Bool) -> Double {
        switch (shift, command) {
        case (true, false): 10
        case (false, true): 0.1
        default: 1
        }
    }

    /// `v + notches * step * wheelMultiplier`, clamped and grid-cleaned.
    public static func wheelValue(_ v: Double, notches: Int, step: Double, shift: Bool, command: Bool,
                                  range: ClosedRange<Double>) -> Double {
        let grid = step * wheelMultiplier(shift: shift, command: command)
        guard grid > 0 else { return clamp(v, to: range) }
        return clean(clamp(v + Double(notches) * grid, to: range), grid: grid)
    }

    /// The scroll delta that counts: vertical, or horizontal when a mouse wheel turned sideways (Shift held);
    /// scrolling up / left-to-right increases.
    public static func wheelDelta(deltaX: Double, deltaY: Double) -> Double {
        deltaY != 0 ? deltaY : -deltaX
    }

    /// Turns wheel deltas into whole notches: one per mouse-wheel line, one per `pointsPerNotch` trackpad points;
    /// the remainder carries over to the next event.
    public struct WheelAccumulator: Sendable, Equatable {
        public static let pointsPerNotch: Double = 8
        private var remainder = 0.0
        public init() {}
        public mutating func add(delta: Double, precise: Bool) -> Int {
            guard delta.isFinite else { return 0 }
            let unit = precise ? Self.pointsPerNotch : 1
            remainder += delta / unit
            let n = remainder.rounded(.towardZero)
            remainder -= n
            return Int(n)
        }
        public mutating func reset() { remainder = 0 }
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

    /// Typed text with simple maths, for committing a field: `+ - * / ( )` and numbers only (hand-written parser, no
    /// expression engine). A leading `+`, `*` or `/` applies to `current` (`+10`, `*2`, `/2`); a leading `-` does too
    /// when `negativeAllowed` is false (the field cannot hold negatives anyway), otherwise `-5` stays the plain
    /// number (type `+-5` to subtract). The rest of the text is one expression (`*2+1` is `current * 3`).
    /// Anything invalid, division by zero or a non-finite result gives nil. The unit (and spaces) may appear anywhere.
    public static func evaluate(_ text: String, unit: String, current: Double, negativeAllowed: Bool = true) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = unit.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { s = s.replacingOccurrences(of: u, with: "", options: .caseInsensitive) }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{00D7}", with: "*")
            .replacingOccurrences(of: "\u{00F7}", with: "/").replacingOccurrences(of: ",", with: ".")
            .filter { !$0.isWhitespace }
        guard let first = s.first else { return nil }
        let relative = "+*/".contains(first) || (first == "-" && !negativeAllowed)
        let chars = Array(relative ? s.dropFirst() : Substring(s))
        if relative, chars.isEmpty { return nil }
        var evaluator = ExpressionParser(chars: chars)
        guard let rhs = evaluator.parseAll() else { return nil }
        let result: Double
        if relative {
            switch first {
            case "+": result = current + rhs
            case "-": result = current - rhs
            case "*": result = current * rhs
            default:
                guard rhs != 0 else { return nil }
                result = current / rhs
            }
        } else {
            result = rhs
        }
        return result.isFinite ? result : nil
    }

    /// Recursive-descent parser for numbers, `+ - * /` and parentheses.
    struct ExpressionParser {
        let chars: [Character]
        var pos = 0
        var depth = 0
        init(chars: [Character]) { self.chars = chars }

        mutating func parseAll() -> Double? {
            guard let v = expr(), pos == chars.count, v.isFinite else { return nil }
            return v
        }
        private var peek: Character? { pos < chars.count ? chars[pos] : nil }

        private mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                pos += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        private mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek, c == "*" || c == "/" {
                pos += 1
                guard let r = factor() else { return nil }
                if c == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
            return v
        }
        private mutating func factor() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 32, let c = peek else { return nil }
            if c == "-" || c == "+" {
                pos += 1
                guard let v = factor() else { return nil }
                return c == "-" ? -v : v
            }
            if c == "(" {
                pos += 1
                guard let v = expr(), peek == ")" else { return nil }
                pos += 1
                return v
            }
            let start = pos
            var dots = 0
            while let d = peek, d.isASCII, d.isNumber || d == "." {
                if d == "." { dots += 1 }
                pos += 1
            }
            let body = String(chars[start..<pos])
            guard dots <= 1, body.contains(where: \.isNumber), let v = Double(body) else { return nil }
            return v
        }
    }

    /// Fixed decimals plus unit. Degree sign hugs the number (90°), other units get a space (42 %, 3 dB).
    public static func format(_ v: Double, decimals: Int, unit: String) -> String {
        var s = String(format: "%.\(max(0, decimals))f", v)
        if Double(s) == 0 { s = String(s.drop(while: { $0 == "-" })) }  // no "-0.0"
        guard !unit.isEmpty else { return s }
        return unit == "°" ? s + unit : s + " " + unit
    }
}
