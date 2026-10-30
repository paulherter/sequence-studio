import Foundation
import Synchronization
import SQCore

/// Keeps the last raster of every text clip that was drawn, so an edit whose new raster is still being rendered (dragging
/// the size field) shows the previous one instead of making the text disappear for a few frames (flicker).
final class TextStandIns: Sendable {
    /// A drawn text: its clip (a graphics layer's id) and the clip that contains it (the graphics clip or nested clip);
    /// layers of graphics clips made from one template share ids, so the container is part of the key.
    struct Key: Hashable { let clip: Clip.ID; let group: Clip.ID? }
    private let last = Mutex<[Key: GeneratorRef]>([:])

    /// The ref to draw for `clip` now: `ref` when its raster is cached (and remembered), else the last drawn ref of the
    /// clip while that one is still cached, else nil (nothing to show yet).
    func resolve(clip: Clip.ID, group: Clip.ID? = nil, ref: GeneratorRef, isCached: (GeneratorRef) -> Bool) -> GeneratorRef? {
        let clip = Key(clip: clip, group: group)
        return last.withLock { m in
            if isCached(ref) { m[clip] = ref; return ref }
            if let old = m[clip], isCached(old) { return old }
            return nil
        }
    }

    func prune(keeping clips: Set<Clip.ID>) {
        last.withLock { m in for k in Array(m.keys) where !clips.contains(k.group ?? k.clip) { m[k] = nil } }
    }
}
