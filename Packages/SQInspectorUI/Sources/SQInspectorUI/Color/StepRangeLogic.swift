import Foundation
import SQCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The three range bars of a Step's Qualifier (Hue, Saturation, Luma) and the Step window's shape titles: the value
/// mapping and the drag rules, shared by the Mac `ColorRangeRow` and the portable `ColorGradeDraw`.
enum StepRangeKind: CaseIterable, Sendable {
    case hue, saturation, luma

    var title: String {
        switch self { case .hue: "Hue"; case .saturation: "Saturation"; case .luma: "Luma" }
    }
    var maximum: Double { self == .hue ? 360 : 100 }

    /// The two Qualifier values a bar edits: Hue is center and full width, Saturation and Luma are minimum and maximum.
    static func pair(_ kind: StepRangeKind) -> (ColorRangeParam, ColorRangeParam) {
        switch kind {
        case .hue: (.hueCenter, .hueWidth)
        case .saturation: (.satMin, .satMax)
        case .luma: (.lumMin, .lumMax)
        }
    }

    /// Bar edges (low, high) from the stored pair.
    static func bounds(_ kind: StepRangeKind, first: Double, second: Double) -> (Double, Double) {
        switch kind {
        case .hue: (max(first - second / 2, 0), min(first + second / 2, 360))
        case .saturation, .luma: (first, second)
        }
    }

    /// Stored values from the bar edges.
    static func params(_ kind: StepRangeKind, low: Double, high: Double) -> [(ColorRangeParam, Float)] {
        let (a, b) = pair(kind)
        switch kind {
        case .hue: return [(a, Float((low + high) / 2)), (b, Float(high - low))]
        case .saturation, .luma: return [(a, Float(low)), (b, Float(high))]
        }
    }
}

/// The bar's pointer math: which part a press grabs (an edge, or the inside to move the range) and the range a drag at
/// `x` gives. A press outside the range centers it there.
struct RangeBarMath {
    var maximum: Double
    var minX: CGFloat
    var width: CGFloat
    static let edge: CGFloat = 6

    enum Grab: Equatable { case low, high, move(offset: Double, width: Double) }

    func x(_ v: Double) -> CGFloat { minX + CGFloat(v / maximum) * width }
    func value(at x: CGFloat) -> Double { min(max(Double((x - minX) / max(width, 1)) * maximum, 0), maximum) }

    func grab(at px: CGFloat, low: Double, high: Double) -> Grab {
        if abs(px - x(low)) <= Self.edge, abs(px - x(low)) <= abs(px - x(high)) { return .low }
        if abs(px - x(high)) <= Self.edge { return .high }
        let v = value(at: px), w = high - low
        return v >= low && v <= high ? .move(offset: v - low, width: w) : .move(offset: w / 2, width: w)
    }

    func apply(_ g: Grab, at px: CGFloat, low: Double, high: Double) -> (low: Double, high: Double) {
        let v = value(at: px)
        switch g {
        case .low: return (min(v, high), high)
        case .high: return (low, max(v, low))
        case .move(let offset, let w):
            let lo = min(max(v - offset, 0), maximum - w)
            return (lo, lo + w)
        }
    }

    /// "low – high" as the value column reads it.
    static func text(_ lo: Double, _ hi: Double) -> String { "\(Int(lo.rounded())) \u{2013} \(Int(hi.rounded()))" }
}

extension StepWindow.Shape {
    /// The shape button's title (version 9 calls the ellipse an oval).
    var chipTitle: String { self == .ellipse ? "Oval" : title }
}
