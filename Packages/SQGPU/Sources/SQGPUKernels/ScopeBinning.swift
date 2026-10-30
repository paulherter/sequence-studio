import Foundation

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
    public var waveformLumaCount: Int { waveformWidth * waveformLevels }
    public var paradeCount: Int { 3 * waveformWidth * waveformLevels }
    public var vectorCount: Int { vectorscopeSize * vectorscopeSize }
    public var histogramCount: Int { 4 * Self.histogramBins }
    public var offsetWaveformLuma: Int { 0 }
    public var offsetParade: Int { waveformLumaCount }
    public var offsetVector: Int { offsetParade + paradeCount }
    public var offsetHistogram: Int { offsetVector + vectorCount }
    public var offsetMaxima: Int { offsetHistogram + histogramCount }
    public var totalCount: Int { offsetMaxima + 4 }
}

/// Raw scope counts (what the GPU accumulates; also the CPU reference output).
///
/// Mappings (the UI draws graticules/targets with these):
/// - **Waveform luma**: `waveformLuma[row * W + col]`, row 0 = top = Y' 1.0. `level = min(floor(Y' * L), L-1)`, `row = L-1-level`.
///   IRE = Y' * 100. Y' = 0.2126 R' + 0.7152 G' + 0.0722 B' of the clamped output signal.
/// - **Parade**: `waveformParade[row * 3W + panel * W + col]`, panel 0/1/2 = R'/G'/B', same level mapping per channel.
/// - **Vectorscope** (BT.709, full range): `Cb = (B'-Y')/1.8556`, `Cr = (R'-Y')/1.5748`, both ±0.5.
///   `vectorscope[row * N + col]`, `col = clamp(floor(Cb*N + N/2 + 0.5))` (Cb → right), `row = clamp(floor(N/2 - Cr*N + 0.5))`
///   (Cr → up, row 0 = top = Cr +0.5). Bin centers sit at `Cb = (col - N/2)/N`; in normalized texture coordinates
///   (0…1, pixel edges) a point (Cb, Cr) is at `u = Cb + 0.5 + 0.5/N`, `v = 0.5 - Cr + 0.5/N`. Gray lands in bin (N/2, N/2).
///   Targets: a 709 color with R'G'B' → compute Cb/Cr with `ScopeBinning.cbcr`. Skin-tone line: hue angle ≈ 123° from +Cb axis
///   counter-clockwise (i.e. atan2(Cr, Cb) ≈ 123° → upper-left of center, between R and Yl targets).
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

/// The binning half of the scopes, shared by every platform: the CPU twin of `Scopes.slang` from the output signal on.
/// `SQRender.ScopesReference` feeds it the Mac's working-linear pixels (through `Rec709Output.encode`); the Windows app
/// feeds it the decoded Rec.709 picture, which already is the output signal.
public enum ScopeBinning {
    /// BT.709 full-range Cb/Cr (±0.5) of an R'G'B' signal.
    public static func cbcr(_ rgb: SIMD3<Float>) -> SIMD2<Float> {
        let y = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
        return SIMD2((rgb.z - y) / 1.8556, (rgb.x - y) / 1.5748)
    }

    public static func level(_ v: Float, levels: Int) -> Int { min(Int(v * Float(levels)), levels - 1) }

    /// (col, row) in the vectorscope, see `ScopeCounts`.
    public static func vectorscopeBin(cb: Float, cr: Float, size n: Int) -> (col: Int, row: Int) {
        let nf = Float(n)
        let c = min(max((cb * nf + nf / 2 + 0.5).rounded(.down), 0), nf - 1)
        let r = min(max((nf / 2 - cr * nf + 0.5).rounded(.down), 0), nf - 1)
        return (Int(c), Int(r))
    }

    /// Adds one output-signal pixel (R'G'B' 0...1, its Y') at source column `x` of `width`.
    @inline(__always)
    public static func add(_ rgb: SIMD3<Float>, luma: Float, x: Int, width: Int, to out: inout ScopeCounts) {
        let l = out.layout
        let W = l.waveformWidth, L = l.waveformLevels, N = l.vectorscopeSize
        let col = min(x * W / width, W - 1)
        out.waveformLuma[(L - 1 - level(luma, levels: L)) * W + col] += 1
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

    /// Fills the four maxima after the last `add`.
    public static func finish(_ out: inout ScopeCounts) {
        out.maxWaveformLuma = out.waveformLuma.max() ?? 0
        out.maxWaveformParade = out.waveformParade.max() ?? 0
        out.maxVectorscope = out.vectorscope.max() ?? 0
        out.maxHistogram = out.histogram.max() ?? 0
    }

    /// Scopes of an 8-bit NV12 picture (luma plane, then interleaved CbCr, stride = width): the decoded Rec.709 signal,
    /// converted to R'G'B' with the BT.709 matrix like the D3D12 picture shader. `pixelStride` N samples every N-th pixel.
    public static func compute(nv12 bytes: [UInt8], width: Int, height: Int, fullRange: Bool, layout: ScopeLayout,
                               pixelStride: Int = 1) -> ScopeCounts {
        var out = ScopeCounts(layout: layout)
        guard width > 1, height > 1, bytes.count >= width * height * 3 / 2 else { return out }
        let step = max(1, pixelStride)
        let chroma = width * height
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                var yy = Float(bytes[y * width + x]) / 255
                let ci = chroma + (y / 2) * width + (x / 2) * 2
                var cb = Float(bytes[ci]) / 255, cr = Float(bytes[ci + 1]) / 255
                if fullRange { cb -= 128.0 / 255; cr -= 128.0 / 255 } else {
                    yy = (yy * 255 - 16) / 219; cb = (cb * 255 - 128) / 224; cr = (cr * 255 - 128) / 224
                }
                let r = yy + 1.5748 * cr, g = yy - 0.1873 * cb - 0.4681 * cr, b = yy + 1.8556 * cb
                let rgb = SIMD3<Float>(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
                let luma = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
                add(rgb, luma: luma, x: x, width: width, to: &out)
            }
        }
        finish(&out)
        return out
    }

    /// Scopes of an 8-bit RGBA picture (R'G'B' as shown, row stride = width * 4): the composited frame the Windows
    /// compositor hands over when it draws more than one layer.
    public static func compute(rgba bytes: [UInt8], width: Int, height: Int, layout: ScopeLayout,
                               pixelStride: Int = 1) -> ScopeCounts {
        var out = ScopeCounts(layout: layout)
        guard width > 1, height > 1, bytes.count >= width * height * 4 else { return out }
        let step = max(1, pixelStride)
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let o = (y * width + x) * 4
                let rgb = SIMD3<Float>(Float(bytes[o]), Float(bytes[o + 1]), Float(bytes[o + 2])) / 255
                add(rgb, luma: rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722, x: x, width: width, to: &out)
            }
        }
        finish(&out)
        return out
    }
}
