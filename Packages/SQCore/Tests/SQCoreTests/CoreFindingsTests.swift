import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, targeted: Bool = false) -> Track {
    var t = Track(kind: kind, isTargeted: targeted)
    for c in clips { try! t.overwrite(c) }
    return t
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }

/// Review findings 3, 7, 10 (docs/cloud/review-SQCore.md).
@Suite struct CoreFindingsTests {
    // MARK: 3 ripple edits shift markers and In/Out
    @Test func rippleDeleteShiftsMarkersAndInOut() throws {
        let a = clip(0, 2), b = clip(2, 20)
        var tl = timeline([track([a, b])])
        tl.markers = [Marker(time: s(1), name: "in"), Marker(time: s(10), name: "later")]
        tl.inOut = TimeRange(start: s(5), end: s(15))
        try tl.rippleDelete([a.id])
        #expect(tl.markers.map(\.time) == [s(0), s(8)])
        #expect(tl.inOut == TimeRange(start: s(3), end: s(13)))
    }

    @Test func extractShiftsMarkers() throws {
        let a = clip(0, 20)
        var tl = timeline([track([a], targeted: true)])
        tl.markers = [Marker(time: s(15), name: "m")]
        try tl.extract(TimeRange(start: s(2), end: s(4)), tracks: [tl.tracks[0].id])
        #expect(tl.markers.map(\.time) == [s(13)])
    }

    @Test func insertShiftsMarkersAndInOut() throws {
        let a = clip(0, 20)
        var tl = timeline([track([a])])
        tl.markers = [Marker(time: s(5), name: "before"), Marker(time: s(15), name: "after")]
        tl.inOut = TimeRange(start: s(2), end: s(18))
        try tl.insert([(clip(0, 4), tl.tracks[0].id)], at: s(10))
        #expect(tl.markers.map(\.time) == [s(5), s(19)])
        #expect(tl.inOut == TimeRange(start: s(2), end: s(22)))
    }

    // MARK: 7 paste into a missing lane
    @Test func pasteIntoMissingLaneDoesNotStackClips() throws {
        let a = clip(0, 10), b = clip(0, 10)
        var src = timeline([track([a]), track([b])])
        let cb = src.clipboard(copying: [a.id, b.id])!
        var tl = timeline([track([], targeted: true)])
        try tl.paste(cb, at: s(0))
        #expect(tl.tracks.filter { $0.kind == .video }.count == 2)
        #expect(tl.tracks.allSatisfy { $0.clips.count <= 1 })
        _ = src
    }

    // MARK: 10 zero frame duration
    @Test func decodingZeroFrameDurationFails() throws {
        let json = #"{"width":1920,"height":1080,"frameDuration":{"value":0,"timescale":30},"audioSampleRate":48000}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SequenceFormat.self, from: Data(json.utf8)) }
        let neg = json.replacingOccurrences(of: #""value":0"#, with: #""value":-1"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SequenceFormat.self, from: Data(neg.utf8)) }
        let ok = json.replacingOccurrences(of: #""value":0"#, with: #""value":1"#)
        _ = try JSONDecoder().decode(SequenceFormat.self, from: Data(ok.utf8))
    }

    @Test func decodingVideoInfoWithZeroFrameDurationFails() throws {
        let v = VideoTrackInfo(width: 1, height: 1, codec: "avc1", bitDepth: 8, chroma: "420",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
        obj["nominalFrameDuration"] = ["value": 0, "timescale": 30]
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VideoTrackInfo.self, from: data) }
    }
}

/// Review findings 4, 5, 6, 8, 9, 11.
@Suite struct CoreFindingsTests2 {
    // MARK: 4 shuttle never exceeds 8x
    @Test func shuttleRateStaysWithinEightX() {
        // Explore every rate reachable through key presses/releases/holds (BFS over Shuttle states).
        var seen: [Shuttle] = [Shuttle()]
        var frontier = seen
        for _ in 0..<12 {
            var next: [Shuttle] = []
            for st in frontier {
                var variants: [Shuttle] = []
                for k in [ShuttleKey.j, .k, .l] {
                    var p = st; _ = p.press(k); variants.append(p)
                    var r = st; _ = r.release(k); variants.append(r)
                    var h = st; _ = h.holdElapsed(k); variants.append(h)
                }
                for v in variants where !seen.contains(v) { seen.append(v); next.append(v) }
            }
            frontier = next
        }
        #expect(seen.count > 10)
        #expect(seen.allSatisfy { Int64(abs($0.rate.num)) <= 8 * Int64($0.rate.den) })
    }

    // MARK: 5 non-container "project" value
    @Test func nonContainerProjectValueIsCorruptNotATrap() {
        for v in [9, 16] {
            let data = Data(#"{"formatVersion":\#(v),"project":5}"#.utf8)
            #expect(throws: ProjectFileError.self) { try ProjectFile.decode(data, migrations: ProjectFile.migrations) }
        }
    }

    // MARK: 6 nested clip follows the inner sequence length at edit time
    @Test func nestedClipExtendsWhenInnerSequenceGrew() throws {
        var p = Project(name: "p")
        let inner = Timeline(name: "inner", frameDuration: Time(1, 30), tracks: [track([clip(0, 10)])])
        let outer = Timeline(name: "outer", frameDuration: Time(1, 30), tracks: [track([])])
        p.timelines = [inner, outer]
        let nested = p.sequenceClips(of: inner.id, at: s(0))!
        try p.edit(outer.id) { try $0.insert([(nested[0], $0.tracks[0].id)], at: s(0)) }
        try p.edit(inner.id) { try $0.insert([(clip(0, 6), $0.tracks[0].id)], at: s(10)) }   // inner is now 16 s
        let id = p.timelines[1].tracks[0].clips[0].id
        let moved = try { () -> Time in
            var d = Time.zero
            try p.edit(outer.id) { d = try $0.rippleTrim(id, edge: ClipEdge.tail, by: s(6)) }
            return d
        }()
        #expect(moved == s(6))
        #expect(p.timelines[1].tracks[0].clips[0].timeline.duration == s(16))
    }

    // MARK: 8 slide with a sub-frame neighbour
    @Test func slideLeftWithSubFrameNeighbourNeverMovesRight() throws {
        let frame = Time(1, 30)
        var prev = clip(0, 1)
        prev.source = TimeRange(start: s(0), duration: Time(1, 60))       // half a frame long
        let mid = clip(0, 5)
        var tr = track([])
        var m = mid; m.start = prev.timeline.end
        try tr.overwrite(prev); try tr.overwrite(m)
        var tl = timeline([tr])
        let moved = try tl.slide(m.id, by: Time(-1, 10))
        #expect(moved <= .zero)
        #expect(tl.tracks[0].isConsistent)
    }

    // MARK: 9 caption trim next to a neighbour
    @Test func captionTailTrimNeverOverlapsNextCaption() {
        let a = CaptionItem(lines: ["a"], range: TimeRange(start: s(0), duration: Time(1, 60)))
        let b = CaptionItem(lines: ["b"], range: TimeRange(start: Time(1, 40), duration: s(2)))   // gap < minDuration
        var t = CaptionTrack(items: [a, b])
        t.trim(a.id, edge: .tail, to: s(5), minDuration: Time(1, 30))
        #expect(t.items[0].range.end <= t.items[1].range.start)
    }

    // MARK: 11 squash / rewind after the 200-step trim
    @Test func squashDepthSurvivesHistoryTrim() {
        var h = History<Int>(0, limit: 3)
        h.commit("a") { $0 = 1 }
        let depth = h.undoDepth
        h.commit("b") { $0 = 2 }
        h.commit("c") { $0 = 3 }
        h.commit("d") { $0 = 4 }              // the 3-step limit drops the oldest entry; `depth` must still mean "before b"
        h.squash(fromDepth: depth, name: "squashed")
        #expect(h.undoName == "squashed")
        h.undo()
        #expect(h.current == 1)               // one undo reverts b, c and d together
    }

    @Test func rewindDepthSurvivesHistoryTrim() {
        var h = History<Int>(0, limit: 3)
        h.commit("a") { $0 = 1 }
        let depth = h.undoDepth
        h.commit("b") { $0 = 2 }
        h.commit("c") { $0 = 3 }
        h.commit("d") { $0 = 4 }
        h.rewind(toDepth: depth)
        #expect(h.current == 1)
    }
}
