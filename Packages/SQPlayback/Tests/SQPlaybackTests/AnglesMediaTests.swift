import Foundation
import Metal
import Testing
import SQCore
@testable import SQPlayback

/// F7.16: the engine only prepares the media of the angles that are really shown.
@Suite struct AnglesMediaTests {
    private let format = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))

    private func camera(_ media: UUID) -> [Clip] {
        [Clip(name: "cam", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
              mediaDuration: Time(10, 1))]
    }

    @Test func onlyTheShownAnglesAreListed() throws {
        let m = [UUID(), UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        let clips = try #require(p.sequenceClips(of: seq, at: .zero))
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        func ids() throws -> Set<UUID> {
            let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
            return Set(RenderLoop.mediaIDs(try #require(p.timeline(main)), sequences: all))
        }
        #expect(try ids() == [m[0]])
        // Cut at 4 s and show angle 3 from there: two angles are in use, the second camera still is not.
        try p.edit(main) { _ = try $0.switchAngle(2, at: Time(4, 1), clip: clips[0].id) }
        #expect(try ids() == [m[0], m[2]])
    }

    /// The angles a piece does not show are its standby media: opened in the background (never decoded), so the first
    /// live switch to one finds its file open instead of holding the picture while it opens.
    @Test func theOtherAnglesAreStandby() throws {
        let m = [UUID(), UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        let clips = try #require(p.sequenceClips(of: seq, at: .zero))
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        func standby() throws -> [UUID] {
            let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
            return RenderLoop.standbyMediaIDs(try #require(p.timeline(main)), sequences: all)
        }
        #expect(try Set(standby()) == [m[1], m[2]])
        try p.edit(main) { _ = try $0.switchAngle(2, at: Time(4, 1), clip: clips[0].id) }
        #expect(try standby() == [m[1]])                          // shown media are never standby
    }

    @Test func aPlainNestedSequenceHasNoStandby() throws {
        let m = [UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        var clips = try #require(p.sequenceClips(of: seq, at: .zero))
        clips[0].angle = nil
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
        #expect(RenderLoop.standbyMediaIDs(try #require(p.timeline(main)), sequences: all).isEmpty)
    }

    /// The engine resolves the standby angles after the shown ones; before, a hidden angle's file was first opened by
    /// the switch itself (held picture, then the placeholder when the open outlasted the hold).
    @Test func setTimelineOpensTheStandbyAngles() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let m = [UUID(), UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        let clips = try #require(p.sequenceClips(of: seq, at: .zero))
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        let loop = try RenderLoop(device: device, resolver: StaticMediaResolver(demuxers: [:]), clock: ManualClock(), cache: FrameCache())
        let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
        loop.setTimeline(try #require(p.timeline(main)), sequences: all)
        await loop.waitForDecodes()
        for id in m {
            if case .unresolved = loop.media.known(id) { Issue.record("angle media \(id) was never resolved") }
        }
    }

    @Test func colorWarmUpOnlyWalksTheShownAngles() throws {
        let m = [UUID(), UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        let clips = try #require(p.sequenceClips(of: seq, at: .zero))
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        func media() throws -> [UUID] {
            let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
            return RenderLoop.colorLayers(try #require(p.timeline(main)), sequences: all).map(\.media)
        }
        #expect(try media() == [m[0]])
        try p.edit(main) { _ = try $0.switchAngle(2, at: Time(4, 1), clip: clips[0].id) }
        #expect(try Set(media()) == [m[0], m[2]])                // the same sequence, walked once per shown angle
        #expect(try media().count == 2)
    }

    @Test func aPlainNestedSequenceStillListsEveryTrack() throws {
        let m = [UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: m.map { AngleInput(name: "Cam", clips: camera($0), offset: .zero) })
        var clips = try #require(p.sequenceClips(of: seq, at: .zero))
        clips[0].angle = nil
        try p.edit(main) { try $0.tracks[0].overwrite(clips[0]) }
        let all = Dictionary(uniqueKeysWithValues: p.timelines.map { ($0.id, $0) })
        #expect(Set(RenderLoop.mediaIDs(try #require(p.timeline(main)), sequences: all)) == Set(m))
    }
}
