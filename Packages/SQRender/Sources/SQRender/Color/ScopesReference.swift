import Foundation
import simd

/// Sizes of the scope accumulation buffers. All scopes read the Rec.709 output signal
/// (`Rec709Output.encode`: working-linear -> clamp 0…1 -> BT.709 OETF), so what you see is what gets exported.
public struct ScopeLayout: Sendable, Equatable {
    /// Waveform columns (source x maps proportionally: `col = x * waveformWidth / sourceWidth`).
    public var waveformWidth: Int = 512
    /// Waveform vertical bins (signal 0…1).
    public var waveformLevels: Int = 256
    /// Vectorscope is `vectorscopeSize` x `vectorscopeSize` bins.
    public var vectorscopeSize: Int = 256

    public init(waveformWidth: Int = 512, waveformLevels: Int = 256, vectorscopeSize: Int = 256) {
        self.waveformWidth = waveformWidth; self.waveformLevels = waveformLevels; self.vectorscopeSize = vectorscopeSize
    }

    public static let histogramBins = 256

    // Element offsets inside the single counts buffer (UInt32 elements).
    var waveformLumaCount: Int { waveformWidth * waveformLevels }
    var paradeCount: Int { 3 * waveformWidth * waveformLevels }
    var vectorCount: Int { vectorscopeSize * vectorscopeSize }
    var histogramCount: Int { 4 * Self.histogramBins }
    var offsetWaveformLuma: Int { 0 }
    var offsetParade: Int { waveformLumaCount }
    var offsetVector: Int { offsetParade + paradeCount }
    var offsetHistogram: Int { offsetVector + vectorCount }
    var offsetMaxima: Int { offsetHistogram + histogramCount }
    var totalCount: Int { offsetMaxima + 4 }
}

/// Raw scope counts (what the GPU accumulates; also the CPU reference output).
///
/// Mappings (the UI draws graticules/targets with these):
/// - **Waveform luma**: `waveformLuma[row * W + col]`, row 0 = top = Y' 1.0. `level = min(floor(Y' * L), L-1)`, `row = L-1-level`.
///   IRE = Y' * 100. Y' = 0.2126 R' + 0.7152 G' + 0.0722 B' of the clamped output signal.
/// - **Parade**: `waveformParade[row * 3W + panel * W + col]`, panel 0/1/2 = R'/G'/B', same level mapping per channel.
/// - **Vectorscope** (BT.709, full range): `Cb = (B'-Y')/1.8556`, `Cr = (R'-Y')/1.5748`, both ±0.5.
///   `vectorscope[row * N + col]`, `col = clamp(floor(Cb*N + N/2 + 0.5))` (Cb → right), `row = clamp(floor(N/2 - Cr*N + 0.5))`
///   (Cr → up, row 0 = top = Cr +0.5). Bin centres sit at `Cb = (col - N/2)/N`; in normalized texture coordinates
///   (0…1, pixel edges) a point (Cb, Cr) is at `u = Cb + 0.5 + 0.5/N`, `v = 0.5 - Cr + 0.5/N`. Grey lands in bin (N/2, N/2).
///   Targets: a 709 colour with R'G'B' → compute Cb/Cr with `ScopesReference.cbcr`. Skin-tone line: hue angle ≈ 123° from +Cb axis
///   counter-clockwise (i.e. atan2(Cr, Cb) ≈ 123° → upper-left of centre, between R and Yl targets).
/// - **Histogram**: `histogram[channel * 256 + bin]`, channel 0 R', 1 G', 2 B', 3 Y'; `bin = min(floor(v * 256), 255)`.
/// - **Maxima** of each scope (for normalizing/log mapping in the UI).
public struct ScopeCounts: Sendable, Equatable {
    public var layout: ScopeLayout
    public var waveformLuma: [UInt32]
    public var waveformParade: [UInt32]
    public var vectorscope: [UInt32]
    public var histogram: [UInt32]
    public var maxWaveformLuma: UInt32
    public var maxWaveformParade: UInt32
    public var maxVectorscope: UInt32
    public var maxHistogram: UInt32

    public init(layout: ScopeLayout) {
        self.layout = layout
        waveformLuma = [UInt32](repeating: 0, count: layout.waveformLumaCount)
        waveformParade = [UInt32](repeating: 0, count: layout.paradeCount)
        vectorscope = [UInt32](repeating: 0, count: layout.vectorCount)
        histogram = [UInt32](repeating: 0, count: layout.histogramCount)
        maxWaveformLuma = 0; maxWaveformParade = 0; maxVectorscope = 0; maxHistogram = 0
    }
}

/// CPU reference for the GPU scopes (same per-pixel functions and binning).
public enum ScopesReference {
    public static let lumaCoefficients = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Output signal R'G'B' (clamped 0…1, BT.709 OETF) and Y'.
    public static func signal(_ workingLinear: SIMD3<Float>) -> (rgb: SIMD3<Float>, y: Float) {
        let s = Rec709Output.encode(workingLinear)
        return (s, s.x * 0.2126 + s.y * 0.7152 + s.z * 0.0722)
    }

    /// BT.709 full-range Cb/Cr (±0.5) of an R'G'B' signal.
    public static func cbcr(_ rgb: SIMD3<Float>) -> SIMD2<Float> {
        let y = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
        return SIMD2((rgb.z - y) / 1.8556, (rgb.x - y) / 1.5748)
    }

    public static func level(_ v: Float, levels: Int) -> Int { min(Int(v * Float(levels)), levels - 1) }

    /// (col, row) in the vectorscope, see `ScopeCounts`.
    public static func vectorscopeBin(cb: Float, cr: Float, size n: Int) -> (col: Int, row: Int) {
        let nf = Float(n)
        let c = min(max(floorf(cb * nf + nf / 2 + 0.5), 0), nf - 1)
        let r = min(max(floorf(nf / 2 - cr * nf + 0.5), 0), nf - 1)
        return (Int(c), Int(r))
    }

    /// `pixels` row-major, working-linear. `pixelStride` N: only pixels with x % N == 0 and y % N == 0.
    public static func compute(pixels: [SIMD3<Float>], width: Int, height: Int, layout: ScopeLayout,
                               pixelStride: Int = 1) -> ScopeCounts {
        var out = ScopeCounts(layout: layout)
        let W = layout.waveformWidth, L = layout.waveformLevels, N = layout.vectorscopeSize
        let step = max(1, pixelStride)
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let (rgb, luma) = signal(pixels[y * width + x])
                let col = min(x * W / width, W - 1)
                let lumaRow = L - 1 - level(luma, levels: L)
                out.waveformLuma[lumaRow * W + col] += 1
                for ch in 0..<3 {
                    let row = L - 1 - level(rgb[ch], levels: L)
                    out.waveformParade[row * 3 * W + ch * W + col] += 1
                }
                let cc = cbcr(rgb)
                let b = vectorscopeBin(cb: cc.x, cr: cc.y, size: N)
                out.vectorscope[b.row * N + b.col] += 1
                let bins = ScopeLayout.histogramBins
                for ch in 0..<3 { out.histogram[ch * bins + level(rgb[ch], levels: bins)] += 1 }
                out.histogram[3 * bins + level(luma, levels: bins)] += 1
            }
        }
        out.maxWaveformLuma = out.waveformLuma.max() ?? 0
        out.maxWaveformParade = out.waveformParade.max() ?? 0
        out.maxVectorscope = out.vectorscope.max() ?? 0
        out.maxHistogram = out.histogram.max() ?? 0
        return out
    }
}
