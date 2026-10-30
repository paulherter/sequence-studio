import Foundation
import SQCore
#if canImport(Accelerate)
import Accelerate
#endif

/// The clip-mask data of a draw (W6.7 masks, W9.8 subject mattes, Magic mattes, C6 Picture masks, color range masks): the
/// float2 entries the layer shaders read (`Shaders/Parts/Mask.slang`), shared by the Metal and the portable compositor.
extension Compositor {
    /// The matte each mask reads and the distinct ones (at most 4: one texture's channels). `slot` per mask: index into
    /// `distinct`, -1 = none.
    static func matteSlots(_ masks: [MaskShape], matte: SubjectMatte?, mattes: [UUID: SubjectMatte])
        -> (distinct: [SubjectMatte], slot: [Int]) {
        func source(_ m: MaskShape) -> SubjectMatte? {
            switch m.source {
            case .path: nil
            case .subject: matte
            case .magic: m.matteKey.flatMap { mattes[$0] }
            case .picture: nil      // C6: read from the level's matte images
            case .colorRange: nil   // v87: read from the picture's own pixel in the shader
            }
        }
        var distinct: [SubjectMatte] = []
        func storage(_ x: SubjectMatte) -> Int { x.values.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        var slot: [Int] = []
        for m in masks {
            guard let x = source(m) else { slot.append(-1); continue }
            if let i = distinct.firstIndex(where: { storage($0) == storage(x) && $0.width == x.width }) { slot.append(i) }
            else if distinct.count < 4 { distinct.append(x); slot.append(distinct.count - 1) }
            else { slot.append(-1) }
        }
        return (distinct, slot)
    }

    /// The mask data entries. Layout (float2 entries): per mask (start, count), (mode, inverted), (feather, expansion),
    /// (opacity, source); then all polygons' points (centered px of `frame`). `pictureSlot` / `matteSlot` per mask: the
    /// Picture image (0, 1) and matte channel it reads, -1 = none; `hasMatte`: the matte texture is bound.
    static func maskEntries(_ masks: [MaskShape], frame: SIMD2<Float>, edgeScale: Float, screen: ScreenMap?,
                            pictureSlot: [Int], matteSlot slot: [Int], hasMatte: Bool) -> [SIMD2<Float>] {
        let channelFlag: [Float] = [1, 3, 4, 5]
        var header: [SIMD2<Float>] = []
        var points: [SIMD2<Float>] = []
        header.reserveCapacity(masks.count * 4)
        let base = masks.count * 4
        for (k, m) in masks.enumerated() {
            let start = base + points.count
            if m.source == .colorRange {
                let c = m.colorRange
                points += [SIMD2(Float(c.red), Float(c.green)), SIMD2(Float(c.blue), Float(c.tolerance)),
                           SIMD2(Float(c.softness), 0)]
            } else if m.source == .picture {
                if pictureSlot[k] >= 0, let s = screen {
                    points += [s.row0, s.row1, s.translation, SIMD2(1 / max(s.canvas.x, 1), 1 / max(s.canvas.y, 1)),
                               s.center, SIMD2(s.tilt.x, s.tilt.y), SIMD2(s.tilt.z, 0)]
                }
            } else {
                for v in m.polygon {
                    points.append(SIMD2(Float(v.x), Float(v.y)) * frame - frame * 0.5)
                }
            }
            header.append(SIMD2(Float(start), m.source == .picture || m.source == .colorRange ? 0 : Float(m.polygon.count)))
            header.append(SIMD2(Float(Self.maskModeID(m.mode)), m.inverted ? 1 : 0))
            // Mattes come with their edge already applied (subject: shader-free; Magic: `MagicMatteStore`).
            header.append(SIMD2(Float(max(0, m.feather)) * edgeScale, Float(m.expansion) * edgeScale))
            let flag: Float
            if m.source == .colorRange {
                flag = 10
            } else if m.source == .picture {
                flag = pictureSlot[k] >= 0 ? Float(6 + 2 * pictureSlot[k] + (m.pictureChannel == .brightness ? 1 : 0)) : 2
            } else {
                flag = m.source == .path ? 0 : (slot[k] >= 0 && hasMatte ? channelFlag[slot[k]] : 2)
            }
            header.append(SIMD2(Float(min(max(m.opacity, 0), 1)), flag))
        }
        return header + points
    }

    /// C6: where a draw's px (centered, the fragment's `local`) land on the level's canvas: `row0` / `row1` / `translation`
    /// of the affine map and the canvas size.
    struct ScreenMap {
        var row0: SIMD2<Float>, row1: SIMD2<Float>, translation: SIMD2<Float>, canvas: SIMD2<Float>
        /// Perspective tilt of the draw (`Uniforms.tilt`: x / y radians, camera distance px; z = 0 flat). The affine part
        /// above gives the pre-tilt place; the shader turns its offset from `center` through the tilt.
        var tilt = SIMD3<Float>(0, 0, 0)
        var center = SIMD2<Float>(0, 0)

        /// The same map for a pass whose px are `factor` layer px (effect passes at reduced size).
        func scaled(_ factor: Float) -> ScreenMap {
            ScreenMap(row0: row0 * factor, row1: row1 * factor, translation: translation, canvas: canvas, tilt: tilt, center: center)
        }
    }

    /// The map of a final draw's uniforms, as `compositeVertex` places the layer: canvas / 2 + position + R * S * (local - anchor).
    static func screenFromLocal(_ u: Uniforms) -> ScreenMap {
        let c = u.rotCos, s = u.rotSin, sx = u.scale.x, sy = u.scale.y
        let row0 = SIMD2(c * sx, -s * sy), row1 = SIMD2(s * sx, c * sy)
        let t = u.canvas * 0.5 + u.position - SIMD2((row0 * u.anchor).sum(), (row1 * u.anchor).sum())
        return ScreenMap(row0: row0, row1: row1, translation: t, canvas: u.canvas, tilt: u.tilt, center: u.canvas * 0.5 + u.position)
    }

    /// `MaskCoverage.opacityMasks` (same rule: a Magic mask without its matte, or with a blank one, is left out), with the
    /// blank test as one vDSP max. `SubjectMatte.isBlank` scans pixel by pixel through a closure: on a 1920 px matte that is
    /// mostly background it cost 180 ms per drawn frame in a debug build.
    static func opacityMasks(_ masks: [MaskShape], mattes: [UUID: SubjectMatte]) -> [MaskShape] {
        guard masks.contains(where: { $0.source == .magic }) else { return masks }
        return masks.filter { m in
            guard m.source == .magic else { return true }
            guard let k = m.matteKey, let x = mattes[k] else { return false }
            return !isBlank(x)
        }
    }

    /// `SubjectMatte.isBlank`: no value reaches one 8-bit step.
    static func isBlank(_ m: SubjectMatte) -> Bool {
        var top: Float = 0
        #if canImport(Accelerate)
        m.values.withUnsafeBufferPointer { v in vDSP_maxv(v.baseAddress!, 1, &top, vDSP_Length(v.count)) }
        #else
        for v in m.values where v > top { top = v }
        #endif
        return !(top >= 0.5 / 255)
    }

    static func maskModeID(_ m: MaskMode) -> UInt32 {
        switch m {
        case .add: 0
        case .subtract: 1
        case .intersect: 2
        case .difference: 3
        }
    }
}
