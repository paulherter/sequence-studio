import Foundation
import Testing
@testable import SSCore

@Suite struct ReplaceClipTests {
    private func timeline() throws -> (Timeline, Clip) {
        var track = Track(kind: .video)
        let c = Clip(name: "c", media: UUID(), kind: .video,
                     source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(1, 1))
        try track.overwrite(c)
        return (Timeline(name: "T", frameDuration: Time(1, 30), tracks: [track]), c)
    }

    @Test func replacesPropertiesOfTheSameClip() throws {
        var (t, c) = try timeline()
        c.name = "renamed"
        try t.replaceClip(c)
        #expect(t.tracks[0].clips[0].name == "renamed")
    }

    @Test func unknownClipThrows() throws {
        var (t, c) = try timeline()
        c.id = UUID()
        #expect(throws: EditError.clipNotFound) { try t.replaceClip(c) }
    }

    @Test func refusesTimingChange() throws {
        var (t, c) = try timeline()
        c.start = Time(9, 1)
        #expect(throws: EditError.collision) { try t.replaceClip(c) }
    }

    @Test func lockedTrackThrows() throws {
        var (t, c) = try timeline()
        t.tracks[0].isLocked = true
        c.name = "x"
        #expect(throws: EditError.trackLocked) { try t.replaceClip(c) }
    }
}
