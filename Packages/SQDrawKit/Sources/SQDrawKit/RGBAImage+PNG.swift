import Foundation

/// Export Frame on platforms without ImageIO: the decoded NV12 picture as RGBA, written as a PNG file.
extension RGBAImage {
    /// An 8-bit NV12 picture (luma plane, then interleaved CbCr, stride = width) as RGBA through the Rec.709 matrix;
    /// `fullRange` false scales video levels (16-235 / 16-240) to full.
    public init(nv12 bytes: [UInt8], width: Int, height: Int, fullRange: Bool) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height * 4))
        guard width > 0, height > 0, bytes.count >= width * height + width * ((height + 1) / 2) else { return }
        let ys: Float = fullRange ? 1 : 255 / 219, cs: Float = fullRange ? 1 : 255 / 224, y0: Float = fullRange ? 0 : 16
        let chroma = width * height
        func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v + 0.5))) }
        for y in 0..<height {
            let crow = chroma + (y / 2) * width
            for x in 0..<width {
                let l = (Float(bytes[y * width + x]) - y0) * ys
                let c = crow + (x & ~1)
                let cb = (Float(bytes[c]) - 128) * cs, cr = (Float(bytes[c + 1]) - 128) * cs
                let o = (y * width + x) * 4
                pixels[o] = clamp(l + 1.5748 * cr)
                pixels[o + 1] = clamp(l - 0.1873 * cb - 0.4681 * cr)
                pixels[o + 2] = clamp(l + 1.8556 * cb)
            }
        }
    }

    /// The picture box-averaged down to `maxWidth` pixels wide (same aspect, at least 1 high); unchanged when it is not wider.
    /// Template thumbnails (320 px) on platforms without ImageIO.
    public func scaled(maxWidth: Int) -> RGBAImage {
        guard width > maxWidth, maxWidth > 0, height > 0, pixels.count >= width * height * 4 else { return self }
        let w = maxWidth, h = max(1, height * w / width)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
            for x in 0..<w {
                let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
                var sum = [Int](repeating: 0, count: 4)
                for yy in y0..<y1 { for xx in x0..<x1 { let i = (yy * width + xx) * 4; for c in 0..<4 { sum[c] += Int(pixels[i + c]) } } }
                let n = (y1 - y0) * (x1 - x0), o = (y * w + x) * 4
                for c in 0..<4 { out[o + c] = UInt8((sum[c] + n / 2) / n) }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// The picture as a PNG file (8-bit RGBA, no filter).
    /// shortcut: stored (uncompressed) deflate blocks, so a 1080p frame is about 8 MB; upgrade to a real deflate
    /// (zlib through FFmpeg's libz or a small LZ77) if frame sizes matter.
    public func pngData() -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            let t = Array(type.utf8)
            out.append(contentsOf: Self.be32(UInt32(body.count)))
            out.append(contentsOf: t)
            out.append(contentsOf: body)
            out.append(contentsOf: Self.be32(Self.crc32(t + body)))
        }
        chunk("IHDR", Self.be32(UInt32(width)) + Self.be32(UInt32(height)) + [8, 6, 0, 0, 0])
        // Scanlines with filter byte 0, wrapped in zlib: header, stored blocks of at most 65535 bytes, Adler-32.
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 4 + 1))
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: pixels[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, raw.count - i)
            let last: UInt8 = i + n >= raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z.append(contentsOf: raw[i..<(i + n)])
            i += n
        } while i < raw.count
        z += Self.be32(Self.adler32(raw))
        chunk("IDAT", z)
        chunk("IEND", [])
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    nonisolated(unsafe) private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunkStart in stride(from: 0, to: bytes.count, by: 5552) {
            for x in bytes[chunkStart..<min(chunkStart + 5552, bytes.count)] { a += UInt32(x); b += a }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }
}
