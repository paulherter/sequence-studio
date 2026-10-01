import Foundation
import SSCore

/// The colour clipboard: the Colour effects of the last clip the user copied from the colour panel. Per app run.
@MainActor
public final class ColorClipboard {
    public static let shared = ColorClipboard()
    public private(set) var color: ClipColor?
    public var hasColor: Bool { color != nil }
    public func copy(_ c: ClipColor) { color = c }
}

extension EditorSession {
    /// Pastes the Colour effects of `other` onto the selected picture clips (or `ids`): one undo step for all of them.
    /// Audio clips are skipped, and the target keeps its own footage interpretation (`ClipColor.pasting(effectsOf:)`).
    /// Returns how many clips changed.
    @discardableResult
    public func pasteColor(_ other: ClipColor, to ids: Set<Clip.ID>? = nil) -> Int {
        let targets = ids ?? selection
        var changed = 0
        let applied = attempt("Paste Colour") { t in
            for track in t.tracks where track.kind == .video {
                for var clip in track.clips where targets.contains(clip.id) {
                    let c = clip.color.pasting(effectsOf: other)
                    guard c != clip.color else { continue }
                    clip.color = c
                    try t.replaceClip(clip)
                    changed += 1
                }
            }
        }
        return applied ? changed : 0
    }
}
