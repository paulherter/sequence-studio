import Foundation

/// The Source Text parameter of `AE.ADBE Text` (base64 `StartKeyframeValue`). Two formats:
/// - current: 8-byte prefix, identifier `44 33 22 11`, then a FlatBuffer. Root field 0 -> main table: field 0 = runs
///   (each: field 0 text, field 1 style {1 size px, 8 tracking 1/1000 em}), field 1 = font PostScript names.
///   Shadow: main table fields 10 (color table, fields 0-2 = r, g, b bytes), 11 (on), 12 (opacity %), 15 (size),
///   16 (blur); angle and distance are not decoded (20/34 are constant per style, also with the shadow off). 15/16 are certain (the maintainer's Premiere panel: size 25.3,
///   blur 151 = f15 25.3, f16 151); Background: field 17 (color table), 18 (on; omitted = off), 19 (opacity %),
///   13 (size), 14 (corner radius), the same color + switch pairing as the shadow's 10 + 11. Color tables hold r, g, b
///   as one-byte fields packed side by side (offsets 4, 5, 6). Field 17 is NOT the fill: the maintainer's captions store cyan
///   75/203/214 there with 18 absent and render white in Premiere (S112 x2, TCL C8L; 2026-10-03). The fill color has
///   no non-white sample yet (white = default), so the flat format leaves `fill` nil. Stroke stays undecoded (33/40 unidentified).
///   Run style table: field 0 = index into the font list (omitted = 0), 1 = size, 8 = tracking. Premiere ends a
///   paragraph with CR ("Bis zu\r3.200", TCL C8L); the decoded text uses LF like the rest of SQ.
/// - legacy (Mister Horse and older titles): 8-byte prefix, UTF-16LE JSON `mTextParam.mStyleSheet`.
public struct PRText: Sendable, Equatable {
    /// Essential Graphics shadow, in text layer pixels.
    public struct Shadow: Sendable, Equatable {
        public var red: Double, green: Double, blue: Double
        /// 0...1.
        public var opacity: Double
        /// Premiere degrees (light direction, same convention as `TextShadow(angle:)`).
        public var angle: Double
        public var distance: Double
        /// Spread before the blur.
        public var size: Double
        public var blur: Double
    }
    public struct RGB: Sendable, Equatable {
        /// 0...1.
        public var red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    }
    public struct Stroke: Sendable, Equatable {
        public var color: RGB
        public var width: Double
    }
    /// One run of the text in one font and size.
    public struct Run: Sendable, Equatable {
        public var text: String
        public var fontName: String?
        public var size: Double?
    }
    /// The font and size of the lines after the first, when they differ from the first line's (SQ two-style text).
    public struct LineStyle: Sendable, Equatable {
        public var fontName: String?
        public var size: Double?
    }
    public var text: String
    public var runs: [Run] = []
    /// Lines 2+ in one other style than line 1 (nil = one style throughout, or `mixedStyles`).
    public var secondLine: LineStyle?
    /// Styles change inside a line, or differ between the later lines: SQ keeps the first run's style (reported).
    public var mixedStyles = false
    /// Fill color; nil = not stored or switched off (white default).
    public var fill: RGB?
    /// Stroke; only the legacy format carries it so far (nil = none / not decoded).
    public var stroke: Stroke?
    public var fontName: String?
    public var size: Double?
    /// 1/1000 em, Premiere units.
    public var tracking: Double?
    /// Area text: the paragraph box (main table fields 2, 3, px). nil = point text.
    public var boxSize: (width: Double, height: Double)?
    /// Paragraph alignment (main table field 4, NSTextAlignment order: 0 left, 1 right, 2 center); nil = left.
    public var alignment: Int?
    /// nil = no shadow (absent or switched off).
    public var shadow: Shadow?
    public struct Background: Sendable, Equatable {
        public var color: RGB
        /// 0...1.
        public var opacity: Double
        /// Premiere "Size": how far the box reaches past the text, px.
        public var size: Double
        public var cornerRadius: Double
    }
    /// nil = no background box (absent or switched off).
    public var background: Background?

    public static func == (a: PRText, b: PRText) -> Bool {
        a.text == b.text && a.fontName == b.fontName && a.size == b.size && a.tracking == b.tracking
            && a.boxSize?.width == b.boxSize?.width && a.boxSize?.height == b.boxSize?.height && a.alignment == b.alignment
            && a.shadow == b.shadow && a.fill == b.fill && a.stroke == b.stroke && a.background == b.background
            && a.runs == b.runs && a.secondLine == b.secondLine && a.mixedStyles == b.mixedStyles
    }
}

public enum PRTextBlob {
    public static func decode(base64: String) -> PRText? {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters).flatMap(decode)
    }

    public static func decode(_ data: Data) -> PRText? {
        let b = [UInt8](data)
        guard b.count > 16 else { return nil }
        if b[8] == 0x44, b[9] == 0x33, b[10] == 0x22, b[11] == 0x11 {
            return FlatReader(Array(b[12...])).premiereText()
        }
        return legacy(Array(b[8...]))
    }

    private static func legacy(_ b: [UInt8]) -> PRText? {
        guard var s = String(bytes: b, encoding: .utf16LittleEndian) else { return nil }
        while s.last == "\0" { s.removeLast() }
        guard let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let tp = json["mTextParam"] as? [String: Any] else { return nil }
        let sheet = tp["mStyleSheet"] as? [String: Any] ?? [:]
        func first(_ key: String) -> Any? {
            ((sheet[key] as? [String: Any])?["mParamValues"] as? [[Any]])?.first.flatMap { $0.count > 1 ? $0[1] : nil }
        }
        guard let text = (sheet["mText"] ?? tp["mText"]) as? String else { return nil }
        func rgb(_ v: Any?) -> PRText.RGB? {
            guard let n = (v as? NSNumber)?.intValue else { return nil }
            return PRText.RGB(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
        }
        func on(_ key: String) -> Bool { (first(key) as? NSNumber)?.boolValue ?? false }
        var t = PRText(text: text, fontName: first("mFontName") as? String, size: (first("mFontSize") as? NSNumber)?.doubleValue,
                       tracking: (first("mTracking") as? NSNumber)?.doubleValue)
        if on("mFillVisible") { t.fill = rgb(first("mFillColor")) }
        // mAlignment (paragraph): 0 left, 1 right, 2 center, 3 to 5 the justified variants (last line left / right / center).
        if let a = (tp["mAlignment"] as? NSNumber)?.intValue {
            switch a { case 0, 1, 2: t.alignment = a; case 3, 4, 5: t.alignment = a - 3; default: break }
        }
        if on("mStrokeVisible"), let c = rgb(first("mStrokeColor")), let w = (first("mStrokeWidth") as? NSNumber)?.doubleValue, w > 0 {
            t.stroke = PRText.Stroke(color: c, width: w)
        }
        return t
    }
}

/// Bounds-checked FlatBuffer reading (little endian). Every accessor returns nil instead of trapping on bad offsets.
struct FlatReader {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    func u32(_ o: Int) -> Int? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    func i32(_ o: Int) -> Int? { u32(o).map { Int(Int32(truncatingIfNeeded: $0)) } }
    func u16(_ o: Int) -> Int? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }
    func f32(_ o: Int) -> Float? { u32(o).map { Float(bitPattern: UInt32($0)) } }

    /// Absolute position of field `i` of the table at `t`, nil when absent.
    func field(_ t: Int, _ i: Int) -> Int? {
        guard let so = i32(t) else { return nil }
        let vt = t - so
        guard let size = u16(vt), 4 + 2 * i < size, let off = u16(vt + 4 + 2 * i), off != 0 else { return nil }
        return t + off
    }
    /// Follows the uoffset stored at `p`.
    func deref(_ p: Int?) -> Int? { p.flatMap { p in u32(p).map { p + $0 } } }
    func string(_ p: Int?) -> String? {
        guard let s = deref(p), let n = u32(s), s + 4 + n <= b.count else { return nil }
        return String(bytes: b[(s + 4)..<(s + 4 + n)], encoding: .utf8)
    }
    /// Element slot positions of the vector referenced at `p`.
    func vector(_ p: Int?) -> [Int] {
        guard let v = deref(p), let n = u32(v), n < 100_000, v + 4 + 4 * n <= b.count else { return [] }
        return (0..<n).map { v + 4 + 4 * $0 }
    }

    func premiereText() -> PRText? {
        guard let rootTable = deref(0), let main = deref(field(rootTable, 0)) else { return nil }
        let fonts = vector(field(main, 1)).map { string($0) }
        var text = "", size: Double?, tracking: Double?, font: String?, gotStyle = false
        var runs: [PRText.Run] = []
        for slot in vector(field(main, 0)) {
            guard let run = deref(slot) else { continue }
            let piece = (string(field(run, 0)) ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            text += piece
            var r = PRText.Run(text: piece, fontName: fonts.first ?? nil, size: nil)
            if let style = deref(field(run, 1)) {
                let index = byte(field(style, 0)) ?? 0
                if fonts.indices.contains(index) { r.fontName = fonts[index] }
                r.size = field(style, 1).flatMap(f32).map(Double.init)
                if !gotStyle {
                    gotStyle = true
                    size = r.size; font = r.fontName
                    tracking = field(style, 8).flatMap(f32).map(Double.init)
                }
            }
            runs.append(r)
        }
        var t = PRText(text: text, fontName: font ?? (fonts.first ?? nil), size: size, tracking: tracking)
        t.runs = runs
        (t.secondLine, t.mixedStyles) = Self.lineStyles(runs)
        if let w = field(main, 2).flatMap(f32), let h = field(main, 3).flatMap(f32), w > 0, h > 0 {
            t.boxSize = (Double(w), Double(h))
        }
        t.alignment = field(main, 4).flatMap { $0 < b.count ? Int(b[$0]) : nil }
        t.shadow = shadow(main)
        t.background = background(main)
        return t
    }

    /// Line 1's style against the later lines' (SQ text has one style for line 1 and one for every later line).
    static func lineStyles(_ runs: [PRText.Run]) -> (PRText.LineStyle?, Bool) {
        var first: [PRText.LineStyle] = [], later: [PRText.LineStyle] = []
        var line = 0
        for r in runs {
            let style = PRText.LineStyle(fontName: r.fontName, size: r.size)
            for (i, part) in r.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { line += 1 }
                guard !part.isEmpty else { continue }
                if line == 0 { if !first.contains(style) { first.append(style) } } else if !later.contains(style) { later.append(style) }
            }
        }
        guard first.count <= 1, later.count <= 1 else { return (nil, true) }
        guard let l = later.first, let f = first.first, l != f else { return (nil, false) }
        return (l, false)
    }

    /// A color table (fields 0, 1, 2 = r, g, b, one byte each).
    private func colour(_ p: Int?) -> PRText.RGB? {
        guard let c = deref(p), let r = byte(field(c, 0)), let g = byte(field(c, 1)), let bl = byte(field(c, 2)) else { return nil }
        return PRText.RGB(red: Double(r) / 255, green: Double(g) / 255, blue: Double(bl) / 255)
    }

    private func background(_ main: Int) -> PRText.Background? {
        guard byte(field(main, 18)) == 1, let c = colour(field(main, 17)) else { return nil }
        func f(_ i: Int) -> Double? { field(main, i).flatMap(f32).map(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        let bg = PRText.Background(color: c, opacity: min(max((f(19) ?? 100) / 100, 0), 1), size: max(f(13) ?? 0, 0),
                                   cornerRadius: max(f(14) ?? 0, 0))
        return bg.opacity > 0 ? bg : nil
    }

    private func byte(_ p: Int?) -> Int? { p.flatMap { $0 >= 0 && $0 < b.count ? Int(b[$0]) : nil } }

    private func shadow(_ main: Int) -> PRText.Shadow? {
        guard byte(field(main, 11)) == 1 else { return nil }
        func f(_ i: Int) -> Double { field(main, i).flatMap(f32).map(Double.init) ?? 0 }
        // Fields 20 and 34 are NOT the shadow angle / distance: every sample of the maintainer's projects (18 files) carries them with
        // one constant pair per text style (44.6/53.5, 19.3/17.8, 51.8/60.0), also on texts whose shadow switch (11) is off,
        // while his panel reads angle 0 / distance 0. No field varies with the shadow's angle or distance, so both stay 0
        // (shortcut: an angled shadow is not importable until a sample with a non-zero panel angle exists).
        let c = colour(field(main, 10)) ?? PRText.RGB(red: 0, green: 0, blue: 0)
        let s = PRText.Shadow(red: c.red, green: c.green, blue: c.blue, opacity: f(12) / 100, angle: 0, distance: 0,
                              size: f(15), blur: f(16))
        return s.opacity > 0 ? s : nil
    }
}
