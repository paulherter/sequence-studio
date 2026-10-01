import simd
import SQCore

/// Clip source colour space: transfer + gamut.
public enum SourceColorSpace: Sendable, Equatable {
    case sLog3SGamut3Cine
    case hlgBT2020
    case rec709

    public var gamut: Gamut {
        switch self {
        case .sLog3SGamut3Cine: .sGamut3Cine
        case .hlgBT2020: .bt2020
        case .rec709: .rec709
        }
    }

    /// HDR sources get the tone map in automatic conversion; Rec.709 bypasses it.
    public var isHDR: Bool { self != .rec709 }

    /// source-encoded (range-expanded 0…1) -> source-linear.
    public func decode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .sLog3SGamut3Cine: TransferFunctions.slog3DecodeLegal(v)
        case .hlgBT2020: TransferFunctions.hlgDecode(v)
        case .rec709: TransferFunctions.bt709InverseOETF(v)
        }
    }

    /// source-linear -> source-encoded (exact inverse of `decode`).
    public func encode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .sLog3SGamut3Cine: TransferFunctions.slog3EncodeLegal(v)
        case .hlgBT2020: TransferFunctions.hlgEncode(v)
        case .rec709: TransferFunctions.bt709OETF(v)
        }
    }
}

/// One step of a clip's colour chain (public, parameter level). The list order is the processing order; the single
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
    case vignette(Vignette)
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
        case vignette(PreparedVignette)
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

    private mutating func compile() {
        toRec709 = source.gamut.matrix(to: .rec709)
        var ops = self.ops
        if !ops.contains(where: { if case .conversion = $0 { true } else { false } }) { ops.insert(.conversion(nil), at: 0) }
        var seenConversion = false
        var out: [ColorStage] = []
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
            case .vignette(let v): out.append(ColorStage(kind: .vignette(PreparedVignette(v)), pre: pre))
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
        if source.isHDR { c = toneMapping.apply(c) }
        return TransferFunctions.bt709OETF(simd_max(c, SIMD3<Float>.zero))
    }

    /// source-encoded -> working-linear (Rec.709 primaries, D65). `uv` (0…1, y down) and `aspect` (width / height)
    /// position the pixel for the vignette.
    public func process(_ sourceEncoded: SIMD3<Float>, uv: SIMD2<Float> = SIMD2(0.5, 0.5), aspect: Float = 16.0 / 9) -> SIMD3<Float> {
        var c = source.decode(sourceEncoded)
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
            case .vignette(let p): c = p.apply(c, uv: uv, aspect: aspect, pre: s.pre)
            }
        }
        return TransferFunctions.bt709InverseOETF(c)
    }

    static func mixLook(_ lut: CubeLUT, _ t: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        let graded = lut.lookup(t)
        return k >= 1 ? graded : t + (graded - t) * k
    }
}
