import Foundation
#if canImport(simd)
import simd
#endif
import SQCore

/// Basic Correction "Auto Tone" on a frame as the Program monitor shows it (working-linear Rec.709, so after the input
/// transform and everything the clip already has). Tone (Exposure, Contrast, Whites, Blacks) comes from the pure maths in
/// SQCore `AutoToneSolver`; a conservative white balance (Temperature, Tint) from its near-gray sample and
/// `WhiteBalanceSolver`. Both are absolute or stop at a dead band, so pressing twice changes nothing more.
public enum AutoTone {
    /// New Basic Correction, or nil when there is nothing to do.
    public static func solve(linear: [SIMD3<Float>], current: BasicCorrection) -> BasicCorrection? {
        let luma = linear.map { TransferFunctions.bt709OETF(min(max(simd_dot(Self.luma, $0), 0), 4)) }
        // White balance first: its matrix acts on linear light before Exposure and moves gray luminance, so the tone solve
        // sees that change as a linear gain (measured on the gray it neutralises).
        var temperature = current.temperature, tint = current.tint
        var gain: Float = 1
        if let grey = AutoToneSolver.neutralSample(linear),
           let wb = WhiteBalanceSolver.solve(picked: grey, temperature: current.temperature, tint: current.tint) {
            temperature = wb.temperature; tint = wb.tint
            var next = current; next.temperature = temperature; next.tint = tint
            let change = PreparedBasic(next, gamut: .rec709).wb * PreparedBasic(current, gamut: .rec709).wb.inverse
            let before = simd_dot(Self.luma, grey)
            if before > 1e-6 { gain = simd_dot(Self.luma, change * grey) / before }
        }
        var b = AutoToneSolver.solveTone(luma: luma, current: current, linearGain: gain) ?? current
        b.temperature = temperature; b.tint = tint
        return b == current ? nil : b
    }

    /// Tone only, from display-encoded luma (see `AutoToneSolver.solveTone`).
    public static func solve(luma: [Float], current: BasicCorrection) -> BasicCorrection? {
        AutoToneSolver.solveTone(luma: luma, current: current)
    }

    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
}
