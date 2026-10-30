import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let format = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))

/// One camera: a video clip and its linked sound over `dur` seconds of media `media`.
private func camera(_ media: UUID, dur: Int64, src: Int64 = 0, audio: Bool = true) -> [Clip] {
    let link: UUID? = audio ? UUID() : nil
    func make(_ k: TrackKind) -> Clip {
        Clip(name: "cam", media: media, kind: k, source: TimeRange(start: s(src), duration: s(dur)), start: .zero, link: link,
             mediaDuration: s(src + dur))
    }
    return audio ? [make(.video), make(.audio)] : [make(.video)]
}

/// Project with a three-angle Angles sequence placed at 0 of "Main" (V1 + A1). Angle media: m[0], m[1], m[2].
private func fixture(follows: Bool = false, audioAngle: Int = 0) throws
    -> (p: Project, main: Timeline.ID, seq: Timeline.ID, media: [UUID], video: Clip.ID, audio: Clip.ID) {
    let m = [UUID(), UUID(), UUID()]
    var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format,
                                                    tracks: [Track(kind: .video), Track(kind: .audio)])])
    let main = p.timelines[0].id
    let seq = try p.makeAnglesSequence(format: format, angles: m.enumerated().map {
        AngleInput(name: "Cam \($0.offset + 1)", clips: camera($0.element, dur: 10))
    }, audioAngle: audioAngle, audioFollowsVideo: follows)
    let clips = try #require(p.sequenceClips(of: seq, at: .zero))
    try p.edit(main) { tl in
        try tl.tracks[0].overwrite(clips[0])
        try tl.tracks[1].overwrite(clips[1])
    }
    return (p, main, seq, m, clips[0].id, clips[1].id)
}

private func pictureMedia(_ p: Project, _ tl: Timeline.ID, at t: Time) -> [UUID] { p.videoLayers(at: t, in: tl).map(\.media) }
private func soundMedia(_ p: Project, _ tl: Timeline.ID, _ from: Int64, _ to: Int64) -> [UUID] {
    p.audioSegments(in: TimeRange(start: s(from), end: s(to)), of: tl).sorted { $0.timeline.start < $1.timeline.start }.map(\.media)
}

@Suite struct AnglesTests {
    // MARK: Sequence

    @Test func sequenceHasOneVideoAndOneAudioTrackPerAngle() throws {
        let f = try fixture()
        let seq = try #require(f.p.timeline(f.seq))
        #expect(seq.name == "Angles 01")
        #expect(seq.tracks.map(\.kind) == [.video, .video, .video, .audio, .audio, .audio])
        #expect(seq.angles == AnglesSetup(audioAngle: 0, audioFollowsVideo: false))
        #expect(seq.angleCount == 3)
        #expect(seq.angleNames == ["Cam 1", "Cam 2", "Cam 3"])
        #expect(f.p.rootBin.parent(of: .sequence(f.seq)) == f.p.rootBin.id)
    }

    @Test func offsetsShiftTheAnglesSoTheEarliestStartsAtZero() throws {
        let a = UUID(), b = UUID()
        var p = Project(name: "P", timelines: [])
        let id = try p.makeAnglesSequence(name: "Talk", format: format, angles: [
            AngleInput(name: "A", clips: camera(a, dur: 10), offset: s(5)),
            AngleInput(name: "B", clips: camera(b, dur: 10, audio: false), offset: Time(-51, 50)),    // off the frame grid
        ], audioAngle: 1)
        let seq = try #require(p.timeline(id))
        #expect(seq.name == "Talk")
        #expect(seq.tracks[1].clips.map(\.start) == [.zero])
        // 5 s + 1.02 s = 6.02 s, on the 25 fps grid: frame 150.5 snaps to a whole frame.
        let start = try #require(seq.tracks[0].clips.first?.start)
        #expect(start == (s(5) + Time(51, 50)).snapped(to: format.frameDuration))
        #expect(seq.tracks[2].clips.map(\.start) == [start])            // the linked sound moved along
        #expect(seq.tracks[3].clips.isEmpty)                            // angle B has no sound, its track stays (index = angle)
        #expect(seq.angles?.audioAngle == 0)                            // angle 2 has no sound: first angle with sound
    }

    @Test func anEmptyListIsRefused() {
        var p = Project(name: "P", timelines: [])
        #expect(throws: EditError.emptyClip) { try p.makeAnglesSequence(format: format, angles: []) }
    }

    // MARK: Evaluation

    @Test func onlyTheActiveAngleIsRequested() throws {
        var f = try fixture()
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[0]])
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0]])
        try f.p.edit(f.main) { try $0.setAngle(2, on: f.video) }
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[2]])
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0]])       // sound stays on its angle
    }

    @Test func aPlainNestedClipStillPlaysEveryTrack() throws {
        var f = try fixture()
        try f.p.edit(f.main) { tl in
            for i in tl.tracks.indices { for var c in tl.tracks[i].clips { c.angle = nil; tl.tracks[i].replace(c) } }
        }
        #expect(Set(pictureMedia(f.p, f.main, at: s(1))) == Set(f.media))
        #expect(Set(soundMedia(f.p, f.main, 0, 10)) == Set(f.media))
    }

    @Test func anIndexPastTheLastAnglePlaysTheLast() throws {
        var f = try fixture()
        try f.p.edit(f.main) { try $0.setAngle(8, on: f.video) }
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[2]])
    }

    @Test func chosenAudioAngleIsUsedForANewClip() throws {
        let f = try fixture(audioAngle: 1)
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[1]])
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[0]])
    }

    // MARK: Switching

    @Test func bladeKeepsTheAngleAndAPieceTakesAnother() throws {
        var f = try fixture()
        try f.p.edit(f.main) { tl in
            try tl.tracks[0].split(at: s(4))
            try tl.setAngle(1, on: tl.tracks[0].clips[1].id)
        }
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[0]])
        #expect(pictureMedia(f.p, f.main, at: s(5)) == [f.media[1]])
        // The cut is frame accurate: the last frame before it is still angle 1, the piece after reads on in the same time.
        let before = try #require(f.p.videoLayers(at: s(4) - format.frameDuration, in: f.main).first)
        let after = try #require(f.p.videoLayers(at: s(4), in: f.main).first)
        #expect(before.media == f.media[0] && after.media == f.media[1])
        #expect(after.sourceTime == s(4))
    }

    @Test func switchAtThePlayheadCutsPictureAndLeavesFixedSoundWhole() throws {
        var f = try fixture()
        var made: Clip.ID?
        try f.p.edit(f.main) { made = try $0.switchAngle(1, at: s(3), clip: f.video) }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(3)])
        #expect(tl.tracks[0].clips.map { $0.angle?.index } == [0, 1])
        #expect(tl.tracks[0].clips[1].id == made)
        // The linked sound is cut with the picture (a normal blade), but both halves keep the chosen audio angle.
        #expect(tl.tracks[1].clips.map { $0.angle?.index } == [0, 0])
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0], f.media[0]])
        #expect(tl.tracks[0].clips[1].link == tl.tracks[1].clips[1].link)
        #expect(tl.tracks[0].clips[0].link == tl.tracks[1].clips[0].link)
        #expect(tl.tracks[0].clips[0].link != tl.tracks[0].clips[1].link)
    }

    @Test func audioFollowsVideoSwitchesTheSoundToo() throws {
        var f = try fixture(follows: true)
        try f.p.edit(f.main) { try $0.switchAngle(2, at: s(3), clip: f.video) }
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0], f.media[2]])
        // Turning it off keeps the sound where it is; the next picture switch leaves it alone.
        try f.p.edit(f.main) { tl in
            let right = tl.tracks[0].clips[1].id
            let changed = try tl.setAudioFollowsVideo(false, on: right)
            #expect(changed)
            try tl.setAngle(1, on: right)
        }
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0], f.media[2]])
        #expect(pictureMedia(f.p, f.main, at: s(5)) == [f.media[1]])
        // Turning it on again takes the picture's angle at once.
        try f.p.edit(f.main) { tl in try tl.setAudioFollowsVideo(true, on: tl.tracks[0].clips[1].id) }
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0], f.media[1]])
    }

    @Test func anAudioPieceTakesItsOwnAngle() throws {
        var f = try fixture()
        try f.p.edit(f.main) { try $0.setAngle(1, on: f.audio) }
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[1]])
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[0]])
    }

    /// A fourth camera without sound: a sound piece switched to it keeps its previous sound (DECISIONS), the picture switches.
    @Test func aSoundPieceKeepsItsSoundOnAnAngleWithoutSound() throws {
        let m = [UUID(), UUID(), UUID()]
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: format, tracks: [Track(kind: .video), Track(kind: .audio)])])
        let main = p.timelines[0].id
        let seq = try p.makeAnglesSequence(format: format, angles: [
            AngleInput(name: "A", clips: camera(m[0], dur: 10)), AngleInput(name: "B", clips: camera(m[1], dur: 10)),
            AngleInput(name: "C", clips: camera(m[2], dur: 10, audio: false))], audioAngle: 0, audioFollowsVideo: true)
        let inner = try #require(p.timeline(seq))
        #expect(inner.silentAngles == [2])
        let clips = try #require(p.sequenceClips(of: seq, at: .zero))
        try p.edit(main) { tl in try tl.tracks[0].overwrite(clips[0]); try tl.tracks[1].overwrite(clips[1]) }
        try p.edit(main) { tl in _ = try tl.switchAngle(1, at: s(2), clip: clips[0].id, silent: inner.silentAngles) }
        try p.edit(main) { tl in _ = try tl.switchAngle(2, at: s(5), clip: tl.tracks[0].clips[1].id, silent: inner.silentAngles) }
        let tl = try #require(p.timeline(main))
        #expect(tl.tracks[0].clips.map { $0.angle?.index } == [0, 1, 2])
        #expect(tl.tracks[1].clips.map { $0.angle?.index } == [0, 1, 1])
        #expect(soundMedia(p, main, 0, 10) == [m[0], m[1], m[1]])
        // A sound piece asked directly changes nothing.
        var t2 = tl
        let sound = t2.tracks[1].clips[2].id
        #expect(try t2.setAngle(2, on: sound, silent: inner.silentAngles) == false)
        // Without the set the old behavior stays (silence).
        #expect(try t2.setAngle(2, on: sound))
    }

    @Test func aNewAnglesClipStartsOnTheChosenAudioAngle() throws {
        let f = try fixture(follows: false, audioAngle: 2)
        let clips = try #require(f.p.sequenceClips(of: f.seq, at: s(4)))
        #expect(clips.map { $0.angle } == [AngleChoice(index: 0), AngleChoice(index: 2)])
        let follow = try fixture(follows: true, audioAngle: 2)
        let c2 = try #require(follow.p.sequenceClips(of: follow.seq, at: .zero))
        #expect(c2[1].angle == AngleChoice(index: 0, followsVideo: true))
    }

    @Test func switchingToTheSameAngleDoesNothing() throws {
        var f = try fixture()
        let before = f.p
        try f.p.edit(f.main) { tl in
            let made = try tl.switchAngle(0, at: s(3), clip: f.video)
            let changed = try tl.setAngle(0, on: f.video)
            #expect(made == nil && !changed)
        }
        #expect(f.p.timeline(f.main) == before.timeline(f.main))
    }

    @Test func switchAtThePieceStartNeedsNoCut() throws {
        var f = try fixture()
        var made: Clip.ID?
        try f.p.edit(f.main) { made = try $0.switchAngle(1, at: .zero, clip: f.video) }
        #expect(made == f.video)
        #expect(f.p.timeline(f.main)?.tracks[0].clips.count == 1)
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[1]])
    }

    @Test func lockedTrackRefusesTheSwitch() throws {
        var f = try fixture()
        #expect(throws: EditError.trackLocked) {
            try f.p.edit(f.main) { tl in
                tl.tracks[0].isLocked = true
                try tl.switchAngle(1, at: s(3), clip: f.video)
            }
        }
        #expect(f.p.timeline(f.main)?.tracks[0].clips.count == 1)
    }

    /// Three live switches at 3 s and 6 s: picture parts 0-3, 3-6, 6-10, each with its own linked sound part.
    private func threeParts() throws -> (p: Project, main: Timeline.ID, media: [UUID]) {
        var f = try fixture()
        try f.p.edit(f.main) { tl in
            let second = try #require(try tl.switchAngle(1, at: s(3), clip: f.video))
            _ = try tl.switchAngle(2, at: s(6), clip: second)
        }
        return (f.p, f.main, f.media)
    }

    @Test func rippleDeleteOfAMiddlePartKeepsPictureAndSoundInSync() throws {
        var f = try threeParts()
        try f.p.edit(f.main) { tl in try tl.rippleDelete([tl.tracks[0].clips[1].id]) }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(3)])
        #expect(tl.tracks[1].clips.map(\.start) == [s(0), s(3)])
        #expect(tl.tracks[0].clips.map(\.source.start) == tl.tracks[1].clips.map(\.source.start))
        #expect(tl.tracks[1].clips.map(\.source.start) == [s(0), s(6)])
    }

    @Test func rippleTrimOfTheFirstPartKeepsPictureAndSoundInSync() throws {
        var f = try threeParts()
        try f.p.edit(f.main) { tl in try tl.rippleTrim(tl.tracks[0].clips[0].id, edge: .tail, by: s(-1)) }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(2), s(5)])
        #expect(tl.tracks[1].clips.map(\.start) == [s(0), s(2), s(5)])
        #expect(tl.tracks[0].clips.map(\.source) == tl.tracks[1].clips.map(\.source))
        #expect(tl.tracks[1].clips.last?.timeline.end == s(9))
    }

    @Test func deletingTheFirstPartRemovesOnlyItsOwnSound() throws {
        var f = try threeParts()
        try f.p.edit(f.main) { tl in try tl.lift([tl.tracks[0].clips[0].id]) }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.tracks[0].clips.map(\.start) == [s(3), s(6)])
        #expect(tl.tracks[1].clips.map(\.start) == [s(3), s(6)])
    }

    @Test func liveSwitchLeavesAFixedSoundWholeEvenOnALockedTrack() throws {
        var f = try fixture()                                  // the sound keeps its angle
        try f.p.edit(f.main) { tl in
            tl.tracks[1].isLocked = true
            let right = try tl.switchAngle(1, at: s(3), clip: f.video)
            #expect(right != nil)
        }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.tracks[0].clips.map { $0.angle?.index } == [0, 1])
        #expect(tl.tracks[1].clips.map(\.id) == [f.audio])      // not cut
        #expect(tl.tracks[1].clips[0].angle?.index == 0)
        #expect(soundMedia(f.p, f.main, 0, 10) == [f.media[0]])
    }

    @Test func liveSwitchIsRefusedWhenAFollowingSoundIsLocked() throws {
        var f = try fixture(follows: true)
        #expect(throws: EditError.trackLocked) {
            try f.p.edit(f.main) { tl in
                tl.tracks[1].isLocked = true
                try tl.switchAngle(1, at: s(3), clip: f.video)
            }
        }
        #expect(f.p.timeline(f.main)?.tracks[0].clips.count == 1)
    }

    // MARK: Sync

    @Test func anOriginPlacesTheFilesTimeZeroAndNoOriginPlacesTheInPointAtZero() throws {
        // No origin at all (In Points): every angle starts together whatever its In point.
        #expect(AnglesOffsets.starts([(nil, s(10)), (nil, .zero)]) == [.zero, .zero])
        // Origins: file time 0 is placed, so the angle starts at origin + In.
        #expect(AnglesOffsets.starts([(s(100), s(10)), (s(103), .zero)]) == [s(110), s(103)])
        // An angle nothing places starts with the earliest placed one: at 0 of the Angles sequence.
        #expect(AnglesOffsets.starts([(s(100), s(10)), (nil, s(4)), (s(103), .zero)]) == [s(110), s(103), s(103)])

        let a = UUID(), b = UUID()
        var p = Project(name: "P", timelines: [])
        let starts = AnglesOffsets.starts([(nil, s(10)), (nil, .zero)])
        let id = try p.makeAnglesSequence(format: format, angles: [
            AngleInput(name: "A", clips: camera(a, dur: 5, src: 10), offset: starts[0]),
            AngleInput(name: "B", clips: camera(b, dur: 5), offset: starts[1]),
        ])
        let seq = try #require(p.timeline(id))
        #expect(seq.tracks.filter { $0.kind == .video }.map { $0.clips.first?.start } == [.zero, .zero])
        #expect(seq.tracks[0].clips.first?.source.start == s(10))
    }

    @Test func anOrdinaryClipIsNoAnglesClip() throws {
        let c = camera(UUID(), dur: 5, audio: false)[0]
        var tl = Timeline(name: "T", format: format, tracks: [Track(kind: .video, clips: [c])])
        #expect(throws: EditError.clipNotFound) { try tl.setAngle(1, on: c.id) }
        #expect(tl.anglesClip(at: s(1)) == nil)
    }

    @Test func pieceUnderThePlayhead() throws {
        var f = try fixture()
        try f.p.edit(f.main) { try $0.switchAngle(1, at: s(3), clip: f.video) }
        let tl = try #require(f.p.timeline(f.main))
        #expect(tl.anglesClip(at: s(2))?.id == f.video)
        #expect(tl.anglesClip(at: s(3))?.id == tl.tracks[0].clips[1].id)
        #expect(tl.anglesClip(at: s(10)) == nil)
    }

    // MARK: Through edits

    @Test func sameAnglePiecesJoinAndDifferentAnglesDoNot() throws {
        var f = try fixture()
        try f.p.edit(f.main) { try $0.switchAngle(1, at: s(3), clip: f.video) }
        var tl = try #require(f.p.timeline(f.main))
        let (l, r) = (tl.tracks[0].clips[0], tl.tracks[0].clips[1])
        #expect(l.joined(with: r) == nil)                                   // two angles: a real cut
        #expect(!Timeline.isThroughEdit(l, r))
        #expect(tl.tracks[1].clips[0].joined(with: tl.tracks[1].clips[1]) != nil)   // the fixed sound is a through edit
        try tl.setAngle(0, on: r.id)                                        // back to the same angle
        #expect(tl.tracks[0].clips[0].joined(with: tl.tracks[0].clips[1]) != nil)
    }

    // MARK: Flatten

    @Test func flattenReplacesTheAnglesPieceByTheShownAngle() throws {
        var f = try fixture()
        try f.p.edit(f.main) { try $0.setAngle(1, on: f.video) }        // picture Cam 2, sound stays on Cam 1
        let placed = try f.p.flattenAngles(clip: f.video, in: f.main)
        let tl = try #require(f.p.timeline(f.main))
        #expect(placed.count == 2)
        #expect(tl.tracks.flatMap(\.clips).allSatisfy { !$0.isAnglesClip && $0.sequence == nil })
        #expect(pictureMedia(f.p, f.main, at: s(1)) == [f.media[1]])
        #expect(soundMedia(f.p, f.main, 0, 5) == [f.media[0]])
        #expect(f.p.timeline(f.seq) != nil)
    }

    @Test func flattenRefusesAnOrdinaryClip() throws {
        var f = try fixture()
        let media = f.media[0]
        try f.p.edit(f.main) { try $0.tracks[0].overwrite(Clip(name: "x", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(20), mediaDuration: s(2))) }
        let plain = try #require(f.p.timeline(f.main)?.tracks[0].clips.last)
        #expect(throws: EditError.self) { try f.p.flattenAngles(clip: plain.id, in: f.main) }
    }

    // MARK: From timeline clips

    @Test func timelineClipsBecomeOneAnglesClip() throws {
        let m = [UUID(), UUID()]
        var a = camera(m[0], dur: 10), b = camera(m[1], dur: 8)
        for i in a.indices { a[i].start = s(2) }
        for i in b.indices { b[i].start = s(4) }
        let other = Clip(name: "x", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(30))
        let tl = Timeline(name: "Main", format: format, tracks: [
            Track(kind: .video, clips: [a[0], other]), Track(kind: .video, clips: [b[0]]),
            Track(kind: .audio, clips: [a[1]]), Track(kind: .audio, clips: [b[1]]),
        ])
        var p = Project(name: "P", timelines: [tl])
        let id = try p.makeAnglesClip(from: [b[0].id, a[0].id], in: tl.id)
        let seq = try #require(p.timeline(id))
        // Timeline positions are the sync: A at 0, B two seconds later; angles ordered by track from the bottom.
        #expect(seq.tracks.map(\.kind) == [.video, .video, .audio, .audio])
        #expect(seq.tracks[0].clips.map(\.media) == [m[0]] && seq.tracks[0].clips[0].start == .zero)
        #expect(seq.tracks[1].clips.map(\.media) == [m[1]] && seq.tracks[1].clips[0].start == s(2))
        let out = try #require(p.timeline(tl.id))
        #expect(out.tracks[0].clips.count == 2 && out.tracks[1].clips.isEmpty && out.tracks[3].clips.isEmpty)
        let v = out.tracks[0].clips[0], au = try #require(out.tracks[2].clips.first)
        #expect(v.sequence == id && v.angle == AngleChoice(index: 0) && v.timeline == TimeRange(start: s(2), end: s(12)))
        #expect(au.angle == AngleChoice(index: 0) && au.link == v.link && v.link != nil)
        #expect(pictureMedia(p, tl.id, at: s(5)) == [m[0]])
    }

    @Test func timelineClipsWithOffsetsAndACollision() throws {
        let m = [UUID(), UUID()]
        let a = camera(m[0], dur: 10, audio: false)[0]
        var b = camera(m[1], dur: 10, audio: false)[0]
        b.start = s(20)
        var blocker = camera(UUID(), dur: 2, audio: false)[0]
        blocker.start = s(11)
        let tl = Timeline(name: "Main", format: format, tracks: [Track(kind: .video, clips: [a, blocker, b])])
        var p = Project(name: "P", timelines: [tl])
        // Synced, B starts 3 s after A: the Angles clip is 13 s long and would run into the clip at 11 s.
        #expect(throws: EditError.collision) {
            try p.makeAnglesClip(from: [a.id, b.id], in: tl.id, offsets: [a.id: .zero, b.id: s(3)])
        }
        #expect(p.timelines.count == 1 && p.timelines[0] == tl)
        let id = try p.makeAnglesClip(from: [a.id, b.id], in: tl.id, offsets: [a.id: .zero, b.id: s(1)])
        #expect(p.timeline(id)?.duration == s(11))
        #expect(throws: EditError.emptyClip) { try p.makeAnglesClip(from: [blocker.id], in: tl.id) }
    }

    // MARK: Project file

    @Test func anAnglesClipWritesV71AndRoundTrips() throws {
        var f = try fixture(follows: true)
        try f.p.edit(f.main) { try $0.switchAngle(2, at: s(3), clip: f.video) }
        #expect(f.p.containsV71Content)
        #expect(ProjectFile.writtenVersion(for: f.p) == 71)
        let data = try ProjectFile.encode(f.p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 71)
        #expect(try ProjectFile.decode(data, migrations: nil) == f.p)
    }

    @Test func projectsWithoutAnglesKeepTheirVersionAndBytes() throws {
        let c = camera(UUID(), dur: 5)
        let tl = Timeline(name: "Main", format: format, tracks: [Track(kind: .video, clips: [c[0]]), Track(kind: .audio, clips: [c[1]])])
        var p = Project(name: "P", timelines: [tl])
        try p.nest(clips: [c[0].id], in: tl.id)
        #expect(!p.containsV71Content)
        #expect(ProjectFile.writtenVersion(for: p) < 71)
        let text = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!text.contains("\"angle\"") && !text.contains("\"angles\""))
    }

    @Test func fixedSoundStoresNoFollowKey() throws {
        let f = try fixture()
        let text = String(decoding: try ProjectFile.encode(f.p), as: UTF8.self)
        #expect(!text.contains("followsVideo"))
        #expect(ProjectFile.v71Version == 71 && ProjectFile.currentVersion >= 71)
    }
}

@Suite struct AnglesProxyTests {
    @Test func pieceDrawsAsMediaOfTheActiveAngle() throws {
        let f = try fixture()
        let inner = try #require(f.p.timeline(f.seq))
        var piece = try #require(f.p.timeline(f.main)?.tracks[0].clips.first)
        piece.angle = AngleChoice(index: 1)
        piece.source = TimeRange(start: s(2), duration: s(5))
        let proxy = try #require(piece.angleProxy(inner: inner))
        #expect(proxy.media == f.media[1])
        #expect(proxy.sequence == nil)
        #expect(proxy.id == piece.id)
        #expect(proxy.source.start == s(2) && proxy.source.duration == s(5))
        var sound = try #require(f.p.timeline(f.main)?.tracks[1].clips.first)
        sound.angle = AngleChoice(index: 2)
        #expect(try #require(sound.angleProxy(inner: inner)).media == f.media[2])
    }

    @Test func angleFramesListEveryAngleAtATime() throws {
        let f = try fixture()
        let inner = try #require(f.p.timeline(f.seq))
        let frames = inner.angleFrames(at: s(3), frameDuration: Time(1, 25))
        #expect(frames.map { $0?.media } == f.media)
        #expect(frames[1]?.time == s(3))
        #expect(inner.angleFrames(at: s(11), frameDuration: Time(1, 25)).allSatisfy { $0 == nil })
        let piece = try #require(f.p.timeline(f.main)?.tracks[0].clips.first)
        #expect(piece.angleInnerTime(at: s(4)) == piece.source.start + s(4))
    }

    @Test func plainClipAndPieceOutsideTheAngleClipGiveNil() throws {
        let f = try fixture()
        let inner = try #require(f.p.timeline(f.seq))
        var plain = try #require(f.p.timeline(f.main)?.tracks[0].clips.first)
        plain.sequence = nil
        #expect(plain.angleProxy(inner: inner) == nil)
        var piece = try #require(f.p.timeline(f.main)?.tracks[0].clips.first)
        piece.source = TimeRange(start: s(8), duration: s(5))     // runs past the angle's clip (10 s)
        #expect(piece.angleProxy(inner: inner) == nil)
    }
}
