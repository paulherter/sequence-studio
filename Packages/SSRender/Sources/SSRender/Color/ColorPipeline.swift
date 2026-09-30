import simd
import SSCore

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

/// Per-clip chain: decode -> correction -> conversion (LUT or automatic) -> creative LUT -> working-linear.
/// `process` is per pixel and allocation-free; the struct is cheap to copy and mutate per frame.
public struct ColorPipeline: Sendable {
    public var source: SourceColorSpace { didSet { refresh() } }
    public var correction: ColorCorrection { didSet { refresh() } }
    public var toneMapping: ToneMapping
    public var conversionLUT: CubeLUT?
    public var creativeLUT: CubeLUT?
    /// 0 = bypass, 1 = full.
    public var creativeIntensity: Float

    /// Precomputed per clip; internal so `ColorPipelineGPU` uploads exactly the CPU values.
    private(set) var prepared: PreparedCorrection
    private(set) var toRec709: simd_float3x3

    public init(source: SourceColorSpace, correction: ColorCorrection = .neutral, toneMapping: ToneMapping = ToneMapping(),
                conversionLUT: CubeLUT? = nil, creativeLUT: CubeLUT? = nil, creativeIntensity: Float = 1) {
        self.source = source
        self.correction = correction
        self.toneMapping = toneMapping
        self.conversionLUT = conversionLUT
        self.creativeLUT = creativeLUT
        self.creativeIntensity = creativeIntensity
        prepared = correction.prepared(for: source.gamut)
        toRec709 = source.gamut.matrix(to: .rec709)
    }

    private mutating func refresh() {
        prepared = correction.prepared(for: source.gamut)
        toRec709 = source.gamut.matrix(to: .rec709)
    }

    /// source-encoded -> working-linear (Rec.709 primaries, D65).
    public func process(_ sourceEncoded: SIMD3<Float>) -> SIMD3<Float> {
        let linear = prepared.apply(source.decode(sourceEncoded))
        var display: SIMD3<Float>
        if let lut = conversionLUT {
            display = lut.lookup(source.encode(linear))
        } else {
            var c = source == .rec709 ? linear : toRec709 * linear
            if source.isHDR { c = toneMapping.apply(c) }
            display = TransferFunctions.bt709OETF(simd_max(c, SIMD3<Float>.zero))
        }
        if let lut = creativeLUT, creativeIntensity > 0 {
            let graded = lut.lookup(display)
            display = creativeIntensity >= 1 ? graded : display + (graded - display) * creativeIntensity
        }
        return TransferFunctions.bt709InverseOETF(display)
    }
}
