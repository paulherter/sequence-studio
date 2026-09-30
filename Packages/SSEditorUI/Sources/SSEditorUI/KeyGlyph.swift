import CoreGraphics
import Foundation
import SSCore

/// Shape of one half of a keyframe glyph (Premiere): the left half reflects how the curve arrives at the key,
/// the right half how it leaves.
public enum KeyHalf: Sendable, Hashable {
    /// Half diamond.
    case linear
    /// Ease / bezier: half hourglass (triangle pointing at the centre).
    case eased
    /// Half square.
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
            let out: KeyHalf? = i + 1 < keys.count ? half(k.interpolation, handle: k.outHandle) : nil
            let inc: KeyHalf? = i > 0 ? half(keys[i - 1].interpolation, handle: k.inHandle) : nil
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

    /// Polygon of one half in glyph space, `h` = half size; the right half is returned, the left one mirrored in x.
    /// Points are (x, y) offsets from the glyph centre, y down.
    public static func polygon(_ half: KeyHalf, side: GlyphSide, h: CGFloat) -> [CGPoint] {
        let s: CGFloat = side == .right ? 1 : -1
        let pts: [CGPoint]
        switch half {
        case .linear: pts = [CGPoint(x: 0, y: -h), CGPoint(x: h, y: 0), CGPoint(x: 0, y: h)]
        case .eased: pts = [CGPoint(x: 0, y: 0), CGPoint(x: h, y: -h), CGPoint(x: h, y: h)]
        case .hold: pts = [CGPoint(x: 0, y: -h), CGPoint(x: h, y: -h), CGPoint(x: h, y: h), CGPoint(x: 0, y: h)]
        }
        return pts.map { CGPoint(x: $0.x * s, y: $0.y) }
    }

    /// Both halves as one outline around `c` (the two halves are drawn as two closed polygons).
    public func polygons(at c: CGPoint, h: CGFloat) -> [[CGPoint]] {
        [(incoming, GlyphSide.left), (outgoing, .right)].map { half, side in
            Self.polygon(half, side: side, h: h).map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) }
        }
    }
}

public enum GlyphSide: Sendable { case left, right }
