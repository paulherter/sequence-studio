import Foundation

/// v87 Color range mask: the pixels of the clip's own picture near a picked color. The color is display-encoded Rec.709
/// (what the eyedropper and the swatch show), 0...1; the distance is the Euclidean RGB distance of display-encoded straight
/// colors divided by sqrt(3) (so 0...1). Coverage is 1 up to `tolerance`, then falls with a smoothstep over `softness`
/// (0 = hard edge). CPU reference of the compositor's `colorRangeValue` (same steps).
public struct ColorRangeKey: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 0...1 (shown as 0...100 %): the distance that is still fully covered.
    public var tolerance: Double
    /// 0...1 (shown as 0...100 %): width of the soft edge outside the tolerance.
    public var softness: Double

    /// A mid green, the usual screen color; tolerance 25 %, softness 15 %.
    public static let `default` = ColorRangeKey(red: 0.1, green: 0.75, blue: 0.2, tolerance: 0.25, softness: 0.15)

    public init(red: Double, green: Double, blue: Double, tolerance: Double = 0.25, softness: Double = 0.15) {
        func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        self.red = c(red); self.green = c(green); self.blue = c(blue)
        self.tolerance = c(tolerance); self.softness = c(softness)
    }

    enum CodingKeys: String, CodingKey { case red, green, blue, tolerance, softness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try c.decode(Double.self, forKey: .red), green: try c.decode(Double.self, forKey: .green),
                  blue: try c.decode(Double.self, forKey: .blue),
                  tolerance: try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? Self.default.tolerance,
                  softness: try c.decodeIfPresent(Double.self, forKey: .softness) ?? Self.default.softness)
    }

    /// Coverage 0...1 of a display-encoded straight color (before invert and opacity).
    public func value(red r: Double, green g: Double, blue b: Double) -> Double {
        let dr = r - red, dg = g - green, db = b - blue
        let d = (dr * dr + dg * dg + db * db).squareRoot() / 3.0.squareRoot()
        guard softness > 1e-6 else { return d <= tolerance ? 1 : 0 }
        let x = min(max((d - tolerance) / softness, 0), 1)
        return 1 - x * x * (3 - 2 * x)
    }
}
