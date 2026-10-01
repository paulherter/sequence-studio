import CoreGraphics
import Foundation
import SQCore

/// How the curve arrives at / leaves a key (per side).
public enum KeyHalf: Sendable, Hashable {
    case linear
    /// Ease / bezier: half hourglass (triangle pointing at the centre).
    case eased
    case hold
}

public struct KeyGlyph: Sendable, Hashable {
    public var incoming: KeyHalf
    public var outgoing: KeyHalf
    public init(incoming: KeyHalf, outgoing: KeyHalf) { self.incoming = incoming; self.outgoing = outgoing }

    public static let linear = KeyGlyph(incoming: .linear, outgoing: .linear)

    static func half(_ interpolation: Interpolation, handle: EaseHandle) -> KeyHalf {
        switch interpolation {
        case .hold: .hold
        case .linear: .linear
        case .bezier: isLinear(handle) ? .linear : .eased
        }
    }

    private static func isLinear(_ h: EaseHandle) -> Bool {
        abs(h.dx - EaseHandle.linear.dx) < 1e-6 && abs(h.dy - EaseHandle.linear.dy) < 1e-6
    }

    /// Glyph of every key. A side without a neighbouring segment (first key's left, last key's right) mirrors the other.
    public static func glyphs<V: KeyframeValue>(of track: KeyframeTrack<V>) -> [(id: UUID, time: Time, glyph: KeyGlyph)] {
        let keys = track.keys
        return keys.enumerated().map { i, k in
            // Rendering ignores `interpolation` except for hold, so the glyph reads the handles the same way:
            // a key eased on one side shows as eased whatever its neighbour's shape is.
            let out: KeyHalf? = i + 1 < keys.count ? half(k.interpolation, handle: k.outHandle) : nil
            let inc: KeyHalf? = i > 0 ? (keys[i - 1].interpolation == .hold ? .hold : (isLinear(k.inHandle) ? .linear : .eased)) : nil
            let g = KeyGlyph(incoming: inc ?? out ?? .linear, outgoing: out ?? inc ?? .linear)
            return (k.id, k.time, g)
        }
    }

    /// Summary glyph of several keys at one time: per side hold if all are hold, eased if any is eased, else linear.
    public static func merged(_ glyphs: [KeyGlyph]) -> KeyGlyph {
        func side(_ halves: [KeyHalf]) -> KeyHalf {
            if !halves.isEmpty, halves.allSatisfy({ $0 == .hold }) { return .hold }
            return halves.contains(.eased) ? .eased : .linear
        }
        return KeyGlyph(incoming: side(glyphs.map(\.incoming)), outgoing: side(glyphs.map(\.outgoing)))
    }

    /// The one solid shape a key is drawn as (hold beats easing beats linear).
    public var shape: KeyShape {
        if incoming == .hold || outgoing == .hold { return .square }
        if incoming == .eased || outgoing == .eased { return .circle }
        return .diamond
    }
}

/// Premiere-like key shapes, each drawn as ONE solid filled closed shape: linear = diamond, any easing = circle,
/// hold = square. No half shapes, no strokes between parts.
public enum KeyShape: Sendable, Hashable {
    case diamond, circle, square

    /// Bounding box of the shape centred on `c`; `size` is the full width/height. The circle and square are a bit
    /// smaller than the diamond's tips so all three look the same size.
    public func bounds(at c: CGPoint, size: CGFloat) -> CGRect {
        let s = self == .diamond ? size : size * 0.82
        return CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    }

    /// Corner points (diamond, square); empty for the circle.
    public func corners(at c: CGPoint, size: CGFloat) -> [CGPoint] {
        let r = bounds(at: c, size: size)
        switch self {
        case .diamond: return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                               CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        case .square: return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                              CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .circle: return []
        }
    }
}
