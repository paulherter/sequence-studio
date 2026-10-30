import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct ToneBleepTests {
    private func project() -> (Project, Timeline.ID, Track.ID, Track.ID) {
        let a1 = Track(kind: .audio), v1 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, a1])
        return (Project(name: "P", timelines: [t]), t.id, a1.id, v1.id)
    }

    @Test func defaultIsOneKilohertzMinusTwelve() {
        let d = ToneSpec.default
        #expect(d.frequencyHz == 1000 && d.levelDB == -12)
        #expect(abs(d.amplitude - 0.2512) < 0.0001)
    }

    @Test func mediaIDRoundTripsAndOrdinaryIDsAreNoTone() {
        let spec = ToneSpec(frequencyHz: 440.5, levelDB: -20.25)
        #expect(ToneSpec(mediaID: spec.mediaID) == spec)
        #expect(ToneSpec(mediaID: UUID()) == nil)
        #expect(ToneSpec.default.mediaID != ToneSpec(frequencyHz: 1001, levelDB: -12).mediaID)
    }

    @Test func valuesAreClamped() {
        let s = ToneSpec(frequencyMilliHz: 5, levelCentiDB: 900)
        #expect(s.frequencyHz == 20 && s.levelDB == 0)
    }

    @Test func addToneClipPlacesAGeneratorAudioClip() throws {
        var (p, tl, a1, v1) = project()
        let id = try p.addToneClip(in: tl, at: s(2), track: a1, duration: s(3))
        let c = p.timeline(tl)!.tracks[1].clips[0]
        #expect(c.id == id && c.kind == .audio && c.isGenerator && c.tone == .default)
        #expect(c.timeline == TimeRange(start: s(2), duration: s(3)))
        #expect(throws: EditError.wrongTrackKind) { try p.addToneClip(in: tl, at: s(0), track: v1, duration: s(1)) }
        #expect(throws: EditError.emptyClip) { try p.addToneClip(in: tl, at: s(0), track: a1, duration: .zero) }
    }

    @Test func setToneChangesPayloadAndAudioSegmentMedia() throws {
        var (p, tl, a1, _) = project()
        let id = try p.addToneClip(in: tl, at: s(0), track: a1, duration: s(4))
        let spec = ToneSpec(frequencyHz: 800, levelDB: -6)
        try p.setTone(clipID: id, spec)
        let seg = p.timeline(tl)!.audioSegments(in: TimeRange(start: s(0), duration: s(4)))
        #expect(seg.count == 1 && seg[0].media == spec.mediaID && ToneSpec(mediaID: seg[0].media) == spec)
    }

    @Test func toneSurvivesTheMediaIDResetOfCopies() throws {
        // Conform/title-block copies set `media = id` on generators; the mixer still plays the tone.
        var (p, tl, a1, _) = project()
        try p.addToneClip(in: tl, at: s(0), track: a1, duration: s(4))
        var t = p.timeline(tl)!
        var c = t.tracks[1].clips[0]
        c.media = c.id
        t.tracks[1].replace(c)
        #expect(t.audioSegments(in: TimeRange(start: s(0), duration: s(1))).first?.media == ToneSpec.default.mediaID)
    }

    @Test func generatorPayloadRoundTripsThroughJSON() throws {
        var (p, tl, a1, _) = project()
        let spec = ToneSpec(frequencyHz: 523.25, levelDB: -9)
        try p.addToneClip(spec, in: tl, at: s(0), track: a1, duration: s(2))
        let data = try JSONEncoder().encode(p.timeline(tl)!)
        let back = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(back.tracks[1].clips[0].tone == spec)
    }

    // MARK: Bleep

    private func dialog() -> (Timeline, Track.ID, Track.ID) {
        let link = UUID()
        let a = Track(kind: .audio, clips: [Clip(name: "Talk", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)),
                                                  start: .zero, link: link, mediaDuration: s(20))])
        let v = Track(kind: .video, clips: [Clip(name: "Pic", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)),
                                                  start: .zero, link: link, mediaDuration: s(20))])
        return (Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v, a]), a.id, v.id)
    }

    @Test func bleepMutesTheRangeAndLaysTheTone() throws {
        var (t, a, _) = dialog()
        let range = TimeRange(start: s(4), end: s(6))
        let toneID = try t.bleep(range, tracks: [a])
        let audio = t.tracks[1].clips
        #expect(audio.map(\.start) == [s(0), s(4), s(6)])
        #expect(audio.map(\.isEnabled) == [true, false, true])
        let tone = t.tracks[2]
        #expect(tone.name == Timeline.bleepTrackName && tone.kind == .audio && !tone.isTargeted)
        #expect(tone.clips.count == 1 && tone.clips[0].id == toneID && tone.clips[0].timeline == range)
        #expect(tone.clips[0].tone == .default)
        // The sound under the bleep is kept, only off: same media, continuous source.
        #expect(audio[0].media == audio[1].media && audio[1].source.end == audio[2].source.start)
    }

    @Test func bleepCutsPictureAndSoundAlikeAnAddEdit() throws {
        var (t, a, _) = dialog()
        try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
        let v = t.tracks[0].clips, au = t.tracks[1].clips
        #expect(v.map(\.start) == [s(0), s(4), s(6)] && v.allSatisfy(\.isEnabled))
        #expect(v.map(\.link) == au.map(\.link) && Set(v.compactMap(\.link)).count == 3)
    }

    @Test func linkedTrimOfThePictureTailWorksBothWays() throws {
        for delta in [Time(-1, 1), Time(1, 1)] {
            var (t, a, _) = dialog()
            try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
            try t.trim(t.tracks[0].clips[2].id, edge: .tail, by: delta)
            #expect(t.tracks.allSatisfy { $0.isConsistent })
            #expect(t.tracks[0].clips[2].timeline.end == t.tracks[1].clips[2].timeline.end)
            #expect(t.tracks[1].clips.map(\.isEnabled) == [true, false, true])
        }
    }

    @Test func enableClipOnThePictureKeepsTheBleep() throws {
        var (t, a, _) = dialog()
        try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
        _ = try t.toggleEnabled([t.tracks[0].clips[0].id])          // outer piece: disables its pair only
        #expect(t.tracks[1].clips.map(\.isEnabled) == [false, false, true])
        #expect(t.tracks[0].clips.map(\.isEnabled) == [false, true, true])
    }

    @Test func repeatedBleepOnTheSameRangeAddsNoSecondTone() throws {
        var (t, a, _) = dialog()
        let r = TimeRange(start: s(4), end: s(6))
        try t.bleep(r, tracks: [a])
        let once = t
        #expect(throws: EditError.emptyClip) { try t.bleep(r, tracks: [a]) }
        #expect(t == once)
        #expect(t.tracks.count == 3 && t.tracks[2].clips.count == 1)
    }

    @Test func theBleepTrackIsNeverATarget() throws {
        var (t, a, _) = dialog()
        try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
        let bleepID = t.tracks[2].id
        try t.bleep(TimeRange(start: s(1), end: s(2)), tracks: [a, bleepID])
        #expect(t.tracks.count == 3 && t.tracks[2].clips.count == 2 && t.tracks[2].clips.allSatisfy(\.isEnabled))
        #expect(throws: EditError.clipNotFound) { try t.bleep(TimeRange(start: s(1), end: s(2)), tracks: [bleepID]) }
    }

    @Test func playedSegmentsHaveTheToneButNotTheBleepedDialog() throws {
        var (t, a, _) = dialog()
        try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
        let segs = t.audioSegments(in: TimeRange(start: s(3), end: s(7)))
        let tones = segs.filter { ToneSpec(mediaID: $0.media) != nil }
        #expect(tones.count == 1 && tones[0].timeline == TimeRange(start: s(4), end: s(6)))
        #expect(tones[0].extent == tones[0].timeline)               // own edges: the mixer fades both ends
        let talk = segs.filter { ToneSpec(mediaID: $0.media) == nil }
        #expect(talk.map(\.timeline) == [TimeRange(start: s(3), end: s(4)), TimeRange(start: s(6), end: s(7))])
        // Dialog edges next to the bleep are real edges too (no through edit across a disabled piece), so they fade as well.
        #expect(talk[0].extent.end == s(4) && talk[1].extent.start == s(6))
    }

    @Test func secondBleepReusesTheBleepTrack() throws {
        var (t, a, _) = dialog()
        try t.bleep(TimeRange(start: s(1), end: s(2)), tracks: [a])
        try t.bleep(TimeRange(start: s(7), end: s(8)), tracks: [a])
        #expect(t.tracks.count == 3 && t.tracks[2].clips.count == 2)
        // An overlapping range cannot share the track: it gets its own.
        try t.bleep(TimeRange(start: s(7), end: s(9)), tracks: [a])
        #expect(t.tracks.count == 4)
    }

    @Test func bleepRefusesBadInput() {
        var (t, a, v) = dialog()
        #expect(throws: EditError.emptyClip) { try t.bleep(TimeRange(start: s(2), end: s(2)), tracks: [a]) }
        #expect(throws: EditError.wrongTrackKind) { try t.bleep(TimeRange(start: s(2), end: s(3)), tracks: [v]) }
        #expect(throws: EditError.clipNotFound) { try t.bleep(TimeRange(start: s(2), end: s(3)), tracks: []) }
        #expect(throws: EditError.emptyClip) { try t.bleep(TimeRange(start: s(20), end: s(21)), tracks: [a]) }   // nothing sounds
        t.tracks[1].isLocked = true
        #expect(throws: EditError.trackLocked) { try t.bleep(TimeRange(start: s(2), end: s(3)), tracks: [a]) }
        #expect(t.tracks.count == 2)                                  // a refused bleep changes nothing
    }

    @Test func projectUndoRestoresEverythingInOneStep() throws {
        // Snapshot model: the edit is one mutation of the timeline value.
        var (t, a, _) = dialog()
        let before = t
        try t.bleep(TimeRange(start: s(4), end: s(6)), tracks: [a])
        #expect(t != before)
        t = before
        #expect(t.tracks.count == 2 && t.tracks[1].clips.count == 1)
    }
}
