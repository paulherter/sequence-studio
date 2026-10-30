import Foundation
import Testing
@testable import SQCore

// N6b Stinger: a Library clip (alpha, e.g. ProRes 4444) laid over a cut. The picture switches from A to B at the edit point,
// which lands on `cutFraction` of the stinger; the stinger is a third decoded layer drawn over the switching picture.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@Suite struct StingerTransitionTests {
    let stingerID = UUID()

    /// Two touching 60 frame clips without handles (source = whole media), cut at frame 60.
    private func cutTimeline() throws -> (Timeline, Clip, Clip) {
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero,
                     mediaDuration: f(60))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60),
                     mediaDuration: f(60))
        var v = Track(kind: .video)
        try v.overwrite(a); try v.overwrite(b)
        return (Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v]), a, b)
    }

    private func stingerTimeline(cut: Double = 0.5, frames: Int64 = 30) throws -> (Timeline, Transition.ID, Clip, Clip) {
        var (t, a, b) = try cutTimeline()
        let id = try t.addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(frames))
        try t.setStinger(id, TransitionStinger(media: stingerID, cutFraction: cut))
        return (t, id, a, b)
    }

    // MARK: Model

    @Test func kindIsAVideoTransitionThatIsNotAMotionMix() {
        #expect(TransitionKind.stinger.trackKind == .video)
        #expect(TransitionKind.stinger.name == "Stinger")
        #expect(!TransitionKind.stinger.isMotion)
        #expect(!TransitionKind.stinger.usesDirection && !TransitionKind.stinger.usesSoftness && !TransitionKind.stinger.usesMotionBlur)
        #expect(TransitionKind.kinds(for: .video).contains(.stinger))
        #expect(TransitionKind.stinger.isStinger)
    }

    @Test func stingerRoundTripsThroughCodable() throws {
        var tr = Transition(kind: .stinger, duration: f(30), outgoing: UUID(), incoming: UUID())
        tr.stinger = TransitionStinger(media: stingerID, cutFraction: 0.4, scale: 0.5)
        let back = try JSONDecoder().decode(Transition.self, from: JSONEncoder().encode(tr))
        #expect(back == tr)
        #expect(back.stinger?.media == stingerID)
        #expect(back.stinger?.cutFraction == 0.4)
        #expect(back.stinger?.scale == 0.5)
        // A transition without a stinger writes no key.
        let plain = Transition(kind: .crossDissolve, duration: f(30), outgoing: UUID(), incoming: UUID())
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("stinger"))
    }

    @Test func cutFractionIsClamped() {
        #expect(TransitionStinger(media: stingerID, cutFraction: -1).cutFraction == 0)
        #expect(TransitionStinger(media: stingerID, cutFraction: 3).cutFraction == 1)
        #expect(TransitionStinger(media: stingerID).cutFraction == 0.5)
    }

    // MARK: Resolution

    @Test func needsNoHandlesAndPutsTheCutFrameOnTheEdit() throws {
        let (t, id, _, _) = try stingerTimeline(cut: 0.5)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == id })
        #expect(r.cut == f(60))
        #expect(r.before == f(15) && r.after == f(15))
        #expect(r.span == TimeRange(start: f(45), duration: f(30)))
        #expect(r.stingerStart == .zero)
        #expect(!r.isClamped)
    }

    @Test func cutFractionMovesTheSpanAroundTheEdit() throws {
        let (t, id, _, _) = try stingerTimeline(cut: 0.2, frames: 30)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == id })
        #expect(r.before == f(6) && r.after == f(24))
    }

    @Test func shortClipsTrimTheStingerButKeepItsCutOnTheEdit() throws {
        // A is only 10 frames: the stinger's first 5 of 15 before-cut frames are skipped (it starts 5 frames into its media).
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(10)), start: .zero,
                     mediaDuration: f(10))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(10),
                     mediaDuration: f(60))
        var v = Track(kind: .video)
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v])
        let id = try t.addTransition(kind: .stinger, track: v.id, outgoing: a.id, incoming: b.id, duration: f(30))
        try t.setStinger(id, TransitionStinger(media: stingerID, cutFraction: 0.5))
        #expect(t.transition(id)?.transition.duration == f(30))   // the request is kept
        let r = try #require(t.resolvedTransitions(on: v.id).first)
        #expect(r.before == f(10) && r.after == f(15))
        #expect(r.stingerStart == f(5))
        #expect(r.isClamped)
    }

    @Test func singleSidedStingerIsRefused() throws {
        var (t, a, _) = try cutTimeline()
        #expect(throws: EditError.notACut) {
            try t.addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: nil, incoming: a.id, duration: f(30))
        }
    }

    @Test func setStingerSetsAndClearsTheClip() throws {
        var (t, a, b) = try cutTimeline()
        let id = try t.addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        try t.setStinger(id, nil)
        #expect(t.transition(id)?.transition.stinger == nil)
        try t.setStinger(id, TransitionStinger(media: stingerID, cutFraction: 0.75))
        #expect(t.transition(id)?.transition.stinger?.cutFraction == 0.75)
        #expect(t.transition(id)?.transition.kind == .stinger)
    }

    // MARK: Evaluation: the third layer

    @Test func beforeTheEditShowsAWithTheStingerOnTop() throws {
        let (t, id, a, _) = try stingerTimeline()
        let ls = t.videoLayers(at: f(50))
        #expect(ls.count == 2)
        #expect(ls[0].clip == a.id)
        #expect(ls[0].sourceTime == f(50))
        #expect(ls[1].media == stingerID)
        #expect(ls[1].clip == id)
        #expect(ls[1].sourceTime == f(5))
        #expect(ls.allSatisfy { $0.inTransition && $0.pair == nil })
        #expect(ls.allSatisfy { $0.transform.opacity == 1 })
    }

    @Test func fromTheEditOnShowsBWithTheStingerOnTop() throws {
        let (t, _, _, b) = try stingerTimeline()
        let ls = t.videoLayers(at: f(60))
        #expect(ls.map(\.clip) == [b.id, ls[1].clip])
        #expect(ls[0].sourceTime == .zero)
        #expect(ls[1].media == stingerID)
        #expect(ls[1].sourceTime == f(15))
        #expect(t.videoLayers(at: f(74)).last?.sourceTime == f(29))
    }

    @Test func outsideTheSpanThereIsNoStinger() throws {
        let (t, _, a, b) = try stingerTimeline()
        #expect(t.videoLayers(at: f(44)).map(\.clip) == [a.id])
        #expect(t.videoLayers(at: f(75)).map(\.clip) == [b.id])
        #expect(t.videoLayers(at: f(44)).allSatisfy { !$0.inTransition })
    }

    @Test func stingerWithoutMediaIsAPlainCut() throws {
        var (t, a, b) = try cutTimeline()
        try t.addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(30))
        #expect(t.videoLayers(at: f(50)).map(\.clip) == [a.id])
        #expect(t.videoLayers(at: f(60)).map(\.clip) == [b.id])
    }

    @Test func stingerUsesItsFitScaleAndStaysOnTheTrack() throws {
        var (t, id, a, _) = try stingerTimeline()
        try t.setStinger(id, TransitionStinger(media: stingerID, cutFraction: 0.5, scale: 0.5))
        // A clip on V2 above stays above the stinger.
        var v2 = Track(kind: .video)
        let top = Clip(name: "T", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(120)), start: .zero)
        try v2.overwrite(top)
        t.tracks.append(v2)
        let ls = t.videoLayers(at: f(50))
        #expect(ls.map(\.clip) == [a.id, id, top.id])
        #expect(ls[1].transform.scale == Vec2(0.5, 0.5))
    }

    @Test func disabledSideLeavesOnlyTheStinger() throws {
        var (t, _, a, _) = try stingerTimeline()
        var c = try #require(t.tracks[0].clip(a.id))
        c.isEnabled = false
        try t.replaceClip(c)
        let ls = t.videoLayers(at: f(50))
        #expect(ls.map(\.media) == [stingerID])
    }

    // MARK: Project: pick a Library clip

    @Test func projectSetStingerFitsTheClipAndTakesItsLength() throws {
        let (t, a, b) = try cutTimeline()
        let info = MediaInfo(duration: f(45), video: VideoTrackInfo(width: 3840, height: 2160, codec: "ap4h", bitDepth: 12,
                                                                   chroma: "4:4:4", nominalFrameDuration: fd, isVariableFrameRate: false))
        let ref = MediaRef(id: stingerID, name: "Stinger", path: "/s.mov", fingerprint: MediaFingerprint(size: 1),
                           duration: f(45), info: info)
        var p = Project(name: "P", media: [ref], timelines: [t])
        let sid = try p.timelines[0].addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(10))
        try p.setStinger(transition: sid, media: stingerID, cutFraction: 0.6, in: p.timelines[0].id)
        let tr = try #require(p.timelines[0].transition(sid)?.transition)
        #expect(tr.kind == .stinger)
        #expect(tr.duration == f(45))
        #expect(tr.stinger?.media == stingerID)
        #expect(tr.stinger?.cutFraction == 0.6)
        #expect(tr.stinger?.scale == 0.5)
        #expect(p.containsStinger)
    }

    @Test func projectSetStingerRefusesUnknownOrAudioOnlyMedia() throws {
        let (t, a, b) = try cutTimeline()
        let audioOnly = MediaRef(name: "a", path: "/a.wav", fingerprint: MediaFingerprint(size: 1), duration: f(30),
                                 info: MediaInfo(duration: f(30), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        var p = Project(name: "P", media: [audioOnly], timelines: [t])
        let sid = try p.timelines[0].addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(10))
        #expect(throws: EditError.self) { try p.setStinger(transition: sid, media: UUID(), cutFraction: 0.5, in: t.id) }
        #expect(throws: EditError.self) { try p.setStinger(transition: sid, media: audioOnly.id, cutFraction: 0.5, in: t.id) }
    }

    // MARK: ProjectFile v38

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func versionConstants() {
        #expect(ProjectFile.currentVersion >= 38)
        #expect(ProjectFile.stingerVersion == 38)
    }

    @Test func aProjectWithAStingerIsWrittenAsV38AndRoundTrips() throws {
        let (t, _, _, _) = try stingerTimeline(cut: 0.3)
        let p = Project(name: "P", timelines: [t])
        #expect(p.containsStinger)
        #expect(try writtenVersion(p) == ProjectFile.stingerVersion)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.timelines[0].tracks[0].transitions[0].stinger?.cutFraction == 0.3)
    }

    @Test func aStingerKindWithoutMediaStillGates() throws {
        // A v37 build would fail on the unknown kind.
        var (t, a, b) = try cutTimeline()
        try t.addTransition(kind: .stinger, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(10))
        #expect(try writtenVersion(Project(name: "P", timelines: [t])) == ProjectFile.stingerVersion)
    }

    @Test func plainProjectsKeepTheLowestVersion() throws {
        let (t, _, _) = try cutTimeline()
        #expect(try writtenVersion(Project(name: "P", timelines: [t])) == 36)
        var withMask = t
        var c = withMask.tracks[0].clips[0]
        c.masks = [ClipMask.makeSubject(name: "Subject")]
        try withMask.replaceClip(c)
        #expect(try writtenVersion(Project(name: "P", timelines: [withMask])) == 37)
    }

    @Test func v37FilesStillOpen() throws {
        let (t, _, _) = try cutTimeline()
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(Project(name: "P", timelines: [t]))) as? [String: Any])
        obj["formatVersion"] = 37
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips.count == 2)
        #expect(!back.containsStinger)
    }
}
