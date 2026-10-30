import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

/// FB-T2 style filters (Vignette, Film Grain, RGB Split, Radial Blur, Flip, Invert, Posterize, Tint, Brightness &
/// Contrast, Twirl, Wave Warp, Spherize, Strobe Light, Alpha Adjust). Four kernel families: per-pixel color ops, warps
/// (one bilinear tap at a moved position), RGB Split and Radial Blur. `plan` turns a filter into one family plus uniforms;
/// the CPU references below read the same uniforms with the same maths, so preview, export and reference agree.
/// Color ops run on display-encoded (BT.709 OETF), un-premultiplied values like Premiere's 8-bit effects.
public enum StyleFilters {
    public enum Family: Sendable { case pixel, warp, rgbSplit, radialBlur, lens, glitch }

    // Op codes (uniform i.w) of the pixel and warp families; mirrored in the kernels.
    static let opVignette: Int32 = 1, opInvert: Int32 = 3, opPosterize: Int32 = 4, opTint: Int32 = 5
    static let opBrightness: Int32 = 6, opStrobe: Int32 = 7, opAlpha: Int32 = 8, opLeak: Int32 = 9, opGradient: Int32 = 10
    static let opFlip: Int32 = 20, opTwirl: Int32 = 21, opWave: Int32 = 22, opSpherize: Int32 = 23, opStage: Int32 = 24
    static let opHalftone: Int32 = 11, opTile: Int32 = 25, opKaleido: Int32 = 26, opFeather: Int32 = 12
    static let opRolling: Int32 = 27, opCorner: Int32 = 28, opStageFill: Int32 = 29

    /// Taps of a Radial Blur: about one per px of the longest smear (half at Low quality), 2...256.
    static func radialTaps(_ smear: Float, high: Bool) -> Int32 {
        Int32(min(256, max(2, Int((smear * (high ? 1 : 0.5)).rounded(.up)) + 1)))
    }

    /// The family and uniforms for `f` on a picture `frame` (texture px) where one texture px is `pf` clip px; nil for a
    /// filter that is not a style filter.
    static func plan(_ f: ImageFilter, frame: ImageFilters.Frame, pf: Double) -> (Family, ImageFilters.Uniforms)? {
        var u = ImageFilters.Uniforms(center: frame.center, frame: frame.size)
        let p = Float(pf)
        func tex(_ v: Vec2) -> SIMD2<Float> { frame.center + SIMD2(Float(v.x), Float(v.y)) / p }
        func f3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        /// Longest distance from `c` to a corner of the picture.
        func reach(_ c: SIMD2<Float>) -> Float {
            let o = frame.origin, e = frame.origin + frame.size
            return [o, SIMD2(e.x, o.y), SIMD2(o.x, e.y), e].map { simd_length($0 - c) }.max() ?? 0
        }
        switch f {
        case .vignette(let amount, let mid, let round, let feather):
            u.a = SIMD4(Float(amount), Float(mid), Float(round), Float(feather)); u.i.w = opVignette
            return (.pixel, u)
        case .invert(let channel, let blend):
            u.a.x = Float(blend); u.i.x = Int32(channel); u.i.w = opInvert
            return (.pixel, u)
        case .posterize(let levels):
            u.a.x = Float(max(levels, 2)); u.i.w = opPosterize
            return (.pixel, u)
        case .tint(let black, let white, let amount):
            u.a = SIMD4(f3(black), Float(amount)); u.b = SIMD4(f3(white), 0); u.i.w = opTint
            return (.pixel, u)
        case .brightnessContrast(let b, let c):
            u.a = SIMD4(Float(b), Float(tan((min(c, 1) * 0.98 + 1) * .pi / 4)), 0, 0); u.i.w = opBrightness
            return (.pixel, u)
        case .strobe(let color, let blend, let op, let transparent):
            u.a = SIMD4(f3(color), Float(blend)); u.i.x = Int32(op); u.i.y = transparent ? 1 : 0; u.i.w = opStrobe
            return (.pixel, u)
        case .alphaAdjust(let opacity, let ignore, let invert, let maskOnly):
            u.a.x = Float(opacity); u.i = SIMD4(ignore ? 1 : 0, invert ? 1 : 0, maskOnly ? 1 : 0, opAlpha)
            return (.pixel, u)
        case .flip(let h, let v):
            u.i = SIMD4(h ? 1 : 0, v ? 1 : 0, 0, opFlip)
            return (.warp, u)
        case .twirl(let c, let angle, let radius):
            u.center = tex(c)
            u.a = SIMD4(Float(angle * .pi / 180), Float(radius) * max(frame.size.x, frame.size.y), 0, 0); u.i.w = opTwirl
            return (.warp, u)
        case .waveWarp(let type, let height, let width, let direction, let phase, let pinning):
            let a = direction * .pi / 180
            u.a = SIMD4(Float(height) / p, Float(max(width, 1e-3)) / p, Float(sin(a)), Float(-cos(a)))
            u.b.x = Float(phase); u.i = SIMD4(Int32(type), Int32(pinning), 0, opWave)
            return (.warp, u)
        case .spherize(let c, let radius, let strength):
            u.center = tex(c); u.a = SIMD4(Float(radius) / p, Float(strength), 0, 0); u.i.w = opSpherize
            return (.warp, u)
        case .stageWarp(let a, let b, let c, let d, let tx, let ty, let opacity):
            // Masked Transform: source = center + M (q - center) + t / pf, times opacity (b.z).
            u.a = SIMD4(Float(a), Float(b), Float(c), Float(d)); u.b = SIMD4(Float(tx) / p, Float(ty) / p, Float(opacity), 0)
            u.i.w = opStage
            return (.warp, u)
        case .stageFill(let a, let b, let c, let d, let tx, let ty, let fill):
            // The Stabilizer's correction with a filled border: opStage's map, then a read outside the clip's frame is folded
            // back over its edge (i.x = 1 mirror, 2 mirror and blur wide, see `filterStyleWarp`).
            u.a = SIMD4(Float(a), Float(b), Float(c), Float(d)); u.b = SIMD4(Float(tx) / p, Float(ty) / p, 1, 0)
            u.i = SIMD4(fill == .blur ? 2 : 1, 0, 0, opStageFill)
            return (.warp, u)
        case .rollingShutter(let shear, let alongX):
            // Rows shifted back: a.xy = the shear in texture px across the scan extent (a.z), i.x = scan along x.
            let extent = alongX ? frame.size.x : frame.size.y
            u.a = SIMD4(Float(shear.x) * extent, Float(shear.y) * extent, extent, 0)
            u.i = SIMD4(alongX ? 1 : 0, 0, 0, opRolling)
            return (.warp, u)
        case .stabilizeWarp(let shear, let alongX, let perspective):
            // The Rolling Shutter warp, with the residual perspective read first: c, d = the inverse of (I + perspective) in
            // texture px about the frame center (m00 m01 m02 m10 | m11 m12 m20 m21, m22 = 1), i.y = 1. A singular map
            // leaves the perspective out.
            let extent = alongX ? frame.size.x : frame.size.y
            u.a = SIMD4(Float(shear.x) * extent, Float(shear.y) * extent, extent, 0)
            u.i = SIMD4(alongX ? 1 : 0, 0, 0, opRolling)
            if let m = perspectiveInverse(perspective, pf: pf) {
                u.c = SIMD4(Float(m[0]), Float(m[1]), Float(m[2]), Float(m[3]))
                u.d = SIMD4(Float(m[4]), Float(m[5]), Float(m[6]), Float(m[7]))
                u.i.y = 1
            }
            return (.warp, u)
        case .cornerPin(let tl, let tr, let br, let bl):
            // Inverse homography (output -> picture) about the frame center, h33 = 1: a = (h11, h12, h13, h21),
            // b = (h22, h23, h31, h32). i.x = 1: the quadrilateral is degenerate, the result is empty.
            let hw = Double(frame.size.x) / 2, hh = Double(frame.size.y) / 2, k = 1 / pf
            let src = [SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh)]
            let dst = zip(src, [tl, tr, br, bl]).map { SIMD2($0.0.x + $0.1.x * k, $0.0.y + $0.1.y * k) }
            if let h = homography(from: dst, to: src) {
                u.a = SIMD4(Float(h[0]), Float(h[1]), Float(h[2]), Float(h[3]))
                u.b = SIMD4(Float(h[4]), Float(h[5]), Float(h[6]), Float(h[7]))
            } else {
                u.i.x = 1
            }
            u.i.w = opCorner
            return (.warp, u)
        case .rgbSplit(let dx, let dy, let radial, let mix):
            u.a = SIMD4(Float(dx) / p, Float(dy) / p, Float(mix), simd_length(frame.size) / 2); u.i.x = radial ? 1 : 0
            return (.rgbSplit, u)
        case .radialBlur(let c, let amount, let zoom, let high):
            u.center = tex(c)
            let r = reach(u.center)
            let smear = zoom ? Float(amount / 100) * r : Float(amount * .pi / 180) * r
            u.a.x = zoom ? Float(amount / 100) : Float(amount * .pi / 180)
            u.i = SIMD4(zoom ? 1 : 0, radialTaps(smear, high: high), 0, 0)
            return (.radialBlur, u)
        case .lensDistortion(let curvature, let decenter, let fillAlpha, let fill, let autoScale, let exactModel):
            // a = (k, half diagonal px, frame origin); b = fill (premultiplied working-linear, opaque) or zero = transparent;
            // i.x = the zoom about the lens center (Float bits; 1 unless Auto Scale), i.z = 1: the exact model (F7.15),
            // 0: the look of effects saved before it (one bilinear tap, pincushion as 1 / (1 + a r^2)). Auto Scale needs
            // the exact model.
            let exact = exactModel || autoScale
            u.center = frame.center + SIMD2(Float(decenter.x), Float(decenter.y)) * frame.size / 2
            u.a = SIMD4(Float(-curvature * 0.6), simd_length(frame.size) / 2, frame.origin.x, frame.origin.y)
            if !fillAlpha { u.b = SIMD4(dec(Float(fill.x)), dec(Float(fill.y)), dec(Float(fill.z)), 1) }
            u.i.x = Int32(bitPattern: (autoScale ? lensAutoZoom(u) : Float(1)).bitPattern); u.i.y = autoScale ? 1 : 0
            u.i.z = exact ? 1 : 0
            return (.lens, u)
        case .halftone(let size, let angle, let softness, let color, let blend):
            // center = frame center (the screen turns around it), a = (pitch px, angle rad, softness, blend), i.x = color mode.
            u.a = SIMD4(Float(max(size, 0.5)) / p, Float(angle * .pi / 180), Float(softness), Float(blend))
            u.i.x = color ? 1 : 0; u.i.w = opHalftone
            return (.pixel, u)
        case .tile(let columns, let rows, let offset, let mirror):
            u.a = SIMD4(Float(columns), Float(rows), Float(offset.x), Float(offset.y)); u.b.x = mirror ? 1 : 0; u.i.w = opTile
            return (.warp, u)
        case .kaleidoscope(let c, let segments, let angle, let zoom):
            u.center = tex(c)
            u.a = SIMD4(Float(2 * Double.pi / Double(max(segments, 2))), Float(angle * .pi / 180), Float(1 / max(zoom, 0.01)), 0)
            u.i.w = opKaleido
            return (.warp, u)
        case .edgeFeather(let amount):
            // center + frame give the picture's rectangle; a.x = feather width in texture px.
            u.a.x = Float(max(amount, 0.001)) / p; u.i.w = opFeather
            return (.pixel, u)
        case .glitch(let amount, let block, let split, let density, let seed):
            // a = (max shift px, band height px, chroma split px, density), i.x = seed.
            u.a = SIMD4(Float(amount) / p, Float(max(block, 1)) / p, Float(split) / p, Float(density))
            u.i.x = Int32(truncatingIfNeeded: seed)
            return (.glitch, u)
        case .lightLeak(let c1, let c2, let intensity, let c, let size, let angle):
            // center = the leak's center px, frame = gradient direction, a = (color 1, intensity), b = (color 2, radius px).
            u.center = frame.center + SIMD2(Float(c.x), Float(c.y)) * frame.size / 2
            u.frame = SIMD2(Float(cos(angle)), Float(sin(angle)))
            u.a = SIMD4(f3(c1), Float(intensity)); u.b = SIMD4(f3(c2), max(Float(size) * simd_length(frame.size), 1e-3))
            u.i.w = opLeak
            return (.pixel, u)
        case .gradient(let c1, let c2, let start, let end, let radial, let blend):
            // center = start px, frame = (end - start) px, a = (color 1, blend), b = (color 2, 0), i.x = radial.
            u.center = tex(start)
            u.frame = SIMD2(Float(end.x - start.x), Float(end.y - start.y)) / p
            u.a = SIMD4(f3(c1), Float(blend)); u.b = SIMD4(f3(c2), 0); u.i.x = radial ? 1 : 0; u.i.w = opGradient
            return (.pixel, u)
        default:
            return nil
        }
    }

    // MARK: Shared maths (mirrored line by line in `msl`)

    /// The 3 x 3 projective map (h33 = 1, returned as h11 h12 h13 h21 h22 h23 h31 h32) that takes each `from[i]` to
    /// `to[i]`; nil when the four points are degenerate (collinear or collapsed).
    static func homography(from: [SIMD2<Double>], to: [SIMD2<Double>]) -> [Double]? {
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (from[i].x, from[i].y), (X, Y) = (to[i].x, to[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -x * X, -y * X, X]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -x * Y, -y * Y, Y]
        }
        for c in 0..<8 {
            var piv = c
            for r in c..<8 where abs(m[r][c]) > abs(m[piv][c]) { piv = r }
            guard abs(m[piv][c]) > 1e-9 else { return nil }
            m.swapAt(c, piv)
            for r in 0..<8 where r != c {
                let f = m[r][c] / m[c][c]
                if f != 0 { for k in c...8 { m[r][k] -= f * m[c][k] } }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] }
    }

    /// The inverse of the map (I + `v`) of a Stabilizer perspective correction (`PerspectiveResidual.values`, clip px about the
    /// center) in texture px (`pf` clip px per texture px), scaled so m22 = 1; nil when singular. Row-major without m22.
    static func perspectiveInverse(_ v: [Double], pf: Double) -> [Double]? {
        guard v.count == 8, v.contains(where: { $0 != 0 }) else { return nil }
        let a = [1 + v[0], v[1], v[2], v[3], 1 + v[4], v[5], v[6], v[7], 1]
        let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-12 else { return nil }
        let inv = [c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                   c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                   c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]].map { $0 / det }
        // Conjugate with the clip <- texture scale diag(pf, pf, 1): the shifts shrink, the perspective terms grow.
        var m = [inv[0], inv[1], inv[2] / pf, inv[3], inv[4], inv[5] / pf, inv[6] * pf, inv[7] * pf, inv[8]]
        guard abs(m[8]) > 1e-12 else { return nil }
        m = m.map { $0 / m[8] }
        return m.allSatisfy(\.isFinite) ? Array(m[0..<8]) : nil
    }

    /// Corner Warp: where the picture is read from at `q`; far outside (transparent) behind the vanishing line or when
    /// the quadrilateral is degenerate.
    static func cornerSource(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD2<Float> {
        let far = SIMD2<Float>(-1e6, -1e6)
        guard u.i.x == 0 else { return far }
        let d = q - u.center
        let den = u.b.z * d.x + u.b.w * d.y + 1
        guard den > 1e-6 else { return far }
        return u.center + SIMD2((u.a.x * d.x + u.a.y * d.y + u.a.z) / den, (u.a.w * d.x + u.b.x * d.y + u.b.y) / den)
    }

    static func enc(_ x: Float) -> Float {
        let v = max(x, 0)
        return v < 0.018053968 ? v * 4.5 : 1.09929682680944 * powf(v, 0.45) - 0.09929682680944
    }
    static func dec(_ e: Float) -> Float {
        let v = max(e, 0)
        return v < 0.081242858 ? v / 4.5 : powf((v + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
    }
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Vignette falloff 0 (center) ... 1 (edge) at texture position `q`.
    static func vignetteFalloff(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> Float {
        let d = q - u.center
        let e = d / (u.frame * 0.5)
        let circle = d / (sqrtf(u.frame.x * u.frame.y) * 0.5)
        let r: Float
        if u.a.z >= 0 {
            r = simd_length(e + (circle - e) * u.a.z)
        } else {
            let n = 2 + 8 * -u.a.z
            r = powf(powf(abs(e.x), n) + powf(abs(e.y), n), 1 / n)
        }
        let m = 0.35 + 0.9 * u.a.y, w = 0.05 + 0.6 * u.a.w
        return smoothstep(m - w, m + w, r)
    }

    /// Per-pixel family: `p` premultiplied working-linear at texture position `q`.
    static func pixel(_ p: SIMD4<Float>, _ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD4<Float> {
        let op = u.i.w
        if op == opVignette && u.a.x < 0 {
            let k = exp2f(u.a.x * vignetteFalloff(q, u))
            return SIMD4(p.x * k, p.y * k, p.z * k, p.w)
        }
        if op == opFeather {
            let o = u.center - u.frame * 0.5
            let d = min(min(q.x - o.x, o.x + u.frame.x - q.x), min(q.y - o.y, o.y + u.frame.y - q.y))
            return p * smoothstep(0, u.a.x, max(d, 0))
        }
        if op == opAlpha {
            let c = p.w > 0 ? SIMD3(p.x, p.y, p.z) / p.w : .zero
            var a = u.i.x != 0 ? 1 : p.w
            if u.i.y != 0 { a = 1 - a }
            a *= u.a.x
            let col = u.i.z != 0 ? SIMD3<Float>(1, 1, 1) : c
            return SIMD4(col * a, a)
        }
        if op == opStrobe && u.i.y != 0 { return p * u.a.w }
        if op == opInvert && u.i.x == 4 {
            let a = p.w + ((1 - p.w) - p.w) * (1 - u.a.x)
            let c = p.w > 0 ? SIMD3(p.x, p.y, p.z) / p.w : .zero
            return SIMD4(c * a, a)
        }
        guard p.w > 0 else { return p }
        let lin = SIMD3(p.x, p.y, p.z) / p.w
        let e = SIMD3(enc(lin.x), enc(lin.y), enc(lin.z))
        var o = e
        switch op {
        case opVignette:
            let f = vignetteFalloff(q, u), k = exp2f(-u.a.x * f)
            o = SIMD3<Float>(1, 1, 1) - (SIMD3<Float>(1, 1, 1) - simd_min(e, SIMD3(repeating: 1))) * k
            o = simd_max(o, e)
        case opInvert:
            var inv = e
            let ce = simd_clamp(e, SIMD3(repeating: 0), SIMD3(repeating: 1))
            if u.i.x == 0 { inv = SIMD3<Float>(1, 1, 1) - ce } else { inv[Int(u.i.x) - 1] = 1 - ce[Int(u.i.x) - 1] }
            o = inv + (e - inv) * u.a.x
        case opPosterize:
            let l = u.a.x - 1
            let ce = simd_clamp(e, SIMD3(repeating: 0), SIMD3(repeating: 1))
            o = SIMD3((ce.x * l).rounded(), (ce.y * l).rounded(), (ce.z * l).rounded()) / l
        case opTint:
            let y = min(max(simd_dot(e, lumaWeights), 0), 1)
            let black = SIMD3(u.a.x, u.a.y, u.a.z), white = SIMD3(u.b.x, u.b.y, u.b.z)
            let target = black + (white - black) * y
            o = e + (target - e) * u.a.w
        case opBrightness:
            o = (e - 0.5) * u.a.y + 0.5 + u.a.x * 0.4
        case opLeak:
            let d = (q - u.center) / u.b.w
            let g = u.a.w * expf(-2 * simd_dot(d, d))
            let t = min(max(0.5 + 0.5 * simd_dot(d, u.frame), 0), 1)
            let c1 = SIMD3(u.a.x, u.a.y, u.a.z), c2 = SIMD3(u.b.x, u.b.y, u.b.z)
            let light = simd_min((c1 + (c2 - c1) * t) * g, SIMD3(repeating: 1))
            o = e + light * simd_max(SIMD3<Float>(1, 1, 1) - e, .zero)
        case opGradient:
            let d = q - u.center, len2 = simd_dot(u.frame, u.frame)
            var t: Float = 0
            if len2 > 1e-12 { t = u.i.x != 0 ? simd_length(d) / len2.squareRoot() : simd_dot(d, u.frame) / len2 }
            t = min(max(t, 0), 1)
            let c1 = SIMD3(u.a.x, u.a.y, u.a.z), c2 = SIMD3(u.b.x, u.b.y, u.b.z)
            o = e + ((c1 + (c2 - c1) * t) - e) * u.a.w
        case opHalftone:
            let y = min(max(simd_dot(e, lumaWeights), 0), 1)
            let m = halftoneCoverage(q, y, u)
            let target: SIMD3<Float> = u.i.x != 0 ? e * m : SIMD3(repeating: m)
            o = e + (target - e) * u.a.w
        case opStrobe:
            let s = SIMD3(u.a.x, u.a.y, u.a.z)
            var r = s
            switch u.i.x {
            case 1: r = e + s
            case 2: r = e * s
            case 3: r = SIMD3<Float>(1, 1, 1) - (SIMD3<Float>(1, 1, 1) - e) * (SIMD3<Float>(1, 1, 1) - s)
            case 4: r = simd_abs(e - s)
            default: break
            }
            o = r + (e - r) * u.a.w
        default:
            return p
        }
        return SIMD4(dec(o.x) * p.w, dec(o.y) * p.w, dec(o.z) * p.w, p.w)
    }

    /// Halftone: how much light a pixel of luma `y` lets through at texture position `q` (1 = paper / full color).
    static func halftoneCoverage(_ q: SIMD2<Float>, _ y: Float, _ u: ImageFilters.Uniforms) -> Float {
        let d = q - u.center, c = cosf(u.a.y), s = sinf(u.a.y)
        let r = SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y) / u.a.x
        let f = r - SIMD2(floorf(r.x), floorf(r.y)) - SIMD2(0.5, 0.5)
        let rn = simd_length(f) / 0.70710678
        let soft = 0.02 + 0.3 * u.a.z
        let colour = u.i.x != 0
        let rho = sqrtf(colour ? y : 1 - y) * (1 + 2 * soft) - soft
        let edge = smoothstep(rho - soft, rho + soft, rn)
        return colour ? 1 - edge : edge
    }

    static func wave(_ x: Float, _ type: Int32) -> Float {
        switch type {
        case 1: return x - floorf(x) < 0.5 ? 1 : -1
        case 2: let f = x - 0.25 - floorf(x - 0.25); return 4 * abs(f - 0.5) - 1
        case 3: let f = x + 0.5 - floorf(x + 0.5); return 2 * f - 1
        default: return sinf(2 * .pi * x)
        }
    }

    /// Warp family: where the picture at texture position `q` is read from.
    static func warpSource(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD2<Float> {
        switch u.i.w {
        case opFlip:
            return SIMD2(u.i.x != 0 ? 2 * u.center.x - q.x : q.x, u.i.y != 0 ? 2 * u.center.y - q.y : q.y)
        case opTwirl:
            let d = q - u.center, r = simd_length(d), big = u.a.y
            guard r < big, big > 0 else { return q }
            let k = 1 - r / big, th = -u.a.x * k * k
            let c = cosf(th), s = sinf(th)
            return u.center + SIMD2(c * d.x - s * d.y, s * d.x + c * d.y)
        case opWave:
            let o = u.center - u.frame * 0.5
            let dir = SIMD2(u.a.z, u.a.w), across = SIMD2(-u.a.w, u.a.z)
            let x = simd_dot(q - o, dir) / u.a.y + u.b.x
            var pin: Float = 1
            let n = (q - o) / u.frame
            let ex = smoothstep(0, 0.1, min(n.x, 1 - n.x)), ey = smoothstep(0, 0.1, min(n.y, 1 - n.y))
            switch u.i.y {
            case 1: pin = ex * ey
            case 2: pin = ey
            case 3: pin = ex
            default: break
            }
            return q - across * (u.a.x * wave(x, u.i.x) * pin)
        case opSpherize:
            let d = q - u.center, r = simd_length(d), big = u.a.x
            guard r < big, r > 0 else { return q }
            let n = r / big, s = u.a.y
            let f = s > 0 ? n + (2 / .pi * asinf(n) - n) * s : n + (sinf(n * .pi / 2) - n) * -s
            return u.center + d * (f / n)
        case opTile:
            let o = u.center - u.frame * 0.5
            let t = (q - o) / u.frame * SIMD2(u.a.x, u.a.y) + SIMD2(u.a.z, u.a.w)
            var f = t - SIMD2(floorf(t.x), floorf(t.y))
            if u.b.x != 0 {
                func fold(_ v: Float) -> Float { let m = v - 2 * floorf(v / 2); return m > 1 ? 2 - m : m }
                f = SIMD2(fold(t.x), fold(t.y))
            }
            return o + f * u.frame
        case opKaleido:
            let d = q - u.center, r = simd_length(d)
            guard r > 0 else { return q }
            let w = u.a.x, th = atan2f(d.y, d.x)
            let m = th - w * floorf(th / w)
            let a = abs(m - w / 2) + u.a.y
            return u.center + r * u.a.z * SIMD2(cosf(a), sinf(a))
        case opStage:
            let d = q - u.center
            return u.center + SIMD2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + SIMD2(u.b.x, u.b.y)
        case opCorner:
            return cornerSource(q, u)
        case opStageFill:
            let d = q - u.center
            return foldIntoFrame(u.center + SIMD2(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + SIMD2(u.b.x, u.b.y), u)
        case opRolling:
            var q = q
            if u.i.y != 0 {     // residual perspective first (Stabilizer warp)
                let d = q - u.center
                let den = u.d.z * d.x + u.d.w * d.y + 1
                guard den > 1e-6 else { return SIMD2(-1e6, -1e6) }
                q = u.center + SIMD2((u.c.x * d.x + u.c.y * d.y + u.c.z) / den, (u.c.w * d.x + u.d.x * d.y + u.d.y) / den)
            }
            // The ideal point q was recorded at r = q + s * v with v the scan position of r itself (-0.5 ... 0.5), so
            // v = v(q) / (1 - s_scan / extent). The picture edge is held: no empty sliver where a row was shifted out.
            let s = SIMD2(u.a.x, u.a.y), ext = max(u.a.z, 1), alongX = u.i.x != 0
            let v0 = (alongX ? q.x - u.center.x : q.y - u.center.y) / ext
            let v = v0 / max(1 - (alongX ? s.x : s.y) / ext, 0.5)
            let lo = u.center - u.frame * 0.5 + SIMD2<Float>(0.5, 0.5), hi = u.center + u.frame * 0.5 - SIMD2<Float>(0.5, 0.5)
            return simd_min(simd_max(q + s * v, lo), simd_max(lo, hi))
        default:
            return q
        }
    }
    /// `s` mirrored back into the clip's frame (reflected over each edge, repeating): the mirror-repeat addressing of Edge Fill.
    static func foldIntoFrame(_ s: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD2<Float> {
        let lo = u.center - u.frame * 0.5
        func fold(_ v: Float) -> Float { let m = v - 2 * floorf(v / 2); return m > 1 ? 2 - m : m }
        let t = (s - lo) / u.frame
        // Held half a texel inside the frame: a read right at the fold line would blend with the transparent outside.
        let hi = lo + u.frame - SIMD2<Float>(0.5, 0.5)
        return simd_min(simd_max(lo + SIMD2(fold(t.x), fold(t.y)) * u.frame, lo + SIMD2<Float>(0.5, 0.5)), simd_max(lo + SIMD2<Float>(0.5, 0.5), hi))
    }
    /// What a warp multiplies its tap by (a stage's opacity; 1 for the others).
    static func warpGain(_ u: ImageFilters.Uniforms) -> Float { u.i.w == opStage ? u.b.z : 1 }
    /// True where a warp leaves the texel as it is: the Rolling Shutter pass outside the clip's own frame (the working
    /// texture is larger than the frame when a Drop Shadow, Glow or blur sits above; that margin is not picture).
    static func warpPassesThrough(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> Bool {
        guard u.i.w == opRolling || u.i.w == opStageFill else { return false }
        let d = simd_abs(q - u.center)
        return d.x > u.frame.x * 0.5 || d.y > u.frame.y * 0.5
    }

    /// Lens Distortion as saved before F7.15 (no `lensModel` key): where the picture at `q` is read from.
    static func lensLegacySource(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD2<Float> {
        let d = q - u.center, r = simd_length(d) / u.a.y, k = u.a.x
        let f = k >= 0 ? 1 + k * r * r : 1 / (1 - k * r * r)
        return u.center + d * f
    }

    /// Lens Distortion: where the picture at texture position `q` (inside the picture) is read from, and how many source px
    /// one output px spans there (x = along the radius, y = across it). With rho = the zoomed distance from the lens center
    /// in half diagonals, k >= 0 (barrel) reads at rho (1 + k rho^2); k < 0 (pincushion) reads at the x that solves
    /// x (1 + |k| x^2) = rho, the exact inverse of the barrel with the same strength (Newton from x0 = rho / (1 + |k| rho^2)).
    static func lensMap(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> (source: SIMD2<Float>, stretch: SIMD2<Float>) {
        let zoom = Float(bitPattern: UInt32(bitPattern: u.i.x))
        let d = q - u.center, rho = simd_length(d) / u.a.y * zoom, k = u.a.x
        var f: Float, g: Float
        if k >= 0 {
            f = 1 + k * rho * rho; g = 1 + 3 * k * rho * rho
        } else {
            let a = -k
            var x = rho / (1 + a * rho * rho)
            for _ in 0..<4 { x -= (x * (1 + a * x * x) - rho) / (1 + 3 * a * x * x) }
            f = rho > 1e-6 ? x / rho : 1; g = 1 / (1 + 3 * a * x * x)
        }
        return (u.center + d * (zoom * f), SIMD2(zoom * g, zoom * f))
    }
    static func lensSource(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD2<Float> { lensMap(q, u).source }

    /// Auto Scale: the largest zoom about the lens center (0.05...4) at which every point of the picture's border still
    /// reads inside the picture, so no empty edge shows (a barrel zooms in, a pincushion zooms out until an edge touches).
    /// The read distance grows with the zoom, so bisection finds it.
    static func lensAutoZoom(_ u: ImageFilters.Uniforms) -> Float {
        let o = SIMD2(u.a.z, u.a.w), n = 32
        var border: [SIMD2<Float>] = []
        for i in 0...n {
            let t = Float(i) / Float(n)
            border += [o + SIMD2(t * u.frame.x, 0), o + SIMD2(t * u.frame.x, u.frame.y), o + SIMD2(0, t * u.frame.y), o + SIMD2(u.frame.x, t * u.frame.y)]
        }
        func fits(_ zoom: Float) -> Bool {
            var v = u
            v.i.x = Int32(bitPattern: zoom.bitPattern)
            return border.allSatisfy { inPicture(lensSource($0, v), v) }
        }
        var lo: Float = 0.05, hi: Float = 4
        if fits(hi) { return hi }
        for _ in 0..<24 { let mid = (lo + hi) / 2; if fits(mid) { lo = mid } else { hi = mid } }
        return lo
    }

    static func cubicWeights(_ t: Float) -> SIMD4<Float> {
        SIMD4(((-0.5 * t + 1) * t - 0.5) * t, (1.5 * t - 2.5) * t * t + 1, ((-1.5 * t + 2) * t + 0.5) * t, (0.5 * t - 0.5) * t * t)
    }
    /// Where a lens tap at `p` reads and how much of it is picture: faded into the fill `u.b` over the last half px
    /// outside the border (what a bilinear tap does there); with Auto Scale (`i.y`) held inside the picture instead.
    static func lensHold(_ p: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> (p: SIMD2<Float>, cover: Float) {
        let o = SIMD2(u.a.z, u.a.w), e = o + u.frame
        if u.i.y != 0 { return (simd_clamp(p, o + 0.5, e - 0.5), 1) }
        let m = simd_clamp(simd_min(p - o, e - p) + 0.5, SIMD2(repeating: 0), SIMD2(repeating: 1))
        return (p, m.x * m.y)
    }
    /// One sharp lens tap: Catmull-Rom over the 12 texels of the 4 x 4 block without its corners (their weights are
    /// below 0.6 % each; the rest is renormalized), which the GPU reads as five bilinear fetches. Texels are held at the
    /// picture's edge (no ringing against the empty outside).
    static func lensTap(_ img: ImageFilters.Image, _ p: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD4<Float> {
        let o = SIMD2(u.a.z, u.a.w), e = o + u.frame
        let (p, cover) = lensHold(p, u)
        if cover <= 0 { return u.b }
        let lo = (o - 0.5).rounded(.up), hi = (e - 0.5).rounded(.down)
        let q = p - 0.5, b = q.rounded(.down)
        let wx = cubicWeights(q.x - b.x), wy = cubicWeights(q.y - b.y)
        var acc = SIMD4<Float>.zero
        for j in 0..<4 {
            for i in 0..<4 where !((i == 0 || i == 3) && (j == 0 || j == 3)) {
                let t = simd_clamp(b + SIMD2(Float(i - 1), Float(j - 1)), lo, hi)
                acc += img[Int(t.x), Int(t.y)] * (wx[i] * wy[j])
            }
        }
        acc /= 1 - (wx[0] + wx[3]) * (wy[0] + wy[3])
        return acc * cover + u.b * (1 - cover)
    }
    /// One soft lens tap (bilinear), held and faded like `lensTap`.
    static func lensTapLinear(_ img: ImageFilters.Image, _ p: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD4<Float> {
        let o = SIMD2(u.a.z, u.a.w), e = o + u.frame
        let (p, cover) = lensHold(p, u)
        if cover <= 0 { return u.b }
        let lo = (o - 0.5).rounded(.up) + 0.5, hi = (e - 0.5).rounded(.down) + 0.5
        return img.sample(simd_clamp(p, lo, hi)) * cover + u.b * (1 - cover)
    }
    /// Where the footprint taps start and where they have fully replaced the sharp tap (source px per output px).
    static let lensShrinkStart: Float = 1.15, lensShrinkFull: Float = 1.4
    /// The lens' resampling: one sharp tap where the picture is magnified or barely shrunk; where one output px spans
    /// more than `lensShrinkFull` source px, four bilinear taps spread over its footprint (along and across the radius)
    /// so fine detail does not shimmer; a blend of both in between. At most 9 fetches per pixel. Never negative.
    static func lensSample(_ img: ImageFilters.Image, _ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> SIMD4<Float> {
        let (s, stretch) = lensMap(q, u)
        let o = SIMD2(u.a.z, u.a.w), e = o + u.frame
        if u.i.y == 0 && (s.x < o.x - 3 || s.y < o.y - 3 || s.x > e.x + 3 || s.y > e.y + 3) { return u.b }
        let t = min(max((max(stretch.x, stretch.y) - lensShrinkStart) / (lensShrinkFull - lensShrinkStart), 0), 1)
        var c = SIMD4<Float>.zero
        if t < 1 { c += lensTap(img, s, u) * (1 - t) }
        if t > 0 {
            let spread = simd_clamp(stretch - 1, SIMD2(repeating: 0), SIMD2(repeating: 2)) * 0.5
            let d = q - u.center, len = simd_length(d)
            let er = len > 1e-6 ? d / len : SIMD2<Float>(1, 0), et = SIMD2(-er.y, er.x)
            let a = er * spread.x, b = et * spread.y
            c += (lensTapLinear(img, s + a + b, u) + lensTapLinear(img, s + a - b, u) + lensTapLinear(img, s - a + b, u)
                + lensTapLinear(img, s - a - b, u)) * (0.25 * t)
        }
        return premultipliedHeld(c)
    }
    /// The sharp tap's negative lobes overshoot at a hard alpha edge (alpha above 1 or below 0). The picture's color
    /// follows its alpha there: above 1 the color is scaled by the same factor as alpha is cut, below 0 nothing is left, so
    /// color never exceeds alpha (a bright halo over the edge). Opaque colors above 1 (HDR) stay.
    static func premultipliedHeld(_ c: SIMD4<Float>) -> SIMD4<Float> {
        if c.w <= 0 { return .zero }
        let k: Float = c.w > 1 ? 1 / c.w : 1
        return SIMD4(max(c.x, 0) * k, max(c.y, 0) * k, max(c.z, 0) * k, min(c.w, 1))
    }
    static func inPicture(_ q: SIMD2<Float>, _ u: ImageFilters.Uniforms) -> Bool {
        let o = SIMD2(u.a.z, u.a.w)
        return q.x >= o.x && q.y >= o.y && q.x <= o.x + u.frame.x && q.y <= o.y + u.frame.y
    }

    /// Glitch Displace: horizontal shift (texture px) of the band holding texture row `y`.
    static func glitchShift(_ y: Float, _ u: ImageFilters.Uniforms) -> Float {
        let band = Int32((y - (u.center.y - u.frame.y * 0.5)) / u.a.y)
        let id = UInt32(bitPattern: band), seed = UInt32(bitPattern: u.i.x)
        guard ImageFilters.hash01(id, 0, seed, 0) < u.a.w else { return 0 }
        return (ImageFilters.hash01(id, 1, seed, 1) * 2 - 1) * u.a.x
    }

    // MARK: CPU references

    /// The reference result of `f` (nil when it is not a style filter).
    public static func reference(_ f: ImageFilter, _ img: ImageFilters.Image, frame: ImageFilters.Frame, pf: Double = 1) -> ImageFilters.Image? {
        guard let (family, u) = plan(f, frame: frame, pf: pf) else { return nil }
        switch family {
        case .pixel:
            return img.map { x, y, p in pixel(p, SIMD2(Float(x) + 0.5, Float(y) + 0.5), u) }
        case .warp:
            let g = warpGain(u)
            return img.map { x, y, p in
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                return warpPassesThrough(q, u) ? p : img.sample(warpSource(q, u)) * g
            }
        case .lens:
            return img.map { x, y, p in
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                guard inPicture(q, u) else { return p }
                if u.i.z == 0 {
                    let s = lensLegacySource(q, u)
                    return u.b.w > 0 && !inPicture(s, u) ? u.b : img.sample(s)
                }
                return lensSample(img, q, u)
            }
        case .rgbSplit:
            return img.map { x, y, p in
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                var d = SIMD2(u.a.x, u.a.y)
                if u.i.x != 0 { d = simd_length(d) * (q - u.center) / u.a.w }
                let r = img.sample(q - d), b = img.sample(q + d)
                let s = SIMD4(r.x, p.y, b.z, max(r.w, max(p.w, b.w)))
                return s + (p - s) * u.a.z
            }
        case .glitch:
            return img.map { x, y, _ in
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5), sx = glitchShift(q.y, u)
                let r = img.sample(q + SIMD2(sx - u.a.z, 0)), g = img.sample(q + SIMD2(sx, 0)), b = img.sample(q + SIMD2(sx + u.a.z, 0))
                return SIMD4(r.x, g.y, b.z, max(r.w, max(g.w, b.w)))
            }
        case .radialBlur:
            let n = Int(u.i.y)
            return img.map { x, y, _ in
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5), d = q - u.center
                var acc = SIMD4<Float>.zero
                for k in 0..<n {
                    let t = (Float(k) / Float(n - 1) - 0.5) * u.a.x
                    let s: SIMD2<Float>
                    if u.i.x != 0 { s = u.center + d * (1 + t) }
                    else { let c = cosf(t), sn = sinf(t); s = u.center + SIMD2(c * d.x - sn * d.y, sn * d.x + c * d.y) }
                    acc += img.sample(s)
                }
                return acc / Float(n)
            }
        }
    }
}
