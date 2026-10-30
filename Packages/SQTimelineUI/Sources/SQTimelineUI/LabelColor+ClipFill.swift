import AppKit
import SQCore

// Moved from ProjectItemTint.swift: the clip text color reads it (`ClipStyle.onFill`), the Project panel tints too
// (DECISIONS "SQEditorUI split").
extension LabelColor {
    /// The fill the timeline draws a clip of this label in (`ClipStyle.label`).
    public var fill: NSColor { ClipStyle.label(self).fill }

    /// WCAG contrast ratio of white (`Theme.Colors.onClip`, the timeline's clip text) on this label's fill.
    public var contrastWithClipText: Double { 1.05 / (Self.luminance(rgb) + 0.05) }

    /// Text color on this label's fill: the clip text color, or black on the few light fills (yellow, lilac, aqua,
    /// teal, orange, indigo) where white would fall under 4.5:1.
    public var onFill: NSColor { contrastWithClipText >= 4.5 ? Theme.Colors.onClip : Theme.TimelineSkin.nameOnLight }

    /// Contrast of `onFill` on the fill (always >= 4.5 for the 16 labels).
    public var onFillContrast: Double { contrastWithClipText >= 4.5 ? contrastWithClipText : (Self.luminance(rgb) + 0.05) / 0.05 }

    static func luminance(_ rgb: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((rgb >> 16) & 255) + 0.7152 * lin((rgb >> 8) & 255) + 0.0722 * lin(rgb & 255)
    }
}
