import Foundation

// FB-T3 easing library of the motion effects (the Curve pop-up of Move, Zoom, Pop, Fade, Shake and the element
// transitions). Stored as the case's raw value in the effect's "curve" parameter; the order is the menu order:
// Premiere's interpolations first (what a Premiere user looks for), then the short-form families (easings.net names:
// In = accelerates, Out = decelerates), then Custom (a cubic bezier kept in the effect, edited with the curve editor).
//
// Premiere mapping for one edge animation (a two-key segment):
//   Bezier            Premiere's default bezier (16.7 % influence, flat tangents).
//   Continuous Bezier 33 % influence on both keys (Premiere's handles when the segment is smoothed through).
//   Auto Bezier       straight speed: with only two keys Premiere's auto tangents point at each other.
//   Linear, Hold      as in Premiere (Hold jumps at the end of the segment).
//   Ease In / Ease Out Premiere's keyframe assistants: Ease In slows into the key (fast start, soft landing),
//                     Ease Out slows out of the key (soft start). 100 % variants = full influence.

/// A CSS-style cubic bezier `cubic-bezier(x1, y1, x2, y2)` from (0,0) to (1,1). X is clamped to 0...1, Y is free
/// (outside 0...1 the curve overshoots).
public struct CubicBezierEase: Sendable, Hashable {
    public var x1: Double, y1: Double, x2: Double, y2: Double
    public init(x1: Double, y1: Double, x2: Double, y2: Double) { self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2 }

    /// The curve editor's shape (handles relative to their key: out from the start, in back from the end).
    public init(_ shape: EaseShape) {
        if shape.interpolation == .linear {
            self.init(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        } else {
            self.init(x1: shape.out.dx, y1: shape.out.dy, x2: 1 - shape.in.dx, y2: 1 - shape.in.dy)
        }
    }

    public var shape: EaseShape {
        EaseShape(interpolation: .bezier, out: EaseHandle(dx: x1, dy: y1), in: EaseHandle(dx: 1 - x2, dy: 1 - y2))
    }

    public func progress(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return KeyframeMath.bezierProgress(x, out: EaseHandle(dx: x1, dy: y1), in: EaseHandle(dx: 1 - x2, dy: 1 - y2))
    }

    /// Default of a fresh Custom curve: Premiere's Continuous Bezier.
    public static let `default` = CubicBezierEase(x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1)
}

public enum MotionCurve: Int, Sendable, CaseIterable {
    // Premiere.
    case premiereDefault, continuousBezier, autoBezier, linear, hold
    // Case names follow `EasingCurve` (CSS sense: easeOut100 decelerates), titles follow `EaseName` (easeOut100 arrives slowly: "Smooth In 100%").
    case easeIn, easeOut, easeOut100, easeIn100, fastStart, spring
    // Families.
    case sineIn, sineOut, sineInOut, quadIn, quadOut, quadInOut, cubicIn, cubicOut, cubicInOut
    case quartIn, quartOut, quartInOut, quintIn, quintOut, quintInOut, expoIn, expoOut, expoInOut
    case circIn, circOut, circInOut, backIn, backOut, backInOut, elasticIn, elasticOut, elasticInOut
    case bounceIn, bounceOut, bounceInOut
    case custom

    /// Older name of Continuous Bezier (33 % in and out).
    public static var easeInOut: MotionCurve { .continuousBezier }

    public var title: String {
        switch self {
        case .premiereDefault: EaseName.gentle
        case .continuousBezier: EaseName.smooth
        case .autoBezier: "Auto"
        case .linear: EaseName.steady
        case .hold: EaseName.hold
        case .easeIn: EaseName.smoothIn
        case .easeOut: EaseName.smoothOut
        case .easeIn100: EaseName.smoothOut100
        case .easeOut100: EaseName.smoothIn100
        case .fastStart: EaseName.fastStart
        case .spring: "Spring"
        case .backIn: "Wind-Up"
        case .backOut: "Overshoot"
        case .backInOut: "Wind-Up Overshoot"
        case .elasticInOut: "Spring In Out"
        case .custom: EaseName.custom
        default: familyTitle
        }
    }

    /// Own words for the strength families (DECISIONS 2026-10-06), in the order of `family`'s shape index.
    private static let familyWords = ["Soft", "Light", "Firm", "Strong", "Heavy", "Sharp", "Round", "", "Spring", "Bounce"]

    /// "<Word> Out" is the family's accelerating form (slow leaving the start), "<Word> In" the decelerating one (slow
    /// arriving), the bare word both: the sense of `EaseName.smoothIn` / `smoothOut`, swapped against the CSS names.
    /// Spring and Bounce follow the same rule: "Out" wobbles or bounces at the start, "In" at the end. Back (Wind-Up,
    /// Overshoot) and the two-sided spring ("Spring In Out", bare "Spring" is the live spring) are named in `title`.
    private var familyTitle: String {
        guard let (shape, kind) = family else { return EaseName.custom }
        let word = Self.familyWords[shape]
        return kind == 0 ? word + " Out" : kind == 1 ? word + " In" : word
    }

    public static let titles: [String] = allCases.map(\.title)

    /// Eased progress for `x` (clamped to 0...1; exactly 0 at 0 and 1 at 1; back, elastic, spring and a custom curve
    /// with Y outside 0...1 overshoot in between). `custom` is the effect's own curve (Custom only; default when nil).
    public func ease(_ x: Double, custom: CubicBezierEase? = nil) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bez(_ c: EasingCurve) -> Double { KeyframeMath.bezierProgress(x, out: c.outHandle, in: c.inHandle) }
        switch self {
        case .premiereDefault: return bez(.premiereDefault)
        case .continuousBezier: return bez(.easeInOut)
        case .autoBezier, .linear: return x
        case .hold: return 0
        // EasingCurve's names are CSS-style (its .easeIn = slow arrival = Premiere's Ease In).
        case .easeIn: return bez(.easeIn)
        case .easeOut: return bez(.easeOut)
        case .easeIn100: return bez(.easeIn100)
        case .easeOut100: return bez(.easeOut100)
        case .fastStart: return bez(.fastStart)
        case .spring: return SpringEasing(bounce: 0.4).progress(x)
        case .custom: return (custom ?? .default).progress(x)
        default: break
        }
        guard let (shape, kind) = family else { return x }
        let f: (Double) -> Double = { Self.easeIn(shape, $0) }
        switch kind {
        case 0: return f(x)
        case 1: return 1 - f(1 - x)
        default: return x < 0.5 ? f(2 * x) / 2 : 1 - f(2 - 2 * x) / 2
        }
    }

    /// The accelerating ("In") shape of a family and which variant this case is (0 In, 1 Out, 2 In-Out).
    private var family: (Int, Int)? {
        let first = MotionCurve.sineIn.rawValue, last = MotionCurve.bounceInOut.rawValue
        guard rawValue >= first, rawValue <= last else { return nil }
        let i = rawValue - first
        return (i / 3, i % 3)
    }

    /// The In form of family `shape` (0 sine, 1 quad, 2 cubic, 3 quart, 4 quint, 5 expo, 6 circ, 7 back, 8 elastic,
    /// 9 bounce): f(0) = 0, f(1) = 1 exactly (expo and elastic are normalized so nothing jumps at the ends).
    static func easeIn(_ shape: Int, _ x: Double) -> Double {
        switch shape {
        case 0: return 1 - cos(x * .pi / 2)
        case 1...4: return pow(x, Double(shape + 1))
        case 5: return (pow(2, 10 * x) - 1) / (pow(2, 10) - 1)
        case 6: return 1 - (max(1 - x * x, 0)).squareRoot()
        case 7:
            let c1 = 1.70158, c3 = c1 + 1
            return c3 * x * x * x - c1 * x * x
        case 8:
            // Elastic Out of easings.net mirrored; divided by its value at 1 so it lands exactly.
            func out(_ u: Double) -> Double { pow(2, -10 * u) * sin((10 * u - 0.75) * 2 * .pi / 3) + 1 }
            return 1 - out(1 - x) / out(1)
        default:
            return 1 - bounceOut(1 - x)
        }
    }

    /// Robert Penner's bounce (4 floor contacts, the first at 1/2.75).
    static func bounceOut(_ x: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        if x < 1 / d1 { return n1 * x * x }
        if x < 2 / d1 { let u = x - 1.5 / d1; return n1 * u * u + 0.75 }
        if x < 2.5 / d1 { let u = x - 2.25 / d1; return n1 * u * u + 0.9375 }
        let u = x - 2.625 / d1
        return n1 * u * u + 0.984375
    }
}

/// The eased-progress function of one evaluation: the effect's Curve with its Custom bezier.
struct EaseFunction {
    let f: (Double) -> Double
    init(_ f: @escaping (Double) -> Double) { self.f = f }
    func ease(_ x: Double) -> Double { f(x) }
}

extension ClipEffect {
    /// The Custom curve of a motion effect: `cubic-bezier(x1, y1, x2, y2)`. Not in the specs (no rows of their own,
    /// never keyed); edited with the curve editor from the Curve row.
    public static let curveX1Key = "curveX1", curveY1Key = "curveY1", curveX2Key = "curveX2", curveY2Key = "curveY2"
    static let customCurveKeys = [curveX1Key, curveY1Key, curveX2Key, curveY2Key]

    /// The stored Custom curve; nil when none was edited (the Custom choice then uses `CubicBezierEase.default`).
    public var customCurve: CubicBezierEase? {
        guard let x1 = parameters[Self.curveX1Key]?.value, let y1 = parameters[Self.curveY1Key]?.value,
              let x2 = parameters[Self.curveX2Key]?.value, let y2 = parameters[Self.curveY2Key]?.value,
              [x1, y1, x2, y2].allSatisfy(\.isFinite) else { return nil }
        return CubicBezierEase(x1: min(max(x1, 0), 1), y1: y1, x2: min(max(x2, 0), 1), y2: y2)
    }

    /// Stores `c` as the Custom curve (static values, X clamped to 0...1, Y to -2...3).
    public mutating func setCustomCurve(_ c: CubicBezierEase) {
        let v = [min(max(c.x1, 0), 1), min(max(c.y1, -2), 3), min(max(c.x2, 0), 1), min(max(c.y2, -2), 3)]
        for (k, x) in zip(Self.customCurveKeys, v) { parameters[k] = AnimatedProperty(x) }
    }
}
