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
                               canvasWidth: Double(canvas.layoutFormat.width), canvasHeight: Double(canvas.height), highlight: highlight,
                               position: item.position ?? library.position)
    }

    /// Box center relative to the canvas center (sequence px, y down), at the project's caption position (FB-Y).
    static func position(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn) -> Vec2 {
        let c = CaptionLayout.boxCentre(canvasWidth: Double(canvas.layoutFormat.width), canvasHeight: Double(canvas.height),
                                        position: item.position ?? library.position)
        return Vec2(c.x, c.y)
    }

    static func animations(for item: CaptionItem, library: CaptionPresetLibrary = .builtIn) -> AnimationSet? {
        AnimationSet(single: library.animation(for: item.animationRef.isEmpty ? nil : item.animationRef))
    }

    static func ref(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn,
                    highlight: TextHighlight? = nil) throws -> GeneratorRef {
        try TextGenerator.makeRef(template: template(for: item, canvas: canvas, library: library, highlight: highlight),
                                  animations: animations(for: item, library: library))
    }

    /// What one frame of a caption needs: the plain caption (the same ref on every frame of the caption, so its raster is
    /// made once), the lit-words layer for the current word, and the layer of the word the playhead reaches next
    /// (prepared ahead of time).
    struct Plan: Equatable {
        var plain: GeneratorRef
        var lit: GeneratorRef?
        var next: GeneratorRef?
    }

    /// `held`: the caption is past its own end (it holds through a small gap, or it is the tail under the next caption,
    /// `CaptionHandover`): it keeps the highlight it ended with.
    /// `forward`: the direction the playhead travels; `next` is the word it reaches next (played backwards the one before).
    static func plan(for item: CaptionItem, karaoke: KaraokeStyle?, canvas: SequenceFormat, at t: Time,
                     library: CaptionPresetLibrary = .builtIn, held: Bool = false, forward: Bool = true) throws -> Plan {
        // A karaoke caption with a pill draws one pill per word (the export burn-in asks `plainHighlight` the same way).
        let style = library.style(for: item.styleRef.isEmpty ? nil : item.styleRef)
        let plain = try ref(for: item, canvas: canvas, library: library,
                            highlight: CaptionKaraoke.plainHighlight(style: style, karaoke: karaoke, wordCount: item.tokens.count))
        guard let karaoke else { return Plan(plain: plain, lit: nil, next: nil) }
        if held {
            let lit = try CaptionKaraoke.heldHighlight(for: item, style: karaoke).map {
                try ref(for: item, canvas: canvas, library: library, highlight: $0)
            }
            // Played backwards the playhead comes into the caption's own range from its end: the last word that lights.
            let last = forward ? nil : item.karaokeKeys.last(where: { $0.activeWord != nil })?.activeWord
            let next = try last.map {
                try ref(for: item, canvas: canvas, library: library, highlight: CaptionKaraoke.highlight(forWord: $0, style: karaoke))
            }
            return Plan(plain: plain, lit: lit, next: next)
        }
        let count = item.tokens.count
        let lit = try CaptionKaraoke.highlight(for: item, style: karaoke, at: t).map { try ref(for: item, canvas: canvas, library: library, highlight: $0) }
        var upcoming: Int?
        if forward {
            let current = item.activeWord(at: t) ?? -1
            if current + 1 < count { upcoming = current + 1 }
        } else {
            // The word lit before the stretch `t` lies in (a gap between words and the time after the last one light none).
            let keys = item.karaokeKeys
            if let i = keys.lastIndex(where: { $0.time <= t }) {
                upcoming = keys[..<i].last(where: { $0.activeWord != nil })?.activeWord
            }
        }
        let next = try upcoming.map {
            try ref(for: item, canvas: canvas, library: library, highlight: CaptionKaraoke.highlight(forWord: $0, style: karaoke))
        }
        return Plan(plain: plain, lit: lit, next: next)
    }
}
