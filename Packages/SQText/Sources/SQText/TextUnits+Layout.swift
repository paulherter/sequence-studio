import Foundation
// The animation model (KeyframeTemplate, AnimationSet, TextAnimator, TextUnits) lives in SQCore since W7.3; SQText
// re-exports it so `import SQText` alone keeps seeing it.
@_exported import SQCore

extension TextUnits {
    /// The animatable units of a laid-out text (lines as the layout broke them).
    public static func segment(_ layout: TextLayoutResult) -> TextUnits {
        segment(text: layout.displayText,
                lines: layout.lines.map { NSRange(location: $0.location, length: ($0.content as NSString).length) })
    }
}
