import Foundation

/// A bundled font file at one point of its variation space: what the portable layout measures and the portable raster
/// draws. Matches Core Text's choice on the Mac (`FontResolver.resolveUprightFont` / `italicVersion`): the family face or
/// named instance whose weight trait is nearest the asked weight, the family's italic file for italic (else the upright
/// face sheared 12 degrees), `opsz` following the point size, the style's own axis values on top.
struct PortableFontChoice: @unchecked Sendable {
    let font: GlyphRasterFont
    /// Normalized variation coordinates (empty for a static font).
    let coords: [Double]
    /// No italic file: the renderer shears the upright outlines.
    let shear: Bool
    /// Core Text's weight trait of the chosen face (-1...1).
    let weightTrait: Double
    var face: SfntFace { font.face }
}

enum PortableFontMatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fonts: [URL: GlyphRasterFont] = [:]
    private struct Key: Hashable { let name: String; let weight: FontWeight; let italic: Bool; let size: Double; let axes: [String: Double]? }
    nonisolated(unsafe) private static var choices: [Key: PortableFontChoice] = [:]

    /// The face for a family (or file) name; unknown names draw in Inter. nil only without the bundled Inter.
    static func choose(name: String, weight: FontWeight, italic: Bool, size: Double,
                       axes: [String: Double]? = nil) -> PortableFontChoice? {
        let key = Key(name: name, weight: weight, italic: italic, size: size, axes: axes)
        if let c = lock.withLock({ choices[key] }) { return c }
        guard let c = resolve(name: name, weight: weight, italic: italic, size: size, axes: axes)
                ?? (name == InterFont.familyName ? nil
                    : resolve(name: InterFont.familyName, weight: weight, italic: italic, size: size, axes: axes)) else { return nil }
        lock.withLock {
            if choices.count > 512 { choices.removeAll() }
            choices[key] = c
        }
        return c
    }

    private static func resolve(name: String, weight: FontWeight, italic: Bool, size: Double,
                                axes: [String: Double]?) -> PortableFontChoice? {
        let files = candidates(for: name)
        guard !files.isEmpty else { return nil }
        let italics = files.filter { $0.lastPathComponent.localizedCaseInsensitiveContains("italic") }
        let uprights = files.filter { !italics.contains($0) }
        let pool = italic ? (italics.isEmpty ? uprights : italics) : (uprights.isEmpty ? files : uprights)
        let shear = italic && italics.isEmpty
        let target = FontResolver.traitValue(for: weight)
        // Options in Core Text's order: each file's default face first, then its named instances; the first nearest wins.
        var best: (GlyphRasterFont, [Double], Double)?
        for u in pool {
            guard let f = font(u) else { continue }
            var options: [([Double], Double)] = []
            if let v = f.face.variations, let w = v.axisIndex("wght") {
                let defaults = v.axes.map(\.defaultValue)
                options.append((defaults, weightTrait(wght: defaults[w])))
                for inst in v.instances where inst.count == v.axes.count { options.append((inst, weightTrait(wght: inst[w]))) }
            } else {
                options.append((f.face.variations?.axes.map(\.defaultValue) ?? [], weightTrait(wght: Double(f.face.weightClass))))
            }
            for (user, t) in options where best == nil || abs(t - target) < abs(best!.2 - target) - 1e-6 { best = (f, user, t) }
        }
        guard let (font, instance, trait) = best else { return nil }
        guard let v = font.face.variations else { return PortableFontChoice(font: font, coords: [], shear: shear, weightTrait: trait) }
        var user = instance
        if let o = v.axisIndex("opsz") { user[o] = size }        // Core Text sets the optical size to the point size
        for (tag, value) in axes ?? [:] where value.isFinite {
            if let i = v.axisIndex(tag) { user[i] = value }
        }
        let wght = v.axisIndex("wght").map { min(max(user[$0], v.axes[$0].minimum), v.axes[$0].maximum) }
        let coords = v.normalized(user)
        return PortableFontChoice(font: font, coords: coords.contains { $0 != 0 } ? coords : [], shear: shear,
                                  weightTrait: wght.map { weightTrait(wght: $0) } ?? trait)
    }

    /// Core Text's weight trait for a `wght` value or OS/2 weight class (measured: 100 -0.6, 200 -0.4, 300 -0.23,
    /// 400 0, 500 0.2, 600 0.3, 700 0.4, 800 0.6, 900 0.8; linear between).
    static func weightTrait(wght: Double) -> Double {
        let table: [(Double, Double)] = [(100, -0.6), (200, -0.4), (300, -0.23), (400, 0), (500, 0.2), (600, 0.3), (700, 0.4),
                                          (800, 0.6), (900, 0.8)]
        if wght <= table[0].0 { return table[0].1 }
        for k in 1..<table.count where wght <= table[k].0 {
            let (a, b) = (table[k - 1], table[k])
            return a.1 + (wght - a.0) / (b.0 - a.0) * (b.1 - a.1)
        }
        return table[table.count - 1].1
    }

    /// The variation axes of the font a name resolves to (the upright file), in axis order.
    static func axes(forFontName name: String) -> [FontResolver.Axis] {
        guard let u = candidates(for: name).first, let v = font(u)?.face.variations else { return [] }
        return v.axes.map { FontResolver.Axis(tag: $0.tag, name: $0.tag, minimum: $0.minimum, maximum: $0.maximum,
                                              defaultValue: $0.defaultValue) }
    }

    static func candidates(for name: String) -> [URL] {
        let n = name.lowercased()
        if n == InterFont.familyName.lowercased() { return InterFont.fontURLs }
        guard let fam = BundledFonts.families.first(where: { $0.name.lowercased() == n || $0.files.contains { $0.lowercased() == n } })
        else { return [] }
        return BundledFonts.fontURLs(of: fam)
    }

    static func font(_ url: URL) -> GlyphRasterFont? {
        if let f = lock.withLock({ fonts[url] }) { return f }
        guard let f = GlyphRasterFont(url: url) else { return nil }
        lock.withLock { fonts[url] = f }
        return f
    }
}
