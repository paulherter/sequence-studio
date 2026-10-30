import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The track behind a Color page slider (the Mac `ColorParam.Track`): plain, or a color ramp for Temperature (blue to
/// orange), Tint (green to magenta) and Saturation / Vibrance (gray to warm).
public enum InspectorColorRamp: Sendable, Equatable {
    case plain, temperature, tint, saturation

    /// The ramp's stops (location 0...1, color): `Theme.Palette.whiteBalanceTemperature`, `whiteBalanceTint`,
    /// `saturationRamp`; nil for the plain track.
    public var stops: [(Float, DrawColor)]? {
        let gray = DrawColor(0.54, 0.54, 0.54)
        switch self {
        case .plain: return nil
        case .temperature: return [(0, DrawColor(hex: 0x4F8FF0)), (0.5, gray), (1, DrawColor(hex: 0xF0A53C))]
        case .tint: return [(0, DrawColor(hex: 0x3FC36A)), (0.5, gray), (1, DrawColor(hex: 0xD463D8))]
        case .saturation:
            return [(0, gray), (0.4, DrawColor(hex: 0x9A86B5)), (0.7, DrawColor(hex: 0xC98199)), (1, DrawColor(hex: 0xD9A25B))]
        }
    }

    /// The ramp's color at `t` (0...1), linear between the stops.
    public func color(at t: Float) -> DrawColor? {
        guard let s = stops, let first = s.first, let last = s.last else { return nil }
        if t <= first.0 { return first.1 }
        for (a, b) in zip(s, s.dropFirst()) where t <= b.0 {
            let k = (t - a.0) / max(b.0 - a.0, 1e-6)
            return DrawColor(a.1.r + (b.1.r - a.1.r) * k, a.1.g + (b.1.g - a.1.g) * k, a.1.b + (b.1.b - a.1.b) * k,
                             a.1.a + (b.1.a - a.1.a) * k)
        }
        return last.1
    }
}

extension InspectorDraw {
    /// Version 9 `.sl` thumb and tracks (the Mac `ColorSlider`): a 3 pt track (5 pt for a color ramp), a 4 x 14 bar thumb.
    public static let colorTrack: CGFloat = 3, colorRampTrack: CGFloat = 5
    public static let colorThumb = CGSize(width: 4, height: 14)
    /// The Mac knob's box (`ColorSlider.knob`): the thumb's center travels 5 pt in from each end of the track.
    public static let colorKnob: CGFloat = 10
    /// Pieces a ramp is drawn in (enough for three or four stops at any width).
    static let rampPieces = 48

    /// A Color page slider (the Mac `ColorSlider.draw`): the plain track with its accent fill from the start, or from the
    /// neutral's center tick for a signed value (`neutral` = the neutral's fraction, nil = fill from the start); a ramp
    /// track shows no fill but a center tick. The thumb is the 4 x 14 bar.
    public static func colorSlider(_ c: inout Canvas, fraction: Double, neutral: Double?, ramp: InspectorColorRamp,
                                   in rect: CGRect, enabled: Bool, _ t: DrawTheme) {
        let a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        let inset = colorKnob / 2
        let x0 = rect.minX + inset, x1 = max(rect.maxX - inset, x0)
        func x(_ f: Double) -> CGFloat { x0 + (x1 - x0) * CGFloat(max(0, min(1, f))) }
        let y = rect.midY.rounded()
        if ramp.stops != nil {
            let th = colorRampTrack, line = CGRect(x: rect.minX, y: y - th / 2, width: rect.width, height: th)
            fill(horizontalRamp: ramp, in: line, alpha: a, &c)
            c.fill(CGRect(x: (rect.midX - 0.5).rounded(), y: y - 4.5, width: 1, height: 9), t.label.alpha(0.5 * a))
        } else {
            let th = colorTrack, line = CGRect(x: rect.minX, y: y - th / 2, width: rect.width, height: th)
            c.fill(roundedRect: line, radius: th / 2, t.fill.alpha(t.fill.a * a))
            if enabled {
                let k = x(fraction), from = neutral.map(x) ?? rect.minX
                let span = CGRect(x: min(from, k), y: line.minY, width: abs(k - from), height: th)
                if span.width > 0 { c.fill(roundedRect: span, radius: th / 2, t.accent) }
            }
        }
        let thumb = CGRect(x: (x(fraction) - colorThumb.width / 2).rounded(), y: y - colorThumb.height / 2,
                           width: colorThumb.width, height: colorThumb.height)
        c.shadow(roundedRect: thumb, radius: colorThumb.width / 2, blur: 1.5, dy: 0.5, DrawColor.black.alpha(0.6 * a))
        c.fill(roundedRect: thumb, radius: colorThumb.width / 2, enabled ? DrawColor(hex: 0xF2F2F2) : t.label3.alpha(t.label3.a * a))
    }

    /// Fraction of a Color page slider for a pointer at `x` (inverse of `colorSlider`).
    public static func colorSliderFraction(x: CGFloat, in rect: CGRect) -> Double {
        let x0 = rect.minX + colorKnob / 2, x1 = rect.maxX - colorKnob / 2
        guard x1 > x0 else { return 0 }
        return Double(max(0, min(1, (x - x0) / (x1 - x0))))
    }

    /// The ramp left to right in `r` with round ends: `rampPieces` flat pieces, each the ramp's color at its center.
    static func fill(horizontalRamp ramp: InspectorColorRamp, in r: CGRect, alpha: Float, _ c: inout Canvas) {
        guard r.width > 0, let first = ramp.color(at: 0), let last = ramp.color(at: 1) else { return }
        let cap = min(r.height / 2, r.width / 2)
        c.fill(ellipseIn: CGRect(x: r.minX, y: r.minY, width: cap * 2, height: r.height), first.alpha(first.a * alpha))
        c.fill(ellipseIn: CGRect(x: r.maxX - cap * 2, y: r.minY, width: cap * 2, height: r.height), last.alpha(last.a * alpha))
        let body = r.insetBy(dx: cap, dy: 0)
        let n = rampPieces, w = body.width / CGFloat(n)
        for i in 0..<n {
            let t = (Float(i) + 0.5) / Float(n)
            guard let col = ramp.color(at: t) else { continue }
            // An opaque piece reaches into the next by a hair so no seam shows (translucent ones would darken there).
            let overlap: CGFloat = i == n - 1 || alpha < 1 ? 0 : 0.5
            c.fill(CGRect(x: body.minX + CGFloat(i) * w, y: r.minY, width: w + overlap, height: r.height),
                   col.alpha(col.a * alpha))
        }
    }
}
