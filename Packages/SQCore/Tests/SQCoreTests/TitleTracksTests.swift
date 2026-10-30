import Foundation
import Testing
@testable import SQCore

/// Add Title puts its lines and emoji on their own video tracks, stacked above everything that plays over the range.
@Suite struct TitleTracksTests {
    private let fd = Time(1, 30)
    private let range = TimeRange(start: .zero, duration: Time(3, 1))

    private func clip(_ start: Time, _ d: Time) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: d), start: start)
    }

    private func videoIDs(_ t: Timeline) -> [Track.ID] { t.tracks.filter { $0.kind == .video }.map(\.id) }

    @Test func freeTracksAboveTheTalkingHead() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 4, audio: 1))
        try t.tracks[0].overwrite(clip(.zero, Time(10, 1)))
        let ids = t.stackedTitleTracks(count: 3, over: range)
        #expect(ids == Array(videoIDs(t)[1...3]))
        #expect(t.tracks.count == 5)
    }

    @Test func missingTracksAreAddedOnTop() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 2, audio: 1))
        try t.tracks[0].overwrite(clip(.zero, Time(10, 1)))
        let ids = t.stackedTitleTracks(count: 3, over: range)
        let v = videoIDs(t)
        #expect(v.count == 4)
        #expect(ids == [v[1], v[2], v[3]])
    }

    @Test func busyAndLockedTracksAreSkipped() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 5, audio: 0))
        try t.tracks[0].overwrite(clip(.zero, Time(10, 1)))
        try t.tracks[2].overwrite(clip(Time(1, 1), Time(1, 1)))   // b-roll on V3 over the range
        t.tracks[3].isLocked = true
        let ids = t.stackedTitleTracks(count: 2, over: range)
        let v = videoIDs(t)
        // Above V3 (the highest busy track): V4 is locked, V5 is free, one new track on top.
        #expect(ids == [v[4], v[5]])
    }

    @Test func clipsOutsideTheRangeDoNotCount() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 3, audio: 0))
        try t.tracks[2].overwrite(clip(Time(20, 1), Time(1, 1)))
        let ids = t.stackedTitleTracks(count: 2, over: range)
        #expect(ids == Array(videoIDs(t)[0...1]))
    }

    @Test func zeroCountChangesNothing() {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 1, audio: 0))
        #expect(t.stackedTitleTracks(count: 0, over: range).isEmpty)
        #expect(t.tracks.count == 1)
    }
}
