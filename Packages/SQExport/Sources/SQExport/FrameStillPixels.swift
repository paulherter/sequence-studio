import Foundation

/// The pixels of one image-sequence still, shared by the Mac writer (`FrameStillWriter`, ImageIO) and the Windows one
/// (`FFmpegExportEncoder`): the export frame is rgba half floats, premultiplied, linear Rec.709 light; each format gets
/// the same code values on both platforms.
/// - PNG, JPEG: 8-bit BT.709 OETF, opaque. PNG (with alpha): 8-bit straight alpha (un-premultiplied in linear light).
/// - TIFF (16-bit): the same at 16 bits. EXR: the half floats unchanged (premultiplied, linear).
public enum FrameStillPixels {
    /// RGBA rows, tightly packed, top down. `bitsPerChannel` 8 (UInt8), 16 (UInt16, little-endian) or, for EXR,
    /// 16 as IEEE half floats (`isFloat`). Channels are always four; `hasAlpha` false = alpha is opaque (skip it).
    public struct Image: Sendable, Equatable {
        public var bytes: [UInt8]
        public var width: Int
        public var height: Int
        public var bitsPerChannel: Int
        public var isFloat: Bool
        public var hasAlpha: Bool
        public var bytesPerRow: Int { width * 4 * bitsPerChannel / 8 }
    }

    /// BT.709 OETF of a linear value (clamped to 0...1).
    public static func oetf(_ x: Float) -> Float {
        let v = min(max(x, 0), 1)
        return v < 0.018053968510807 ? 4.5 * v : 1.09929682680944 * powf(v, 0.45) - 0.09929682680944
    }

    /// IEEE binary16 bits to Float (portable: Float16 is not on every platform the shared code builds for).
    @inline(__always)
    public static func float(halfBits h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int(h >> 10) & 0x1F
        let mant = UInt32(h & 0x3FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let v = Float(mant) / 1024 / 16384   // subnormal: mant * 2^-24
            return sign != 0 ? -v : v
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13)) }
        return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | mant << 13)
    }

    /// `src`: `height` rows of `width` rgba halves (little-endian), `bytesPerRow` apart.
    public static func image(halfRGBA src: UnsafeRawBufferPointer, width w: Int, height h: Int, bytesPerRow: Int,
                             format: FrameStillFormat) -> Image? {
        guard w > 0, h > 0, bytesPerRow >= w * 8, src.count >= (h - 1) * bytesPerRow + w * 8 else { return nil }
        func half(_ y: Int, _ i: Int) -> UInt16 { src.loadUnaligned(fromByteOffset: y * bytesPerRow + i * 2, as: UInt16.self) }
        if format == .exr {
            var out = [UInt8](repeating: 0, count: w * h * 8)
            out.withUnsafeMutableBytes { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w * 8, src.baseAddress! + y * bytesPerRow, w * 8) }
            }
            return Image(bytes: out, width: w, height: h, bitsPerChannel: 16, isFloat: true, hasAlpha: true)
        }
        let alpha = format.keepsAlpha
        let sixteen = format == .tiff16 || format == .tiff16Alpha
        let scale: Float = sixteen ? 65535 : 255
        var out = [UInt8](repeating: 0, count: w * h * (sixteen ? 8 : 4))
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                for x in 0..<w {
                    var r = float(halfBits: half(y, x * 4)), g = float(halfBits: half(y, x * 4 + 1))
                    var b = float(halfBits: half(y, x * 4 + 2))
                    var a: Float = 1
                    if alpha {
                        // Straight (not premultiplied) alpha: un-premultiply in linear light, then apply the curve.
                        a = min(max(float(halfBits: half(y, x * 4 + 3)), 0), 1)
                        if a > 0 { r /= a; g /= a; b /= a } else { r = 0; g = 0; b = 0 }
                    }
                    let p = (y * w + x) * 4
                    func put(_ k: Int, _ c: Float) {
                        let v = (c * scale).rounded()
                        if sixteen { dst.storeBytes(of: UInt16(v).littleEndian, toByteOffset: (p + k) * 2, as: UInt16.self) }
                        else { dst[p + k] = UInt8(v) }
                    }
                    put(0, oetf(r)); put(1, oetf(g)); put(2, oetf(b)); put(3, a)
                }
            }
        }
        return Image(bytes: out, width: w, height: h, bitsPerChannel: sixteen ? 16 : 8, isFloat: false, hasAlpha: alpha)
    }
}
