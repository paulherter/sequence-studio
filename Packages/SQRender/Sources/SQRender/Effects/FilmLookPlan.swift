import Foundation
import SQCore

/// The film / tape look's kernel uniforms and Gate Weave placement (see `FilmLookPass.swift`), shared by the Metal and the
/// portable compositor.
extension Compositor {
    struct LookUniforms {
        var dims = SIMD4<Float>(0, 0, 1, 0)
        var ids = SIMD4<UInt32>(0, 0, 0, 0)
        var grain = SIMD4<Float>(0, 0, 0, 0)
        var scan = SIMD4<Float>(0, 0, 0, 0)
        var chroma = SIMD4<Float>(0, 0, 0, 0)
        var track = SIMD4<Float>(0, 0, 0, 0)
        var aged = SIMD4<Float>(0, 0, 0, 0)
    }

    static let lookFlagGrain: UInt32 = 1
    static let lookFlagScanlines: UInt32 = 8, lookFlagChroma: UInt32 = 16, lookFlagTracking: UInt32 = 32, lookFlagAged: UInt32 = 64

    /// Uniforms of the look kernel for a layer `width` x `height` px. `scale` = layer px per 1080-line px.
    static func lookUniforms(_ look: FilmLook, width: Int, height: Int) -> LookUniforms {
        var u = LookUniforms()
        let scale = Float(height) / 1080
        u.dims = SIMD4(Float(width), Float(height), scale, Float(look.grain?.color ?? 0))
        var flags: UInt32 = 0
        if let g = look.grain {
            flags |= lookFlagGrain
            u.grain = SIMD4(Float(g.amount), Float(g.size), Float(g.softness), Float(g.lumaWeight))
            u.ids.y = g.seed
        }
        if let a = look.aged {
            flags |= lookFlagAged
            u.aged = SIMD4(Float(a.dust), Float(a.scratches), Float(a.flicker), 0)
            u.ids.w = a.seed
        }
        if let s = look.scanlines {
            flags |= lookFlagScanlines
            u.scan = SIMD4(Float(s.intensity), Float(s.spacing), Float(s.thickness), 0)
        }
        if let c = look.chromaBleed {
            flags |= lookFlagChroma
            u.chroma = SIMD4(Float(c.bleed), Float(c.shift), 0, 0)
        }
        if let t = look.tracking {
            flags |= lookFlagTracking
            u.track = SIMD4(Float(t.amount), Float(t.bandHeight), Float(t.phase), 0)
            u.ids.z = t.seed
        }
        u.ids.x = flags
        return u
    }

    /// Gate Weave moves, turns and slightly enlarges the layer's final draw (canvas px; the offsets are 1080-line px).
    static func applyWeave(_ weave: GateWeave, to u: inout Uniforms) {
        let s = Double(u.canvas.y) / 1080
        u.position += SIMD2(Float(weave.offsetX * s), Float(weave.offsetY * s))
        let a = atan2(Double(u.rotSin), Double(u.rotCos)) + weave.rotation * .pi / 180
        u.rotCos = Float(cos(a)); u.rotSin = Float(sin(a))
        // Overscan relative to the layer as it appears on the canvas.
        let w = Double(u.size.x * u.scale.x), h = Double(u.size.y * u.scale.y)
        let k = Float(weave.overscan(width: w, height: h, scale: s))
        u.scale *= k
    }
}
