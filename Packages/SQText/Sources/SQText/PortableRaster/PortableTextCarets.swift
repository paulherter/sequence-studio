import Foundation
import SQCore

/// Caret positions of a text block where the portable raster draws its glyphs: one caret per character boundary of the
/// stored text, in layout px relative to the raster's top-left (the ink origin, the monitor's text frame corner).
/// The monitor's on-canvas text field draws its caret and selection from it and maps a click to a character.
public struct TextCaretMap: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let top: Double, height: Double
    }
    public struct Caret: Sendable, Equatable {
        public let line: Int
        public let x: Double
    }
    public let lines: [Line]
    /// `text.count + 1` entries: caret `i` sits before character `i` (the last one after the text).
    public let carets: [Caret]

    /// The caret nearest to (`x`, `y`): the line under `y` (clamped to the first / last), then the nearest caret on it.
    public func index(atX x: Double, y: Double) -> Int {
        guard !lines.isEmpty, !carets.isEmpty else { return 0 }
        let row = lines.lastIndex { $0.top <= y } ?? 0
        var best = 0, bestDistance = Double.infinity
        for (i, c) in carets.enumerated() where c.line == row {
            let d = abs(c.x - x)
            if d < bestDistance { best = i; bestDistance = d }
        }
        return bestDistance.isFinite ? best : (y < lines[0].top ? 0 : carets.count - 1)
    }
}

extension PortableTextRenderer {
    /// The caret map of `text` as `render` lays it out (same style, wrap and box). nil when nothing would be drawn.
    /// shortcut: carets of right-to-left lines run left to right (the raster does not reorder them either), and All Caps
    /// letters that change length (ß) shift the carets after them; upgrade with HarfBuzz shaping.
    public static func caretMap(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil) -> TextCaretMap? {
        let style = style.drawn
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        let ink = layout.inkBounds
        guard !layout.lines.isEmpty, ink.x.isFinite, ink.y.isFinite else { return nil }
        let pens = GlyphPlacer(layout: layout, style: style, ink: ink, scale: 1).carets
        let lines = layout.lines.map { TextCaretMap.Line(top: $0.y - ink.y, height: $0.height) }
        // The layout's lines in display-text order (UTF-16 location); a caret belongs to the last line starting at or
        // before it. Offsets past a line's end (the break, a wrapped space) sit at its end.
        func caret(utf16 u: Int) -> TextCaretMap.Caret {
            let li = layout.lines.lastIndex { $0.location <= u } ?? 0
            let l = layout.lines[li]
            let local = u - l.location + l.markerLength
            let map = pens[li]
            let end = map.keys.max().flatMap { map[$0] } ?? l.x
            let start = map[l.markerLength] ?? l.x
            let x = local < l.markerLength ? start : (map[local] ?? end)
            return TextCaretMap.Caret(line: li, x: x - ink.x)
        }
        var carets: [TextCaretMap.Caret] = []
        carets.reserveCapacity(text.count + 1)
        var u = 0
        for ch in text {
            carets.append(caret(utf16: u))
            u += ch.utf16.count
        }
        carets.append(caret(utf16: u))
        return TextCaretMap(lines: lines, carets: carets)
    }
}

/// The text frame of a clip without drawing it: where `portableFrame` would place its raster (scale 1) and the
/// animation at `localTime`. The monitor's text frame, Type tool hits and the font-size handles on Windows read it.
public struct PortableTextBox: Sendable, Equatable {
    public let x: Double, y: Double
    public let width: Double, height: Double
    public let opacity: Double, scale: Double
    public let offsetX: Double, offsetY: Double
    public let rotation: Double
}

extension TextGenerator {
    /// `portableFrame(ref:…)`'s placement from the layout alone (no raster): nil for empty text or ink.
    public static func portableBox(ref: GeneratorRef, localTime: Time, clipDuration: Time,
                                   canvas: SequenceFormat) throws -> PortableTextBox? {
        let (template, set) = try decode(ref)
        let layout = TextLayout.layout(text: template.text, style: template.style.drawn, maxWidth: template.box?.width,
                                       boxHeight: template.box?.height)
        let ink = layout.inkBounds
        let w = ink.width.rounded(.up), h = ink.height.rounded(.up)
        guard !layout.lines.isEmpty, w.isFinite, h.isFinite, w > 0, h > 0, ink.x.isFinite, ink.y.isFinite else { return nil }
        let a = (set ?? AnimationSet(single: template.animation))?.sample(clipTime: localTime, clipDuration: clipDuration) ?? .rest
        let b = layout.bounds
        return PortableTextBox(x: (Double(canvas.displayWidth) - b.width) / 2 + (ink.x - b.x),
                               y: (Double(canvas.height) - b.height) / 2 + (ink.y - b.y),
                               width: w, height: h, opacity: a.opacity, scale: a.scale,
                               offsetX: a.offset.x, offsetY: a.offset.y, rotation: a.rotation)
    }

    /// `graphicsRect` from `portableBox`: a text layer's box in a graphic (offset from the canvas center, y down).
    public static func portableGraphicsRect(ref: GeneratorRef, localTime: Time, clipDuration: Time,
                                            canvas: SequenceFormat) -> GraphicsRect? {
        guard let f = try? portableBox(ref: ref, localTime: localTime, clipDuration: clipDuration, canvas: canvas) else {
            return nil
        }
        let minX = f.x - Double(canvas.displayWidth) / 2 + f.offsetX, minY = f.y - Double(canvas.height) / 2 + f.offsetY
        return GraphicsRect(minX: minX, minY: minY, maxX: minX + f.width, maxY: minY + f.height)
    }
}
