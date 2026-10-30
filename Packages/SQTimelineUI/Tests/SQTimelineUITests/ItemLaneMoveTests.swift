import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// V1 holds a 10 s Graphic at 2 s with layers a, b (b on top); V2 (above V1) is free.
@MainActor private func setup() throws -> (TimelineView, Clip.ID, Track.ID, [UUID]) {
    let v1 = Track(kind: .video), v2 = Track(kind: .video)
    let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2])
    var p = Project(name: "P", timelines: [t])
    var a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080); a.name = "a"
    var b = a; b.id = UUID(); b.name = "b"
    let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v1.id, duration: s(10), layers: [a, b])
    let v = TimelineView(timeline: p.timeline(t.id)!, frame: NSRect(x: 0, y: 0, width: 1200, height: 500))
    v.setZoom(pointsPerSecond: 60, anchorX: TimelineGeometry.contentOriginX)
    v.toggleItemLanes(id)
    return (v, id, v2.id, [a.id, b.id])
}

@MainActor @Suite struct ItemLaneMoveTests {
    @Test func dragToAFreeTrackMakesANewGraphic() throws {
        let (v, id, v2, ids) = try setup()
        let rows = v.layoutRows()
        let src = rows.first { $0.laneSpace > 0 }!, free = rows.first { $0.track == v2 }!
        var got: [(Clip.ID, [UUID], GraphicsLayerDestination, Bool)] = []
        v.onItemLaneMoveOut = { got.append(($0, $1, $2, $3)) }
        let press = CGPoint(x: TimelineGeometry.toolColumnWidth + 20, y: src.maxY + ItemLanes.laneHeight / 2)   // top lane = b
        #expect(v.beginItemLaneDrag(at: press, modifiers: []))
        let drop = CGPoint(x: TimelineGeometry.contentOriginX + 300, y: free.y + free.height / 2)
        _ = v.updateItemLaneDrag(to: drop, modifiers: [.option])
        #expect(v.itemLanes.move?.target == .newGraphic(v2))
        #expect(v.endItemLaneDrag(at: drop, modifiers: [.option]))
        #expect(got.count == 1 && got[0].0 == id && got[0].1 == [ids[1]] && got[0].2 == .newGraphic(track: v2) && got[0].3)
    }

    @Test func dragBetweenLanesReorders() throws {
        let (v, id, _, ids) = try setup()
        let src = v.layoutRows().first { $0.laneSpace > 0 }!
        var got: [(Clip.ID, [UUID], Int)] = []
        v.onItemLaneReorder = { got.append(($0, $1, $2)) }
        let press = CGPoint(x: TimelineGeometry.toolColumnWidth + 20, y: src.maxY + ItemLanes.laneHeight / 2)
        #expect(v.beginItemLaneDrag(at: press, modifiers: []))
        let drop = CGPoint(x: TimelineGeometry.contentOriginX + 100, y: src.bottom - 1)   // below the last lane
        _ = v.updateItemLaneDrag(to: drop, modifiers: [])
        #expect(v.endItemLaneDrag(at: drop, modifiers: []))
        #expect(got.count == 1 && got[0].0 == id && got[0].1 == [ids[1]] && got[0].2 == 0)   // b goes to the bottom of the list
    }

    @Test func dropOnItsOwnTrackIsRefused() throws {
        let (v, _, _, _) = try setup()
        let src = v.layoutRows().first { $0.laneSpace > 0 }!
        var called = false
        v.onItemLaneMoveOut = { _, _, _, _ in called = true }
        let press = CGPoint(x: TimelineGeometry.toolColumnWidth + 20, y: src.maxY + ItemLanes.laneHeight / 2)
        _ = v.beginItemLaneDrag(at: press, modifiers: [])
        let drop = CGPoint(x: TimelineGeometry.contentOriginX + 300, y: src.y + src.height / 2)
        _ = v.updateItemLaneDrag(to: drop, modifiers: [])
        #expect(v.itemLanes.move?.target == nil)
        _ = v.endItemLaneDrag(at: drop, modifiers: [])
        #expect(!called)
    }
}
