import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI

private let fd = Time(1, 24)

/// V2, V1 (top to bottom), A1, A2.
private func timeline() -> Timeline {
    let c = Clip(name: "Clip", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero)
    let a = Clip(name: "Aud", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 48), start: .zero)
    return Timeline(name: "t", frameDuration: fd, tracks: [
        Track(kind: .video, clips: [c]), Track(kind: .video), Track(kind: .audio, clips: [a]), Track(kind: .audio),
    ])
}

private func rows(_ t: Timeline, overrides: [Track.ID: CGFloat] = [:]) -> [TrackRow] {
    var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
    g.heightOverrides = overrides
    return g.rows(for: t)
}

@Suite struct TrackSizingTests {
    @Test func resizingOneTrackLeavesTheOthersAndClamps() {
        let t = timeline(), r = rows(t)
        let id = r[1].track
        let out = TrackSizing.resized(rows: r, track: id, to: 60, wholeKind: false)
        #expect(out[id] == 60)
        for row in r where row.track != id { #expect(out[row.track] == row.height) }
        #expect(TrackSizing.resized(rows: r, track: id, to: 2, wholeKind: false)[id] == TrackSizing.minimizedHeight)
        #expect(TrackSizing.resized(rows: r, track: id, to: 5000, wholeKind: false)[id] == TrackSizing.maxHeight)
    }

    @Test func shiftResizesEveryTrackOfThatKind() {
        let t = timeline(), r = rows(t)
        let out = TrackSizing.resized(rows: r, track: r[2].track, to: 50, wholeKind: true)   // A1
        #expect(out[r[2].track] == 50 && out[r[3].track] == 50)
        #expect(out[r[0].track] == r[0].height && out[r[1].track] == r[1].height)
    }

    @Test func splitDragGivesVideoOrAudioMoreRoom() {
        let t = timeline(), r = rows(t, overrides: Dictionary(uniqueKeysWithValues: t.tracks.map { ($0.id, CGFloat(40)) }))
        let down = TrackSizing.splitDragged(rows: r, dy: 20)
        let video = r.filter { $0.kind == .video }, audio = r.filter { $0.kind == .audio }
        #expect(video.allSatisfy { down[$0.track] == 50 })      // two video tracks share +20
        #expect(audio.allSatisfy { down[$0.track] == 30 })      // two audio tracks share -20
        #expect(down.values.reduce(0, +) == 160)                 // total unchanged
        let up = TrackSizing.splitDragged(rows: r, dy: -1000)
        #expect(video.allSatisfy { up[$0.track] == TrackSizing.minimizedHeight })
        #expect(audio.allSatisfy { up[$0.track] == TrackSizing.maxHeight })
    }

    @Test func steppedCommandsTouchOnlyTheirKind() {
        let t = timeline(), r = rows(t)
        let v = TrackSizing.stepped(rows: r, kind: .video, direction: 1)
        #expect(v[r[0].track] == r[0].height + TrackSizing.step)
        #expect(v[r[2].track] == r[2].height)
        let a = TrackSizing.stepped(rows: r, kind: .audio, direction: -1)
        #expect(a[r[2].track] == r[2].height - TrackSizing.step && a[r[0].track] == r[0].height)
        let all = TrackSizing.stepped(rows: r, kind: nil, direction: 1)
        #expect(r.allSatisfy { all[$0.track] == $0.height + TrackSizing.step })
        // Repeated shrinking stops at the minimum.
        var cur = r
        for _ in 0..<40 { cur = rows(t, overrides: TrackSizing.stepped(rows: cur, kind: nil, direction: -1)) }
        #expect(cur.allSatisfy { $0.height == TrackSizing.minimizedHeight })
    }

    @Test func minimizeAndExpandAll() {
        let t = timeline(), r = rows(t)
        let min = TrackSizing.minimizedAll(rows: r)
        #expect(min.count == 4 && min.values.allSatisfy { $0 == TrackSizing.minimizedHeight })
        #expect(TrackSizing.isThin(TrackSizing.minimizedHeight) && !TrackSizing.isThin(Theme.Metrics.trackA1))
        #expect(TrackSizing.expandedAll.isEmpty)
    }

    @Test func zonesSeparateSplitAndHeaderEdges() {
        let t = timeline(), r = rows(t)                     // V2, V1, A1, A2
        let w: CGFloat = 1000
        let splitY = r[1].maxY
        #expect(TrackSizing.zone(at: CGPoint(x: 600, y: splitY), rows: r, viewWidth: w) == .split)          // content area
        #expect(TrackSizing.zone(at: CGPoint(x: 100, y: splitY + 2), rows: r, viewWidth: w) == .split)      // header column
        #expect(TrackSizing.zone(at: CGPoint(x: 100, y: r[0].maxY), rows: r, viewWidth: w) == .trackEdge(r[0].track))
        #expect(TrackSizing.zone(at: CGPoint(x: 600, y: r[0].maxY), rows: r, viewWidth: w) == nil)          // lanes: no edge
        #expect(TrackSizing.zone(at: CGPoint(x: 100, y: r[2].maxY), rows: r, viewWidth: w) == .trackEdge(r[2].track))
        #expect(TrackSizing.zone(at: CGPoint(x: 100, y: r[0].y + 10), rows: r, viewWidth: w) == nil)
        #expect(TrackSizing.zone(at: CGPoint(x: 10, y: splitY), rows: r, viewWidth: w) == nil)             // tool column
    }

    @Test func storeRoundTripsPerSequence() throws {
        let suite = "sq-trackheights-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let store = TrackHeightStore(defaults: d)
        let s1 = UUID(), s2 = UUID(), a = UUID(), b = UUID()
        store.save([a: 40, b: 18], for: s1)
        #expect(store.load(s1) == [a: 40, b: 18])
        #expect(store.load(s2).isEmpty)
        store.save([:], for: s1)
        #expect(store.load(s1).isEmpty)
    }
}

@MainActor
@Suite struct TrackResizeViewTests {
    private func rig() -> (window: NSWindow, view: TimelineView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let v = TimelineView(timeline: timeline(), frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        window.contentView?.addSubview(v)
        return (window, v)
    }

    private func event(_ type: NSEvent.EventType, _ v: TimelineView, _ w: NSWindow, x: CGFloat, y: CGFloat, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: v.convert(CGPoint(x: x, y: y), to: nil),
                           modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func draggingTheSplitMovesRoomBetweenVideoAndAudio() throws {
        let (w, v) = rig()
        let before = v.geometry.rows(for: v.timeline)
        let splitY = before[1].maxY
        var changes: [[Track.ID: CGFloat]] = []
        v.onTrackHeightsChange = { changes.append($0) }
        let hit = try #require(w.contentView?.hitTest(v.convert(CGPoint(x: 600, y: splitY), to: nil)))
        #expect(hit === v)
        hit.mouseDown(with: event(.leftMouseDown, v, w, x: 600, y: splitY))
        hit.mouseDragged(with: event(.leftMouseDragged, v, w, x: 600, y: splitY + 20))
        hit.mouseUp(with: event(.leftMouseUp, v, w, x: 600, y: splitY + 20))
        let after = v.geometry.rows(for: v.timeline)
        #expect(after[0].height == before[0].height + 10 && after[1].height == before[1].height + 10)
        #expect(after[2].height == before[2].height - 10 && after[3].height == before[3].height - 10)
        #expect(changes.count == 1)
    }

    @Test func draggingAHeaderEdgeResizesThatTrackAndShiftTheKind() throws {
        let (w, v) = rig()
        let before = v.geometry.rows(for: v.timeline)
        let edge = before[2].maxY                                  // bottom edge of A1's header
        let hit = try #require(w.contentView?.hitTest(v.convert(CGPoint(x: 100, y: edge), to: nil)))
        hit.mouseDown(with: event(.leftMouseDown, v, w, x: 100, y: edge))
        hit.mouseDragged(with: event(.leftMouseDragged, v, w, x: 100, y: edge + 14, shift: true))
        hit.mouseUp(with: event(.leftMouseUp, v, w, x: 100, y: edge + 14, shift: true))
        let after = v.geometry.rows(for: v.timeline)
        #expect(after[2].height == before[2].height + 14 && after[3].height == before[2].height + 14)
        #expect(after[0].height == before[0].height)
    }

    @Test func commandsAndPersistenceHooks() {
        let (_, v) = rig()
        let r0 = v.geometry.rows(for: v.timeline)
        v.sizeTracks(.video, direction: 1)
        let r1 = v.geometry.rows(for: v.timeline)
        #expect(r1[0].height == r0[0].height + TrackSizing.step && r1[2].height == r0[2].height)
        v.minimizeAllTracks()
        #expect(v.geometry.rows(for: v.timeline).allSatisfy { $0.height == TrackSizing.minimizedHeight })
        v.expandAllTracks()
        #expect(v.trackHeights.isEmpty)
        v.setTrackHeights([v.timeline.tracks[0].id: 100])         // restored from the store
        #expect(v.geometry.heightOverrides[v.timeline.tracks[0].id] == 100)
    }
}
