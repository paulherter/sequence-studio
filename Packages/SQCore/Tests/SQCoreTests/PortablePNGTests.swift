import Foundation
import Testing
@testable import SQCore

@Suite struct PortablePNGTests {
    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count) + Array(type.utf8) + body + [0, 0, 0, 0] }   // CRC not checked

    /// A zlib stream of stored blocks (no compression), the form the Windows template saver writes.
    private func stored(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65535, raw.count - at), last: UInt8 = at + n >= raw.count ? 1 : 0
            out += [last, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)] + raw[at..<(at + n)]
            at += n
        } while at < raw.count
        return out + [0, 0, 0, 0]
    }

    private func png(width: Int, height: Int, depth: Int, type: Int, rows: [[UInt8]], filters: [UInt8]? = nil,
                     plte: [UInt8] = [], trns: [UInt8] = [], compress: (([UInt8]) -> [UInt8])? = nil) -> Data {
        let bpp = max(1, (depth * [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][type]!) / 8)
        var raw: [UInt8] = []
        for (y, row) in rows.enumerated() {
            let f = filters?[y % filters!.count] ?? 0
            raw.append(f)
            for x in 0..<row.count {
                let a = x >= bpp ? Int(row[x - bpp]) : 0
                let b = y > 0 ? Int(rows[y - 1][x]) : 0
                let c = (x >= bpp && y > 0) ? Int(rows[y - 1][x - bpp]) : 0
                let pred: Int
                switch f {
                case 1: pred = a
                case 2: pred = b
                case 3: pred = (a + b) / 2
                case 4:
                    let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                    pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: pred = 0
                }
                raw.append(UInt8(truncatingIfNeeded: Int(row[x]) - pred))
            }
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(width) + be32(height) + [UInt8(depth), UInt8(type), 0, 0, 0])
        if !plte.isEmpty { out += chunk("PLTE", plte) }
        if !trns.isEmpty { out += chunk("tRNS", trns) }
        let z = (compress ?? stored)(raw)
        // Two IDAT chunks: the stream is joined across them.
        let half = z.count / 2
        out += chunk("IDAT", Array(z[..<half])) + chunk("IDAT", Array(z[half...])) + chunk("IEND", [])
        return Data(out)
    }

    @Test func rgbaWithEveryFilterKeepsStraightAlpha() throws {
        let w = 7, h = 10
        var rows: [[UInt8]] = []
        for y in 0..<h { rows.append((0..<(w * 4)).map { UInt8(truncatingIfNeeded: ($0 * 37 + y * 11) ^ (y * 5)) }) }
        let img = try #require(PortablePNG.decode(png(width: w, height: h, depth: 8, type: 6, rows: rows, filters: [0, 1, 2, 3, 4])))
        #expect(img.width == w && img.height == h)
        #expect(img.rgba == rows.flatMap { $0 })
    }

    @Test func transparencyOfTheTilePictureSurvives() throws {
        // Half transparent red over a fully transparent pixel: alpha 128 and 0 come back as they are.
        let img = try #require(PortablePNG.decode(png(width: 2, height: 1, depth: 8, type: 6, rows: [[255, 0, 0, 128, 10, 20, 30, 0]])))
        #expect(img.rgba == [255, 0, 0, 128, 10, 20, 30, 0])
    }

    @Test func rgbGrayPaletteAndSixteenBit() throws {
        let rgb = try #require(PortablePNG.decode(png(width: 2, height: 1, depth: 8, type: 2, rows: [[1, 2, 3, 4, 5, 6]])))
        #expect(rgb.rgba == [1, 2, 3, 255, 4, 5, 6, 255])
        let ga = try #require(PortablePNG.decode(png(width: 1, height: 1, depth: 8, type: 4, rows: [[100, 50]])))
        #expect(ga.rgba == [100, 100, 100, 50])
        // 4-bit gray: two pixels in one byte (0x0F -> 0 and 255).
        let g4 = try #require(PortablePNG.decode(png(width: 2, height: 1, depth: 4, type: 0, rows: [[0x0F]])))
        #expect(g4.rgba == [0, 0, 0, 255, 255, 255, 255, 255])
        // 2-bit palette with tRNS: index 1 half transparent.
        let pal = try #require(PortablePNG.decode(png(width: 3, height: 1, depth: 2, type: 3, rows: [[0b00_01_10_00]],
                                                      plte: [9, 9, 9, 200, 100, 50, 1, 2, 3], trns: [255, 128])))
        #expect(pal.rgba == [9, 9, 9, 255, 200, 100, 50, 128, 1, 2, 3, 255])
        // 16-bit RGBA: high bytes after rounding 0x8000 -> 128, 0xFFFF -> 255.
        let deep = try #require(PortablePNG.decode(png(width: 1, height: 1, depth: 16, type: 6, rows: [[0x80, 0, 0xFF, 0xFF, 0, 0, 0x40, 0]])))
        #expect(deep.rgba == [128, 255, 0, 64])
    }

    @Test func rejectsWhatItCannotRead() {
        #expect(PortablePNG.decode(Data([1, 2, 3])) == nil)
        var interlaced = [UInt8](png(width: 1, height: 1, depth: 8, type: 6, rows: [[1, 2, 3, 4]]))
        interlaced[28] = 1   // IHDR interlace byte
        #expect(PortablePNG.decode(Data(interlaced)) == nil)
        let truncated = png(width: 4, height: 4, depth: 8, type: 6, rows: Array(repeating: [UInt8](repeating: 9, count: 16), count: 4)).prefix(60)
        #expect(PortablePNG.decode(Data(truncated)) == nil)
    }

    #if canImport(Compression)
    @Test func realDeflateFromTheSystemDecodesToo() throws {
        let w = 64, h = 48
        let rows = (0..<h).map { y in (0..<(w * 4)).map { UInt8(truncatingIfNeeded: ($0 / 4 + y) * ($0 % 4 + 1)) } }
        let data = png(width: w, height: h, depth: 8, type: 6, rows: rows, filters: [0, 1, 2, 3, 4]) { raw in
            // Raw deflate from Compression, wrapped in a zlib header.
            let packed = (try? (Data(raw) as NSData).compressed(using: .zlib) as Data) ?? Data()
            return [0x78, 0x9C] + [UInt8](packed) + [0, 0, 0, 0]
        }
        let img = try #require(PortablePNG.decode(data))
        #expect(img.rgba == rows.flatMap { $0 })
    }

    @Test func rawInflateMatchesCompression() throws {
        var text = ""
        for i in 0..<5000 { text += "<Clip id=\"\(i % 97)\">Premiere \(i * 31 % 1013)</Clip>\n" }
        let raw = Data(text.utf8)
        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        #expect(packed.count < raw.count / 2)
        #expect(try RawInflate.inflate([UInt8](packed), limit: raw.count) == raw)
        #expect(throws: RawInflate.Failure.corrupt) { try RawInflate.inflate([UInt8](packed), limit: 100) }
        #expect(throws: RawInflate.Failure.corrupt) { try RawInflate.inflate([UInt8](packed.prefix(40)), limit: raw.count) }
    }
    #endif
}
