import Foundation
import SQCore
import SQGPU
import SQGPUKernels

extension Compositor {
    /// Mirrors `TemporalU` (48 bytes).
    struct TemporalUniforms {
        var count: UInt32 = 1, nBefore: UInt32 = 0, statsBefore: UInt32 = 0, flags: UInt32 = 0
        var lumaS: Float = 0, colorS: Float = 0, motion: Float = 1, keep: Float = 0
        var searchStep: Int32 = 1, searchCount: UInt32 = 1, tilesX: UInt32 = 1, tilesY: UInt32 = 1
    }
    /// Mirrors `DeflickerU` (32 bytes).
    struct DeflickerUniforms {
        var frames: UInt32 = 1, tiles: UInt32 = 1, dfBefore: UInt32 = 0, dfAfter: UInt32 = 0
        var statsBefore: UInt32 = 0, local: UInt32 = 0
        var strength: Float = 1, pad: Float = 0
    }
    /// Mirrors `SpatialU` (32 bytes).
    struct SpatialUniforms {
        var radius: Int32 = 1, step: Int32 = 1
        var lumaS: Float = 0, colorS: Float = 0
        var linearize: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }

    /// Mirrors `TrailsU` (48 bytes).
    struct TrailsUniforms {
        var count: UInt32 = 0, blend: UInt32 = 0, flags: UInt32 = 0, pad: UInt32 = 0
        var w0 = SIMD4<Float>(repeating: 0), w1 = SIMD4<Float>(repeating: 0)
    }
    /// Most echoes the trails kernel binds (+ the center in slot 0).
    static let trailSlots = 9

    /// Deflicker gain grid (Best: per tile; Fast uses the same tiles for its frame mean).
    static let deflickerTiles = (x: 16, y: 9)
    /// Most frames the denoise kernel binds (center + 5 each side).
    static let temporalSlots = 11

    /// Thresholds (encoded 0...1 units) of the temporal stage, from the effect's 0...1 controls.
    static func temporalThresholds(_ d: TemporalFilter.Denoise) -> (luma: Float, color: Float, motion: Float) {
        (d.luma > 0 ? Float(0.01 + d.luma * 0.15) : 0,
         d.color > 0 ? Float(0.01 + d.color * 0.15) : 0,
         Float(0.05 + d.motionLimit * 0.3))
    }
}

/// Deflicker, Video Denoise and Trails on the GPU protocol (SQGPU Shaders TemporalStats, DeflickerGains, TemporalDenoise,
/// SpatialDenoise, TemporalTrails), written once for the Metal `Compositor` and the `GPUCompositor`.
struct TemporalPasses<D: GPUDevice> {
    typealias Planes = (D.Texture, D.Texture)
    let stats: D.Pipeline, gains: D.Pipeline, denoise: D.Pipeline, spatial: D.Pipeline, trails: D.Pipeline

    init(device: D) throws {
        func make(_ m: GPUShaderModule) throws -> D.Pipeline { try device.makePipeline(GPUKernel(m, m.entries[0])) }
        stats = try make(GeneratedShaders.temporalStats); gains = try make(GeneratedShaders.deflickerGains)
        denoise = try make(GeneratedShaders.temporalDenoise); spatial = try make(GeneratedShaders.spatialDenoise)
        trails = try make(GeneratedShaders.temporalTrails)
    }

    /// How many neighbor frames `filter` reads before / after the center (nearest first).
    static func neighborLimits(_ filter: TemporalFilter) -> (before: Int, after: Int) {
        let dn = filter.denoise, df = filter.deflicker
        let wantA = max(dn?.isTemporal == true ? dn!.framesEachSide : 0, df?.framesEachSide ?? 0)
        // Trails read back in source order, or ahead for a backward (reversed) clip: the frames the viewer has seen.
        let back = filter.trails?.backward == true
        let trailReach = filter.trails?.reach ?? 0
        return (max(wantA, back ? 0 : trailReach), max(wantA, back ? trailReach : 0))
    }

    /// Runs the filter on the center planes (with its neighbor planes, same size and kind, nearest first) into an
    /// intermediate, then `grade` (the layer's color pipeline in place, false = failed; nil = the inverse BT.709 OETF in the kernels):
    /// straight working-linear color + alpha, drawn with `linearize = 0`. nil when nothing runs or anything fails.
    /// `buffer` hands out scratch buffers that live until the command buffer completes (the kernels write every byte they read).
    func run(_ filter: TemporalFilter, center: Planes, before: [Planes], after: [Planes], u: Compositor.Uniforms,
             width w: Int, height h: Int, _ cb: D.CommandBuffer, dummy: D.Texture, dummyBuffer: D.Buffer,
             acquire: (Int, Int) -> D.Texture?, buffer: (Int) -> D.Buffer?, grade: ((D.Texture) -> Bool)?) -> D.Texture? {
        let dn = filter.denoise, df = filter.deflicker
        let temporalDenoise = dn?.isTemporal == true
        let back = filter.trails?.backward == true
        let nB = temporalDenoise ? min(dn!.framesEachSide, before.count) : 0
        let nA = temporalDenoise ? min(dn!.framesEachSide, after.count) : 0
        let dfB = df.map { min($0.framesEachSide, before.count) } ?? 0
        let dfA = df.map { min($0.framesEachSide, after.count) } ?? 0
        let spatialOn = dn?.isSpatial == true
        // Trails: echo k is the frame `offsets[k]` back; the first one missing (clip start, not decoded yet, another size)
        // ends the list, so a reduced-size center only ever blends reduced-size echoes.
        var echoes: [Planes] = [], weights: [Float] = []
        if let tr = filter.trails {
            for (o, wt) in zip(tr.offsets, tr.weights) {
                let seen = back ? after : before
                guard o - 1 < seen.count else { break }
                echoes.append(seen[o - 1]); weights.append(Float(wt))
            }
        }
        let trailsOn = !echoes.isEmpty
        let prepass = nB + nA > 0 || df != nil || spatialOn
        guard prepass || trailsOn else { return nil }

        guard let mid = acquire(w, h) else { return nil }
        var out = mid
        var cu = u

        // 1. Deflicker: tile means of every frame used, then the gains.
        var t = Compositor.TemporalUniforms()
        let statsBefore = df != nil ? max(nB, dfB) : nB
        let statsAfter = df != nil ? max(nA, dfA) : nA
        var gainBuffer = dummyBuffer
        let tilesX = Compositor.deflickerTiles.x, tilesY = Compositor.deflickerTiles.y
        if let df {
            let tiles = tilesX * tilesY
            let statFrames = [center] + Array(before.prefix(statsBefore)) + Array(after.prefix(statsAfter))
            guard let means = buffer(statFrames.count * tiles * 4), let gainsBuf = buffer(statFrames.count * tiles * 4),
                  let enc = cb.makeComputeEncoder() else { return nil }
            enc.setPipeline(stats)
            withUnsafeBytes(of: &cu) { enc.setConstantBytes($0, slot: 0) }
            enc.setBuffer(means, at: 2)
            for (j, f) in statFrames.enumerated() {
                let p = SIMD4<UInt32>(UInt32(j), UInt32(tilesX), UInt32(tilesY), 0)
                enc.setInput(f.0, at: 0); enc.setInput(f.1, at: 1)
                withUnsafeBytes(of: p) { enc.setConstantBytes($0, slot: 1) }
                // One 16 x 16 group per tile.
                enc.dispatch(width: tilesX * 16, height: tilesY * 16)
            }
            let d = Compositor.DeflickerUniforms(frames: UInt32(statFrames.count), tiles: UInt32(tiles), dfBefore: UInt32(dfB),
                                                 dfAfter: UInt32(dfA), statsBefore: UInt32(statsBefore), local: df.local ? 1 : 0,
                                                 strength: Float(df.strength))
            enc.setPipeline(gains)
            enc.setBuffer(means, at: 2); enc.setBuffer(gainsBuf, at: 3)
            withUnsafeBytes(of: d) { enc.setConstantBytes($0, slot: 0) }
            enc.dispatch(width: tiles, height: 1)
            enc.end()
            gainBuffer = gainsBuf
            t.flags |= 2
            t.tilesX = UInt32(tilesX); t.tilesY = UInt32(tilesY)
        }

        // 2. Temporal denoise (+ deflicker gain) of the center into `mid`, straight encoded color (or linear when it is last).
        t.count = UInt32(1 + nB + nA); t.nBefore = UInt32(nB); t.statsBefore = UInt32(statsBefore)
        if let dn, nB + nA > 0 {
            t.flags |= 1
            let th = Compositor.temporalThresholds(dn)
            t.lumaS = th.luma; t.colorS = th.color; t.motion = th.motion; t.keep = Float(dn.keepOriginal)
            if dn.best {
                t.flags |= 4
                let unit = max(1, Int((Double(h) / 1080).rounded()))
                switch dn.motionSearch {
                case 0: t.searchCount = 1
                case 1: t.searchCount = 5; t.searchStep = Int32(2 * unit)
                default: t.searchCount = 9; t.searchStep = Int32(4 * unit)
                }
            }
        }
        if !spatialOn && grade == nil && !trailsOn { t.flags |= 8 }
        guard let enc = cb.makeComputeEncoder() else { return nil }
        if prepass {
            enc.setPipeline(denoise)
            let slots = [center] + Array(before.prefix(nB)) + Array(after.prefix(nA))
            for i in 0..<Compositor.temporalSlots {
                let f = i < slots.count ? slots[i] : (dummy, dummy)
                enc.setInput(f.0, at: i); enc.setInput(f.1, at: Compositor.temporalSlots + i)
            }
            enc.setOutput(mid)
            withUnsafeBytes(of: &cu) { enc.setConstantBytes($0, slot: 0) }
            withUnsafeBytes(of: &t) { enc.setConstantBytes($0, slot: 1) }
            enc.setBuffer(gainBuffer, at: 3)
            enc.dispatch(width: w, height: h)

            // 3. Spatial smoothing.
            if let dn, spatialOn {
                guard let sp = acquire(w, h) else { enc.end(); return nil }
                let s = max(1, Int((Double(h) / 1080).rounded()))
                var su = Compositor.SpatialUniforms()
                switch dn.detailSize {
                case 1: su.radius = 1; su.step = Int32(s)
                case 2: su.radius = 2; su.step = Int32(s)
                default: su.radius = 2; su.step = Int32(2 * s)
                }
                su.lumaS = dn.spatialLuma > 0 ? Float(0.004 + dn.spatialLuma * 0.06) : 0
                su.colorS = dn.spatialColor > 0 ? Float(0.004 + dn.spatialColor * 0.08) : 0
                su.linearize = grade == nil && !trailsOn ? 1 : 0
                enc.setPipeline(spatial)
                enc.setInput(mid, at: 0); enc.setOutput(sp)
                withUnsafeBytes(of: &su) { enc.setConstantBytes($0, slot: 0) }
                enc.dispatch(width: w, height: h)
                out = sp
            }
        }

        // 3b. Trails over the (filtered) center.
        if trailsOn {
            var tu = Compositor.TrailsUniforms(count: UInt32(echoes.count), blend: UInt32(filter.trails!.blend.rawValue),
                                               flags: (prepass ? 1 : 0) | (grade == nil ? 2 : 0))
            for (k, wt) in weights.enumerated() { if k < 4 { tu.w0[k] = wt } else { tu.w1[k - 4] = wt } }
            let dst: D.Texture
            if prepass {
                guard let tt = acquire(w, h) else { enc.end(); return nil }
                dst = tt
            } else {
                dst = mid
            }
            enc.setPipeline(trails)
            let slots = [center] + echoes
            for i in 0..<Compositor.trailSlots {
                let f = i < slots.count ? slots[i] : (dummy, dummy)
                enc.setInput(f.0, at: i); enc.setInput(f.1, at: Compositor.trailSlots + i)
            }
            enc.setInput(prepass ? out : dummy, at: 2 * Compositor.trailSlots)
            enc.setOutput(dst)
            withUnsafeBytes(of: &cu) { enc.setConstantBytes($0, slot: 0) }
            withUnsafeBytes(of: &tu) { enc.setConstantBytes($0, slot: 1) }
            enc.dispatch(width: w, height: h)
            out = dst
        }
        enc.end()

        // 4. The layer's color pipeline on the filtered picture.
        if let grade, !grade(out) { return nil }
        return out
    }
}
