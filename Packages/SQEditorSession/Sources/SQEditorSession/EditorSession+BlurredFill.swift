import Foundation
import SQCore

/// Clip > Video Options > Fit with Blurred Fill / Card / Remove. Always explicit, per clip; one undo step per command.
extension EditorSession {
    /// Applies the look to the selected video clips (or the ones under the playhead). Clips that already have the sequence's
    /// aspect are skipped for Fit; a refused edit (locked track, unknown size) sets the error and changes nothing.
    /// Returns whether anything changed.
    @discardableResult
    public func applyBlurredFill(_ style: BlurredFillStyle, options: BlurredFillOptions = BlurredFillOptions()) -> Bool {
        guard let t = activeTimeline else { return false }
        var jobs: [(id: Clip.ID, size: (width: Int, height: Int))] = []
        var seen = Set<Clip.ID>()
        for c in commandClips(kind: .video) {
            // The blurred copy stands for its picture.
            let pid = t.blurredFillPicture(of: c.id)
            guard seen.insert(pid).inserted, let pic = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == pid }),
                  let size = project.pictureSize(of: pic) else { continue }
            let applied = t.blurredFillPair(of: pid) != nil
            if style == .fit, !applied, BlurredFill.matchesAspect(picture: size, frame: t.format) { continue }
            jobs.append((pid, size))
        }
        guard !jobs.isEmpty else { return false }
        let name = style == .fit ? "Fit with Blurred Fill" : "Card with Blurred Background"
        return attempt(name) { tl in
            for j in jobs { try tl.applyBlurredFill(j.id, picture: j.size, style: style, options: options) }
        }
    }

    /// Removes the look from the selected pictures (either clip of a pair works).
    @discardableResult
    public func removeBlurredFill() -> Bool {
        guard let t = activeTimeline else { return false }
        var seen = Set<Clip.ID>()
        let ids = commandClips(kind: .video).filter { t.blurredFillPair(of: $0.id) != nil }.map { t.blurredFillPicture(of: $0.id) }
            .filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return false }
        return attempt("Remove Blurred Fill") { tl in
            for id in ids { try tl.removeBlurredFill(id) }
        }
    }

    /// Menu enabling: a video clip with a known size (Apply) or one that belongs to a pair (Remove).
    public func blurredFillEnabled(_ command: EditorCommand) -> Bool {
        guard let t = activeTimeline else { return false }
        let clips = commandClips(kind: .video)
        switch command {
        case .removeBlurredFill: return clips.contains { t.blurredFillPair(of: $0.id) != nil }
        default: return clips.contains { project.pictureSize(of: $0) != nil }
        }
    }
}
