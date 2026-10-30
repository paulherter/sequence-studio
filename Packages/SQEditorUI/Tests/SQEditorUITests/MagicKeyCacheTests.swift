import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// The lane keys of a Magic mask are built once per revision of the tracked frames, not on every draw.
@MainActor @Suite struct MagicKeyCacheTests {
    func rig() -> (Clip, ClipMask, MagicTrackedFrames, String) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let mask = ClipMask.makeMagic(name: "Magic", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])
        clip.masks = [mask]
        let store = MagicMatteStore(directory: nil)
        let key = mask.magic!.cacheKey(media: clip.media)
        for s in [1.0, 2.0, 3.0] { store.put(SubjectMatte(width: 2, height: 2, values: [0, 1, 1, 0]), key: key, pts: s) }
        return (clip, mask, MagicTrackedFrames(store: store, loadsInBackground: false), key)
    }

    @Test func keysAreReusedUntilTheFramesOrTheClipChange() {
        let (clip, mask, frames, key) = rig()
        let fd = Time(1, 30)
        let a = frames.keys(clip: clip, mask: mask, key: key, frameDuration: fd)
        #expect(a.count == 3)
        #expect(frames.keyBuilds == 1)
        _ = frames.keys(clip: clip, mask: mask, key: key, frameDuration: fd)
        #expect(frames.keyBuilds == 1)
        // Deleting a frame bumps the revision: rebuilt, one key fewer.
        frames.remove(key: key, times: [2.0])
        let b = frames.keys(clip: clip, mask: mask, key: key, frameDuration: fd)
        #expect(frames.keyBuilds == 2 && b.count == 2)
        // A clip change (moved on the timeline) rebuilds too.
        var moved = clip; moved.start = Time(9, 1)
        _ = frames.keys(clip: moved, mask: mask, key: key, frameDuration: fd)
        #expect(frames.keyBuilds == 3)
    }
}
