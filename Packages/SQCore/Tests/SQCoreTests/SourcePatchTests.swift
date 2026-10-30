import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// MON-30 / TL-44: source patching decides where Insert / Overwrite put the source's video and audio; track targeting
/// does not (it stays for paste, match frame and the playhead edits).
@Suite struct SourcePatchTests {
    private func timeline() -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks()) }
    private func ids(_ t: Timeline, _ k: TrackKind) -> [Track.ID] { t.tracks.filter { $0.kind == k }.map(\.id) }

    @Test func defaultPatchIsV1AndA1() {
        var t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        let p = SourcePatch()
        #expect(t.patchedTrack(p, kind: .video) == v[0])
        #expect(t.patchedTrack(p, kind: .audio) == a[0])
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: true) == [v[0], a[0]])
    }

    @Test func targetingDoesNotMoveThePatch() {
        var t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        for i in t.tracks.indices { t.tracks[i].isTargeted = false }
        t.tracks[t.tracks.firstIndex { $0.id == v[2] }!].isTargeted = true
        #expect(t.sourcePatchTargets(SourcePatch(), hasVideo: true, hasAudio: true) == [v[0], a[0]])
    }

    @Test func patchingVideoToV2KeepsAudioOnA1() {
        var t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        var p = SourcePatch()
        p.patch(.video, to: v[1], in: t)
        #expect(t.patchedTrack(p, kind: .video) == v[1])
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: true) == [v[1], a[0]])
    }

    @Test func bRollVideoWithoutItsAudio() {
        var t = timeline()
        let v = ids(t, .video)
        var p = SourcePatch()
        p.patch(.video, to: v[1], in: t)
        p.toggleConnection(.audio)
        #expect(!p.audio.isConnected)
        #expect(t.patchedTrack(p, kind: .audio) == nil)
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: true) == [v[1]])
        // Reconnecting goes back to the same track.
        p.toggleConnection(.audio)
        #expect(t.patchedTrack(p, kind: .audio) == ids(t, .audio)[0])
    }

    @Test func patchingToATrackOfTheOtherKindIsIgnored() {
        let t = timeline()
        var p = SourcePatch()
        p.patch(.video, to: ids(t, .audio)[1], in: t)
        #expect(p == SourcePatch())
    }

    @Test func draggingADisconnectedChipConnectsIt() {
        let t = timeline()
        var p = SourcePatch()
        p.toggleConnection(.video)
        p.patch(.video, to: ids(t, .video)[2], in: t)
        #expect(t.patchedTrack(p, kind: .video) == ids(t, .video)[2])
    }

    @Test func aDeletedPatchedTrackFallsBackToTheFirstOfItsKind() {
        var t = timeline()
        let v = ids(t, .video)
        var p = SourcePatch()
        p.patch(.video, to: v[2], in: t)
        t.tracks.removeAll { $0.id == v[2] }
        #expect(t.patchedTrack(p, kind: .video) == v[0])
    }

    @Test func streamsAndMediaLimitThePlacement() {
        var t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        let p = SourcePatch()
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: true, streams: .videoOnly) == [v[0]])
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: true, streams: .audioOnly) == [a[0]])
        #expect(t.sourcePatchTargets(p, hasVideo: false, hasAudio: true) == [a[0]])
        #expect(t.sourcePatchTargets(p, hasVideo: true, hasAudio: false) == [v[0]])
        var off = p
        off.toggleConnection(.video)
        #expect(t.sourcePatchTargets(off, hasVideo: true, hasAudio: false) == nil)
        #expect(t.sourcePatchTargets(off, hasVideo: true, hasAudio: true, streams: .videoOnly) == nil)
    }

    @Test func missingAudioTrackIsCreatedAsA1() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let got = t.sourcePatchTargets(SourcePatch(), hasVideo: true, hasAudio: true)
        #expect(got?.count == 2)
        #expect(t.tracks.filter { $0.kind == .audio }.count == 1)
        #expect(got?.last == t.tracks.first { $0.kind == .audio }?.id)
    }

    @Test func noVideoTrackPlacesOnlyTheAudio() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .audio)])
        #expect(t.sourcePatchTargets(SourcePatch(), hasVideo: true, hasAudio: true) == [t.tracks[0].id])
        #expect(t.sourcePatchTargets(SourcePatch(), hasVideo: true, hasAudio: false) == nil)
    }

    @Test func overwriteLandsOnThePatchedTracks() throws {
        var t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        var p = SourcePatch()
        p.patch(.video, to: v[1], in: t)
        p.patch(.audio, to: a[2], in: t)
        let found = t.sourcePatchTargets(p, hasVideo: true, hasAudio: true)
        let targets = try #require(found)
        try t.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), targets: targets, at: s(1), mode: .overwrite)
        #expect(t.track(v[1])?.clips.count == 1)
        #expect(t.track(a[2])?.clips.count == 1)
        #expect(t.track(v[0])?.clips.isEmpty == true)
        #expect(t.track(a[0])?.clips.isEmpty == true)
        #expect(t.track(v[1])?.clips.first?.link != nil)
    }

    /// Random patches and streams over the fuzz timelines: Insert / Overwrite either apply or throw an `EditError`, and the
    /// timeline stays valid.
    @Test(arguments: [UInt64(1), 2, 3, 4])
    func randomPatchedEditsKeepTheTimelineValid(seed: UInt64) {
        var rng = EditCoreCrashFuzzTests.LCG(s: seed &* 31)
        let fd = EditCoreCrashFuzzTests.fd
        var t = EditCoreCrashFuzzTests.make(seed: seed)
        for step in 0..<300 {
            var p = SourcePatch()
            for kind in [TrackKind.video, .audio] {
                let pool = t.tracks.filter { $0.kind == kind }
                if !pool.isEmpty, rng.chance(2) { p.patch(kind, to: pool[rng.int(pool.count)].id, in: t) }
                if rng.chance(4) { p.toggleConnection(kind) }
            }
            if rng.chance(10), t.tracks.count > 1 { t.tracks.remove(at: rng.int(t.tracks.count)) }
            let streams: SourceStreams = [.both, .videoOnly, .audioOnly][rng.int(3)]
            let at = fd * Int64(rng.int(400)), len = fd * Int64(1 + rng.int(60))
            let mode: ThreePointMode = rng.chance(2) ? .insert : .overwrite
            var work = t
            do {
                guard let targets = work.sourcePatchTargets(p, hasVideo: !rng.chance(5), hasAudio: !rng.chance(5), streams: streams)
                else { continue }
                try work.threePointEdit(source: TimeRange(start: .zero, duration: len), media: UUID(), mediaDuration: len,
                                        targets: targets, at: at, mode: mode)
                t = work
            } catch is EditError {
            } catch {
                Issue.record("seed \(seed) step \(step): non-EditError \(error)")
            }
            let problems = EditCoreCrashFuzzTests.problems(t, frameExact: false)
            #expect(problems.isEmpty, "seed \(seed) step \(step): \(problems)")
            if !problems.isEmpty { return }
            if t.tracks.flatMap(\.clips).count > 120 { t = EditCoreCrashFuzzTests.make(seed: seed &+ UInt64(step)) }
        }
    }

    @Test func soloKeepsOnlyOneStreamAndTogglesBack() {
        var p = SourcePatch()
        p.solo(.video)
        #expect(p.video.isConnected && !p.audio.isConnected)
        p.solo(.video)
        #expect(p.video.isConnected && p.audio.isConnected)
        p.solo(.audio)
        #expect(!p.video.isConnected && p.audio.isConnected)
    }

    @Test func patchBothKeepsTheDistanceAndClamps() {
        let t = timeline()
        let v = ids(t, .video), a = ids(t, .audio)
        var p = SourcePatch()
        p.patchBoth(.video, to: v[1], in: t)
        #expect(t.patchedTrack(p, kind: .video) == v[1])
        #expect(t.patchedTrack(p, kind: .audio) == a[1])
        p.patchBoth(.video, to: v[2], in: t)
        #expect(t.patchedTrack(p, kind: .audio) == a[2 < a.count ? 2 : a.count - 1])
        p.patchBoth(.audio, to: a[0], in: t)
        #expect(t.patchedTrack(p, kind: .audio) == a[0])
        #expect(t.patchedTrack(p, kind: .video) == v[0])
    }
}
