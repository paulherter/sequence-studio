import Foundation
import SSCore
import SSText

/// Captions in the Program monitor: each visible caption is drawn like a text layer at the bottom safe area, with the
/// same style, wrap width and margin as the export burn-in, so the picture you cut on is the picture you export.
enum CaptionPreview {
    /// Distance of the text block's bottom from the canvas bottom (fraction of the height) and the wrap width
    /// (fraction of the width); `CaptionPlacement.bottomSafeArea` in SSExport uses the same numbers.
    static func template(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn) -> TextTemplate {
        CaptionLayout.template(text: item.lines.joined(separator: "\n"),
                               style: library.style(for: item.styleRef.isEmpty ? nil : item.styleRef),
                               canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
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

    static func ref(for item: CaptionItem, canvas: SequenceFormat) throws -> GeneratorRef {
        try TextGenerator.makeRef(template: template(for: item, canvas: canvas), animations: animations(for: item))
    }
}
