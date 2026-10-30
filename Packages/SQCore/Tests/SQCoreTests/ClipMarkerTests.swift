import Foundation
import Testing
@testable import SQCore

// v60: clip markers (`Clip.markers`, Premiere's clip markers). Marker times are source time, so trims, slips and splits
// carry them with the picture; `visibleMarkers` gives the ones inside the played range at clip-local time.

private let fd30 = Time(1, 30)

private func clip(source: TimeRange = TimeRange(start: Time(2, 1), duration: Time(4, 1)), start: Time = .zero,
                  markers: [Marker]? = nil) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: source, start: start, mediaDuration: Time(20, 1))
    c.markers = markers
    return c
}

private func project(_ clips: [Clip]) throws -> Project {
    var tracks: [Track] = []
    for c in clips { var t = Track(kind: .video); try t.overwrite(c); tracks.append(t) }
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                   tracks: tracks)])
}

@Suite struct ClipMarkerTests {
    @Test func versionConstant() {
        #expect(ProjectFile.v60Version == 60)
        #expect(ProjectFile.currentVersion >= 60)
    }

    @Test func markersBumpToV60AndRoundTrip() throws {
        let m = Marker(time: Time(3, 1), name: "Beat", color: .red, comment: "hit", duration: Time(1, 2))
        let p = try project([clip(markers: [m])])
        #expect(p.containsV60Content)
        #expect(ProjectFile.writtenVersion(for: p) == 60)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.timelines[0].tracks[0].clips[0].markers == [m])
        #expect(back == p)
    }

    @Test func clipsWithoutMarkersKeepTheirVersion() throws {
        let p = try project([clip(), clip(markers: [])])
        #expect(!p.containsV60Content)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.stabilizeVersion)
    }

    /// Effect kinds added after the v59 build shipped gate v60 too, on a clip or on a graphics layer: a v59 build does not
    /// know them and would render the clip without the effect.
    @Test func effectKindsNewerThanV59BumpToV60() throws {
        #expect(ClipEffect.v60Kinds == ["audio.highCut", "audio.stereoWidth", "audio.chorus", "edgeFeather", "glitchDisplace"])
        for kind in ClipEffect.v60Kinds.sorted() {
            var c = clip()
            c.effects = [ClipEffect(kind: kind)]
            let p = try project([c])
            #expect(p.containsV60Content, "\(kind)")
            #expect(ProjectFile.writtenVersion(for: p) == 60)
            #expect(try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil) == p)

            var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
            layer.effects = [ClipEffect(kind: kind)]
            var g = clip()
            g.graphics = GraphicsDocument(layers: [layer])
            #expect(try project([g]).containsV60Content, "layer \(kind)")
        }
        var old = clip()
        old.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind)]
        #expect(!(try project([old]).containsV60Content))
    }

    /// A template clip plays its content through the zones whatever its source range: source time does not say what shows.
    @Test func templateClipPlayingThroughZonesShowsNone() {
        var c = clip(markers: [Marker(time: Time(3, 1))])
        #expect(c.visibleMarkers(frameDuration: fd30).count == 1)
        c.sequence = UUID()
        c.zones = AnimationZones(introEnd: Time(1, 1), outroLength: Time(1, 1), designDuration: Time(4, 1))
        #expect(c.playsThroughZones)
        #expect(c.visibleMarkers(frameDuration: fd30).isEmpty)
    }

    /// A v59 file (no marker key) still opens and reads the same.
    @Test func v59FileStillOpens() throws {
        let p = try project([clip()])
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 59
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].markers == nil)
        #expect(back.timelines == p.timelines)
    }

    /// Only the markers inside the played source range show, at clip-local time.
    @Test func visibleMarkersAreClipLocal() {
        let inside = Marker(time: Time(3, 1), name: "in")
        let c = clip(markers: [Marker(time: Time(1, 1)), inside, Marker(time: Time(6, 1)), Marker(time: Time(2, 1), name: "head")])
        #expect(c.visibleMarkers(frameDuration: fd30).map(\.name) == ["head", "in"])
        #expect(c.visibleMarkers(frameDuration: fd30).map(\.time) == [.zero, Time(1, 1)])
        #expect(c.visibleMarkers(frameDuration: fd30)[1].id == inside.id)
    }

    @Test func visibleMarkersFollowSpeedAndDirection() {
        var c = clip(markers: [Marker(time: Time(3, 1))])
        c.speed = ClipSpeed(percent: 200)
        c.source = TimeRange(start: Time(2, 1), duration: Time(4, 1))
        #expect(c.visibleMarkers(frameDuration: fd30).map(\.time) == [Time(1, 2)])
        // A frame the 200 % clip skips sits on the frame playing across it, on the grid.
        c.markers = [Marker(time: Time(2, 1) + fd30)]
        #expect(c.visibleMarkers(frameDuration: fd30).map(\.time) == [.zero])
    }

    /// Reversed: the frame starting at source `s` is shown one frame before the clip passes `s` (same convention as
    /// `sourceTime(at:frameDuration:)`), so every visible marker lies inside the clip and on the frame showing it.
    @Test func reversedClipPutsMarkersOnTheFrameShowingThem() {
        var c = clip(markers: [Marker(time: Time(3, 1), name: "mid"), Marker(time: Time(2, 1), name: "sourceStart"),
                               Marker(time: Time(6, 1) - fd30, name: "lastSourceFrame"), Marker(time: Time(6, 1), name: "end")])
        c.reversed = true
        let v = c.visibleMarkers(frameDuration: fd30)
        #expect(v.map(\.name) == ["lastSourceFrame", "mid", "sourceStart"])
        #expect(v.map(\.time) == [.zero, Time(3, 1) - fd30, Time(4, 1) - fd30])
        for m in v {
            #expect(m.time < c.duration)
            let source = c.sourceTime(at: c.start + m.time, frameDuration: fd30)
            #expect(source == c.markers?.first { $0.id == m.id }?.time)
            #expect(c.timelineTime(forSource: source, frameDuration: fd30) == c.start + m.time)
        }
    }

    /// A speed track that plays forwards then backwards passes a source time twice: the marker shows at every visit, on the
    /// grid, by the reversed frame convention on the way back. The hull's end counts at the turning point.
    @Test func speedTrackShowsEveryVisitOnTheFrameGrid() {
        var c = clip(markers: [Marker(time: Time(5, 2), name: "twice"), Marker(time: Time(3, 1), name: "peak"),
                               Marker(time: Time(2, 1), name: "ends")])
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(1, 1), from: .normal),
                                            SpeedSegment(duration: Time(1, 1), from: .normal, reversed: true)], origin: Time(2, 1)))
        let v = c.visibleMarkers(frameDuration: fd30)
        #expect(v.map(\.name) == ["ends", "twice", "peak", "twice", "ends"])
        #expect(v.map(\.time) == [.zero, Time(1, 2), Time(1, 1), Time(3, 2) - fd30, Time(2, 1) - fd30])
        #expect(Set(v.filter { $0.name == "twice" }.map(\.id)).count == 1)
    }

    /// A ramp's inverse is solved numerically (1/2^20 s): the visible time is still a whole frame.
    @Test func rampedClipSnapsMarkersToFrames() {
        var c = clip(markers: [Marker(time: Time(23, 10)), Marker(time: Time(7, 2), name: "outPoint")])
        // 100 % -> 200 % over 1 s from source 2 s: position = 2 + t + t^2 / 2, ends at 3.5 s. Source 2.3 s is at t = 0.2649 s.
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(1, 1), from: .normal, to: ClipSpeed(percent: 200))],
                                 origin: Time(2, 1)))
        let v = c.visibleMarkers(frameDuration: fd30)
        #expect(v.map(\.time) == [fd30 * 7])       // the out point (hull end, reached only at the clip's end) is not shown
    }

    /// A clip relinked to a still loses its source offset (Premiere's huge still in point): its markers shift with it.
    @Test func relinkToAStillShiftsMarkersWithTheSource() throws {
        let ref = MediaRef(name: "a.png", path: "/new/a.png", fingerprint: MediaFingerprint(size: 0))
        var c = Clip(name: "a.png", media: ref.id, kind: .video, source: TimeRange(start: Time(3600, 1), duration: Time(5, 1)), start: .zero)
        c.markers = [Marker(time: Time(3602, 1), name: "m")]
        var p = Project(name: "t", media: [ref], timelines: [Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd30),
                                                                      tracks: [Track(kind: .video, clips: [c])])])
        p.adoptProbedInfo([ref.id: MediaInfo(duration: Time(5, 1), isStill: true)])
        let after = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(after.source.start == .zero)
        #expect(after.markers?.map(\.time) == [Time(2, 1)])
        #expect(after.visibleMarkers(frameDuration: fd30).map(\.time) == [Time(2, 1)])
    }

    /// A hold frame shows one frame: no markers.
    @Test func holdFrameShowsNone() {
        var c = clip(markers: [Marker(time: Time(3, 1))])
        c.holdFrame = Time(3, 1)
        #expect(c.visibleMarkers(frameDuration: fd30).isEmpty)
    }

    /// Markers stay on their source frame through a trim (they are source time) and both halves of a split keep them.
    @Test func trimAndSplitKeepMarkersOnTheirFrames() throws {
        var t = Track(kind: .video)
        let c = clip(markers: [Marker(time: Time(3, 1), name: "a"), Marker(time: Time(5, 1), name: "b")])
        try t.overwrite(c)
        try t.split(at: Time(2, 1))
        #expect(t.clips.count == 2)
        #expect(t.clips[0].visibleMarkers(frameDuration: fd30).map(\.name) == ["a"])
        #expect(t.clips[0].visibleMarkers(frameDuration: fd30).map(\.time) == [Time(1, 1)])
        #expect(t.clips[1].visibleMarkers(frameDuration: fd30).map(\.name) == ["b"])
        // Second half starts at timeline 2 s = source 4 s: marker b (source 5 s) is 1 s in.
        #expect(t.clips[1].visibleMarkers(frameDuration: fd30).map(\.time) == [Time(1, 1)])
    }

    @Test func noMarkersMeansNoneVisible() {
        #expect(clip().visibleMarkers(frameDuration: fd30).isEmpty)
    }
}
