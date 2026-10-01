import Foundation
import SQCore
import SQText

/// Captions in the Program monitor: each visible caption is drawn like a text layer at the bottom safe area, with the
/// same style, wrap width and margin as the export burn-in, so the picture you cut on is the picture you export.
enum CaptionPreview {
    /// Distance of the text block's bottom from the canvas bottom (fraction of the height) and the wrap width
    /// (fraction of the width); `CaptionPlacement.bottomSafeArea` in SQExport uses the same numbers.
    static func template(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn,
                         highlight: TextHighlight? = nil) -> TextTemplate {
        CaptionLayout.template(text: item.lines.joined(separator: "\n"),
                               style: library.style(for: item.styleRef.isEmpty ? nil : item.styleRef),
                               canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height), highlight: highlight)
    }

    /// Box centre relative to the canvas centre (sequence px, y down).
    static func position(canvas: SequenceFormat) -> Vec2 {
        let c = CaptionLayout.boxCentre(canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
        return Vec2(c.x, c.y)
    }

    static func animations(for item: CaptionItem, library: CaptionPresetLibrary = .builtIn) -> AnimationSet? {
        let a = library.animation(for: item.animationRef.isEmpty ? nil : item.animationRef)
        if a == .none { return nil }
        return a.anchor == .start ? AnimationSet(in: a, out: nil) : AnimationSet(in: nil, out: a)
    }

    static func ref(for item: CaptionItem, canvas: SequenceFormat, highlight: TextHighlight? = nil) throws -> GeneratorRef {
        try TextGenerator.makeRef(template: template(for: item, canvas: canvas, highlight: highlight), animations: animations(for: item))
    }

    /// What one frame of a caption needs: the plain caption (the same ref on every frame of the caption, so its raster is
    /// made once), the lit-words layer for the current word, and the layer of the next word (prepared ahead of time).
    struct Plan: Equatable {
        var plain: GeneratorRef
        var lit: GeneratorRef?
        var next: GeneratorRef?
    }

    static func plan(for item: CaptionItem, karaoke: KaraokeStyle?, canvas: SequenceFormat, at t: Time) throws -> Plan {
        let plain = try ref(for: item, canvas: canvas)
        guard let karaoke else { return Plan(plain: plain, lit: nil, next: nil) }
        let count = item.tokens.count
        let lit = try CaptionKaraoke.highlight(for: item, style: karaoke, at: t).map { try ref(for: item, canvas: canvas, highlight: $0) }
        let current = item.activeWord(at: t) ?? -1
        let next = current + 1 < count
            ? try ref(for: item, canvas: canvas, highlight: CaptionKaraoke.highlight(forWord: current + 1, style: karaoke)) : nil
        return Plan(plain: plain, lit: lit, next: next)
    }
}
