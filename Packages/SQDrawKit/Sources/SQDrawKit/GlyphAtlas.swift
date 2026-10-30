import Foundation
import SQText

/// Glyph coverage packed into one 8-bit texture (shelf packing). Glyphs sit on whole pixels, so the GPU and the
/// software renderer read the same texels without filtering. Main-thread object: the UI owns one.
/// Faces: 0 is the UI font; `face(for:)` adds another font (look and template previews) whose glyphs share the page, so
/// renderers need nothing new.
/// Fallback: a character the face has no glyph for (the Mac system font has no ⇥ ↩ ↵ ⇞ ⇟ ␣ ◆) draws from the bundled
/// Inter at the same weight, so symbol keys render on the Mac and on Windows alike.
/// shortcut: a full atlas is cleared and refilled (no eviction policy); upgrade when UI text grows past one 1024² page.
public final class GlyphAtlas {
    public struct Entry: Sendable, Equatable { public var x, y, w, h, left, top: Int }
    private struct Key: Hashable { var glyph: Int; var size: Int; var face: Int }

    public let size: Int
    /// Device pixels per point of the window (backing scale, not the Interface Size): the system font's tracking depends on
    /// the point size. The host sets it with the scale; 1 until then.
    public var pointScale: Float = 1
    public private(set) var pixels: [UInt8]
    /// Bumped whenever `pixels` changed (the renderer re-uploads on a new value).
    public private(set) var generation = 0
    public let font: GlyphRasterFont
    /// Every face baked into the page; `faces[0]` is `font`.
    public private(set) var faces: [GlyphRasterFont]
    /// More faces than this fall back to the UI face (a preview grid of many families must not thrash the page).
    public static let maxFaces = 16
    private var entries: [Key: Entry] = [:]
    /// Per face: glyph and advance (font units) of each character met so far; ASCII in a flat table. The cmap and hmtx
    /// reads cost more than the rest of a text draw (Color page round 6 profile).
    private var asciiMetrics: [[Metric?]] = []
    private var otherMetrics: [[UInt32: Metric]] = []
    private var shelfX = 1, shelfY = 1, shelfH = 0

    public init?(font: GlyphRasterFont? = .inter, size: Int = 1024) {
        guard let font else { return nil }
        self.font = font; self.size = size; faces = [font]
        pixels = [UInt8](repeating: 0, count: size * size)
    }

    /// Size key in quarter pixels.
    private static func key(_ px: Float) -> Int { Int((px * 4).rounded()) }

    /// The face index of `f` (added on first use); 0 (the UI face) once `maxFaces` are in.
    public func face(for f: GlyphRasterFont) -> Int {
        if let i = faces.firstIndex(where: { $0 === f }) { return i }
        guard faces.count < Self.maxFaces else { return 0 }
        faces.append(f)
        return faces.count - 1
    }

    /// The face of the UI font's SemiBold (`GlyphRasterFont.interSemibold`; the UI face when the font has no weight
    /// axis): panel titles, card titles and empty-state titles, as the Mac UI sets them.
    public private(set) lazy var semiboldFace: Int = {
        let i = font === GlyphRasterFont.inter
            ? GlyphRasterFont.interSemibold.map { face(for: $0) } ?? 0
            : font.instance(weight: 600).map { face(for: $0) } ?? 0
        if i > 0 { faceWeights[i] = 600 }
        return i
    }()

    /// The face of the UI font's Medium (`GlyphRasterFont.interMedium`; the UI face without a weight axis): dock and
    /// sequence tab titles, clip names and the Export button, as the Mac UI sets them.
    public private(set) lazy var mediumFace: Int = {
        let i = font === GlyphRasterFont.inter
            ? GlyphRasterFont.interMedium.map { face(for: $0) } ?? 0
            : font.instance(weight: 500).map { face(for: $0) } ?? 0
        if i > 0 { faceWeights[i] = 500 }
        return i
    }()

    /// Weight of the SemiBold and Medium faces (everything else falls back to Inter regular).
    private var faceWeights: [Int: Int] = [:]
    /// Per face: the face missing characters draw from (nil: Inter itself, no fallback).
    private var fallbacks: [Int: Int?] = [:]

    /// The bundled Inter face at face `f`'s weight; nil when `f` already is Inter (or no Inter is bundled).
    func fallbackFace(of f: Int) -> Int? {
        if let known = fallbacks[f] { return known }
        let own = self.font(face: f)
        let inters = [GlyphRasterFont.inter, GlyphRasterFont.interMedium, GlyphRasterFont.interSemibold]
        var answer: Int?
        if !inters.contains(where: { $0 === own }) {
            let w = faceWeights[f] ?? 400
            let weighted = w >= 600 ? GlyphRasterFont.interSemibold : w >= 500 ? GlyphRasterFont.interMedium : GlyphRasterFont.inter
            if let inter = weighted ?? GlyphRasterFont.inter {
                let i = face(for: inter)
                answer = i != f && faces[i] === inter ? i : nil
            }
        }
        fallbacks[f] = answer
        return answer
    }

    /// Cap height of the UI face per em (Inter 0.727, San Francisco about 0.70), measured once from its "H".
    public private(set) lazy var capHeightRatio: Float = {
        let h = font.glyph(for: "H")
        let bmp = font.rasterize(glyph: h, pixelsPerEm: 200)
        return h != 0 && bmp.height > 0 ? Float(bmp.height) / 200 : 0.727
    }()

    /// The font of face `i` (the UI face for an unknown index).
    public func font(face i: Int) -> GlyphRasterFont { faces.indices.contains(i) ? faces[i] : font }

    /// A character's glyph and advance in font units of the asked face (`GlyphRasterFont.glyph(for:)` /
    /// `advance(glyph:)`), cached; `face` is the face that holds the glyph (the fallback face for a missing character).
    public struct Metric: Sendable, Equatable { public var glyph: Int; public var advance: Int; public var face: Int }
    public func metric(for u: Unicode.Scalar, face: Int = 0) -> Metric {
        let f = faces.indices.contains(face) ? face : 0
        while asciiMetrics.count <= f { asciiMetrics.append([Metric?](repeating: nil, count: 128)); otherMetrics.append([:]) }
        let v = u.value
        if v < 128, let m = asciiMetrics[f][Int(v)] { return m }
        if v >= 128, let m = otherMetrics[f][v] { return m }
        let font = faces[f]
        // The Mac UI sets every digit tabular (AppKit `monospacedDigitSystemFont`, `Theme.Typography.ns`).
        var g = font.glyph(for: u)
        if v >= 0x30, v <= 0x39 { g = font.tabularGlyph(g) }
        var m = Metric(glyph: g, advance: font.advance(glyph: g), face: f)
        if g == 0, v >= 0x20, let fb = fallbackFace(of: f) {
            let other = faces[fb], h = other.glyph(for: u)
            if h != 0 {
                let adv = Double(other.advance(glyph: h)) * Double(font.unitsPerEm) / Double(other.unitsPerEm)
                m = Metric(glyph: h, advance: Int(adv.rounded()), face: fb)
            }
        }
        if v < 128 { asciiMetrics[f][Int(v)] = m } else { otherMetrics[f][v] = m }
        return m
    }

    /// Core Text draws the system font with font smoothing, which thickens every stem: measured on the Mac, white 13 pt text
    /// carries about 1.3 times the ink of the plain outline coverage (regular, 1x and 2x). A coverage curve (exponent
    /// `stemDarkeningExponent`) gives the shared UI that weight. shortcut: one curve for every size and weight; upgrade to
    /// per-weight curves if semibold looks too heavy next to AppKit.
    static let stemDarkeningExponent = 0.42
    static let stemDarkening: [UInt8] = (0...255).map { UInt8((pow(Double($0) / 255, stemDarkeningExponent) * 255).rounded()) }

    public func entry(glyph: Int, pixelSize: Float, face: Int = 0) -> Entry {
        let k = Key(glyph: glyph, size: Self.key(pixelSize), face: faces.indices.contains(face) ? face : 0)
        if let e = entries[k] { return e }
        let bmp = font(face: k.face).rasterize(glyph: glyph, pixelsPerEm: Double(k.size) / 4)
        guard bmp.width > 0, bmp.height > 0, bmp.width + 2 < size, bmp.height + 2 < size else {
            let e = Entry(x: 0, y: 0, w: 0, h: 0, left: 0, top: 0); entries[k] = e; return e
        }
        if shelfX + bmp.width + 1 > size { shelfX = 1; shelfY += shelfH + 1; shelfH = 0 }
        if shelfY + bmp.height + 1 > size {
            pixels = [UInt8](repeating: 0, count: size * size); entries.removeAll(); shelfX = 1; shelfY = 1; shelfH = 0
        }
        let darken = faces[k.face].hasSystemTypography
        for row in 0..<bmp.height {
            let dst = (shelfY + row) * size + shelfX
            let src = bmp.coverage[(row * bmp.width)..<((row + 1) * bmp.width)]
            pixels.replaceSubrange(dst..<(dst + bmp.width), with: darken ? src.map { Self.stemDarkening[Int($0)] } : Array(src))
        }
        let e = Entry(x: shelfX, y: shelfY, w: bmp.width, h: bmp.height, left: bmp.left, top: bmp.top)
        shelfX += bmp.width + 1; shelfH = max(shelfH, bmp.height)
        entries[k] = e
        generation += 1
        return e
    }

    // MARK: Text

    /// Advance of `text` in pixels at `pixelSize` (pen positions round to whole pixels, as drawn). The system font is set as
    /// Core Text sets it: pair kerning, and the `trak` tracking after every glyph.
    public func width(of text: String, pixelSize: Float, face: Int = 0) -> Float {
        var pen: Float = 0
        var run = TextRun(atlas: self, pixelSize: pixelSize, face: face)
        for u in text.unicodeScalars { pen += run.step(u).advance }
        return pen.rounded()
    }

    /// One walk along a line: the metric of each scalar and its pen advance in pixels (advance, kerning against the glyph
    /// before it, tracking).
    struct TextRun {
        let atlas: GlyphAtlas, pixelSize: Float, face: Int
        private var prev: Metric?
        private var trackFor: [Int: Float] = [:]
        init(atlas: GlyphAtlas, pixelSize: Float, face: Int) { self.atlas = atlas; self.pixelSize = pixelSize; self.face = face }

        /// `advance` is the pen movement from the previous glyph's origin to this glyph's origin plus its own tracking:
        /// kerning moves this glyph, so draws place it at `pen + kern`.
        mutating func step(_ u: Unicode.Scalar) -> (metric: Metric, kern: Float, advance: Float) {
            let m = atlas.metric(for: u, face: face)
            let font = atlas.faces[m.face]
            let s = pixelSize / Float(font.unitsPerEm)
            var kern: Float = 0
            var track: Float = 0
            if font.hasSystemTypography {
                if let p = prev, p.face == m.face { kern = Float(atlas.kern(p.glyph, m.glyph, face: m.face)) * s }
                if let t = trackFor[m.face] { track = t } else {
                    track = Float(font.trackingUnits(pointSize: Double(pixelSize / atlas.pointScale))) * s
                    trackFor[m.face] = track
                }
            }
            prev = m
            return (m, kern, Float(m.advance) * s + kern + track)
        }
    }

    private var kernCache: [UInt64: Double] = [:]
    func kern(_ a: Int, _ b: Int, face: Int) -> Double {
        let k = UInt64(face) << 48 | UInt64(a) << 24 | UInt64(b)
        if let v = kernCache[k] { return v }
        let v = faces[face].kernUnits(a, b)
        kernCache[k] = v
        return v
    }

    /// `text` shortened with a trailing ellipsis to fit `maxWidth` (nil when not even the ellipsis fits).
    public func fitted(_ text: String, pixelSize: Float, maxWidth: Float, face: Int = 0) -> String? {
        fittedWithWidth(text, pixelSize: pixelSize, maxWidth: maxWidth, face: face)?.text
    }

    /// `fitted` and the width of its answer (one measure for the common text that fits).
    func fittedWithWidth(_ text: String, pixelSize: Float, maxWidth: Float, face: Int = 0) -> (text: String, width: Float)? {
        let full = width(of: text, pixelSize: pixelSize, face: face)
        if full <= maxWidth { return (text, full) }
        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            let t = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            let w = width(of: t, pixelSize: pixelSize, face: face)
            if w <= maxWidth { return (t, w) }
        }
        let w = width(of: "…", pixelSize: pixelSize, face: face)
        return w <= maxWidth ? ("…", w) : nil
    }

    /// Line metrics in pixels at `pixelSize`.
    public func ascent(pixelSize: Float, face: Int = 0) -> Float {
        let font = font(face: face)
        return Float(font.ascender) * pixelSize / Float(font.unitsPerEm)
    }
    public func descent(pixelSize: Float, face: Int = 0) -> Float {
        let font = font(face: face)
        return Float(-font.descender) * pixelSize / Float(font.unitsPerEm)
    }
}

public extension DrawList {
    enum TextAlign: Sendable { case left, center, right }

    /// Draws one line of text with its baseline at `baseline`; `x` is the left, center or right edge per `align`.
    /// Text longer than `maxWidth` ends in an ellipsis. Returns the drawn width.
    @discardableResult
    mutating func text(_ s: String, x: Float, baseline: Float, pixelSize: Float, color: DrawColor, atlas: GlyphAtlas,
                       align: TextAlign = .left, maxWidth: Float = .infinity, face: Int = 0) -> Float {
        guard let fit = atlas.fittedWithWidth(s, pixelSize: pixelSize, maxWidth: maxWidth, face: face) else { return 0 }
        let t = fit.text, w = fit.width
        var penX: Float
        switch align {
        case .left: penX = x
        case .center: penX = x - w / 2
        case .right: penX = x - w
        }
        penX = penX.rounded()
        let base = baseline.rounded()
        var advance: Float = 0
        var run = GlyphAtlas.TextRun(atlas: atlas, pixelSize: pixelSize, face: face)
        for u in t.unicodeScalars {
            let step = run.step(u), m = step.metric
            let e = atlas.entry(glyph: m.glyph, pixelSize: pixelSize, face: m.face)
            if e.w > 0 {
                let gx = penX + (advance + step.kern).rounded() + Float(e.left), gy = base - Float(e.top)
                glyph(DrawRect(x: gx, y: gy, w: Float(e.w), h: Float(e.h)), atlasX: e.x, atlasY: e.y, color)
            }
            advance += step.advance
        }
        return w
    }

    /// Text centered vertically in `rect` (cap height centered), aligned horizontally per `align`, clipped to `rect` width.
    @discardableResult
    mutating func text(_ s: String, in rect: DrawRect, pixelSize: Float, color: DrawColor, atlas: GlyphAtlas,
                       align: TextAlign = .left, inset: Float = 0, face: Int = 0) -> Float {
        let capHeight = pixelSize * atlas.capHeightRatio
        let baseline = rect.midY + capHeight / 2
        let x: Float = switch align {
        case .left: rect.x + inset
        case .center: rect.midX
        case .right: rect.maxX - inset
        }
        return text(s, x: x, baseline: baseline, pixelSize: pixelSize, color: color, atlas: atlas, align: align,
                    maxWidth: max(0, rect.w - 2 * inset), face: face)
    }
}
