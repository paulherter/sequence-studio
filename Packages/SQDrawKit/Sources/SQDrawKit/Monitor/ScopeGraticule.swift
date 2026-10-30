import Foundation

/// Which scope the view shows (picker order).
public enum ScopeKind: Int, CaseIterable, Sendable {
    case waveform, parade, vectorscope, histogram
    public var title: String {
        switch self {
        case .waveform: "Waveform"
        case .parade: "Parade"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }
}

/// Pure graticule geometry in unit plot coordinates: origin top-left, y down, (0,0)…(1,1) = the plot rect.
/// Matches the GPU texture mappings documented on `ScopeCounts` (SQRender).
public enum ScopeGraticule {
    public struct IRELine: Equatable, Sendable {
        public let ire: Int
        public let y: Double
        public var isMajor: Bool { ire % 50 == 0 }
    }
    /// 0, 10 … 100 IRE. 0 IRE = bottom (y 1), 100 IRE = top (y 0).
    public static let ireLines: [IRELine] = stride(from: 0, through: 100, by: 10).map { IRELine(ire: $0, y: 1 - Double($0) / 100) }

    public struct Target: Equatable, Sendable {
        public let name: String
        public let rgb: SIMD3<Double>
        public let center: SIMD2<Double>
    }

    /// Vectorscope unit coords of a BT.709 full-range R'G'B' signal: Cb → x, Cr → y up; the circle (radius 0.5) spans Cb/Cr ±0.5.
    public static func vectorscopePoint(r: Double, g: Double, b: Double) -> SIMD2<Double> {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return SIMD2(0.5 + (b - y) / 1.8556, 0.5 - (r - y) / 1.5748)
    }

    /// Graticule targets R, Mg, B, Cy, G, Yl at the given bar amplitude (0.75 or 1).
    public static func vectorscopeTargets(amplitude a: Double) -> [Target] {
        let defs: [(String, Double, Double, Double)] = [
            ("R", 1, 0, 0), ("Mg", 1, 0, 1), ("B", 0, 0, 1), ("Cy", 0, 1, 1), ("G", 0, 1, 0), ("Yl", 1, 1, 0),
        ]
        return defs.map { d in
            let rgb = SIMD3(d.1 * a, d.2 * a, d.3 * a)
            return Target(name: d.0, rgb: rgb, center: vectorscopePoint(r: rgb.x, g: rgb.y, b: rgb.z))
        }
    }

    /// Skin-tone line: hue angle from +Cb counter-clockwise.
    public static let skinToneAngleDegrees: Double = 123
    /// End of the skin-tone line on the circle (it starts at the center).
    public static var skinToneLineEnd: SIMD2<Double> {
        let a = skinToneAngleDegrees * .pi / 180
        return SIMD2(0.5 + 0.5 * cos(a), 0.5 - 0.5 * sin(a))
    }

    /// Vertical guides of the histogram (fractions of the plot width).
    public static let histogramVerticals: [Double] = [0, 0.25, 0.5, 0.75, 1]

    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
    }

    /// Plot rect inside a view of `size`. Waveforms/parade keep a left margin for IRE labels; the vectorscope is the largest centered square.
    public static func plotRect(_ kind: ScopeKind, in size: (width: Double, height: Double), labelMargin: Double) -> Rect {
        switch kind {
        case .waveform, .parade:
            return Rect(x: labelMargin, y: 0, width: max(0, size.width - labelMargin), height: size.height)
        case .vectorscope:
            let s = max(0, min(size.width, size.height))
            return Rect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
        case .histogram:
            return Rect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }
}
