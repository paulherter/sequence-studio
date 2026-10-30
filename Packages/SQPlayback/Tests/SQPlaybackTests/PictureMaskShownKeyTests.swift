import Foundation
import Testing
import SQCore
@testable import SQPlayback

// C6 re-review #3: a track that is both drawn and a Picture matte appears twice in one tick (the drawn copy and the matte
// copy, `LayerRequest.matteFor`). When the drawn copy is hidden under an opaque cover its key lands in `lastHidden`; the
// matte copy must not share that key, or it takes the uncovered close-frame path, counts as cold-uncovered and freezes the
// picture. Matte copies get their own stand-in key and use the normal fallback.

@Suite struct PictureMaskShownKeyTests {
    @Test func aMatteCopyHasItsOwnShownKey() {
        let track = UUID()
        let drawn = LayerRequest(clip: UUID(), media: UUID(), track: track, sourceTime: .zero)
        var matte = drawn
        matte.matteFor = track
        #expect(RenderLoop.ShownKey(drawn) != RenderLoop.ShownKey(matte))
        let hidden: Set<RenderLoop.ShownKey> = [RenderLoop.ShownKey(drawn)]
        #expect(!hidden.contains(RenderLoop.ShownKey(matte)))
        // Two matte copies of the same clip (same track at the same level) still share one key.
        #expect(RenderLoop.ShownKey(matte) == RenderLoop.ShownKey(matte))
    }
}
