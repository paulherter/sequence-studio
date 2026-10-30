import Foundation
#if canImport(simd)
import simd
#endif
import SQCore

/// The automatic HDR/SDR conform step: moves a clip's picture between SDR and the two HDR transfer curves before the
/// grade. All maths run on display-referred light with 1.0 = reference white (203 nit), the same unit as
/// `TransferFunctions.hlgDecode` / `pqDecode`.
///
/// `ClipColor.hdrConform` switches the HDR to SDR direction off (see `ColorPipeline.skipsToneMap`). The SDR-to-HDR and
/// HLG/PQ directions here are the maths for an HDR target; the compositor's output path is still Rec.709, so they are
/// not wired into rendering yet.
public enum HDRConform {
    /// Where SDR white lands in an HLG picture.
    public enum WhiteReference: Sendable, Equatable {
        /// SDR white at 75 % signal (203 nit, the broadcast reference white).
        case percent75
        /// SDR white at 100 % signal (the HLG peak).
        case percent100
    }

    public enum Kind: Sendable, Equatable {
        case hlgToSDR, pqToSDR
        case sdrToHLG(WhiteReference)
        case sdrToPQ(peakNits: Float)
        case hlgToPQ, pqToHLG
    }

    /// The step for a source that is converted to `target`; nil when nothing is needed (same transfer, log source).
    public static func kind(from source: SourceColorSpace, to target: TargetSpace) -> Kind? {
        switch (source, target) {
        case (.hlgBT2020, .rec709), (.hlgBT2020, .rec2020): .hlgToSDR
        case (.pqBT2020, .rec709), (.pqBT2020, .rec2020): .pqToSDR
        case (.rec709, .rec2020HLG): .sdrToHLG(.percent75)
        case (.rec709, .rec2020PQ): .sdrToPQ(peakNits: TransferFunctions.pqReferenceWhite)
        case (.hlgBT2020, .rec2020PQ): .hlgToPQ
        case (.pqBT2020, .rec2020HLG): .pqToHLG
        default: nil
        }
    }

    /// Input: the signal of the source (HLG or PQ code values) for the HDR sources, linear Rec.709 light for SDR.
    /// Output: linear Rec.709 light (0...1 after the roll-off) for `*ToSDR`, the target's code values otherwise.
    public static func convert(_ v: SIMD3<Float>, _ kind: Kind, toneMapping: ToneMapping = ToneMapping()) -> SIMD3<Float> {
        let to2020 = Gamut.rec709.matrix(to: .bt2020)
        switch kind {
        case .hlgToSDR:
            let c = Gamut.bt2020.matrix(to: .rec709) * TransferFunctions.hlgDecode(v)
            return toneMapping.apply(toneMapping.trim(c), peak: SourceColorSpace.hlgBT2020.toneMapPeak)
        case .pqToSDR:
            let c = Gamut.bt2020.matrix(to: .rec709) * TransferFunctions.pqDecode(v)
            return toneMapping.apply(toneMapping.trim(c), peak: SourceColorSpace.pqBT2020.toneMapPeak)
        case .hlgToPQ:
            return TransferFunctions.pqEncode(TransferFunctions.hlgDecode(v))
        case .pqToHLG:
            return simd_min(TransferFunctions.hlgEncode(TransferFunctions.pqDecode(v)), SIMD3(repeating: 1))
        case .sdrToHLG(let ref):
            let gain: Float = ref == .percent75 ? 1 : TransferFunctions.hlgDecode(SIMD3(repeating: 1)).x
            return simd_min(TransferFunctions.hlgEncode(to2020 * v * gain), SIMD3(repeating: 1))
        case .sdrToPQ(let peak):
            let gain = min(max(peak, 10), 10_000) / TransferFunctions.pqReferenceWhite
            return TransferFunctions.pqEncode(to2020 * v * gain)
        }
    }
}
