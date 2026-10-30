import Foundation
import SQCore
import SQText

/// Text Looks and Animations dropped on text layers (Effects panel): independent, one undo step each.
extension EditorSession {
    /// Applies a `textlook.` (style only) or `textanim.` (motion only) preset to the text layers among `ids`.
    /// Returns false when none of them is a text layer or the id is unknown.
    @discardableResult
    public func addTextPreset(id: String, to ids: Set<Clip.ID>) -> Bool {
        let look = TextPresetCatalog.look(id: id), motion = TextPresetCatalog.motion(id: id)
        guard look != nil || motion != nil, !ids.isEmpty else { return false }
        let title = look.map { "Text Look: \($0.name)" } ?? "Text Animation: \(motion?.name ?? "")"
        return attempt(title) { t in
            var changed = false
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
                      var g = c.generator, g.kind == GeneratorRef.text else { continue }
                if let look { g = try TextPresetApply.apply(look: look, to: g) }
                else if let motion { g = try TextPresetApply.apply(motion: motion, to: g) }
                c.generator = g
                try t.replaceClip(c)
                changed = true
            }
            if !changed { throw EditError.wrongTrackKind }
        }
    }
}
