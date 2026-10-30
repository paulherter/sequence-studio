import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Keyframes of a graphics item live in Controls: the picked item is shown as a plain clip and edits go back to that item.
@MainActor @Suite struct GraphicItemControlsTests {
    private func rig() -> (EditorSession, GraphicsEditor, EffectControlsModel, Clip.ID, [UUID]) {
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: session)
        let id = e.newGraphicsClip()!
        e.addShape(.rectangle)
        e.addShape(.ellipse)
        let ids = e.clip?.graphics?.layers.map(\.id) ?? []
        let m = EffectControlsModel()
        m.sync(with: session, change: [.project, .selection])
        return (session, e, m, id, ids)
    }

    @Test func noPickShowsTheWholeGraphic() {
        let (session, e, m, id, _) = rig()
        e.select([])
        m.sync(with: session, change: .selection)
        #expect(m.clip?.id == id && m.clip?.isGraphics == true && m.itemHost == nil)
    }

    @Test func aPickedItemShowsAsItsOwnClip() throws {
        let (session, e, m, id, ids) = rig()
        e.select([ids[1]])
        m.sync(with: session, change: .selection)
        let c = try #require(m.clip)
        #expect(c.id == id && !c.isGraphics && c.generator?.shapeKind == .ellipse)
        #expect(m.itemHost?.layer == ids[1])
    }

    @Test func severalPickedItemsShowTheWholeGraphic() {
        let (session, e, m, _, ids) = rig()
        e.select(Set(ids))
        m.sync(with: session, change: .selection)
        #expect(m.clip?.isGraphics == true)
    }

    @Test func aKeyOnAPickedItemIsStoredOnThatItemOnly() throws {
        let (session, e, m, id, ids) = rig()
        e.select([ids[0]])
        m.sync(with: session, change: .selection)
        var edits: [Clip] = []
        m.onEdit = { c, _, _ in edits.append(c) }
        m.toggleStopwatch(.opacity)
        let host = try #require(edits.last)
        #expect(host.id == id && host.isGraphics)
        #expect(host.graphics?.layer(ids[0])?.animation.opacity.isAnimated == true)
        #expect(host.graphics?.layer(ids[1])?.animation.opacity.isAnimated == false)
        #expect(host.animation.opacity.isAnimated == false)
    }

    @Test func oneShapeItemIsNotShownTwice() {
        let (_, e, _, _, ids) = rig()
        let layers = e.clip?.graphics?.layers ?? []
        #expect(GraphicItemRows.rowLayers(Array(layers.prefix(1))).isEmpty)
        #expect(GraphicItemRows.rowLayers(layers).count == ids.count)
    }

    @Test func pickerRowComingOrGoingReMeasures() {
        let (_, e, _, id, _) = rig()
        let v = GraphicSectionView()
        v.itemRows.editor = e
        var calls = 0
        v.onHeightChange = { calls += 1 }
        var clip = e.clip!
        v.show(clip)
        v.show(clip)
        #expect(calls == 0)             // the row is shown and stays
        let items = clip.graphics?.layers ?? []
        clip.graphics?.layers = []
        v.show(clip)
        #expect(calls == 1)             // no items: the row left
        clip.graphics?.layers = items
        v.show(clip)
        #expect(calls == 2)             // items again: the row is back
        _ = id
    }
}
