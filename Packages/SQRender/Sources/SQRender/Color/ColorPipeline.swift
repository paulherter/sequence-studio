#if canImport(simd)
import simd
#endif
import SQCore

/// Clip source color space: transfer + gamut.
/// The shader's transfer index is `ColorPipelineGPU.shaderIndex` (several cases share one curve).
public enum SourceColorSpace: Sendable, Equatable, CaseIterable {
    case sLog3SGamut3Cine
    case hlgBT2020
    case rec709
    case vLogVGamut
    case appleLog
    case pqBT2020
    case dLogDGamut
    // F7.2 Canon Log / Canon Log 2 / Canon Log 3, each in Cinema Gamut, BT.2020 and BT.709.
    case canonLogCinemaGamut, canonLogBT2020, canonLogBT709
    case canonLog2CinemaGamut, canonLog2BT2020, canonLog2BT709
    case canonLog3CinemaGamut, canonLog3BT2020, canonLog3BT709
    // Vendor log spaces (shader indices 20...26, see `ColorPipelineGPU.shaderIndex`).
    case logC3WideGamut3, logC4WideGamut4, log3G10RedWideGamut, bmdFilmGen5WideGamut, nLogBT2020, fLog2FGamutC, acesCCTAP1

    public var gamut: Gamut {
        switch self {
        case .sLog3SGamut3Cine: .sGamut3Cine
        case .hlgBT2020, .appleLog, .pqBT2020, .canonLogBT2020, .canonLog2BT2020, .canonLog3BT2020: .bt2020
        case .rec709, .canonLogBT709, .canonLog2BT709, .canonLog3BT709: .rec709
        case .vLogVGamut: .vGamut
        case .dLogDGamut: .dGamut
        case .canonLogCinemaGamut, .canonLog2CinemaGamut, .canonLog3CinemaGamut: .cinemaGamut
        case .logC3WideGamut3: .arriWideGamut3
        case .logC4WideGamut4: .arriWideGamut4
        case .log3G10RedWideGamut: .redWideGamutRGB
        case .bmdFilmGen5WideGamut: .blackmagicWideGamut
        case .nLogBT2020: .bt2020
        case .fLog2FGamutC: .fGamutC
        case .acesCCTAP1: .acesAP1
        }
    }

    /// Log and HDR sources (scene or display light above 1.0) get the tone map in automatic conversion; Rec.709 bypasses it.
    public var isHDR: Bool { self != .rec709 }

    /// source-encoded (range-expanded 0…1) -> source-linear.
    public func decode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .sLog3SGamut3Cine: TransferFunctions.slog3DecodeLegal(v)
        case .hlgBT2020: TransferFunctions.hlgDecode(v)
        case .rec709: TransferFunctions.bt709InverseOETF(v)
        case .vLogVGamut: TransferFunctions.vlogDecodeLegal(v)
        case .appleLog: TransferFunctions.appleLogDecode(v)
        case .pqBT2020: TransferFunctions.pqDecode(v)
        case .dLogDGamut: TransferFunctions.dlogDecodeLegal(v)
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709: TransferFunctions.canonLogDecodeLegal(v)
        case .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709: TransferFunctions.canonLog2DecodeLegal(v)
        case .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: TransferFunctions.canonLog3DecodeLegal(v)
        case .logC3WideGamut3: TransferFunctions.logC3DecodeLegal(v)
        case .logC4WideGamut4: TransferFunctions.logC4DecodeLegal(v)
        case .log3G10RedWideGamut: TransferFunctions.log3G10Decode(v)
        case .bmdFilmGen5WideGamut: TransferFunctions.bmdFilmGen5DecodeLegal(v)
        case .nLogBT2020: TransferFunctions.nLogDecodeLegal(v)
        case .fLog2FGamutC: TransferFunctions.fLog2DecodeLegal(v)
        case .acesCCTAP1: TransferFunctions.acesCCTDecode(v)
        }
    }

    /// source-linear -> source-encoded (exact inverse of `decode`).
    public func encode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .sLog3SGamut3Cine: TransferFunctions.slog3EncodeLegal(v)
        case .hlgBT2020: TransferFunctions.hlgEncode(v)
        case .rec709: TransferFunctions.bt709OETF(v)
        case .vLogVGamut: TransferFunctions.vlogEncodeLegal(v)
        case .appleLog: TransferFunctions.appleLogEncode(v)
        case .pqBT2020: TransferFunctions.pqEncode(v)
        case .dLogDGamut: TransferFunctions.dlogEncodeLegal(v)
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709: TransferFunctions.canonLogEncodeLegal(v)
        case .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709: TransferFunctions.canonLog2EncodeLegal(v)
        case .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: TransferFunctions.canonLog3EncodeLegal(v)
        case .logC3WideGamut3: TransferFunctions.logC3EncodeLegal(v)
        case .logC4WideGamut4: TransferFunctions.logC4EncodeLegal(v)
        case .log3G10RedWideGamut: TransferFunctions.log3G10Encode(v)
        case .bmdFilmGen5WideGamut: TransferFunctions.bmdFilmGen5EncodeLegal(v)
        case .nLogBT2020: TransferFunctions.nLogEncodeLegal(v)
        case .fLog2FGamutC: TransferFunctions.fLog2EncodeLegal(v)
        case .acesCCTAP1: TransferFunctions.acesCCTEncode(v)
        }
    }
}

/// One step of a clip's color chain (public, parameter level). The list order is the processing order; the single
/// `.conversion` marks where source-linear light becomes the display-referred tone signal (Input LUT or the built-in
/// automatic conversion): ops before it work on the source, ops after it on the display signal.
public enum ColorOp: Sendable {
    case conversion(CubeLUT?)
    case basic(BasicCorrection)
    /// Creative adjustments without the look LUT (Faded Film, Vibrance, Saturation, Shadow/Highlight Tint).
    case creative(CreativeLook)
    /// Look LUT with intensity 0…1 (expects and returns the display signal).
    case look(CubeLUT, intensity: Float)
    case curves(RGBCurves)
    case hueCurves(HueCurves)
    case wheels(ColorWheels)
    /// Color Range (HSL secondary): a qualified correction.
    case hslSecondary(HSLSecondary)
    /// Zone Board (v94): four zones with puck, saturation and exposure.
    case zoneBoard(ZoneBoard)
    case vignette(Vignette)
    /// Pro grade Step primaries (lift, gain, offset, gamma, contrast, saturation).
    case primaries(StepPrimaries)
    /// Start of a limited Step: remembers the Step's input.
    case stepBegin
    /// End of a limited Step: mixes the Step's result over its input by the qualifier (on the input) and the window.
    /// Must follow a `stepBegin` with no other begin / end between them.
    /// `mix` (0...1) scales the matte: a Step at Mix 50 shows half of its result.
    case stepEnd(qualifier: ColorQualifier?, window: StepWindow?, mix: Float = 1)
    /// Start of a column with Parallel / Layer Steps: remembers the column's input (`g0`) and clears the sum (`acc`).
    case groupBegin
    /// End of one branch of a column; the signal goes back to the column's input. A parallel branch (the column's
    /// serial Step or a Parallel Step) adds its keyed, mixed result over `g0` to `acc`; a layer branch lays its result
    /// over `acc` by its key. Must sit between `groupBegin` and `groupEnd`.
    case branchEnd(layer: Bool, qualifier: ColorQualifier?, window: StepWindow?, mix: Float)
    /// After the parallel branches: `acc` becomes their average (`count` 0 = `g0`, nothing to average).
    case groupMerge(count: Int)
    /// End of the column: the signal is `acc`.
    case groupEnd
    /// One key wire into the key input of the next `stepEnd` / `branchEnd` / `keyApply`: sets or combines the key register
    /// (matte so far). Sits between the Step's body and its end, or (for a mixer box) between the last branch and `keyApply`.
    case keyTerm(KeyTerm)
    /// Before `groupEnd`: the column's result is mixed back over the column's input by the key register.
    case keyApply
    /// Right before a layer `branchEnd`: how the layer's result composites over what is below (Layer mix).
    case layerMix(LayerMixMode)
}

/// A compiled op: parameters turned into the prepared constants the CPU maths and the GPU uniforms both use.
struct ColorStage: Sendable {
    enum Kind: Sendable {
        case conversion(CubeLUT?)
        case basic(PreparedBasic)
        case creative(PreparedCreative)
        case look(CubeLUT, Float)
        case curves(CurveTable)
        case hueCurves(PreparedHueCurves)
        case wheels(PreparedWheels)
        case hslSecondary(PreparedHSLSecondary)
        case zoneBoard(PreparedZoneBoard)
        case vignette(PreparedVignette)
        case primaries(PreparedPrimaries)
        case stepBegin
        case stepEnd(PreparedStepMatte)
        case groupBegin
        case branchEnd(PreparedStepMatte, layer: Bool)
        /// 1 / count (0 = no parallel branch: the average is the column's input).
        case groupMerge(Float)
        case groupEnd
        case keyTerm(PreparedKeyTerm)
        case keyApply
    }
    var kind: Kind
    /// Before the conversion: the signal is source-linear light (wrapped through the tone signal).
    var pre: Bool
}

/// Per-clip chain: decode -> ops in order (with the conversion in its place) -> working-linear.
/// `process` is per pixel and allocation-free; the struct is cheap to copy and mutate per frame.
public struct ColorPipeline: Sendable {
    public var source: SourceColorSpace { didSet { compile() } }
    public var toneMapping: ToneMapping { didSet { compile() } }
    /// HDR conform off (`ClipColor.hdrConform`): an HLG / PQ source is not tone-mapped in the automatic conversion; its
    /// highlights above SDR white clip. Log sources keep their roll-off.
    public var skipsToneMap = false { didSet { compile() } }
    public var ops: [ColorOp] { didSet { compile() } }

    private(set) var stages: [ColorStage] = []
    /// The GPU compute passes of the compiled chain, built once in `compile()` (they are pure data: sections, curve tables):
    /// the compositor encodes them for every graded layer on every frame.
    private(set) var gpuPasses: [ColorPipelineGPU.Pass] = []
    private(set) var toRec709: simd_float3x3

    public init(source: SourceColorSpace, ops: [ColorOp] = [.conversion(nil)], toneMapping: ToneMapping = ToneMapping()) {
        self.source = source
        self.ops = ops
        self.toneMapping = toneMapping
        toRec709 = source.gamut.matrix(to: .rec709)
        compile()
    }

    /// Convenience for a chain with only a conversion LUT (or none) and an optional creative look.
    public init(source: SourceColorSpace, conversionLUT: CubeLUT?, look: CubeLUT? = nil, lookIntensity: Float = 1,
                toneMapping: ToneMapping = ToneMapping()) {
        var ops: [ColorOp] = [.conversion(conversionLUT)]
        if let look { ops.append(.look(look, intensity: lookIntensity)) }
        self.init(source: source, ops: ops, toneMapping: toneMapping)
    }

    /// Test switch: a copy whose GPU passes keep their identity blocks (until the next edit recompiles it).
    func keepingIdentityBlocks() -> ColorPipeline {
        var c = self
        c.gpuPasses = ColorPipelineGPU.passes(for: self, skipIdentities: false)
        return c
    }

    private mutating func compile() {
        toRec709 = source.gamut.matrix(to: .rec709)
        var ops = self.ops
        if !ops.contains(where: { if case .conversion = $0 { true } else { false } }) { ops.insert(.conversion(nil), at: 0) }
        var seenConversion = false
        var out: [ColorStage] = []
        var keyed = false, blend = LayerMixMode.normal
        for op in ops {
            let pre = !seenConversion
            let gamut = pre ? source.gamut : Gamut.rec709
            switch op {
            case .conversion(let lut):
                if seenConversion { continue }   // only the first one converts
                seenConversion = true
                out.append(ColorStage(kind: .conversion(lut), pre: false))
            case .basic(let b): out.append(ColorStage(kind: .basic(PreparedBasic(b, gamut: gamut)), pre: pre))
            case .creative(let c): out.append(ColorStage(kind: .creative(PreparedCreative(c, gamut: gamut)), pre: pre))
            case .look(let lut, let k): out.append(ColorStage(kind: .look(lut, k), pre: pre))
            case .curves(let c): out.append(ColorStage(kind: .curves(CurveTable(c)), pre: pre))
            case .hueCurves(let h): out.append(ColorStage(kind: .hueCurves(PreparedHueCurves(h, gamut: gamut)), pre: pre))
            case .wheels(let w): out.append(ColorStage(kind: .wheels(PreparedWheels(w, gamut: gamut)), pre: pre))
            case .hslSecondary(let r):
                out.append(ColorStage(kind: .hslSecondary(PreparedHSLSecondary(r, gamut: gamut)), pre: pre))
            case .zoneBoard(let z): out.append(ColorStage(kind: .zoneBoard(PreparedZoneBoard(z, gamut: gamut)), pre: pre))
            case .vignette(let v): out.append(ColorStage(kind: .vignette(PreparedVignette(v)), pre: pre))
            case .primaries(let p): out.append(ColorStage(kind: .primaries(PreparedPrimaries(p)), pre: pre))
            case .stepBegin: out.append(ColorStage(kind: .stepBegin, pre: pre))
            case .stepEnd(let q, let w, let mix):
                out.append(ColorStage(kind: .stepEnd(PreparedStepMatte(qualifier: q, window: w, mix: mix, keyed: keyed)), pre: pre))
                keyed = false
            case .groupBegin: out.append(ColorStage(kind: .groupBegin, pre: pre))
            case .branchEnd(let layer, let q, let w, let mix):
                out.append(ColorStage(kind: .branchEnd(PreparedStepMatte(qualifier: q, window: w, mix: mix, keyed: keyed,
                                                                         blend: layer ? blend : .normal), layer: layer), pre: pre))
                keyed = false; blend = .normal
            case .groupMerge(let n): out.append(ColorStage(kind: .groupMerge(n > 0 ? 1 / Float(n) : 0), pre: pre))
            case .groupEnd: out.append(ColorStage(kind: .groupEnd, pre: pre))
            case .keyTerm(let k): out.append(ColorStage(kind: .keyTerm(PreparedKeyTerm(k)), pre: pre)); keyed = true
            case .keyApply: out.append(ColorStage(kind: .keyApply, pre: pre)); keyed = false
            case .layerMix(let m): blend = m
            }
        }
        stages = out
        gpuPasses = ColorPipelineGPU.passes(for: self)
    }

    /// The conversion LUT, if any (diagnostics and tests).
    public var conversionLUT: CubeLUT? {
        for case .conversion(let l) in ops { return l }
        return nil
    }

    /// First creative look LUT and its intensity, if any (diagnostics and tests).
    public var creativeLUT: CubeLUT? {
        for case .look(let l, _) in ops { return l }
        return nil
    }
    public var creativeIntensity: Float {
        for case .look(_, let k) in ops { return k }
        return 0
    }

    /// Nothing to do on top of plain Rec.709 (only an empty conversion on a Rec.709 source).
    public var isIdentity: Bool {
        source == .rec709 && ops.allSatisfy { if case .conversion(nil) = $0 { true } else { false } }
    }

    /// source-linear -> display-referred tone signal (Rec.709 primaries, BT.709 encoded): the conversion step.
    func convert(_ linear: SIMD3<Float>, lut: CubeLUT?) -> SIMD3<Float> {
        if let lut { return lut.lookup(source.encode(linear)) }
        var c = source == .rec709 ? linear : toRec709 * linear
        if source.isHDR && !(skipsToneMap && source.toneMapPeak != nil) {
            c = toneMapping.apply(toneMapping.trim(c), peak: source.toneMapPeak)
        }
        return TransferFunctions.bt709OETF(simd_max(c, SIMD3<Float>.zero))
    }

    /// source-encoded -> working-linear (Rec.709 primaries, D65). `uv` (0…1, y down) and `aspect` (width / height)
    /// position the pixel for the vignette.
    public func process(_ sourceEncoded: SIMD3<Float>, uv: SIMD2<Float> = SIMD2(0.5, 0.5), aspect: Float = 16.0 / 9) -> SIMD3<Float> {
        var c = source.decode(sourceEncoded)
        var n0 = c
        var acc = SIMD3<Float>.zero
        var km: Float = 1
        for s in stages {
            switch s.kind {
            case .conversion(let lut): c = convert(c, lut: lut)
            case .basic(let p): c = p.apply(c, pre: s.pre)
            case .creative(let p): c = p.apply(c, pre: s.pre)
            case .look(let lut, let k):
                if s.pre {
                    let t = TransferFunctions.bt709OETF(c)
                    c = TransferFunctions.bt709InverseOETF(Self.mixLook(lut, t, k))
                } else { c = Self.mixLook(lut, c, k) }
            case .curves(let t): c = t.apply(c, pre: s.pre)
            case .hueCurves(let p): c = p.apply(c, pre: s.pre)
            case .wheels(let p): c = p.apply(c, pre: s.pre)
            case .hslSecondary(let p): c = p.apply(c, pre: s.pre)
            case .zoneBoard(let p): c = p.apply(c, pre: s.pre)
            case .vignette(let p): c = p.apply(c, uv: uv, aspect: aspect, pre: s.pre)
            case .primaries(let p): c = p.apply(c, pre: s.pre)
            case .stepBegin: n0 = c
            case .stepEnd(let m):
                c = m.apply(c, input: n0, uv: uv, aspect: aspect, pre: s.pre, key: m.keyed ? km : 1)
                if m.keyed { km = 1 }
            case .groupBegin: n0 = c; acc = .zero
            case .branchEnd(let m, let layer):
                var k = m.matte(input: n0, uv: uv, aspect: aspect, pre: s.pre)
                if m.keyed { k *= km; km = 1 }
                if layer { acc = acc + (m.composite(c, over: acc) - acc) * k } else { acc += n0 + (c - n0) * k }
                c = n0
            case .groupMerge(let inv): acc = inv > 0 ? acc * inv : n0
            case .groupEnd: c = acc
            case .keyTerm(let t): km = t.apply(km, input: n0, uv: uv, aspect: aspect, pre: s.pre)
            case .keyApply: acc = n0 + (acc - n0) * km; km = 1
            }
        }
        return TransferFunctions.bt709InverseOETF(c)
    }

    static func mixLook(_ lut: CubeLUT, _ t: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        let graded = lut.lookup(t)
        return k >= 1 ? graded : t + (graded - t) * k
    }
}
