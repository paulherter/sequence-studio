import Foundation

/// A glyph's coverage bitmap: 8-bit alpha, rows top to bottom. `left`/`top` place it relative to the pen position on the
/// baseline (pixels, y down: the bitmap's top row sits `top` pixels above the baseline).
public struct GlyphBitmap: Sendable, Equatable {
    public var width: Int, height: Int
    public var left: Int, top: Int
    public var coverage: [UInt8]
    public init(width: Int, height: Int, left: Int, top: Int, coverage: [UInt8]) {
        self.width = width; self.height = height; self.left = left; self.top = top; self.coverage = coverage
    }
    public static let empty = GlyphBitmap(width: 0, height: 0, left: 0, top: 0, coverage: [])
}

/// A TrueType (`glyf`) font that maps characters, measures them and rasterizes outlines on the CPU, the same on every
/// platform (the portable UI draws its text with it: Windows and the Mac comparison renderer get identical pixels).
/// shortcut: no kerning, no hinting, CFF fonts unsupported (nil); upgrade with a `kern`/GPOS reader when UI text needs it.
public final class GlyphRasterFont: @unchecked Sendable {
    public let unitsPerEm: Int
    public let ascender: Int, descender: Int, lineGap: Int
    let face: SfntFace
    private let bytes: [UInt8]
    private let loca: Int, glyf: Int, longLoca: Bool, glyphCount: Int
    /// Normalized variation coordinates every outline and advance uses (empty: the default instance).
    public let coords: [Double]
    /// The axis values (user units) this instance was made with; `instance(weight:)` keeps the others (optical size).
    public let settings: [String: Double]

    public init?(data: Data) {
        guard let face = SfntFace(data: data) else { return nil }
        let b = face.bytes.b
        func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        var tables: [String: Int] = [:]
        for i in 0..<u16(4) {
            let rec = 12 + i * 16
            guard rec + 16 <= b.count else { return nil }
            tables[String(decoding: b[rec..<(rec + 4)], as: UTF8.self)] = u32(rec + 8)
        }
        guard let head = tables["head"], let loca = tables["loca"], let glyf = tables["glyf"], let maxp = tables["maxp"]
        else { return nil }
        self.face = face; self.bytes = face.bytes.b
        self.loca = loca; self.glyf = glyf
        longLoca = u16(head + 50) == 1
        glyphCount = u16(maxp + 4)
        unitsPerEm = face.unitsPerEm
        ascender = face.ascender; descender = face.descender; lineGap = face.lineGap
        coords = []
        settings = [:]
    }

    private init(_ base: GlyphRasterFont, coords: [Double], settings: [String: Double]) {
        face = base.face; bytes = base.bytes; loca = base.loca; glyf = base.glyf; longLoca = base.longLoca
        glyphCount = base.glyphCount; unitsPerEm = base.unitsPerEm
        ascender = base.ascender; descender = base.descender; lineGap = base.lineGap
        self.coords = coords; self.settings = settings
    }

    /// The same font at `weight` on its `wght` axis (100...900; nil for a font without one): one file, several weights.
    /// Other axes keep this instance's settings.
    public func instance(weight: Double) -> GlyphRasterFont? {
        guard face.variations?.axisIndex("wght") != nil else { return nil }
        return instance(settings.merging(["wght": weight]) { $1 })
    }

    /// The same font with the given axis values (user units, by tag; tags the font lacks are ignored, the rest stay at
    /// their defaults). nil for a font without variations.
    public func instance(_ axes: [String: Double]) -> GlyphRasterFont? {
        guard let v = face.variations else { return nil }
        var user = v.axes.map(\.defaultValue)
        var kept: [String: Double] = [:]
        for (tag, value) in axes { if let i = v.axisIndex(tag) { user[i] = value; kept[tag] = value } }
        return GlyphRasterFont(self, coords: v.normalized(user), settings: kept)
    }

    public convenience init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: d)
    }

    /// The Mac system UI font (San Francisco, the variable `SFNS.ttf` at text optical size), the face AppKit's
    /// `NSFont.systemFont` draws: the Mac shared UI's text font. nil elsewhere or when the file is missing or unreadable.
    /// shortcut: reads the system file by path and sets one optical size (13 pt) for every UI size; upgrade to a per-size
    /// optical size when small captions look too loose.
    public static let macSystemUI: GlyphRasterFont? = {
        #if os(macOS)
        guard let f = GlyphRasterFont(url: URL(fileURLWithPath: "/System/Library/Fonts/SFNS.ttf")),
              f.glyph(for: "H") != 0 else { return nil }
        return f.instance(["opsz": 13, "wght": 400]) ?? f
        #else
        return nil
        #endif
    }()

    /// The bundled Inter (regular instance of the variable font).
    public static let inter: GlyphRasterFont? = InterFont.fontURLs.lazy.compactMap { GlyphRasterFont(url: $0) }.first
    /// Inter SemiBold (600), the weight the Mac UI sets panel titles and empty-state titles in.
    public static let interSemibold: GlyphRasterFont? = inter?.instance(weight: 600)
    /// Inter Medium (500), the Mac UI's weight for tab titles, clip names and button labels.
    public static let interMedium: GlyphRasterFont? = inter?.instance(weight: 500)

    /// Whether this font carries the system font's typography (`trak` tracking, GPOS kerning): the Mac system UI font does,
    /// the bundled Inter and the Windows fonts are set without either, as before.
    public var hasSystemTypography: Bool { face.tracking != nil }
    /// The tracking Core Text adds after every glyph at `pointSize`, in font units (0 without a `trak` table).
    public func trackingUnits(pointSize: Double) -> Double { face.tracking?.at(pointSize: pointSize) ?? 0 }
    /// Pair kerning between two glyphs in font units (system typography only).
    public func kernUnits(_ a: Int, _ b: Int) -> Double { face.tracking == nil ? 0 : face.kern(a, b, coords: coords) }

    /// The tabular (equal width) form of a digit glyph, as AppKit's `monospacedDigitSystemFont` draws it (system typography
    /// only; any other glyph comes back unchanged).
    public func tabularGlyph(_ g: Int) -> Int { face.tracking == nil ? g : face.tabularDigits?.map[g] ?? g }

    public func glyph(for scalar: Unicode.Scalar) -> Int { face.glyph(for: scalar) }
    /// Advance width in font units.
    public func advance(glyph: Int) -> Int { coords.isEmpty ? face.advance(glyph: glyph) : Int(face.advance(glyph: glyph, coords: coords).rounded()) }
    /// Advance width in font units at normalized variation coordinates.
    func advance(glyph: Int, coords: [Double]) -> Double { face.advance(glyph: glyph, coords: coords) }

    // MARK: Outlines

    /// One outline point in font units.
    public struct Point: Sendable, Equatable { public var x: Double, y: Double, onCurve: Bool }

    private func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) << 8 | Int(bytes[o + 1]) : 0 }
    private func s16(_ o: Int) -> Int { let v = u16(o); return v >= 0x8000 ? v - 0x10000 : v }
    private func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }

    private func glyphRange(_ g: Int) -> (Int, Int)? {
        guard g >= 0, g < glyphCount else { return nil }
        let a = longLoca ? u32(loca + g * 4) : u16(loca + g * 2) * 2
        let b = longLoca ? u32(loca + g * 4 + 4) : u16(loca + g * 2 + 2) * 2
        return b > a ? (glyf + a, glyf + b) : nil
    }

    /// The closed contours of a glyph (composite glyphs resolved), font units, y up. `coords`: normalized variation
    /// coordinates (`gvar` deltas applied, untouched points interpolated); empty = the default instance.
    public func contours(glyph g: Int, coords: [Double] = [], depth: Int = 0) -> [[Point]] {
        guard depth < 8, let (start, _) = glyphRange(g) else { return [] }
        let n = s16(start)
        let varies = face.variations != nil && coords.contains { $0 != 0 }
        if n >= 0 {
            let contours = simpleContours(start, count: n)
            guard varies else { return contours }
            let flat = contours.flatMap { $0 }
            var ends: [Int] = [], total = 0
            for c in contours { total += c.count; ends.append(total - 1) }
            guard let d = face.variations?.deltas(glyph: g, pointCount: flat.count, original: flat, ends: ends, coords: coords)
            else { return contours }
            var k = 0
            return contours.map { c in
                c.map { p in defer { k += 1 }; return Point(x: p.x + d[k].x, y: p.y + d[k].y, onCurve: p.onCurve) }
            }
        }
        // Composite: the component offsets are the glyph's variation points.
        var components = 0
        var scan = start + 10
        while true {
            let flags = u16(scan)
            components += 1
            scan += 4 + (flags & 0x1 != 0 ? 4 : 2) + (flags & 0x8 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0)
            if flags & 0x20 == 0 || components > 256 { break }
        }
        let deltas = varies ? face.variations?.deltas(glyph: g, pointCount: components, original: nil, ends: [], coords: coords) : nil
        var component = 0
        var out: [[Point]] = []
        var o = start + 10
        while true {
            let flags = u16(o), child = u16(o + 2)
            o += 4
            var dx = 0.0, dy = 0.0
            if flags & 0x1 != 0 { dx = Double(s16(o)); dy = Double(s16(o + 2)); o += 4 } else {
                dx = Double(Int8(bitPattern: bytes[o])); dy = Double(Int8(bitPattern: bytes[o + 1])); o += 2
            }
            if flags & 0x2 == 0 { dx = 0; dy = 0 }   // point matching: unused by UI fonts
            if let deltas, component < deltas.count, flags & 0x2 != 0 { dx += deltas[component].x; dy += deltas[component].y }
            component += 1
            var m = (1.0, 0.0, 0.0, 1.0)
            func f2(_ p: Int) -> Double { Double(s16(p)) / 16384 }
            if flags & 0x8 != 0 { let s = f2(o); m = (s, 0, 0, s); o += 2 } else if flags & 0x40 != 0 {
                m = (f2(o), 0, 0, f2(o + 2)); o += 4
            } else if flags & 0x80 != 0 { m = (f2(o), f2(o + 2), f2(o + 4), f2(o + 6)); o += 8 }
            for c in contours(glyph: child, coords: coords, depth: depth + 1) {
                out.append(c.map { Point(x: $0.x * m.0 + $0.y * m.2 + dx, y: $0.x * m.1 + $0.y * m.3 + dy, onCurve: $0.onCurve) })
            }
            if flags & 0x20 == 0 { break }
        }
        return out
    }

    private func simpleContours(_ start: Int, count n: Int) -> [[Point]] {
        guard n > 0 else { return [] }
        var ends: [Int] = []
        for i in 0..<n { ends.append(u16(start + 10 + i * 2)) }
        let points = (ends.last ?? -1) + 1
        var o = start + 10 + n * 2
        o += 2 + u16(o)
        var flags: [UInt8] = []
        flags.reserveCapacity(points)
        while flags.count < points, o < bytes.count {
            let f = bytes[o]; o += 1
            flags.append(f)
            if f & 0x8 != 0, o < bytes.count {
                let r = Int(bytes[o]); o += 1
                for _ in 0..<r where flags.count < points { flags.append(f) }
            }
        }
        func coords(_ short: UInt8, _ same: UInt8) -> [Double] {
            var v = 0, out: [Double] = []
            out.reserveCapacity(points)
            for f in flags {
                if f & short != 0 { let d = Int(bytes[o]); o += 1; v += f & same != 0 ? d : -d } else if f & same == 0 {
                    v += s16(o); o += 2
                }
                out.append(Double(v))
            }
            return out
        }
        let xs = coords(0x2, 0x10), ys = coords(0x4, 0x20)
        var result: [[Point]] = []
        var first = 0
        for e in ends where e < points && e >= first {
            result.append((first...e).map { Point(x: xs[$0], y: ys[$0], onCurve: flags[$0] & 1 != 0) })
            first = e + 1
        }
        return result
    }

    // MARK: Raster

    /// Rasterizes a glyph at `pixelsPerEm` (pen on an integer pixel, no hinting).
    public func rasterize(glyph g: Int, pixelsPerEm: Double) -> GlyphBitmap {
        let s = pixelsPerEm / Double(unitsPerEm)
        let lines = Self.flatten(contours(glyph: g, coords: coords), scale: s)
        guard !lines.isEmpty else { return .empty }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for l in lines { minX = min(minX, l.0, l.2); maxX = max(maxX, l.0, l.2); minY = min(minY, l.1, l.3); maxY = max(maxY, l.1, l.3) }
        let left = Int(minX.rounded(.down)), right = Int(maxX.rounded(.up))
        let bottom = Int(minY.rounded(.down)), top = Int(maxY.rounded(.up))
        let w = max(1, right - left), h = max(1, top - bottom)
        var r = CoverageRasterizer(width: w, height: h)
        for l in lines {
            r.line(Float(l.0 - Double(left)), Float(Double(top) - l.1), Float(l.2 - Double(left)), Float(Double(top) - l.3))
        }
        return GlyphBitmap(width: w, height: h, left: left, top: top, coverage: r.coverage())
    }

    /// Contours to line segments (x0, y0, x1, y1) in pixels, y up; quadratic curves split by their size.
    static func flatten(_ contours: [[Point]], scale s: Double) -> [(Double, Double, Double, Double)] {
        var out: [(Double, Double, Double, Double)] = []
        for c in contours where c.count > 1 {
            // Start on an on-curve point (or the midpoint of two off-curve points).
            var pts = c.map { Point(x: $0.x * s, y: $0.y * s, onCurve: $0.onCurve) }
            if let i = pts.firstIndex(where: { $0.onCurve }) { pts = Array(pts[i...] + pts[..<i]) } else {
                let m = Point(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2, onCurve: true)
                pts.insert(m, at: 1); pts = Array(pts[1...] + pts[..<1])
            }
            var cur = pts[0]
            var ctrl: Point?
            func quad(_ p0: Point, _ c: Point, _ p1: Point) {
                let len = hypot(c.x - p0.x, c.y - p0.y) + hypot(p1.x - c.x, p1.y - c.y)
                let n = max(1, min(16, Int((len / 2).rounded(.up))))
                var px = p0.x, py = p0.y
                for k in 1...n {
                    let t = Double(k) / Double(n), u = 1 - t
                    let x = u * u * p0.x + 2 * u * t * c.x + t * t * p1.x
                    let y = u * u * p0.y + 2 * u * t * c.y + t * t * p1.y
                    out.append((px, py, x, y)); px = x; py = y
                }
            }
            for p in pts[1...] + [pts[0]] {
                if p.onCurve {
                    if let c = ctrl { quad(cur, c, p) } else { out.append((cur.x, cur.y, p.x, p.y)) }
                    cur = p; ctrl = nil
                } else if let c = ctrl {
                    let mid = Point(x: (c.x + p.x) / 2, y: (c.y + p.y) / 2, onCurve: true)
                    quad(cur, c, mid); cur = mid; ctrl = p
                } else { ctrl = p }
            }
        }
        return out
    }
}

/// Exact-area coverage of a nonzero path from line segments: each segment adds its signed area to an accumulation
/// buffer, a running sum per row gives the coverage. The accumulation approach follows font-rs (Raph Levien,
/// Apache-2.0/MIT, docs/THIRD_PARTY.md); written here from the algorithm.
public struct CoverageRasterizer: Sendable {
    public let width: Int, height: Int
    private var acc: [Float]

    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        acc = [Float](repeating: 0, count: width * height + 4)
    }

    /// A segment in pixels (y down).
    public mutating func line(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
        if abs(y0 - y1) <= 1e-6 { return }
        let (dir, ax, ay, bx, by): (Float, Float, Float, Float, Float) = y0 < y1 ? (1, x0, y0, x1, y1) : (-1, x1, y1, x0, y0)
        let dxdy = (bx - ax) / (by - ay)
        var x = ax
        if ay < 0 { x -= ay * dxdy }
        let yStart = max(0, Int(ay)), yEnd = min(height, Int(by.rounded(.up)))
        guard yStart < yEnd else { return }
        for y in yStart..<yEnd {
            let row = y * width
            let dy = min(Float(y + 1), by) - max(Float(y), ay)
            let xNext = x + dxdy * dy
            let d = dy * dir
            let (lo, hi) = x < xNext ? (x, xNext) : (xNext, x)
            let loFloor = lo.rounded(.down), hiCeil = hi.rounded(.up)
            let loI = Int(loFloor), hiI = Int(hiCeil)
            func add(_ i: Int, _ v: Float) { let k = row + i; if k >= 0 && k < acc.count { acc[k] += v } }
            if hiI <= loI + 1 {
                let mid = 0.5 * (x + xNext) - loFloor
                add(loI, d - d * mid)
                add(loI + 1, d * mid)
            } else {
                let s = 1 / (hi - lo)
                let loF = lo - loFloor
                let a0 = 0.5 * s * (1 - loF) * (1 - loF)
                let hiF = hi - hiCeil + 1
                let am = 0.5 * s * hiF * hiF
                add(loI, d * a0)
                if hiI == loI + 2 {
                    add(loI + 1, d * (1 - a0 - am))
                } else {
                    let a1 = s * (1.5 - loF)
                    add(loI + 1, d * (a1 - a0))
                    if loI + 2 < hiI - 1 { for xi in (loI + 2)..<(hiI - 1) { add(xi, d * s) } }
                    let a2 = a1 + Float(hiI - loI - 3) * s
                    add(hiI - 1, d * (1 - a2 - am))
                }
                add(hiI, d * am)
            }
            x = xNext
        }
    }

    /// 8-bit coverage, rows top to bottom.
    public func coverage() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var sum: Float = 0
        for i in 0..<(width * height) {
            sum += acc[i]
            out[i] = UInt8(min(1, abs(sum)) * 255 + 0.5)
        }
        return out
    }

    /// Coverage 0...1, rows top to bottom (the portable text raster blends in float).
    public func coverageValues() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        var sum: Float = 0
        for i in 0..<(width * height) {
            sum += acc[i]
            out[i] = min(1, abs(sum))
        }
        return out
    }
}
