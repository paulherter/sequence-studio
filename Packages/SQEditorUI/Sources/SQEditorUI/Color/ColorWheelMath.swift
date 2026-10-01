import Foundation

/// Pure geometry for `ColorWheelControl`. Disc-local coordinates, y up, origin at the disc centre.
public enum ColorWheelMath {
    /// hue in degrees [0, 360), 0 = +x, counter-clockwise. amount 0…1 (fraction of the radius).
    public struct Value: Sendable, Equatable {
        public var hue: Double
        public var amount: Double
        public init(hue: Double, amount: Double) { self.hue = hue; self.amount = amount }
        public var isNeutral: Bool { amount == 0 }
    }

    public static let reset = Value(hue: 0, amount: 0)
    /// Shift-drag moves the puck at this fraction of the pointer speed.
    public static let fineFactor = 0.2

    public static func value(dx: Double, dy: Double, radius: Double) -> Value {
        guard radius > 0 else { return reset }
        let len = hypot(dx, dy)
        guard len > 0 else { return reset }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        if hue >= 360 { hue -= 360 }
        return Value(hue: hue, amount: min(len / radius, 1))
    }

    public static func offset(of v: Value, radius: Double) -> (dx: Double, dy: Double) {
        let a = min(max(v.amount, 0), 1) * radius
        let r = v.hue * .pi / 180
        return (a * cos(r), a * sin(r))
    }

    /// Absolute drag follows the pointer; fine drag moves the puck relative to where it started.
    public static func drag(start: Value, startPoint: (Double, Double), point: (Double, Double),
                            radius: Double, fine: Bool) -> Value {
        guard fine else { return value(dx: point.0, dy: point.1, radius: radius) }
        let o = offset(of: start, radius: radius)
        return value(dx: o.dx + (point.0 - startPoint.0) * fineFactor,
                     dy: o.dy + (point.1 - startPoint.1) * fineFactor, radius: radius)
    }

    /// Side slider: `y` is measured from the top edge; top = +1, middle = 0, bottom = -1.
    public static func master(forY y: Double, height: Double) -> Double {
        guard height > 0 else { return 0 }
        return min(max(1 - 2 * y / height, -1), 1)
    }
    public static func y(forMaster m: Double, height: Double) -> Double {
        (1 - min(max(m, -1), 1)) / 2 * height
    }
}
