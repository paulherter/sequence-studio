import Foundation

/// A PNG reader without ImageIO or FFmpeg: straight-alpha RGBA8 for the saved-template tiles on Windows (`RawInflate` +
/// row unfiltering). Handles every color type (gray, RGB, palette with tRNS, gray+alpha, RGBA) at 1 to 16 bits, not
/// interlaced. Color management chunks (gAMA, iCCP) are ignored; the pixels are taken as sRGB.
/// shortcut: Adam7 interlaced pictures return nil (the caller falls back to another decoder); upgrade when one shows up.
public enum PortablePNG {
    public struct Image: Sendable, Equatable {
        public var width: Int, height: Int
        /// width * height * 4 bytes, R G B A, straight (not premultiplied) alpha.
        public var rgba: [UInt8]
    }

    /// Largest picture taken (pixels), so a corrupt header cannot ask for gigabytes.
    static let maxPixels = 64_000_000

    public static func decode(_ data: Data) -> Image? {
        let png = [UInt8](data)
        guard png.count > 33, png.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func u32(_ o: Int) -> Int { Int(png[o]) << 24 | Int(png[o + 1]) << 16 | Int(png[o + 2]) << 8 | Int(png[o + 3]) }
        var width = 0, height = 0, depth = 0, colorType = 0
        var palette: [UInt8] = [], trns: [UInt8] = [], idat: [UInt8] = []
        var sawHeader = false, p = 8
        while p + 12 <= png.count {
            let n = u32(p), type = u32(p + 4), body = p + 8
            guard n >= 0, body + n + 4 <= png.count else { return nil }
            switch type {
            case 0x4948_4452:   // IHDR
                guard n == 13 else { return nil }
                width = u32(body); height = u32(body + 4); depth = Int(png[body + 8]); colorType = Int(png[body + 9])
                guard png[body + 10] == 0, png[body + 11] == 0, png[body + 12] == 0 else { return nil }   // method, filter, not interlaced
                sawHeader = true
            case 0x504C_5445: palette = Array(png[body..<(body + n)])   // PLTE
            case 0x7452_4E53: trns = Array(png[body..<(body + n)])      // tRNS
            case 0x4944_4154: idat.append(contentsOf: png[body..<(body + n)])   // IDAT
            case 0x4945_4E44: p = png.count; continue                   // IEND
            default: break
            }
            p = body + n + 4
        }
        guard sawHeader, width > 0, height > 0, width * height <= maxPixels else { return nil }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        let allowed: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard allowed[colorType]?.contains(depth) == true else { return nil }
        if colorType == 3, palette.count < 3 { return nil }
        let bitsPerPixel = channels * depth
        let bpp = max(1, bitsPerPixel / 8)                 // bytes per complete pixel for the filters
        let stride = (width * bitsPerPixel + 7) / 8
        guard let raw = try? RawInflate.zlib(idat, limit: height * (stride + 1)), raw.count == height * (stride + 1) else { return nil }
        // Unfilter row by row into `lines` (stride bytes each).
        var lines = [UInt8](repeating: 0, count: height * stride)
        raw.withUnsafeBytes { src in
            lines.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let filter = src[y * (stride + 1)]
                    let s = y * (stride + 1) + 1, o = y * stride, up = o - stride
                    for x in 0..<stride {
                        let a = x >= bpp ? Int(out[o + x - bpp]) : 0
                        let b = y > 0 ? Int(out[up + x]) : 0
                        let c = (x >= bpp && y > 0) ? Int(out[up + x - bpp]) : 0
                        let v = Int(src[s + x])
                        let r: Int
                        switch filter {
                        case 1: r = v + a
                        case 2: r = v + b
                        case 3: r = v + (a + b) / 2
                        case 4:
                            let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                            r = v + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                        default: r = v
                        }
                        out[o + x] = UInt8(truncatingIfNeeded: r)
                    }
                }
            }
        }
        // One sample (at most 16 bits) of line `y`, sample index `i` (pixel * channels + channel).
        func sample(_ y: Int, _ i: Int) -> Int {
            let base = y * stride
            switch depth {
            case 8: return Int(lines[base + i])
            case 16: return Int(lines[base + 2 * i]) << 8 | Int(lines[base + 2 * i + 1])
            default:
                let bit = i * depth, byte = Int(lines[base + bit / 8])
                return (byte >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
            }
        }
        let maxValue = (1 << depth) - 1
        /// The sample scaled to 8 bits.
        func to8(_ v: Int) -> UInt8 { depth == 8 ? UInt8(v) : UInt8((v * 255 + maxValue / 2) / maxValue) }
        // tRNS color key for gray / RGB.
        func key(_ k: Int) -> Int? { trns.count >= 2 * (k + 1) ? Int(trns[2 * k]) << 8 | Int(trns[2 * k + 1]) : nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let d = (y * width + x) * 4
                switch colorType {
                case 0:
                    let g = sample(y, x), v = to8(g)
                    rgba[d] = v; rgba[d + 1] = v; rgba[d + 2] = v
                    if let k = key(0), k == g { rgba[d + 3] = 0 }
                case 2:
                    let r = sample(y, x * 3), g = sample(y, x * 3 + 1), b = sample(y, x * 3 + 2)
                    rgba[d] = to8(r); rgba[d + 1] = to8(g); rgba[d + 2] = to8(b)
                    if let kr = key(0), let kg = key(1), let kb = key(2), kr == r, kg == g, kb == b { rgba[d + 3] = 0 }
                case 3:
                    let i = sample(y, x)
                    guard i * 3 + 2 < palette.count else { return nil }
                    rgba[d] = palette[i * 3]; rgba[d + 1] = palette[i * 3 + 1]; rgba[d + 2] = palette[i * 3 + 2]
                    if i < trns.count { rgba[d + 3] = trns[i] }
                case 4:
                    let v = to8(sample(y, x * 2))
                    rgba[d] = v; rgba[d + 1] = v; rgba[d + 2] = v; rgba[d + 3] = to8(sample(y, x * 2 + 1))
                default:
                    for k in 0..<4 { rgba[d + k] = to8(sample(y, x * 4 + k)) }
                }
            }
        }
        return Image(width: width, height: height, rgba: rgba)
    }
}
