import Foundation

/// Color value of the picker: HSB plus alpha, all 0...1. Pure; converts to sRGB and hex.
public struct SQColorValue: Equatable, Sendable {
    public var h: Double, s: Double, b: Double, a: Double
    public init(h: Double, s: Double, b: Double, a: Double = 1) {
        self.h = min(max(h, 0), 1); self.s = min(max(s, 0), 1); self.b = min(max(b, 0), 1); self.a = min(max(a, 0), 1)
    }

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        self.init(h: h, s: mx == 0 ? 0 : d / mx, b: mx, a: a)
    }

    public var rgb: (r: Double, g: Double, b: Double) {
        let hh = (h >= 1 ? 0 : h) * 6, i = Int(hh), f = hh - Double(i)
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }

    /// `RRGGBB` (alpha omitted) uppercase.
    public var hex: String {
        let c = rgb
        func b8(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", b8(c.r), b8(c.g), b8(c.b))
    }

    /// Parses `RGB`, `RRGGBB` or `RRGGBBAA`, with optional leading `#`. Alpha defaults to `keepingAlpha`.
    public static func parse(hex text: String, keepingAlpha: Double = 1) -> SQColorValue? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard [3, 6, 8].contains(t.count), t.allSatisfy(\.isHexDigit) else { return nil }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(t, radix: 16) else { return nil }
        let hasA = t.count == 8
        let r = Double((v >> (hasA ? 24 : 16)) & 0xFF) / 255, g = Double((v >> (hasA ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasA ? 8 : 0)) & 0xFF) / 255
        return SQColorValue(r: r, g: g, b: b, a: hasA ? Double(v & 0xFF) / 255 : keepingAlpha)
    }
}
