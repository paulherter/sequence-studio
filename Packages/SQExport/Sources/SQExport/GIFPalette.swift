import Foundation

/// The 256 colors of one animated-GIF frame (each frame gets its own table, as on the Mac: a scene change does not
/// inherit the palette of the shot before it). Used by the Windows writer (`FFmpegExportEncoder`); the Mac quantizes
/// through ImageIO.
/// Median cut over a 5-bit-per-channel histogram, each box's color the pixel-weighted mean, then every pixel to the
/// nearest palette color (no dithering, so a still area stays still from frame to frame).
/// shortcut: no dithering and no transparency; add error diffusion when gradients band visibly in delivered GIFs.
public enum GIFPalette {
    public struct Frame: Sendable, Equatable {
        /// One palette index per pixel, rows top down.
        public var indices: [UInt8]
        /// Up to 256 colors as (r, g, b).
        public var colors: [(UInt8, UInt8, UInt8)]
        public static func == (a: Frame, b: Frame) -> Bool {
            a.indices == b.indices && a.colors.count == b.colors.count
                && zip(a.colors, b.colors).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
        }
    }

    /// `pixels`: `width * height` packed 4-byte pixels, `rOffset` / `gOffset` / `bOffset` the channel bytes (RGBA: 0, 1, 2;
    /// BGRA: 2, 1, 0), rows `bytesPerRow` apart.
    public static func quantize(_ pixels: UnsafeRawBufferPointer, width w: Int, height h: Int, bytesPerRow: Int,
                                rOffset: Int = 0, gOffset: Int = 1, bOffset: Int = 2, maxColors: Int = 256) -> Frame {
        let n = w * h
        guard n > 0 else { return Frame(indices: [], colors: []) }
        @inline(__always) func rgb(_ p: Int) -> (Int, Int, Int) {
            let o = (p / w) * bytesPerRow + (p % w) * 4
            return (Int(pixels[o + rOffset]), Int(pixels[o + gOffset]), Int(pixels[o + bOffset]))
        }
        // Exact colors when the frame has few (flat graphics stay exact).
        var exact: [UInt32: UInt8] = [:]
        var exactColors: [(UInt8, UInt8, UInt8)] = []
        var fits = true
        var indices = [UInt8](repeating: 0, count: n)
        for p in 0..<n {
            let (r, g, b) = rgb(p)
            let key = UInt32(r << 16 | g << 8 | b)
            if let i = exact[key] { indices[p] = i; continue }
            guard exactColors.count < maxColors else { fits = false; break }
            exact[key] = UInt8(exactColors.count)
            indices[p] = UInt8(exactColors.count)
            exactColors.append((UInt8(r), UInt8(g), UInt8(b)))
        }
        if fits { return Frame(indices: indices, colors: exactColors) }

        // Histogram of 15-bit colors with channel sums (for the box means).
        var count = [Int](repeating: 0, count: 32768)
        var sums = [Int](repeating: 0, count: 32768 * 3)
        for p in 0..<n {
            let (r, g, b) = rgb(p)
            let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            count[k] += 1; sums[k * 3] += r; sums[k * 3 + 1] += g; sums[k * 3 + 2] += b
        }
        let used = (0..<32768).filter { count[$0] > 0 }
        struct Box { var keys: [Int]; var pixels: Int }
        func axisRange(_ keys: [Int]) -> (axis: Int, span: Int) {
            var lo = [31, 31, 31], hi = [0, 0, 0]
            for k in keys {
                let c = [(k >> 10) & 31, (k >> 5) & 31, k & 31]
                for a in 0..<3 { lo[a] = min(lo[a], c[a]); hi[a] = max(hi[a], c[a]) }
            }
            let spans = (0..<3).map { hi[$0] - lo[$0] }
            let a = spans.firstIndex(of: spans.max()!)!
            return (a, spans[a])
        }
        var boxes = [Box(keys: used, pixels: n)]
        while boxes.count < maxColors {
            // Split the box with the most pixels that still has a span (ties: the first).
            guard let bi = boxes.indices.filter({ boxes[$0].keys.count > 1 }).max(by: { boxes[$0].pixels < boxes[$1].pixels })
            else { break }
            let box = boxes[bi]
            let (axis, span) = axisRange(box.keys)
            guard span > 0 else { break }
            let shift = axis == 0 ? 10 : axis == 1 ? 5 : 0
            let sorted = box.keys.sorted { ($0 >> shift) & 31 < ($1 >> shift) & 31 }
            // Median by pixel count.
            var acc = 0, cut = 1
            for (i, k) in sorted.enumerated() {
                acc += count[k]
                if acc * 2 >= box.pixels { cut = max(1, min(sorted.count - 1, i + 1)); break }
            }
            let a = Array(sorted[..<cut]), b = Array(sorted[cut...])
            boxes[bi] = Box(keys: a, pixels: a.reduce(0) { $0 + count[$1] })
            boxes.append(Box(keys: b, pixels: b.reduce(0) { $0 + count[$1] }))
        }
        var colors: [(UInt8, UInt8, UInt8)] = []
        for box in boxes {
            var r = 0, g = 0, b = 0
            for k in box.keys { r += sums[k * 3]; g += sums[k * 3 + 1]; b += sums[k * 3 + 2] }
            let m = max(1, box.pixels)
            colors.append((UInt8((r + m / 2) / m), UInt8((g + m / 2) / m), UInt8((b + m / 2) / m)))
        }
        // Nearest palette color per histogram cell (at the cell's mean), then per pixel through the cell.
        var map = [UInt8](repeating: 0, count: 32768)
        for k in used {
            let c = max(1, count[k])
            let r = sums[k * 3] / c, g = sums[k * 3 + 1] / c, b = sums[k * 3 + 2] / c
            var best = 0, bestD = Int.max
            for (i, p) in colors.enumerated() {
                let dr = r - Int(p.0), dg = g - Int(p.1), db = b - Int(p.2)
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if d < bestD { bestD = d; best = i }
            }
            map[k] = UInt8(best)
        }
        for p in 0..<n {
            let (r, g, b) = rgb(p)
            indices[p] = map[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)]
        }
        return Frame(indices: indices, colors: colors)
    }
}
