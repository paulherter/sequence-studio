import Foundation
import SQCore

/// The pill look (`CaptionEmphasis.pill` in SQTranscribe): a fully rounded filled box behind the caption text. Monitor and
/// burn-in both draw `TextStyle.background` from the same `TextRenderer` layout, so one style gives one picture; this is
/// the single place that decides the pill's color, padding and rounding. A short-video caption is one word, so the box
/// around the caption is the box around the active word.
public enum CaptionPill {
    /// Style id of the built-in pill look in `CaptionPresetLibrary`.
    public static let styleID = "pill"
    public static let color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.82)
    /// Padding in em (fraction of the font size) so the pill scales with the text.
    public static let horizontalEm = 0.40
    public static let verticalEm = 0.16

    /// The pill background for `style`: `color` unless given or the style already has a background color, padding from
    /// the font size, corner radius large enough that the renderer clamps it to half the pill height (round ends).
    public static func background(for style: TextStyle, color override: RGBAColor? = nil) -> TextBackground {
        TextBackground(color: override ?? style.background?.color ?? color,
                       padding: BoxPadding(horizontal: (style.size * horizontalEm).rounded(),
                                           vertical: (style.size * verticalEm).rounded()),
                       cornerRadius: 10_000)
    }

    public static func apply(to style: TextStyle, color override: RGBAColor? = nil) -> TextStyle {
        var s = style
        s.background = background(for: style, color: override)
        return s
    }

    /// The pill rectangle of a laid-out caption (layout space, origin top-left of the text block); nil for empty text.
    public static func rect(of layout: TextLayoutResult) -> TextRect? { layout.backgroundRect }
}
