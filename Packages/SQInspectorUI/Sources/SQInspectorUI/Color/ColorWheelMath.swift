import Foundation
import SQCore

/// Pure geometry for `ColorWheelControl`. Disc-local coordinates, y up, origin at the disc center.
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

    /// Slider below the disc (version 9): `x` is measured from the left edge; left = -1, middle = 0, right = +1.
    public static func master(forX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(2 * x / width - 1, -1), 1)
    }
    public static func x(forMaster m: Double, width: Double) -> Double {
        (min(max(m, -1), 1) + 1) / 2 * width
    }
}

/// How a Pro Primaries wheel (Lift, Gamma, Gain, Offset) reads and writes a Step's per-channel triple. The puck is the
/// triple's chroma (the channels around their mean, hue 0 = red), the side slider is the mean (the master).
public enum PrimaryWheel: CaseIterable, Sendable {
    case lift, gamma, gain, offset

    public var title: String {
        switch self { case .lift: "Lift"; case .gamma: "Gamma"; case .gain: "Gain"; case .offset: "Offset" }
    }

    /// Chroma at the rim of the disc (per channel, around the mean).
    var rim: Float { switch self { case .lift, .offset: 0.25; case .gamma, .gain: 0.5 } }
    /// Lift and Offset add (master -1...1 is -0.5...0.5); Gamma and Gain scale (master -1...1 is x0.5...x2).
    var isAdditive: Bool { self == .lift || self == .offset }
    var channelRange: ClosedRange<Float> {
        switch self {
        case .lift: StepPrimaries.liftRange
        case .offset: StepPrimaries.offsetRange
        case .gamma: StepPrimaries.gammaRange
        case .gain: StepPrimaries.gainRange
        }
    }

    public func triple(_ p: StepPrimaries) -> ColorTriple {
        switch self { case .lift: p.lift; case .gamma: p.gamma; case .gain: p.gain; case .offset: p.offset }
    }
    public func write(_ t: ColorTriple, into p: inout StepPrimaries) {
        switch self { case .lift: p.lift = t; case .gamma: p.gamma = t; case .gain: p.gain = t; case .offset: p.offset = t }
    }

    func mean(_ t: ColorTriple) -> Float { (t.r + t.g + t.b) / 3 }

    /// The master slider's value, -1...1.
    public func master(of t: ColorTriple) -> Double {
        let m = mean(t)
        let v = isAdditive ? Double(m) * 2 : log2(Double(max(m, 0.0001)))
        return min(max(v, -1), 1)
    }

    /// The puck of a triple.
    public func puck(of t: ColorTriple) -> ColorWheelMath.Value {
        let m = mean(t)
        let cr = t.r - m, cg = t.g - m, cb = t.b - m
        let x = (2.0 / 3.0) * (Double(cr) - 0.5 * Double(cg) - 0.5 * Double(cb))
        let y = (2.0 / 3.0) * (sqrt(3.0) / 2) * Double(cg - cb)
        let k = hypot(x, y)
        guard k > 1e-6 else { return ColorWheelMath.reset }
        var hue = atan2(y, x) * 180 / .pi
        if hue < 0 { hue += 360 }
        // A scaling wheel's chroma is relative to its mean, so the rim is the same at every master.
        let scale = isAdditive ? 1 : Double(max(m, 0.0001))
        return .init(hue: hue, amount: min(k / scale / Double(rim), 1))
    }

    /// The triple for a puck and a master value (clamped to the channel range).
    public func triple(puck: ColorWheelMath.Value, master: Double) -> ColorTriple {
        let m: Float = isAdditive ? Float(master / 2) : Float(pow(2, master))
        let k = Float(puck.amount) * rim * (isAdditive ? 1 : m)
        let h = Float(puck.hue * Double.pi / 180)
        let d = Float(2 * Double.pi / 3)
        func ch(_ c: Float) -> Float { min(max(m + k * c, channelRange.lowerBound), channelRange.upperBound) }
        return ColorTriple(ch(cos(h)), ch(cos(h - d)), ch(cos(h + d)))
    }
}
