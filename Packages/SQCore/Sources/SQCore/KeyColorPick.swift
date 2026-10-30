import Foundation

/// Color Key eyedropper: the Key Hue (degrees) of a picked color. The keyer measures hue on the un-premultiplied
/// working-linear color (`UltraKey.hsv`), so the picked linear RGB is converted the same way.
public enum KeyColorPick {
    /// Below this saturation or brightness the hue is noise (gray, near black): nothing is picked.
    public static let minSaturation: Float = 0.08
    public static let minValue: Float = 0.005

    /// Hue 0..<360 of a linear RGB color, or nil for a gray / black / non-finite pick.
    public static func hue(fromLinear c: SIMD3<Float>) -> Double? {
        guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { return nil }
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        guard mx >= minValue, d / mx >= minSaturation else { return nil }
        var h: Float
        if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return Double(h.rounded())
    }
}
