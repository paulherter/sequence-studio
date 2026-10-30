import Foundation
import Testing
@testable import SQCore

// Pitch Shift and Disguise Voice (F7.8): catalog, stage values, and the range edit that places the disguise.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .audio, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)),
         start: s(start), link: link, mediaDuration: s(100))
}
private func track(_ clips: [Clip], kind: TrackKind = .audio, locked: Bool = false) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    t.isLocked = locked
    return t
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }

@Suite struct PitchEffectTests {
    @Test func specs() throws {
        let pitch = try #require(EffectCatalog.spec(for: ClipEffect.audioPitchShiftKind))
        #expect(pitch.title == "Pitch Shift")
        #expect(pitch.params.map(\.key) == [ClipEffect.pitchSemitonesKey, ClipEffect.pitchCentsKey, ClipEffect.pitchFormantsKey])
        #expect(pitch.params[0].range == -12...12 && pitch.params[0].defaultValue == 0)
        let disguise = try #require(EffectCatalog.spec(for: ClipEffect.audioDisguiseVoiceKind))
        #expect(disguise.title == "Disguise Voice")
        // No seed, no strength: nothing stored that describes how to undo it.
        #expect(disguise.params.map(\.key) == [ClipEffect.disguiseVoiceKey])
        #expect(ClipEffect.isAudioKind(ClipEffect.audioPitchShiftKind) && ClipEffect.isAudioKind(ClipEffect.audioDisguiseVoiceKind))
        #expect(EffectCatalog.audio.contains { $0.kind == ClipEffect.audioPitchShiftKind })
        #expect(EffectCatalog.audio.contains { $0.kind == ClipEffect.audioDisguiseVoiceKind })
    }

    @Test func hintPromisesNothing() {
        let h = AudioDisguiseValues.hint.lowercased()
        #expect(h.contains("not a guarantee"))
        for word in ["anonym", "safe", "secure", "unrecognizable", "protect"] { #expect(!h.contains(word)) }
    }

    @Test func pitchStageAddsCentsAndClamps() throws {
        var a = clip(0, 4)
        let added = a.addEffect(kind: ClipEffect.audioPitchShiftKind)
        let id = try #require(added)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .pitchShift(semitones: 0, preserveFormants: true))
        a.setParameter(id, ClipEffect.pitchSemitonesKey, to: 40)
        a.setParameter(id, ClipEffect.pitchCentsKey, to: -50)
        a.setParameter(id, ClipEffect.pitchFormantsKey, to: 0)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .pitchShift(semitones: 11.5, preserveFormants: false))
        #expect(abs(AudioPitchValues.ratio(semitones: 12) - 2) < 1e-12)
    }

    @Test func disguiseStageCarriesTheClipPosition() throws {
        var a = clip(0, 4)
        #expect(a.addEffect(kind: ClipEffect.audioDisguiseVoiceKind) != nil)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .disguiseVoice(voice: 0, at: .zero))
        #expect(a.audioFXSteps(atLocal: Time(3, 2))[0].stage == .disguiseVoice(voice: 0, at: Time(3, 2)))
        #expect(a.audioFXLayout.map(\.kind) == [ClipEffect.audioDisguiseVoiceKind])
    }

    @Test func rangeEditCutsTheClipAndDisguisesOnlyTheInside() throws {
        let a = clip(0, 10), other = clip(12, 4)
        var t = timeline([track([a, other])])
        let parts = try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a.id], voice: 1)
        let clips = t.tracks[0].clips
        #expect(clips.map(\.start) == [s(0), s(3), s(6), s(12)])
        #expect(clips.map(\.hasDisguiseVoice) == [false, true, false, false])
        #expect(parts == [clips[1].id])
        #expect(clips[1].timeline == TimeRange(start: s(3), end: s(6)))
        #expect(clips[1].audioFXSteps(atLocal: .zero)[0].stage == .disguiseVoice(voice: 1, at: .zero))
        #expect(clips[0].id == a.id)
    }

    @Test func rangeLargerThanTheClipDisguisesAllOfItWithoutCuts() throws {
        let a = clip(2, 4), b = clip(8, 4)
        var t = timeline([track([a, b])])
        let parts = try t.disguiseVoice(range: TimeRange(start: s(0), end: s(9)), clips: [a.id, b.id])
        let clips = t.tracks[0].clips
        #expect(clips.map(\.start) == [s(2), s(8), s(9)])
        #expect(clips.map(\.hasDisguiseVoice) == [true, true, false])
        #expect(parts.count == 2)
    }

    @Test func secondRunDoesNotStackTheEffect() throws {
        let a = clip(0, 10)
        var t = timeline([track([a])])
        let r = TimeRange(start: s(3), end: s(6))
        try t.disguiseVoice(range: r, clips: [a.id])
        let mid = t.tracks[0].clips[1].id
        try t.disguiseVoice(range: r, clips: [mid])
        #expect(t.tracks[0].clips.count == 3)
        #expect(t.tracks[0].clips[1].effects.filter { $0.kind == ClipEffect.audioDisguiseVoiceKind }.count == 1)
    }

    @Test func linkedPictureIsCutWithTheSoundAndPartsStayPairs() throws {
        let link = UUID()
        let v = clip(0, 10, kind: .video, link: link), a = clip(0, 10, link: link)
        var t = timeline([track([v], kind: .video), track([a])])
        try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a.id])
        let vs = t.tracks[0].clips, au = t.tracks[1].clips
        #expect(vs.count == 3 && au.count == 3)
        for k in 0..<min(3, vs.count, au.count) { #expect(vs[k].link != nil && vs[k].link == au[k].link) }
        #expect(Set(au.compactMap(\.link)).count == 3)
        #expect(vs.allSatisfy { !$0.hasDisguiseVoice })
    }

    @Test func unselectedClipsAndOtherTracksAreUntouched() throws {
        let a = clip(0, 10), b = clip(0, 10)
        var t = timeline([track([a]), track([b])])
        try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a.id])
        #expect(t.tracks[1].clips == [b])
    }

    @Test func failuresChangeNothing() {
        let a = clip(0, 10)
        var t = timeline([track([a], locked: true)])
        let before = t
        #expect(throws: EditError.trackLocked) { try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a.id]) }
        #expect(throws: EditError.clipNotFound) { try t.disguiseVoice(range: TimeRange(start: s(20), end: s(26)), clips: [a.id]) }
        #expect(throws: EditError.clipNotFound) { try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: []) }
        #expect(t == before)
    }

    // MARK: Review of the first version: privacy and links

    @Test func samplePositionIsRationalAtAnyRate() {
        #expect(AudioPitchValues.sample(Time(3, 2), rate: 48_000) == 72_000)
        #expect(AudioPitchValues.sample(Time(3, 2), rate: 44_100) == 66_150)
        #expect(AudioPitchValues.sample(Time(1_001, 30_000), rate: 44_100) == 1_471)        // 1471.47
        #expect(AudioPitchValues.sample(Time(-1, 3), rate: 48_000) == -16_000)
        #expect(AudioPitchValues.sample(Time(-1, 96_000), rate: 48_000) == 0)               // -0.5 rounds up, like +0.5
        #expect(AudioPitchValues.sample(Time(-3, 96_000), rate: 48_000) == -1)
    }

    /// Dual mono: the second track holds the same voice. Selecting one clip disguises both.
    @Test func linkedAudioPartnerIsDisguisedToo() throws {
        let link = UUID()
        let v = clip(0, 10, kind: .video, link: link), a1 = clip(0, 10, link: link), a2 = clip(0, 10, link: link)
        var t = timeline([track([v], kind: .video), track([a1]), track([a2])])
        let parts = try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a1.id])
        #expect(parts.count == 2)
        for tr in t.tracks[1...] {
            #expect(tr.clips.map(\.start) == [s(0), s(3), s(6)])
            #expect(tr.clips.map(\.hasDisguiseVoice) == [false, true, false])
        }
        #expect(t.tracks[0].clips.allSatisfy { !$0.hasDisguiseVoice })
        for k in 0..<3 { #expect(Set(t.tracks.map { $0.clips[k].link }).count == 1) }
    }

    @Test func lockedLinkedAudioPartnerRefusesEverything() {
        let link = UUID()
        let a1 = clip(0, 10, link: link), a2 = clip(0, 10, link: link)
        var t = timeline([track([a1]), track([a2], locked: true)])
        let before = t
        #expect(throws: DisguiseVoiceError.linkedAudioLocked) {
            try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a1.id])
        }
        #expect(t == before)
        #expect(DisguiseVoiceError.linkedAudioLocked.errorDescription?.contains("locked track") == true)
        // A linked partner outside the range does not block.
        let far = clip(20, 5, link: link)
        var u = timeline([track([a1]), track([far], locked: true)])
        #expect(throws: Never.self) { try u.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a1.id]) }
    }

    /// The partner starts after the range: it stays linked to the piece it overlaps (the last one), not to the first.
    @Test func partnerThatDoesNotSpanTheCutsFollowsThePieceItOverlaps() throws {
        let link = UUID()
        let a = clip(0, 20, link: link)
        var v = clip(5, 15, kind: .video, link: link)
        v.source = TimeRange(start: s(5), duration: s(15))
        var t = timeline([track([v], kind: .video), track([a])])
        try t.disguiseVoice(range: TimeRange(start: s(2), end: s(4)), clips: [a.id])
        let au = t.tracks[1].clips, vs = t.tracks[0].clips
        #expect(au.map(\.start) == [s(0), s(2), s(4)])
        #expect(vs.count == 1)
        #expect(au[0].link == link)
        #expect(Set(au.compactMap(\.link)).count == 3)
        #expect(vs[0].link == au[2].link)
    }

    @Test func partnerOverlappingOneCutIsCutThereAndEachHalfKeepsItsPiece() throws {
        let link = UUID()
        let a = clip(0, 20, link: link)
        let v = clip(5, 15, kind: .video, link: link)
        var t = timeline([track([v], kind: .video), track([a])])
        try t.disguiseVoice(range: TimeRange(start: s(2), end: s(8)), clips: [a.id])
        let au = t.tracks[1].clips, vs = t.tracks[0].clips
        #expect(vs.map(\.start) == [s(5), s(8)])
        #expect(vs[0].link == au[1].link && vs[1].link == au[2].link)
        #expect(au[1].hasDisguiseVoice)
    }

    /// A fade on a range edge: the piece outside never plays into its handle, which is the source under the disguised piece.
    @Test func outerPieceHasNoHandleNextToADisguisedPiece() throws {
        let a = clip(0, 10)
        func segments(disguised: Bool) throws -> [AudioSegment] {
            var t = timeline([track([a])])
            if disguised {
                try t.disguiseVoice(range: TimeRange(start: s(3), end: s(6)), clips: [a.id])
            } else {
                try t.tracks[0].split(at: s(3)); try t.tracks[0].split(at: s(6))
            }
            let c = t.tracks[0].clips
            for k in 0..<2 {
                try t.addTransition(point: .cut(outgoing: c[k].id, incoming: c[k + 1].id), kind: .constantPower,
                                    track: t.tracks[0].id, duration: s(1))
            }
            let all = t.audioSegments(in: TimeRange(start: s(0), end: s(10)))
            return c.map { clip in all.first { $0.clip == clip.id }! }
        }
        let plain = try segments(disguised: false)
        #expect(plain.map(\.timeline) == [TimeRange(start: s(0), end: Time(7, 2)), TimeRange(start: Time(5, 2), end: Time(13, 2)),
                                          TimeRange(start: Time(11, 2), end: s(10))])
        let out = try segments(disguised: true)
        #expect(out[0].timeline == TimeRange(start: s(0), end: s(3)))
        #expect(out[1].timeline == TimeRange(start: Time(5, 2), end: Time(13, 2)))      // the disguised piece fades on both sides
        #expect(out[2].timeline == TimeRange(start: s(6), end: s(10)))
        // Nothing of the range's source is reachable from the outer pieces.
        #expect(out[0].source.end <= s(3) && out[2].source.start >= s(6))
    }
}
