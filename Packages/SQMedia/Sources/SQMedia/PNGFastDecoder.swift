import Accelerate
import Compression
import Foundation

/// FB-L: own decoder for the common transparent-animation PNG (8-bit RGBA, not interlaced, no ICC profile). ImageIO
/// decodes PNG one picture at a time per process (20 parallel decodes of a 1080p frame took as long as 20 serial ones),
/// which caps a png MOV at ~28 fps; this one is plain inflate (Compression) + row unfilter + vImage and runs on every
/// core. Anything else (palette, gray, 16-bit, RGB, interlaced, color-managed incl. a non-sRGB gAMA) returns false and
/// goes to ImageIO.
enum PNGFastDecoder {
    /// Decodes `png` into premultiplied BGRA at `dst` (`width` x `height`, `rowBytes`). false = not handled here.
    static func decode(_ png: UnsafeRawBufferPointer, width: Int, height: Int, into dst: UnsafeMutableRawPointer, rowBytes: Int) -> Bool {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard png.count > 8 + 25, png.prefix(8).elementsEqual(sig) else { return false }
        func u32(_ o: Int) -> Int { Int(png[o]) << 24 | Int(png[o + 1]) << 16 | Int(png[o + 2]) << 8 | Int(png[o + 3]) }
        // Chunks: IHDR checks, IDAT ranges, color management -> ImageIO.
        var p = 8, idat: [(Int, Int)] = [], total = 0, sawHeader = false, gamma: Int?, sRGB = false
        while p + 8 <= png.count {
            let n = u32(p), type = u32(p + 4), body = p + 8
            guard n >= 0, body + n + 4 <= png.count else { return false }
            switch type {
            case 0x4948_4452:   // IHDR
                guard n == 13, u32(body) == width, u32(body + 4) == height, png[body + 8] == 8, png[body + 9] == 6,
                      png[body + 10] == 0, png[body + 11] == 0, png[body + 12] == 0 else { return false }
                sawHeader = true
            case 0x4944_4154: idat.append((body, n)); total += n   // IDAT
            case 0x6943_4350, 0x6348_524D: return false             // iCCP, cHRM: color managed
            case 0x6741_4D41: guard n == 4 else { return false }; gamma = u32(body)   // gAMA
            case 0x7352_4742: sRGB = true                            // sRGB
            case 0x4945_4E44: p = png.count; continue                // IEND
            default: break
            }
            p = body + n + 4
        }
        // A gamma other than sRGB's (1/2.2 = 45455) without an sRGB chunk: ImageIO applies it.
        if let gamma, gamma != 45_455, !sRGB { return false }
        guard sawHeader, total > 6 else { return false }
        // Contiguous zlib stream; skip the 2-byte zlib header (Compression's ZLIB is raw deflate).
        let z = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 16)
        defer { z.deallocate() }
        var o = 0
        for (at, n) in idat { z.advanced(by: o).copyMemory(from: png.baseAddress!.advanced(by: at), byteCount: n); o += n }
        let zb = z.assumingMemoryBound(to: UInt8.self)
        guard zb[0] & 0x0F == 8, zb[1] & 0x20 == 0, (Int(zb[0]) << 8 | Int(zb[1])) % 31 == 0 else { return false }
        let stride = width * 4, rawCount = height * (stride + 1)
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: rawCount)
        defer { raw.deallocate() }
        let got = compression_decode_buffer(raw, rawCount, zb + 2, total - 2, nil, COMPRESSION_ZLIB)
        guard got == rawCount else { return false }
        // Unfilter in place (each row: filter byte, then stride bytes), 4 bytes per pixel.
        var prev: UnsafeMutablePointer<UInt8>? = nil
        for y in 0..<height {
            let row = raw + y * (stride + 1) + 1
            guard unfilter(row, prev: prev, filter: row[-1], stride: stride) else { return false }
            prev = row
        }
        // RGBA straight -> BGRA premultiplied.
        var src = vImage_Buffer(data: raw + 1, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride + 1)
        var out = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        let map: [UInt8] = [2, 1, 0, 3]
        guard vImagePermuteChannels_ARGB8888(&src, &out, map, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImagePremultiplyData_RGBA8888(&out, &out, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
        return true
    }

    @inline(__always) private static func load(_ p: UnsafeMutablePointer<UInt8>) -> SIMD4<UInt8> {
        UnsafeRawPointer(p).loadUnaligned(as: SIMD4<UInt8>.self)
    }
    @inline(__always) private static func store(_ v: SIMD4<UInt8>, _ p: UnsafeMutablePointer<UInt8>) {
        UnsafeMutableRawPointer(p).storeBytes(of: v, as: SIMD4<UInt8>.self)
    }

    /// PNG filter types 0-4 on one row of 4-byte pixels; `prev` = the unfiltered row above (nil on the first row).
    static func unfilter(_ row: UnsafeMutablePointer<UInt8>, prev: UnsafeMutablePointer<UInt8>?, filter: UInt8, stride: Int) -> Bool {
        let n = stride / 4
        switch filter {
        case 0: return true
        case 1:   // Sub
            var left = SIMD4<UInt8>(repeating: 0)
            for i in 0..<n { let v = load(row + i * 4) &+ left; store(v, row + i * 4); left = v }
        case 2:   // Up
            guard let prev else { return true }
            var i = 0
            while i + 16 <= stride {
                let a = UnsafeRawPointer(row + i).loadUnaligned(as: SIMD16<UInt8>.self)
                let b = UnsafeRawPointer(prev + i).loadUnaligned(as: SIMD16<UInt8>.self)
                UnsafeMutableRawPointer(row + i).storeBytes(of: a &+ b, as: SIMD16<UInt8>.self)
                i += 16
            }
            while i < stride { row[i] &+= prev[i]; i += 1 }
        case 3:   // Average
            var left = SIMD4<UInt16>(repeating: 0)
            for i in 0..<n {
                let up = prev.map { SIMD4<UInt16>(truncatingIfNeeded: load($0 + i * 4)) } ?? .zero
                let v = load(row + i * 4) &+ SIMD4<UInt8>(truncatingIfNeeded: (left &+ up) &>> 1)
                store(v, row + i * 4); left = SIMD4<UInt16>(truncatingIfNeeded: v)
            }
        case 4:   // Paeth
            guard let prev else {   // no row above: Paeth = Sub
                var left = SIMD4<UInt8>(repeating: 0)
                for i in 0..<n { let v = load(row + i * 4) &+ left; store(v, row + i * 4); left = v }
                return true
            }
            var a = SIMD4<Int16>(repeating: 0), c = SIMD4<Int16>(repeating: 0)
            for i in 0..<n {
                let b = SIMD4<Int16>(truncatingIfNeeded: load(prev + i * 4))
                let pa = abs(b &- c), pb = abs(a &- c), pc = abs(a &+ b &- c &- c)
                // a if pa <= pb && pa <= pc, else b if pb <= pc, else c.
                let useA = (pa .<= pb) .& (pa .<= pc)
                let useB = (.!useA) .& (pb .<= pc)
                let pred = c.replacing(with: b, where: useB).replacing(with: a, where: useA)
                let v = load(row + i * 4) &+ SIMD4<UInt8>(truncatingIfNeeded: pred)
                store(v, row + i * 4)
                a = SIMD4<Int16>(truncatingIfNeeded: v); c = b
            }
        default: return false
        }
        return true
    }

    @inline(__always) private static func abs(_ v: SIMD4<Int16>) -> SIMD4<Int16> { v.replacing(with: 0 &- v, where: v .< 0) }
}
