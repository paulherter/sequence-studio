import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }

private func item(_ name: String, _ range: TimeRange?) -> GraphicsLayer {
    var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    l.name = name
    l.range = range
    return l
}

/// V1 with a 10 s Graphic at 2 s holding `items`, A1 below.
private func graphicTimeline(_ items: [GraphicsLayer]) throws -> (Timeline, Clip.ID) {
    let v = Track(kind: .video), a = Track(kind: .audio)
    let t = Timeline(name: "T", frameDuration: fd, tracks: [v, a])
    var p = Project(name: "P", timelines: [t])
    let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10), layers: items)
    return (p.timeline(t.id)!, id)
}

@MainActor private func view(_ t: Timeline, height: CGFloat = 400) -> TimelineView {
    let v = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1200, height: height))
    v.setZoom(pointsPerSecond: 60, anchorX: TimelineGeometry.contentOriginX)
    return v
}

private func graphic(_ t: Timeline, _ id: Clip.ID) -> Clip { t.tracks.flatMap(\.clips).first { $0.id == id }! }
private func ranges(_ c: Clip) -> [String: TimeRange?] {
    Dictionary(uniqueKeysWithValues: (c.graphics?.layers ?? []).map { ($0.name, $0.range) })
}

@MainActor private func render(_ v: TimelineView, _ rep: NSBitmapImageRep) {
    guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let cg = base.cgContext
    cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh)); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    v.draw(v.bounds)
    NSGraphicsContext.restoreGraphicsState()
}

@MainActor private func makeRep(_ size: CGSize) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

@MainActor private final class EditLog {
    var list: [(Clip, VolumeEditPhase)] = []
    var phases: [VolumeEditPhase] { list.map(\.1) }
}

@MainActor private func edits(_ v: TimelineView) -> EditLog {
    let log = EditLog()
    v.onItemLaneEdit = { log.list.append(($0, $1)) }
    return log
}

@MainActor @Suite struct ItemLaneTests {
    // MARK: Layout

    @Test func laneSpaceMovesTheRowsBelow() throws {
        let (t, _) = try graphicTimeline([item("a", nil), item("b", nil)])
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 60)
        let plain = g.rows(for: t), height = g.contentHeight(for: t)
        g.laneSpace = [t.tracks[0].id: 40]
        let open = g.rows(for: t)
        #expect(open[0].y == plain[0].y && open[0].height == plain[0].height)
        #expect(open[0].laneSpace == 40 && open[0].bottom == plain[0].y + plain[0].height + 40)
        #expect(open[1].y == plain[1].y + 40)
        #expect(g.contentHeight(for: t) == height + 40)
    }

    @Test func everyGraphicHasTheArrowAndSingleItemOpens() throws {
        let (one, a) = try graphicTimeline([item("a", nil)])
        #expect(ItemLanes.isAvailable(for: graphic(one, a)))
        let v1 = view(one)
        #expect(v1.itemLaneChevronRect(clip: a) != nil)
        v1.toggleItemLanes(a)
        #expect(v1.openItemLanes == [a])
        #expect(v1.geometry.laneSpace == [one.tracks[0].id: ItemLanes.laneHeight])
        v1.toggleItemLanes(a)

        let (two, b) = try graphicTimeline([item("a", nil), item("b", nil)])
        let v2 = view(two)
        let chevron = try #require(v2.itemLaneChevronRect(clip: b))
        let p = CGPoint(x: chevron.midX, y: chevron.midY)
        #expect(v2.beginItemLaneDrag(at: p, modifiers: []))
        #expect(v2.endItemLaneDrag(at: p, modifiers: []))
        #expect(v2.openItemLanes == [b])
        #expect(v2.geometry.laneSpace == [two.tracks[0].id: 2 * ItemLanes.laneHeight])
        #expect(v2.timeline == two)                               // opened is view state: the model is untouched
        #expect(v2.beginItemLaneDrag(at: p, modifiers: []))
        _ = v2.endItemLaneDrag(at: p, modifiers: [])
        #expect(v2.openItemLanes.isEmpty && v2.geometry.laneSpace.isEmpty)
    }

    /// The arrow sits at the head in front of the name, clear of both trim handles: a press on a handle of a Graphic with
    /// lanes is the clip's trim, and only the Select tool opens lanes (Razor on the arrow cuts).
    @Test func theArrowLeavesTheTrimHandlesAndOtherToolsAlone() throws {
        let (t, id) = try graphicTimeline([item("a", nil), item("b", nil)])
        let v = view(t)
        let chevron = try #require(v.itemLaneChevronRect(clip: id))
        let x0 = v.geometry.x(for: s(2)), x1 = v.geometry.x(for: s(12))
        let handle = TimelineGeometry.maxTrimHandleWidth
        #expect(chevron.minX - 2 >= x0 + handle && chevron.maxX + 2 <= x1 - handle)
        #expect(chevron.midX < (x0 + x1) / 2)                          // head side
        for x in [x0 + 1, x0 + handle - 0.5, x1 - handle + 0.5, x1 - 1] {
            for y in [chevron.minY - 2, chevron.midY, chevron.maxY + 2] {
                #expect(!v.beginItemLaneDrag(at: CGPoint(x: x, y: y), modifiers: []))
            }
        }
        guard case .clip(let hit, let zone) = v.geometry.hitTest(CGPoint(x: x1 - 3, y: chevron.midY), in: v.timeline) else {
            Issue.record("the tail handle is not hit"); return
        }
        #expect(hit == id && zone == .tail)
        #expect(v.openItemLanes.isEmpty)

        let p = CGPoint(x: chevron.midX, y: chevron.midY)
        v.toolState.tool = .razor
        #expect(!v.beginItemLaneDrag(at: p, modifiers: []))            // falls through to the Razor
        #expect(v.openItemLanes.isEmpty)
        v.toolState.tool = .selection
        #expect(v.beginItemLaneDrag(at: p, modifiers: []))
        _ = v.endItemLaneDrag(at: p, modifiers: [])
        #expect(v.openItemLanes == [id])
    }

    /// A locked item, or any item on a locked track, is selected by a press on its bar but neither moves nor trims.
    @Test func aLockedItemOrTrackOnlySelects() throws {
        var locked = item("a", r(1, 4))
        locked.isLocked = true
        let (t, id) = try graphicTimeline([locked, item("b", r(2, 6))])
        func drags(_ v: TimelineView, _ itemID: UUID) throws -> (edits: Int, selected: Set<UUID>) {
            v.toggleItemLanes(id)
            let log = edits(v)
            var selected: Set<UUID> = []
            v.onItemLaneSelect = { _, items in selected = items }
            let bar = try #require(v.itemLaneBarRect(clip: id, item: itemID))
            for x in [bar.midX, bar.minX + 1, bar.maxX - 1] {
                let p = CGPoint(x: x, y: bar.midY)
                #expect(v.beginItemLaneDrag(at: p, modifiers: []))
                _ = v.updateItemLaneDrag(to: CGPoint(x: p.x + 90, y: p.y), modifiers: [])
                _ = v.endItemLaneDrag(at: CGPoint(x: p.x + 90, y: p.y), modifiers: [])
            }
            #expect(v.timeline == t || v.timeline.tracks[0].isLocked)
            return (log.list.count, selected)
        }
        let a = graphic(t, id).graphics!.layers[0].id, b = graphic(t, id).graphics!.layers[1].id
        let v = view(t)
        let onLocked = try drags(v, a)
        #expect(onLocked.edits == 0 && onLocked.selected == [a])
        #expect(ranges(graphic(v.timeline, id)) == ["a": r(1, 4), "b": r(2, 6)])

        var lockedTrack = t
        lockedTrack.tracks[0].isLocked = true
        let v2 = view(lockedTrack)
        let onTrack = try drags(v2, b)
        #expect(onTrack.edits == 0 && onTrack.selected == [b])
        #expect(ranges(graphic(v2.timeline, id)) == ["a": r(1, 4), "b": r(2, 6)])
    }

    @Test func lanesCloseWhenTheClipLosesThem() throws {
        let (t, id) = try graphicTimeline([item("a", nil), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        #expect(v.openItemLanes == [id])
        var c = graphic(t, id)
        var doc = try #require(c.graphics)
        doc.remove(Set(doc.layers.map(\.id)))
        c.graphics = doc
        var edited = t
        try edited.replaceClip(c)
        v.setTimeline(edited)
        #expect(v.openItemLanes.isEmpty && v.geometry.laneSpace.isEmpty)
        v.setTimeline(t)
        v.toggleItemLanes(id)
        #expect(v.openItemLanes == [id])
        var gone = t
        gone.tracks[0] = Track(kind: .video)
        v.setTimeline(gone)
        #expect(v.openItemLanes.isEmpty && v.geometry.laneSpace.isEmpty)
    }

    @Test func lanesListTheTopItemFirst() throws {
        let (t, id) = try graphicTimeline([item("bottom", r(1, 4)), item("top", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let doc = try #require(graphic(t, id).graphics)
        let top = try #require(v.itemLaneBarRect(clip: id, item: doc.layers[1].id))
        let bottom = try #require(v.itemLaneBarRect(clip: id, item: doc.layers[0].id))
        #expect(bottom.minY == top.minY + ItemLanes.laneHeight)
        let x0 = TimelineGeometry.contentOriginX
        #expect(abs(top.minX - (x0 + 120)) < 0.01 && abs(top.maxX - (x0 + 720)) < 0.01)        // the whole clip: 2 s to 12 s
        #expect(abs(bottom.minX - (x0 + 180)) < 0.01 && abs(bottom.maxX - (x0 + 360)) < 0.01)  // 3 s to 6 s
    }

    // MARK: Gestures

    @Test func aBarMovesInsideTheClipAsOneGesture() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        #expect(v.beginItemLaneDrag(at: p, modifiers: []))
        #expect(log.list.isEmpty)                                 // a press alone edits nothing
        #expect(v.updateItemLaneDrag(to: CGPoint(x: p.x + 60.6, y: p.y), modifiers: []))   // 1 s and a bit: lands on the frame
        #expect(ranges(graphic(v.timeline, id))["a"] == r(2, 5))
        #expect(v.updateItemLaneDrag(to: CGPoint(x: p.x + 2000, y: p.y), modifiers: []))
        #expect(ranges(graphic(v.timeline, id))["a"] == r(7, 10))  // stays inside the clip
        #expect(v.endItemLaneDrag(at: CGPoint(x: p.x - 2000, y: p.y), modifiers: []))
        #expect(ranges(graphic(v.timeline, id))["a"] == r(0, 3))
        #expect(log.phases.first == .began && log.phases.last == .ended)
        #expect(log.phases.filter { $0 == .began }.count == 1 && log.phases.filter { $0 == .ended }.count == 1)
        #expect(log.list.last?.0 == graphic(v.timeline, id))
        #expect(v.openItemLanes == [id])
    }

    @Test func aTrimSnapsToThePlayheadAndKeepsOneFrame() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.setPlayhead(s(9))
        v.toggleItemLanes(id)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let tail = CGPoint(x: bar.maxX - 1, y: bar.midY)
        #expect(v.beginItemLaneDrag(at: tail, modifiers: []))
        _ = v.updateItemLaneDrag(to: CGPoint(x: tail.x + 177, y: tail.y), modifiers: [])   // 8.95 s: in reach of the playhead at 9 s
        #expect(ranges(graphic(v.timeline, id))["a"] == r(1, 7))
        v.toolState.snapping = false
        _ = v.updateItemLaneDrag(to: CGPoint(x: tail.x + 177, y: tail.y), modifiers: [])
        let free = try #require(ranges(graphic(v.timeline, id))["a"] ?? nil)
        #expect(free.end != s(7) && free.end > s(6))                   // off the playhead
        _ = v.updateItemLaneDrag(to: CGPoint(x: tail.x - 5000, y: tail.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["a"] == TimeRange(start: s(1), end: s(1) + fd))
        _ = v.endItemLaneDrag(at: CGPoint(x: tail.x - 5000, y: tail.y), modifiers: [])

        // The head of an item that fills the clip can be trimmed in.
        let b = graphic(t, id).graphics!.layers[1].id
        let whole = try #require(v.itemLaneBarRect(clip: id, item: b))
        let head = CGPoint(x: whole.minX + 1, y: whole.midY)
        #expect(v.beginItemLaneDrag(at: head, modifiers: []))
        _ = v.endItemLaneDrag(at: head, modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["b"] == .some(nil))    // a click changes nothing
        #expect(v.beginItemLaneDrag(at: head, modifiers: []))
        _ = v.updateItemLaneDrag(to: CGPoint(x: head.x + 120, y: head.y), modifiers: [])
        _ = v.endItemLaneDrag(at: CGPoint(x: head.x + 120, y: head.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["b"] == r(2, 10))
    }

    @Test func cancelPutsTheRangeBack() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        _ = v.updateItemLaneDrag(to: CGPoint(x: p.x + 120, y: p.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["a"] == r(3, 6))
        v.cancelGesture()
        #expect(v.timeline == t)
        #expect(log.list.last?.0 == graphic(t, id) && log.phases.last == .ended)
        #expect(!v.updateItemLaneDrag(to: p, modifiers: []))            // the gesture is over
    }

    @Test func anotherToolDoesNotDrag() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        v.toolState.tool = .razor
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        _ = v.updateItemLaneDrag(to: CGPoint(x: p.x + 120, y: p.y), modifiers: [])
        _ = v.endItemLaneDrag(at: CGPoint(x: p.x + 120, y: p.y), modifiers: [])
        #expect(v.timeline == t)
    }

    @Test func aToolChangeCancelsTheDrag() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        #expect(v.itemLaneDragged(to: CGPoint(x: p.x + 120, y: p.y), modifiers: []))
        #expect(v.isDragging)                                           // Escape reaches the view
        #expect(ranges(graphic(v.timeline, id))["a"] == r(3, 6))
        v.toolState.snapping.toggle()                                   // not a tool change: the drag goes on
        #expect(v.isDragging)
        v.toolState.tool = .razor
        #expect(v.timeline == t && !v.isDragging)
        #expect(log.list.last?.0 == graphic(t, id) && log.phases.last == .ended)
        #expect(log.phases.filter { $0 == .ended }.count == 1)
        #expect(!v.itemLaneDragged(to: CGPoint(x: p.x + 200, y: p.y), modifiers: []))   // the rest of the drag does nothing
        #expect(!v.endItemLaneDrag(at: p, modifiers: []))
        #expect(v.timeline == t)
    }

    @Test func losingTheWindowCancelsTheDrag() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let tail = CGPoint(x: bar.maxX - 1, y: bar.midY)
        _ = v.beginItemLaneDrag(at: tail, modifiers: [])
        _ = v.itemLaneDragged(to: CGPoint(x: tail.x + 120, y: tail.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["a"] == r(1, 6))
        v.windowResignedKey()
        #expect(v.timeline == t && !v.isDragging)
        #expect(log.list.last?.0 == graphic(t, id) && log.phases.last == .ended)
        // A press that started no drag is let go too (its mouse up may never arrive).
        _ = v.beginItemLaneDrag(at: tail, modifiers: [])
        v.windowResignedKey()
        #expect(!v.endItemLaneDrag(at: tail, modifiers: []))
        #expect(log.phases.filter { $0 == .ended }.count == 1)
    }

    /// The autoscroll of a clip drag scrolls and feeds the gesture the same pointer again: the bar follows the time
    /// under the pointer, for a move and for a trim.
    @Test func aDragFollowsTheTimelineScrollingUnderIt() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.setZoom(pointsPerSecond: 200, anchorX: TimelineGeometry.contentOriginX)
        v.toolState.snapping = false
        v.toggleItemLanes(id)
        let a = graphic(t, id).graphics!.layers[0].id
        var bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        _ = v.itemLaneDragged(to: CGPoint(x: p.x + 100, y: p.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["a"] == TimeRange(start: Time(3, 2), end: Time(9, 2)))
        let x = v.geometry.scrollX
        v.scroll(byX: 100, y: 0)
        try #require(v.geometry.scrollX == x + 100)
        v.refreshGesture()                                              // what an autoscroll tick does after it scrolled
        #expect(ranges(graphic(v.timeline, id))["a"] == r(2, 5))        // half a second more passed under the pointer
        _ = v.endItemLaneDrag(at: CGPoint(x: p.x + 100, y: p.y), modifiers: [])
        #expect(ranges(graphic(v.timeline, id))["a"] == r(2, 5))

        bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let tail = CGPoint(x: bar.maxX - 1, y: bar.midY)
        _ = v.beginItemLaneDrag(at: tail, modifiers: [])
        _ = v.itemLaneDragged(to: CGPoint(x: tail.x + 100, y: tail.y), modifiers: [])
        v.scroll(byX: 100, y: 0)
        v.refreshGesture()
        _ = v.endItemLaneDrag(at: CGPoint(x: tail.x + 100, y: tail.y), modifiers: [])
        let trimmed = try #require(ranges(graphic(v.timeline, id))["a"] ?? nil)
        #expect(trimmed.start == s(2) && trimmed.end >= s(6) - fd && trimmed.end <= s(6) + fd)
    }

    @Test func aBarHasAClipsTrimCursors() {
        #expect(TimelineView.itemLaneCursor(.head) == .trimIn)
        #expect(TimelineView.itemLaneCursor(.tail) == .trimOut)
        #expect(TimelineView.itemLaneCursor(.move) == nil)             // a clip's body keeps the arrow too
    }

    /// Escape undoes a moved bar like any other drag: `cancelsOnEscape` and `isDragging` agree.
    @Test func escapeCancelsTheDrag() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        #expect(!v.cancelsOnEscape && !v.isDragging)                    // a press alone is no drag yet
        #expect(v.itemLaneDragged(to: CGPoint(x: p.x + 120, y: p.y), modifiers: []))
        #expect(v.cancelsOnEscape && v.isDragging)
        #expect(ranges(graphic(v.timeline, id))["a"] == r(3, 6))
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                                isARepeat: false, keyCode: 53))
        v.keyDown(with: esc)
        #expect(v.timeline == t && !v.isDragging && !v.cancelsOnEscape)
        #expect(log.list.last?.0 == graphic(t, id) && log.phases.last == .ended)
        #expect(log.phases.filter { $0 == .ended }.count == 1)
        #expect(!v.itemLaneDragged(to: CGPoint(x: p.x + 200, y: p.y), modifiers: []))   // the rest of the drag does nothing
        #expect(v.timeline == t)
    }

    /// A view taken out of its window never gets the mouse up: the drag ends there and the clip is put back.
    @Test func leavingTheWindowCancelsTheDrag() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        host.addSubview(v)
        v.toggleItemLanes(id)
        let log = edits(v)
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let p = CGPoint(x: bar.midX, y: bar.midY)
        _ = v.beginItemLaneDrag(at: p, modifiers: [])
        _ = v.itemLaneDragged(to: CGPoint(x: p.x + 120, y: p.y), modifiers: [])
        #expect(v.isDragging && v.window != nil)
        v.removeFromSuperview()
        #expect(v.window == nil && !v.isDragging)
        #expect(v.timeline == t)
        #expect(log.list.last?.0 == graphic(t, id) && log.phases.filter { $0 == .ended }.count == 1)
        #expect(!v.endItemLaneDrag(at: p, modifiers: []))
    }

    /// The trim cursor shows wherever a press trims: the full lane height at both ends of a bar, not just the drawn bar.
    @Test func trimCursorsCoverTheHeightAPressAccepts() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let rects = v.itemLaneCursorRects(in: v.bounds)
        #expect(rects.count == 4)                                       // head and tail of both bars
        for (rect, kind) in rects {
            #expect(rect.height == ItemLanes.laneHeight)
            // Every corner of the zone is a press on that end of a bar, and the cursor names the same end.
            for p in [CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.25), CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.25)] {
                guard case .bar(_, _, let mode)? = v.itemLaneHit(at: p) else { Issue.record("no bar at \(p)"); continue }
                #expect(TimelineView.itemLaneCursor(mode) == kind)
            }
        }
        // Above and below the drawn bar, still inside its lane: a trim press, and a trim cursor.
        let a = graphic(t, id).graphics!.layers[0].id
        let bar = try #require(v.itemLaneBarRect(clip: id, item: a))
        let below = CGPoint(x: bar.maxX - 1, y: bar.maxY + 1)
        guard case .bar(_, let item, .tail)? = v.itemLaneHit(at: below) else { Issue.record("no tail below the bar"); return }
        #expect(item == a)
        #expect(rects.contains { $0.rect.contains(below) && $0.kind == .trimOut })
        v.toolState.tool = .razor                                       // another tool: no trim zones
        #expect(v.itemLaneCursorRects(in: v.bounds).isEmpty)
    }

    // MARK: Selection

    @Test func aLaneSelectsItsItemAndShowsTheSelection() throws {
        let (t, id) = try graphicTimeline([item("a", r(1, 4)), item("b", nil)])
        let v = view(t)
        v.toggleItemLanes(id)
        let layers = graphic(t, id).graphics!.layers
        var picked: [(Clip.ID, Set<UUID>)] = []
        v.onItemLaneSelect = { picked.append(($0, $1)) }
        let top = try #require(v.itemLaneBarRect(clip: id, item: layers[1].id))
        #expect(v.beginItemLaneDrag(at: CGPoint(x: top.midX, y: top.midY), modifiers: []))
        _ = v.endItemLaneDrag(at: CGPoint(x: top.midX, y: top.midY), modifiers: [])
        #expect(picked.last?.0 == id && picked.last?.1 == [layers[1].id])
        // Another bar, with Shift: added to the selection.
        let bar = try #require(v.itemLaneBarRect(clip: id, item: layers[0].id))
        #expect(v.beginItemLaneDrag(at: CGPoint(x: bar.midX, y: bar.midY), modifiers: .shift))
        _ = v.endItemLaneDrag(at: CGPoint(x: bar.midX, y: bar.midY), modifiers: .shift)
        #expect(picked.last?.1 == [layers[0].id, layers[1].id])
        // From outside (monitor, Controls): the lanes take it over, without reporting it back.
        let before = picked.count
        v.setItemSelection(clip: id, items: [layers[0].id])
        #expect(v.itemLanes.selectedItems == [layers[0].id] && picked.count == before)
        // Empty lane space takes the press: no clip gesture starts under an opened Graphic.
        let empty = CGPoint(x: TimelineGeometry.contentOriginX + 40, y: top.midY)
        #expect(v.beginItemLaneDrag(at: empty, modifiers: []))
        #expect(v.endItemLaneDrag(at: empty, modifiers: []))
        #expect(!v.endItemLaneDrag(at: empty, modifiers: []))
    }

    // MARK: Cost

    /// The draw budget of the timeline (6 ms, `redrawPerformance200Clips`) holds with a Graphic of 20 item lanes opened.
    @Test func twentyOpenLanesStayInsideTheDrawBudget() throws {
        let f24 = Time(1, 24)
        var tracks: [Track] = []
        for (i, kind) in [TrackKind.video, .video, .audio, .audio].enumerated() {
            let clips = (0..<50).map { n in
                Clip(name: "Clip \(i * 50 + n)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: f24 * 24),
                     start: f24 * (Int64(n) * 30))
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
        }
        let top = Track(kind: .video)
        tracks.insert(top, at: 2)
        let t = Timeline(name: "big", frameDuration: f24, tracks: tracks)
        var p = Project(name: "P", timelines: [t])
        let items = (0..<20).map { item("Item \($0)", TimeRange(start: s(Int64($0)), end: s(Int64($0) + 20))) }
        let id = try p.addGraphicsClip(in: t.id, at: s(5), track: top.id, duration: s(50), layers: items)
        let v = TimelineView(timeline: p.timeline(t.id)!, frame: NSRect(x: 0, y: 0, width: 1600, height: 640))
        v.setZoom(pointsPerSecond: 23, anchorX: TimelineGeometry.contentOriginX)
        v.setPlayhead(f24 * 300)
        let rep = makeRep(v.bounds.size)
        func median() -> Double {
            for _ in 0..<5 { render(v, rep) }
            var best = Double.infinity
            for _ in 1...4 {
                var samples: [Double] = []
                for _ in 0..<30 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    render(v, rep)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                samples.sort()
                best = min(best, samples[15])
                if best < 4 { break }
            }
            return best
        }
        let closed = median()
        v.toggleItemLanes(id)
        v.setItemSelection(clip: id, items: [items[3].id])
        #expect(v.geometry.laneSpace.values.first == 20 * ItemLanes.laneHeight)
        let open = median()
        if let path = ProcessInfo.processInfo.environment["SQ_PERF_LOG"] {
            try? "item lanes: draw 1600x640, 200 clips, closed \(closed) ms, 20 lanes open \(open) ms\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(open < SQTiming.budget(6), "closed \(closed) ms, open \(open) ms")
    }

    // MARK: Text and shape clips

    /// A text clip has the arrow too: pressing it asks the host to make the clip a Graphic, and the lanes open as soon as
    /// the timeline shows the converted clip.
    @Test func aTextClipOpensThroughMakeGraphic() throws {
        let v = Track(kind: .video)
        let t0 = Timeline(name: "T", frameDuration: fd, tracks: [v])
        var p = Project(name: "P", timelines: [t0])
        let id = try p.addShapeClip(.ellipse, in: t0.id, at: s(2), track: v.id, duration: s(5))
        let t = p.timeline(t0.id)!
        let view = view(t)
        let chevron = try #require(view.itemLaneChevronRect(clip: id))
        var asked: [Clip.ID] = []
        view.onItemLanesMakeGraphic = { asked.append($0) }
        let pt = CGPoint(x: chevron.midX, y: chevron.midY)
        #expect(view.beginItemLaneDrag(at: pt, modifiers: []))
        _ = view.endItemLaneDrag(at: pt, modifiers: [])
        #expect(asked == [id])
        #expect(view.openItemLanes.isEmpty)
        var q = p
        try q.convertToGraphics(clipID: id)
        view.setTimeline(q.timeline(t0.id)!)
        #expect(view.openItemLanes == [id])
    }
}
