import Foundation
import SQCore

/// Basic Correction "Auto". Looks at the luma of the picture as the Program monitor shows it (display-encoded 0…1) and
/// raises Exposure so the brightest 0.5 % land just under white, then sets Blacks so the darkest 0.5 % sit at black as far
/// as the slider reaches (Blacks moves the black point by at most 0.1). The change is added to the current Exposure and
/// Blacks (the shown picture already contains them), so pressing Auto twice is stable. Contrast, Highlights, Shadows and
/// Whites are not touched; a picture that already uses the full range is left alone.
public enum AutoTone {
    static let blackTarget: Float = 0.02, whiteTarget: Float = 0.96

    /// New Basic Correction (only Exposure and Blacks changed), or nil when there is nothing to do (empty, flat or
    /// already full-range picture).
    public static func solve(luma: [Float], current: BasicCorrection) -> BasicCorrection? {
        let v = luma.filter { $0.isFinite }.sorted()
        guard v.count >= 16 else { return nil }
        var lo = v[Int(Float(v.count - 1) * 0.005)]
        let hi = v[Int(Float(v.count - 1) * 0.995)]
        guard hi - lo >= 0.05 else { return nil }
        var b = current
        // Exposure acts on linear light: a gain of 2^ev.
        if hi < whiteTarget - 0.02 {
            let gain = TransferFunctions.bt709InverseOETF(whiteTarget) / max(TransferFunctions.bt709InverseOETF(hi), 1e-4)
            let ev = min(max(log2f(gain), 0), 5 - max(current.exposure, 0))
            b.exposure = ((current.exposure + ev) * 100).rounded() / 100
            lo = TransferFunctions.bt709OETF(TransferFunctions.bt709InverseOETF(lo) * exp2f(ev))
        }
        // Blacks: lower the black point to `lo` (an offset of lo - blackTarget), composed with the current levels
        // (x -> (x - bp) / (wp - bp)); the white point stays where it is.
        if lo > blackTarget + 0.005 {
            let bp = -0.1 * min(max(current.blacks, -100), 100) / 100, wp = 1 - 0.2 * min(max(current.whites, -100), 100) / 100
            let a0 = (lo - blackTarget) / (1 - blackTarget)            // levels (x - a0) / (1 - a0): lo -> blackTarget, 1 stays 1
            let newBP = bp + a0 * (wp - bp)
            b.blacks = min(max(-newBP / 0.1 * 100, -100), 100)
            b.blacks = (b.blacks * 10).rounded() / 10
        }
        return b == current ? nil : b
    }
}
