import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

// G11 Follow from the Graphics panel: target, edges, padding as undo steps; the overlay draws from the same resolution as
// playback and export.

@MainActor @Suite struct GraphicsFollowEditorTests {
    private func setup() throws -> (EditorSession, GraphicsEditor, text: UUID, box: UUID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                         tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        try #require(e.newGraphicsClip() != nil)
        e.addShape(.rectangle)
        let box = try #require(e.selectedLayers.first)
        let text = try #require(e.addText(at: Vec2(200, 100), string: "Lower third"))
        e.select([box])
        return (s, e, text, box)
    }

    @Test func boxFollowsTextInOverlayMonitorAndExportAlike() throws {
        let (s, e, text, box) = try setup()
        #expect(e.followCandidates.map(\.id) == [text])
        let depth = s.undoDepth
        e.setFollowTarget(.layer(id: text))
        #expect(s.undoDepth == depth + 1)
        #expect(e.follow == GraphicsFollow(target: .layer(id: text), padding: GraphicsEditor.defaultFollowPadding))
        let shown = try #require(e.shownDocument)
        let tb = try #require(shown.bounds(of: text, atLocal: e.localTime, text: e.textMeasure))
        let bb = try #require(shown.bounds(of: box, atLocal: e.localTime, text: e.textMeasure))
        let p = GraphicsEditor.defaultFollowPadding
        #expect(abs(bb.minX - (tb.minX - p)) < 1e-6 && abs(bb.maxY - (tb.maxY + p)) < 1e-6)
        // Playback and export evaluate the timeline: the box request has the size and place the overlay shows.
        let tl = try #require(s.activeTimeline)
        let req = try #require(tl.videoLayers(at: s.playhead).first { $0.clip == box })
        #expect(abs((req.shape?.width ?? 0) - bb.width) < 1e-6 && abs((req.shape?.height ?? 0) - bb.height) < 1e-6)
        #expect(abs(req.transform.position.x - bb.midX) < 1e-6 && abs(req.transform.position.y - bb.midY) < 1e-6)
        #expect(e.shownSelectedLayer?.animation.position.value == Vec2(bb.midX, bb.midY))
    }

    @Test func edgesPaddingAndStop() throws {
        let (s, e, text, _) = try setup()
        e.setFollowTarget(.layer(id: text))
        e.toggleFollowEdge(.top)
        #expect(e.follow?.edges == [.left, .right, .bottom])
        e.beginGesture()
        let depth = s.undoDepth
        e.setFollowPadding(10)
        e.setFollowPadding(12)
        #expect(s.undoDepth == depth + 1)                  // one drag, one step
        #expect(e.follow?.padding == 12)
        e.setFollowTarget(.frame)                          // a new target keeps edges and padding
        #expect(e.follow == GraphicsFollow(target: .frame, edges: [.left, .right, .bottom], padding: 12))
        #expect(e.followTitle(e.follow?.target) == "Frame")
        e.setFollowTarget(nil)
        #expect(e.follow == nil)
    }

    @Test func perEdgePadding() throws {
        let (_, e, text, _) = try setup()
        e.setFollowTarget(.layer(id: text))
        e.beginGesture()
        e.setFollowPadding(10)
        e.setFollowPadding(30, for: .left)
        #expect(e.follow?.edgePadding == GraphicsEdgePadding(left: 30, top: 10, right: 10, bottom: 10))
        e.setFollowPadding(10, for: .left)
        #expect(e.follow?.edgePadding == nil && e.follow?.padding == 10)
        e.setFollowPadding(30, for: .top)
        e.setFollowPadding(50)                             // the single value resets every edge
        #expect(e.follow?.edgePadding == nil && e.follow?.padding == 50)
    }

    @Test func alignUsesTheDrawnBoxOfAPinnedFollower() throws {
        let (_, e, text, box) = try setup()
        e.setFollowTarget(.layer(id: text))
        e.addShape(.rectangle)
        let other = try #require(e.selectedLayers.first)
        e.translateSelected(by: Vec2(500, 300))
        let stored = e.document?.layer(box)?.animation.position.value
        e.select([box, other])
        e.align(.left)
        let shown = try #require(e.shownDocument)
        let bb = try #require(shown.bounds(of: box, atLocal: e.localTime, text: e.textMeasure))
        let ob = try #require(shown.bounds(of: other, atLocal: e.localTime, text: e.textMeasure))
        #expect(abs(ob.minX - bb.minX) < 1e-6)                          // aligned to the box as drawn
        #expect(e.document?.layer(box)?.animation.position.value == stored)   // the pinned box stays Follow's
    }

    @Test func monitorDragUnpinsTheDraggedAxisFromWhereItIsDrawn() throws {
        let (_, e, text, box) = try setup()
        e.setFollowTarget(.layer(id: text))
        let before = try #require(e.shownDocument?.bounds(of: box, atLocal: e.localTime, text: e.textMeasure))
        e.translateSelected(by: Vec2(30, 0))
        #expect(e.document?.layer(box)?.follow?.edges == [.top, .bottom])
        let after = try #require(e.shownDocument?.bounds(of: box, atLocal: e.localTime, text: e.textMeasure))
        #expect(abs(after.minX - (before.minX + 30)) < 1e-6 && abs(after.minY - before.minY) < 1e-6)
    }

    @Test func cycleIsRefusedAndDeletingTheTargetUnpins() throws {
        let (s, e, text, box) = try setup()
        e.setFollowTarget(.layer(id: text))
        e.select([text])
        #expect(e.followCandidates.isEmpty)               // the box follows the text: the text cannot follow the box
        let depth = s.undoDepth
        e.setFollowTarget(.layer(id: box))
        #expect(s.undoDepth == depth && e.follow == nil)
        e.deleteSelected()
        #expect(e.document?.layer(box)?.follow == nil)
    }
}
