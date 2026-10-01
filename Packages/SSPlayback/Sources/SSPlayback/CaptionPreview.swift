import Foundation
import SSCore
import SSText

/// Captions in the Program monitor: each visible caption is drawn like a text layer at the bottom safe area, with the
/// same style, wrap width and margin as the export burn-in, so the picture you cut on is the picture you export.
enum CaptionPreview {
    /// Distance of the text block's bottom from the canvas bottom (fraction of the height) and the wrap width
    /// (fraction of the width); `CaptionPlacement.bottomSafeArea` in SSExport uses the same numbers.
    static let bottomMargin = 0.12
    static let widthFraction = 0.86
    /// The area text box the caption sits in (it is bottom-aligned inside it).
    static let boxHeightFraction = 0.30

    static func template(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn) -> TextTemplate {
        var style = library.style(for: item.styleRef.isEmpty ? nil : item.styleRef)
        style.alignment = .center
        style.verticalAlignment = .bottom
        var t = TextTemplate(name: "Caption", text: item.lines.joined(separator: "\n"), style: style)
        t.box = TextBox(width: Double(canvas.width) * widthFraction, height: Double(canvas.height) * boxHeightFraction)
        return t
    }

    /// Box centre relative to the canvas centre (sequence px, y down).
    static func position(canvas: SequenceFormat) -> Vec2 {
        let h = Double(canvas.height)
        return Vec2(0, h * (0.5 - bottomMargin) - h * boxHeightFraction / 2)
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
