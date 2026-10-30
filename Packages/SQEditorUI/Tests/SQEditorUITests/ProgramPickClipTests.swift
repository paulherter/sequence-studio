import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@Suite struct ProgramPickClipTests {
    private func clip(_ name: String, scale: Double) -> Clip {
        var c = Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                     start: .zero, mediaDuration: Time(100, 1))
        c.animation.scale = AnimatedProperty(Vec2(scale, scale))
        return c
    }

    @Test func clickPicksTheTopmostPictureUnderThePointer() {
        let bottom = clip("bottom", scale: 1), top = clip("top", scale: 0.5)
        let tl = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video, clips: [bottom]), Track(kind: .video, clips: [top])])
        let project = Project(name: "P", timelines: [tl])
        let w = Double(tl.format.width), h = Double(tl.format.height)
        // Center: both cover it, the upper track wins. Near the corner only the full-size clip is there.
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: tl, project: project, time: .zero) == top.id)
        #expect(TextHitTest.topmostVisualClip(at: Vec2(w * 0.45, h * 0.45), in: tl, project: project, time: .zero) == bottom.id)
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: tl, project: project, time: Time(50, 1)) == nil)   // nothing under the playhead
    }

    /// Magic picks only clips it can segment: a hold frame above the video does not catch its click.
    @Test func magicPicksTheVideoBelowAClipItCannotUse() {
        let bottom = clip("bottom", scale: 1)
        var top = clip("top", scale: 1)
        top.holdFrame = Time(1, 1)
        let tl = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video, clips: [bottom]), Track(kind: .video, clips: [top])])
        let project = Project(name: "P", timelines: [tl])
        #expect(MagicMaskTool.canUse(bottom) && !MagicMaskTool.canUse(top))
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: tl, project: project, time: .zero) == top.id)
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: tl, project: project, time: .zero,
                                              accepting: MagicMaskTool.canUse) == bottom.id)
    }

    /// Nothing under the pointer on the targeted track: a clip on another track (V3) is picked. Both: the targeted track wins.
    @Test func clickPicksOtherTracksButTheTargetedTrackWinsOnOverlap() {
        let v1 = clip("v1", scale: 1), v2 = clip("v2", scale: 1), v3 = clip("v3", scale: 0.5)
        let tl = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [
            Track(kind: .video, clips: [v1], isTargeted: true), Track(kind: .video, clips: [v2]), Track(kind: .video, clips: [v3])])
        let project = Project(name: "P", timelines: [tl])
        let w = Double(tl.format.width), h = Double(tl.format.height)
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: tl, project: project, time: .zero) == v1.id)   // overlap: V1 targeted
        let off = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [
            Track(kind: .video, isTargeted: true), Track(kind: .video, clips: [v2]), Track(kind: .video, clips: [v3])])   // nothing on the targeted track
        #expect(TextHitTest.topmostVisualClip(at: .zero, in: off, project: project, time: .zero) == v3.id)
        #expect(TextHitTest.topmostVisualClip(at: Vec2(w * 0.45, h * 0.45), in: off, project: project, time: .zero) == v2.id)
    }

    @Test func graphicTextHitRespectsTargetPriority() {
        let tracks = [Track(kind: .video, isTargeted: true), Track(kind: .video), Track(kind: .video)]
        #expect(TextHitTest.hitWins(2, over: nil, tracks: tracks))
        #expect(!TextHitTest.hitWins(2, over: 0, tracks: tracks))   // text above, but the targeted picture wins
        #expect(TextHitTest.hitWins(0, over: 2, tracks: tracks))
        #expect(TextHitTest.hitWins(2, over: 1, tracks: tracks))
        #expect(!TextHitTest.hitWins(1, over: 2, tracks: tracks))
    }
}
