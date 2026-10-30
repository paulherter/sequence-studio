import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@MainActor @Suite struct AdjustmentSessionTests {
    @Test func addAdjustmentLayerGoesOnTheFirstFreeTrackSelectedAsOneUndoStep() throws {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                         tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let depth = session.undoDepth
        let id = try #require(session.addAdjustmentLayer())
        #expect(session.undoDepth == depth + 1)
        #expect(session.selection == [id])
        let c = try #require(session.singleSelectedClip)
        #expect(c.isAdjustment && c.name == "Adjustment Layer")
        let tl = try #require(session.activeTimeline)
        #expect(tl.tracks[0].clips.map(\.id) == [id])
    }

    @Test func everyBlendModeIsOffered() {
        // The Opacity > Blend Mode popup lists `BlendMode.allCases`.
        #expect(BlendMode.allCases.count == 27)
    }
}

@MainActor @Suite struct ExtendToSequenceEndUITests {
    /// V1 holds a 10 s clip, V2 an adjustment layer 0..4 s (flag off).
    private func make() throws -> (EditorSession, adj: Clip.ID, video: Clip.ID) {
        var v1 = Track(kind: .video); let v2 = Track(kind: .video)
        try v1.overwrite(Clip(id: UUID(), name: "A", media: UUID(), kind: .video,
                              source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero))
        let base = v1.clips[0].id
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2])
        var p = Project(name: "P", timelines: [t])
        let adj = try p.addAdjustmentClip(in: t.id, at: .zero, track: v2.id, duration: Time(4, 1))
        return (EditorSession(project: p), adj, base)
    }

    @Test func menuItemIsEnabledOnlyForAdjustmentClipsAndChecksTheFlag() throws {
        let (s, adj, video) = try make()
        let t = try #require(s.activeTimeline)
        func item(_ tl: Timeline, _ sel: Set<Clip.ID>) throws -> TimelineMenuItem {
            try #require(TimelineContextMenu.items(timeline: tl, selection: sel, clipboardHasClips: false)
                .first { $0.action == .extendToSequenceEnd })
        }
        #expect(try item(t, [adj]).isEnabled)
        #expect(try !item(t, [adj]).isChecked)
        #expect(try !item(t, [video]).isEnabled)
        #expect(try !item(t, [adj, video]).isEnabled)
        #expect(try !item(t, []).isEnabled)
        s.select(clips: [adj])
        s.toggleExtendToSequenceEndSelection()
        #expect(try item(#require(s.activeTimeline), [adj]).isChecked)
    }

    @Test func toggleIsOneUndoStepAndExtendsTheLayer() throws {
        let (s, adj, video) = try make()
        s.select(clips: [adj])
        let depth = s.undoDepth
        s.toggleExtendToSequenceEndSelection()
        #expect(s.undoDepth == depth + 1)
        let t = try #require(s.activeTimeline)
        let layer = try #require(t.tracks.flatMap(\.clips).first { $0.id == adj })
        let vid = try #require(t.tracks.flatMap(\.clips).first { $0.id == video })
        #expect(layer.extendsToSequenceEnd && layer.timeline.end == vid.timeline.end)
        s.toggleExtendToSequenceEndSelection()   // off again
        #expect(s.undoDepth == depth + 2)
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == adj }?.extendsToSequenceEnd == false)
    }

    @Test func commandIsWiredAndInTheClipMenu() {
        #expect(CommandSupport.isSupported(.extendToSequenceEnd))
        #expect(EditorMenus.clip.commands.contains(.extendToSequenceEnd))
        #expect(CommandMap.premiereDefault.binding(for: .extendToSequenceEnd) == nil)
    }
}
