import simd

/// Rec.709 1-1-1 output: working-linear -> clamp 0…1 -> BT.709 OETF.
public enum Rec709Output {
    /// H.273 / CICP codes written as the output tags.
    public static let colorPrimaries = 1
    public static let transferFunction = 1
    public static let yCbCrMatrix = 1

    @inline(__always) public static func encode(_ workingLinear: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_clamp(workingLinear, SIMD3<Float>.zero, SIMD3<Float>.one)
        return TransferFunctions.bt709OETF(c)
    }
}
