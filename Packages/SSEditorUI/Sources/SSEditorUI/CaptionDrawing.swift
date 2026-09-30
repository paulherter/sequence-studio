import Foundation
import SSCore

/// Text shown on a caption item in the timeline.
public enum CaptionDrawing {
    /// Lines joined with a space (one row is too low for line breaks); empty captions show a placeholder.
    public static func preview(_ item: CaptionItem) -> String {
        let t = item.lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "(empty)" : t
    }
}
