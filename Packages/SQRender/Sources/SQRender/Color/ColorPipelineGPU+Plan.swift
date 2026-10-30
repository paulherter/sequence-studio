import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

#if !canImport(Metal)
/// The color chain on the portable GPU backend (Windows). The pass plan below is shared with the Metal class.
public final class ColorPipelineGPU: @unchecked Sendable {}
#endif

// The color chain's pass plan: which sections run in which dispatch, with which constants. No GPU calls, the same on
// every backend (the Metal class and the Slang color chain read these blocks).
extension ColorPipelineGPU {
    // MARK: Uniforms (layout mirrors MSL `ColorHeader` / `Sec`)

    struct Header {
        var ints: SIMD4<UInt32>   // count, start domain, end domain, source
        var extra: SIMD4<UInt32> = .zero   // x: the texture is a quarter-turned picture (vignette geometry is upright); yz: dispatch origin
    }

    struct Sec {
        var head: SIMD4<UInt32> = .zero   // kind, pre, flags, extra
        var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero, d = SIMD4<Float>.zero
        var m = matrix_identity_float3x3
    }

    /// One compute dispatch: up to `maxSections` blocks with at most one LUT and `maxCurves` curve tables.
    struct Pass {
        var header: Header
        var sections: [Sec] = []
        var curves: [SIMD4<Float>] = []
        var lut: CubeLUT?
        /// Structure key of the specialised kernel (set by `passes(for:)`).
        var layout = ColorKernelSource.PassLayout(start: 0, end: 0, source: 0, blocks: [])
    }

    static let maxSections = 8
    /// A column with Parallel / Layer Steps keeps its registers in one pass: it may fill a pass up to this many blocks
    /// (a `Sec` is 128 B, so 24 stay below the 4 KB `setBytes` limit). Its LUT and curve budget is the pass's.
    /// `Sec.c.w` of the conversion section: 1 / 0 = soft gamut compression on / off, -1 = conform off (no trim, no tone map).
    static func conversionToneMapFlag(_ p: ColorPipeline) -> Float {
        if p.skipsToneMap && p.source.toneMapPeak != nil { return -1 }
        return p.toneMapping.compressesGamut ? 1 : 0
    }

    static let maxGroupSections = 24
    static let maxCurves = 3   // 3 x 64 x 16 B stays below the 4 KB setBytes limit (a Hue Saturation Curves block takes 2)

    static let kindConversion: UInt32 = 0, kindBasic: UInt32 = 1, kindCreative: UInt32 = 2, kindLook: UInt32 = 3,
               kindCurves: UInt32 = 4, kindWheels: UInt32 = 5, kindVignette: UInt32 = 6, kindHueCurves: UInt32 = 7,
               kindHSLSecondary: UInt32 = 8, kindPrimaries: UInt32 = 9, kindStepBegin: UInt32 = 10, kindStepEnd: UInt32 = 11,
               kindGroupBegin: UInt32 = 12, kindBranchEnd: UInt32 = 13, kindGroupMerge: UInt32 = 14, kindGroupEnd: UInt32 = 15,
               kindKeyTerm: UInt32 = 16, kindKeyApply: UInt32 = 17, kindZoneBoard: UInt32 = 18
    static let lutPresent: UInt32 = 1, lut1D: UInt32 = 2, lutIn: UInt32 = 4, lutOut: UInt32 = 8, lutTrilinear: UInt32 = 16

    private static func lutFields(_ s: inout Sec, _ l: CubeLUT) {
        var f = lutPresent | (l.kind == .lut1D ? lut1D : 0)
        if l.inVideoRange { f |= lutIn }
        if l.outVideoRange { f |= lutOut }
        if l.interpolation == .trilinear { f |= lutTrilinear }
        s.head.z = f
        s.head.w = UInt32(l.size)
        s.a = SIMD4(l.domainMin, 0); s.b = SIMD4(l.domainMax, 1)
    }

    /// Splits the compiled chain into passes. Between passes the texture holds the running signal: source-linear light
    /// before the conversion, the display tone signal after it; the last pass ends in working-linear.
    /// Transfer index in the shader's `map3` (decode = index, encode = index + 10; 2 = Rec.709). The gamut travels as
    /// a matrix, so sources that share a curve share an index. Indices 0…9 are taken; the next block is 20…29 (encode 30…39,
    /// still +10). Callers test `transfer < 30u`.
    static func shaderIndex(_ s: SourceColorSpace) -> UInt32 {
        switch s {
        case .sLog3SGamut3Cine: 0
        case .hlgBT2020: 1
        case .rec709: 2
        case .vLogVGamut: 3
        case .appleLog: 4
        case .pqBT2020: 5
        case .dLogDGamut: 6
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709: 7
        case .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709: 8
        case .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: 9
        // 10...19 are the encode functions of 0...9; the vendor logs decode at 20...26 and encode at 30...36 (always +10).
        case .logC3WideGamut3: 20
        case .logC4WideGamut4: 21
        case .log3G10RedWideGamut: 22
        case .bmdFilmGen5WideGamut: 23
        case .nLogBT2020: 24
        case .fLog2FGamutC: 25
        case .acesCCTAP1: 26
        }
    }

    static func passes(for p: ColorPipeline, skipIdentities: Bool = true) -> [Pass] {
        let source = shaderIndex(p.source)
        var passes: [Pass] = []
        var domain: UInt32 = 0   // 0 source-encoded, 1 source-linear, 2 display
        var cur = Pass(header: Header(ints: SIMD4(0, domain, 0, source)))
        func close(last: Bool) {
            cur.header.ints.x = UInt32(cur.sections.count)
            cur.header.ints.z = last ? 3 : domain == 0 ? 1 : domain
            passes.append(cur)
            let next: UInt32 = domain == 0 ? 1 : domain
            cur = Pass(header: Header(ints: SIMD4(0, next, 0, source)))
            domain = next
        }
        // What a limited Step (begin … end) needs: it must fit one pass, its input lives in a register.
        func stepNeeds(from i: Int) -> (sections: Int, curves: Int, lut: Bool) {
            var n = 0, curves = 0, lut = false
            for st in p.stages[i...] {
                n += 1
                switch st.kind {
                case .curves: curves += 1
                case .hueCurves: curves += 2
                case .look, .conversion(.some): lut = true
                default: break
                }
                if case .stepEnd = st.kind { break }
            }
            return (n, curves, lut)
        }
        // What a column (group begin ... end) needs: all of it in one pass.
        func groupNeeds(from i: Int) -> (sections: Int, curves: Int, lut: Bool) {
            var n = 0, curves = 0, lut = false
            for st in p.stages[i...] {
                n += 1
                switch st.kind {
                case .curves: curves += 1
                case .hueCurves: curves += 2
                case .look, .conversion(.some): lut = true
                default: break
                }
                if case .groupEnd = st.kind { break }
            }
            return (n, curves, lut)
        }
        var inGroup = false
        for (index, st) in p.stages.enumerated() {
            if case .groupBegin = st.kind {
                let need = groupNeeds(from: index)
                let curveCount = cur.curves.count / CurveTable.count
                if !cur.sections.isEmpty && (cur.sections.count + need.sections > maxGroupSections
                    || curveCount + need.curves > maxCurves || (need.lut && cur.lut != nil)) {
                    close(last: false)
                }
                inGroup = true
            }
            if case .stepBegin = st.kind {
                let need = stepNeeds(from: index)
                let curveCount = cur.curves.count / CurveTable.count
                if !cur.sections.isEmpty && (cur.sections.count + need.sections > maxSections
                    || curveCount + need.curves > maxCurves || (need.lut && cur.lut != nil)) {
                    close(last: false)
                }
            }
            var sec = Sec()
            sec.head.y = st.pre ? 1 : 0
            var needsLUT: CubeLUT?
            var curvesRows: [SIMD4<Float>] = []
            switch st.kind {
            case .conversion(let lut):
                sec.head.x = kindConversion
                sec.m = p.toRec709
                sec.c = SIMD4(p.toneMapping.knee, p.source.toneMapPeak ?? 0, p.toneMapping.exposureGain,
                              conversionToneMapFlag(p))   // peak 0 = exponential roll-off; z = export gain; w = gamut compression, -1 = no tone map
                if let lut { lutFields(&sec, lut); needsLUT = lut }
            case .basic(let b):
                sec.head.x = kindBasic
                var f: UInt32 = 0
                if b.hasWB { f |= 1 }
                if b.hasExposure { f |= 2 }
                if b.hasContrast { f |= 4 }
                if b.hasShadows { f |= 8 }
                if b.hasHighlights { f |= 64 }
                if b.hasLevels { f |= 16 }
                if b.saturation != 1 || b.vibrance != 0 { f |= 32 }
                sec.head.z = f
                if b.lumetri {
                    // head.w 1 = Lumetri tone model (BasicToneCurves): a = (exposure gain, contrast k, highlights bump,
                    // shadows bump), b = (blacks lift, whites gain, sat, vib), c.w = exposure shoulder on,
                    // d = (contrast pivot, exposure knee).
                    typealias C = BasicToneCurves
                    sec.head.w = 1
                    let k = b.con >= 0 ? b.con * C.contrastUp : b.con * C.contrastDown
                    sec.a = SIMD4(b.exposureScale, k, C.highlightsReach * b.hi, C.shadowsReach * b.sh)
                    sec.b = SIMD4(C.blacksReach * b.bl, exp2f(C.whitesStops * b.wh), b.saturation, b.vibrance)
                    sec.c = SIMD4(b.luma, b.ev > 0 ? 1 : 0)
                    sec.d = SIMD4(C.contrastPivot, C.exposureKnee, 0, 0)
                } else {
                    sec.a = SIMD4(b.exposureScale, b.contrastK, b.highlights, b.shadows)
                    sec.b = SIMD4(b.blackPoint, b.whitePoint, b.saturation, b.vibrance)
                    sec.c = SIMD4(b.luma, 0)
                }
                sec.m = b.wb
            case .creative(let c):
                sec.head.x = kindCreative
                sec.head.z = c.hasTint ? 1 : 0
                sec.a = SIMD4(c.fade, c.saturation, c.vibrance, c.balance)
                sec.b = SIMD4(c.shadowTint, 0); sec.c = SIMD4(c.highlightTint, 0); sec.d = SIMD4(c.luma, 0)
            case .look(let lut, let k):
                sec.head.x = kindLook
                lutFields(&sec, lut)
                sec.c = SIMD4(k, 0, 0, 0)
                needsLUT = lut
            case .curves(let t):
                sec.head.x = kindCurves
                curvesRows = t.table.map { SIMD4($0, 0) }
            case .hueCurves(let h):
                sec.head.x = kindHueCurves
                sec.d = SIMD4(h.luma, 0)
                curvesRows = h.table
            case .wheels(let w):
                sec.head.x = kindWheels
                sec.head.z = w.hasGamma ? 1 : 0
                sec.a = SIMD4(w.lift, w.saturation); sec.b = SIMD4(w.gammaExponent, 0); sec.c = SIMD4(w.gain, 0)
                sec.d = SIMD4(w.luma, 0)
            case .hslSecondary(let r):
                // a = (center, half width, hue edge, all hues), b = (sat lo, sat hi, sat edge, invert),
                // c = (luma lo, luma hi, luma edge, saturation), d = (luma row, hue rotation), m = diagonal gains.
                // Color volume (head.w = 1): a = (ball center, radius), b = (edge, 0, 0, invert).
                sec.head.x = kindHSLSecondary
                sec.a = SIMD4(r.center, r.halfWidth, r.hueSoft, r.allHues ? 1 : 0)
                sec.b = SIMD4(r.satLo, r.satHi, r.satSoft, r.invert ? 1 : 0)
                sec.c = SIMD4(r.lumLo, r.lumHi, r.lumSoft, r.saturation)
                if r.volume {
                    sec.head.w = 1
                    sec.a = SIMD4(r.volumeCenter, r.volumeRadius)
                    sec.b = SIMD4(r.volumeEdge, 0, 0, r.invert ? 1 : 0)
                }
                sec.d = SIMD4(r.luma, r.theta)
                sec.m = simd_float3x3(diagonal: r.gains)
            case .zoneBoard(let z):
                // a…d = (tint offset, saturation factor) of Global, Shadows, Midtones, Highlights; m = (exposure gains,
                // luma row).
                sec.head.x = kindZoneBoard
                sec.a = SIMD4(z.offsets[0], z.saturations[0]); sec.b = SIMD4(z.offsets[1], z.saturations[1])
                sec.c = SIMD4(z.offsets[2], z.saturations[2]); sec.d = SIMD4(z.offsets[3], z.saturations[3])
                sec.m = simd_float3x3(SIMD3(z.gains[0], z.gains[1], z.gains[2]), SIMD3(z.gains[3], z.luma.x, z.luma.y),
                                      SIMD3(z.luma.z, 0, 0))
            case .vignette(let v):
                sec.head.x = kindVignette
                sec.a = SIMD4(v.amount, v.start, v.feather, v.exponent); sec.b = SIMD4(v.aspectMix, 0, 0, 0)
            case .primaries(let q):
                // a = (lift, contrast), b = (gamma, pivot), c = (gain, saturation), d = (offset, 0).
                sec.head.x = kindPrimaries
                sec.head.z = q.flags
                sec.a = SIMD4(q.lift, q.contrast); sec.b = SIMD4(q.gamma, q.pivot)
                sec.c = SIMD4(q.gain, q.saturation); sec.d = SIMD4(q.offset, 0)
            case .stepBegin:
                sec.head.x = kindStepBegin
            case .stepEnd(let mt):
                // a…d = the qualifier in the Color Range layout, m = the window (PreparedWindow.matrix).
                sec.head.x = kindStepEnd
                sec.head.z = mt.flags
                if let r = mt.qualifier {
                    sec.a = SIMD4(r.center, r.halfWidth, r.hueSoft, r.allHues ? 1 : 0)
                    sec.b = SIMD4(r.satLo, r.satHi, r.satSoft, r.invert ? 1 : 0)
                    sec.c = SIMD4(r.lumLo, r.lumHi, r.lumSoft, 1)
                    sec.d = SIMD4(r.luma, 0)
                }
                if let w = mt.window { sec.m = w.matrix }
                sec.d.w = mt.mix
            case .groupBegin:
                sec.head.x = kindGroupBegin
            case .branchEnd(let mt, let layer):
                // Like a Step end; flag bit 3 = layer.
                sec.head.x = kindBranchEnd
                sec.head.z = mt.flags | (layer ? 8 : 0)
                if let r = mt.qualifier {
                    sec.a = SIMD4(r.center, r.halfWidth, r.hueSoft, r.allHues ? 1 : 0)
                    sec.b = SIMD4(r.satLo, r.satHi, r.satSoft, r.invert ? 1 : 0)
                    sec.c = SIMD4(r.lumLo, r.lumHi, r.lumSoft, 1)
                    sec.d = SIMD4(r.luma, 0)
                }
                if let w = mt.window { sec.m = w.matrix }
                sec.d.w = mt.mix
            case .keyTerm(let k):
                // Like a Step end's matte: a…d = the qualifier, m = the window; flags in PreparedKeyTerm.flags.
                sec.head.x = kindKeyTerm
                sec.head.z = k.flags
                if let r = k.qualifier {
                    sec.a = SIMD4(r.center, r.halfWidth, r.hueSoft, r.allHues ? 1 : 0)
                    sec.b = SIMD4(r.satLo, r.satHi, r.satSoft, r.invert ? 1 : 0)
                    sec.c = SIMD4(r.lumLo, r.lumHi, r.lumSoft, 1)
                    sec.d = SIMD4(r.luma, 0)
                }
                if let w = k.window { sec.m = w.matrix }
            case .keyApply:
                sec.head.x = kindKeyApply
            case .groupMerge(let inv):
                sec.head.x = kindGroupMerge
                sec.head.z = inv > 0 ? 0 : 1
                sec.a.x = inv
            case .groupEnd:
                sec.head.x = kindGroupEnd
            }
            let curveCount = cur.curves.count / CurveTable.count
            if !inGroup && (cur.sections.count >= maxSections || (needsLUT != nil && cur.lut != nil)
                || (!curvesRows.isEmpty && curveCount + curvesRows.count / CurveTable.count > maxCurves)) {
                close(last: false)
            }
            if case .groupEnd = st.kind { inGroup = false }
            if !curvesRows.isEmpty { sec.head.w = UInt32(cur.curves.count / CurveTable.count); cur.curves += curvesRows }
            if let needsLUT { cur.lut = needsLUT }
            cur.sections.append(sec)
            if case .conversion = st.kind { domain = 2 }
        }
        close(last: true)
        return skipIdentities ? skippingIdentities(passes) : passes.map { var q = $0; q.layout = ColorKernelSource.layout(q); return q }
    }

    /// Drops blocks that leave every value bit for bit as it is (on the GPU, in float, incl. -0, inf, NaN), and passes
    /// left without blocks that neither change domain nor end the chain (a half texture read and written back is the
    /// same texture). Pass boundaries are kept: each one rounds to half, so merging passes would move pixels.
    /// - Basic with no flags: `basicStage` returns its input untouched (pre or post).
    /// - Creative after the conversion with no fade, no tint, saturation 1, vibrance 0: `satVib` returns its input.
    /// - Vignette with amount 0: `c * exp2(0)` is `c * 1`.
    /// Not dropped: a look at intensity 0 and neutral wheels (`t + 0` turns -0 into +0), neutral curves (table
    /// interpolation is not exact), pre-conversion creative (BT.709 round trip).
    static func skippingIdentities(_ passes: [Pass]) -> [Pass] {
        var out: [Pass] = []
        for (i, var p) in passes.enumerated() {
            p.sections.removeAll { s in
                switch s.head.x {
                case kindBasic: return s.head.z == 0
                case kindCreative: return s.head.y == 0 && s.head.z == 0 && s.a.x == 0 && s.a.y == 1 && s.a.z == 0
                case kindVignette: return s.a.x == 0
                default: return false
                }
            }
            p.header.ints.x = UInt32(p.sections.count)
            if p.sections.isEmpty && i > 0 && i < passes.count - 1 && p.header.ints.y == p.header.ints.z { continue }
            p.layout = ColorKernelSource.layout(p)
            out.append(p)
        }
        return out
    }
}
