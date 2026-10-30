import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

// Item lanes review: the monitor overlay outlines and gives handles only to items inside their range at the playhead (the
// gate of render and hit test), and the editor's selection never holds an item a cut dropped.

@MainActor @Suite struct GraphicsOverlayRangeTests {
    /// A 5 s+ Graphic at 0 with two shapes; the first shows only in 1..<2 s.
    private func setup() throws -> (EditorSession, GraphicsEditor, ranged: UUID, whole: UUID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        try #require(e.newGraphicsClip() != nil)
        e.addShape(.rectangle)
        let a = try #require(e.selectedLayers.first)
        e.addShape(.ellipse)
        let b = try #require(e.selectedLayers.first)
        var c = try #require(e.clip)
        var doc = try #require(c.graphics)
        doc.layers[try #require(doc.index(of: a))].range = TimeRange(start: Time(1, 1), end: Time(2, 1))
        c.graphics = doc
        s.replaceClip(c, name: "Item Range", continuesGesture: false)
        e.sync()
        return (s, e, a, b)
    }

    @Test func anItemOutsideItsRangeHasNoOutlineAndNoHandles() throws {
        let (s, e, a, b) = try setup()
        let start = try #require(e.clip).start
        e.select([a])
        s.seek(to: start + Time(3, 2))                                // local 1.5 s: inside
        #expect(Set(e.outlinedLayers.map(\.id)) == [a, b])
        #expect(e.handledLayer?.id == a)
        s.seek(to: start + Time(3, 1))                                // local 3 s: outside
        #expect(e.outlinedLayers.map(\.id) == [b])
        #expect(e.handledLayer == nil)
        #expect(e.selectedLayers == [a])                              // still selected for its lane and the panel
        e.select([b])
        #expect(e.handledLayer?.id == b)
    }

    /// The monitor's measure (outline, handles, hit test, align) runs on the item's range like the picture: a text shown
    /// 1..<3 s with a 0.5 s slide In and Out has its box mid-slide at 1.1 s and on the Out at 2.9 s. Without a range the
    /// box stays on clip time.
    @Test func theMonitorMeasuresARangedTextOnItsRange() throws {
        let (s, e, _, _) = try setup()
        func slide(_ from: Double, _ to: Double) -> KeyframeTemplate {
            KeyframeTemplate(tracks: [AnimationTrack(property: "positionX", keys: [(.zero, from, .linear), (Time(1, 2), to, .linear)])],
                             duration: Time(1, 2))
        }
        let ref = try TextGenerator.makeRef(
            template: TextTemplate(name: "T", text: "Slide", style: CaptionPresetLibrary.builtIn.style(for: "title")),
            animations: AnimationSet(in: slide(-300, 0), out: slide(0, 300)))
        let range = TimeRange(start: Time(1, 1), end: Time(3, 1))
        var text = GraphicsLayer.text(ref)
        var c = try #require(e.clip)
        let format = try #require(s.activeTimeline?.format)
        for ranged in [true, false] {
            text.range = ranged ? range : nil
            c.graphics = GraphicsDocument(layers: [text])
            s.replaceClip(c, name: "Item Range", continuesGesture: false)
            e.sync()
            for t in [Time(11, 10), Time(29, 10)] {
                s.seek(to: c.start + t)
                #expect(e.localTime == t)
                let shown = try #require(e.shownDocument?.layer(text.id))
                let box = try #require(shown.contentRect(atLocal: e.localTime, text: e.textMeasure))
                let onRange = try #require(TextGenerator.graphicsRect(ref: ref, localTime: t - range.start, clipDuration: range.duration,
                                                                      canvas: format))
                let onClip = try #require(TextGenerator.graphicsRect(ref: ref, localTime: t, clipDuration: c.duration, canvas: format))
                #expect(abs(onRange.midX - onClip.midX) > 10)
                #expect(box == (ranged ? onRange : onClip))
            }
        }
    }

    @Test func aCutPrunesADroppedItemFromTheSelection() throws {
        let (s, e, a, b) = try setup()
        e.select([a, b])
        // The piece from 3 s on: the ranged item has nothing left there and is dropped.
        let c = try #require(e.clip)
        var track = try #require(s.activeTimeline?.tracks.first { $0.clips.contains { $0.id == c.id } })
        try track.split(at: c.start + Time(3, 1))
        let right = try #require(track.clips.last)
        #expect(right.graphics?.layers.map { $0.id } == [b])
        var cut = c                                                   // the selected clip is now that piece's graphic
        cut.graphics = right.graphics
        s.replaceClip(cut, name: "Cut", continuesGesture: false)
        e.sync()
        #expect(e.selectedLayers == [b])
        #expect(e.outlinedLayers.map(\.id) == [b])
    }
}
