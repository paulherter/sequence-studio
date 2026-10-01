import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let frame = Time(1, 30)
private func audio(_ start: Int64 = 0, _ dur: Int64 = 10) -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

@Suite struct FadeKeysTests {
    @Test func oneSecondHeadFadeMakesTwoKeys() {
        var c = audio()
        c.setAudioFadeIn(s(1), frameDuration: frame)
        let k = c.animation.volume.track.keys
        #expect(k.count == 2)
        #expect(k[0].time == .zero && k[0].value == 0)
        #expect(k[1].time == s(1) && k[1].value == 1)          // 0 dB
        #expect(c.audioFadeIn == s(1))
        #expect(c.volume(at: Time(1, 2) + c.start) == 0.5)
    }

    @Test func tailFadeEndsSilent() {
        var c = audio()
        c.setAudioFadeOut(s(2), frameDuration: frame)
        let k = c.animation.volume.track.keys
        #expect(k.map(\.time) == [s(8), s(10)] && k.map(\.value) == [1, 0])
        #expect(c.audioFadeOut == s(2) && c.audioFadeIn == .zero)
    }

    @Test func undoByRestoringTheClipIsExact() {
        let before = audio()
        var c = before
        c.setAudioFadeIn(s(1), frameDuration: frame)
        c.setAudioFadeOut(s(1), frameDuration: frame)
        #expect(c != before)
        c.setAudioFadeIn(.zero, frameDuration: frame)
        c.setAudioFadeOut(.zero, frameDuration: frame)
        #expect(c.animation == before.animation)               // dragging back to 0 removes the keys again
    }

    @Test func subFrameFadeSnapsToZero() {
        var c = audio()
        c.setAudioFadeIn(Time(1, 60), frameDuration: frame)
        #expect(c.animation.volume.track.isEmpty && c.audioFadeIn == .zero)
        c.setAudioFadeIn(Time(3, 60), frameDuration: frame)    // 1.5 frames -> 1 frame
        #expect(c.audioFadeIn == frame)
    }

    @Test func fadeKeepsTheLevelAndIsClamped() {
        var c = audio()
        c.animation.volume = AnimatedProperty(0.5)
        c.setAudioFadeIn(s(1), frameDuration: frame)
        #expect(c.animation.volume.track.keys.last?.value == 0.5)
        c.setAudioFadeOut(s(100), frameDuration: frame)         // cannot overlap the head fade
        #expect(c.audioFadeIn == s(1) && c.audioFadeOut == s(9))
    }

    @Test func headHandleFollowsATrim() {
        var c = audio()
        c.setAudioFadeIn(s(2), frameDuration: frame)
        c.extendHead(by: s(-1))                                  // 1 s trimmed off the head: keys shift with the content
        c.start = c.start + s(1)
        #expect(c.audioFadeIn == s(1))
    }
}

@Suite struct VolumeKeyLimitTests {
    @Test func aKeyCannotCrossItsNeighbours() {
        var c = audio()
        let a = c.addVolumeKey(atLocal: s(2)), b = c.addVolumeKey(atLocal: s(4)), d = c.addVolumeKey(atLocal: s(6))
        c.moveVolumeKey(b, toLocal: s(9), gainDB: 0)
        let t = c.animation.volume.track
        #expect(t.keys.map(\.id) == [a, b, d])
        #expect(t.key(id: b)!.time < s(6) && t.key(id: b)!.time > s(5))
        c.moveVolumeKey(b, toLocal: s(0), gainDB: 0)
        #expect(c.animation.volume.track.keys.map(\.id) == [a, b, d])
        #expect(c.animation.volume.track.key(id: b)!.time > s(2))
    }
}

@Suite struct TrackPanTests {
    @Test func centreIsUnityForBothLaws() {
        for stereo in [true, false] {
            let c = TrackPan.gains(pan: 0, stereoSource: stereo)
            #expect(c.left == 1 && c.right == 1)
        }
    }

    @Test func panNeverBoostsAboveUnity() {
        for stereo in [true, false] {
            for p in stride(from: -1.0, through: 1.0, by: 0.05) {
                let g = TrackPan.gains(pan: p, stereoSource: stereo)
                #expect(g.left <= 1 && g.right <= 1 && g.left >= 0 && g.right >= 0, "pan \(p) stereo \(stereo)")
            }
        }
    }

    @Test func stereoBalanceAttenuatesOnlyTheOppositeSide() {
        let r = TrackPan.gains(pan: 0.5)
        #expect(r.right == 1 && abs(r.left - 0.5) < 1e-12)
        let l = TrackPan.gains(pan: -0.25)
        #expect(l.left == 1 && abs(l.right - 0.75) < 1e-12)
    }

    @Test func monoUsesEqualPowerAndIsContinuousThroughTheCentre() {
        let g = TrackPan.gains(pan: -0.5, stereoSource: false)
        #expect(g.left == 1 && abs(g.right - 2.0.squareRoot() * sin(Double.pi / 8)) < 1e-12)
        let near = TrackPan.gains(pan: 0.001, stereoSource: false)
        #expect(abs(near.left - 1) < 0.01 && near.right == 1)       // no step next to the centre
    }

    @Test func hardLeftSilencesTheRight() {
        for stereo in [true, false] {
            let g = TrackPan.gains(pan: -1, stereoSource: stereo)
            #expect(abs(g.right) < 1e-12 && g.left == 1)
            #expect(abs(TrackPan.gains(pan: 1, stereoSource: stereo).left) < 1e-12)
            #expect(TrackPan.gains(pan: -5, stereoSource: stereo).right == TrackPan.gains(pan: -1, stereoSource: stereo).right)
        }
    }

    @Test func faderFloorMutes() {
        #expect(TrackPan.linear(volumeDB: 0) == 1)
        #expect(TrackPan.linear(volumeDB: -60) == 0)
        #expect(abs(TrackPan.linear(volumeDB: -6.0206) - 0.5) < 1e-4)
        let g = TrackPan.channelGains(volumeDB: 0, pan: 0)
        #expect(g.left == 1 && g.right == 1)
    }

    @Test func trackFieldsRoundTripAndOldTracksDefault() throws {
        var t = Track(kind: .audio); t.volumeDB = -3; t.pan = 0.5
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        #expect(back.volumeDB == -3 && back.pan == 0.5)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Track(kind: .audio))) as! [String: Any]
        obj["volumeDB"] = nil; obj["pan"] = nil
        let old = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.volumeDB == 0 && old.pan == 0)
    }

    @Test func clipTagRoundTripsAndDefaultsDocumentedTargets() throws {
        var c = audio(); c.audioTag = .music; c.duckKeyIDs = [UUID()]
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.audioTag == .music && back.duckKeyIDs == c.duckKeyIDs)
        #expect(AudioTag.dialogue.targetLUFS == -14)
        #expect(AudioTag.music.targetLUFS == AudioTag.dialogue.targetLUFS - 6)
        #expect(AudioGain.targetLUFS(for: audio()) == -14)
        #expect(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(audio())).audioTag == nil)
    }

    @Test func v20MigrationIsIdentity() throws {
        let o: [String: Any] = ["formatVersion": 19, "project": ["x": 1]]
        let r = try ProjectFile.migrateV19toV20(o)
        #expect((r["project"] as? [String: Int]) == ["x": 1])
        #expect(ProjectFile.migrations[19] != nil)
    }
}

@Suite struct DuckingTests {
    @Test func noDialogueNoKeys() {
        #expect(Ducking.keys(dialogue: [], duration: s(10), amountDB: 12, fade: Ducking.defaultFade) { _ in 1 }.isEmpty)
        var c = audio(); c.animation.volume = AnimatedProperty(0.8)
        #expect(c.applyDucking(dialogue: []) == 0)
        #expect(c.animation.volume.track.isEmpty && c.animation.volume.value == 0.8)
    }

    @Test func duckRampsAroundDialogue() {
        let k = Ducking.keys(dialogue: [TimeRange(start: s(4), duration: s(2))], duration: s(10), amountDB: 20,
                             fade: Time(1, 2)) { _ in 1 }
        #expect(k.map(\.time) == [Time(7, 2), s(4), s(6), Time(13, 2)])
        #expect(k.map(\.value).map { Int(($0 * 100).rounded()) } == [100, 10, 10, 100])
    }

    @Test func closeRangesMergeAndEdgesClamp() {
        let k = Ducking.keys(dialogue: [TimeRange(start: .zero, duration: s(2)), TimeRange(start: Time(5, 2), duration: s(1))],
                             duration: Time(7, 2), amountDB: 6, fade: Time(1, 2)) { _ in 1 }
        #expect(k.map(\.time) == [.zero, Time(7, 2)])           // one span, ducked at both clip edges
    }

    @Test func rerunReplacesGeneratedKeysAndKeepsUserKeys() {
        var c = audio()
        let user = c.addVolumeKey(atLocal: s(9))
        let n1 = c.applyDucking(dialogue: [TimeRange(start: s(3), duration: s(2))], amountDB: 12, fade: Time(1, 2))
        #expect(n1 == 4 && c.animation.volume.track.keys.count == 5)
        let n2 = c.applyDucking(dialogue: [TimeRange(start: s(1), duration: s(1))], amountDB: 12, fade: Time(1, 2))
        #expect(n2 == 4 && c.animation.volume.track.keys.count == 5)
        #expect(c.animation.volume.track.key(id: user) != nil)
        #expect(c.volume(at: Time(3, 2)) < 0.3 && c.volume(at: s(4)) == 1)
        c.applyDucking(dialogue: [])
        #expect(c.animation.volume.track.keys.map(\.id) == [user])
    }

    @Test func dialogueInTimelineTimeIsShiftedIntoTheClip() {
        var c = audio(20)
        c.applyDucking(dialogue: [TimeRange(start: s(24), duration: s(2))], amountDB: 12, fade: Time(1, 2))
        #expect(c.animation.volume.track.keys.map(\.time).contains(s(4)))
        #expect(c.volume(at: s(25)) < 0.3 && c.volume(at: s(21)) == 1)
    }
}

@Suite struct LoudnessMatchTests {
    @Test func minus23ToMinus14Gives9dB() {
        #expect(abs(AudioGain.matchLoudness(measuredLUFS: -23, targetLUFS: -14)! - 9) < 0.1)
        #expect(abs(AudioGain.matchLoudness(measuredLUFS: -10, targetLUFS: -14)! + 4) < 0.1)
    }

    @Test func silenceAndUnmeasuredStayUnchanged() {
        #expect(AudioGain.matchLoudness(measuredLUFS: -.infinity, targetLUFS: -14) == nil)
        #expect(AudioGain.matchLoudness(measuredLUFS: -80, targetLUFS: -14) == nil)
        #expect(AudioGain.matchLoudness(measuredLUFS: nil, targetLUFS: -14) == nil)
    }

    @Test func resultIsClamped() {
        #expect(AudioGain.matchLoudness(measuredLUFS: -69, targetLUFS: 90)! == AudioGain.maxGainDB)
    }
}

@Suite struct SilenceRemovalTests {
    @Test func cutsLeaveAPadAndLandOnFrames() {
        // 30 fps; pause 2.0-4.0 s, pad 0.1 s -> cut 2.1-3.9 s
        let c = SilenceRemoval.cuts(silences: [TimeRange(start: s(2), duration: s(2))], padding: Time(1, 10), frameDuration: frame)
        #expect(c == [TimeRange(start: Time(21, 10), duration: Time(18, 10))])
        // not on the grid: start rounds up, end rounds down
        let d = SilenceRemoval.cuts(silences: [TimeRange(start: Time(1, 100), duration: Time(1, 1))], padding: .zero, frameDuration: frame)
        #expect(d.count == 1)
        #expect(d[0].start.frameIndex(frameDuration: frame) == 1 && d[0].start == frame)
        #expect(d[0].end <= Time(101, 100) && d[0].end.frameIndex(frameDuration: frame) * 1 == 30)
    }

    @Test func tooShortAfterPaddingIsDropped() {
        #expect(SilenceRemoval.cuts(silences: [TimeRange(start: s(2), duration: Time(1, 2))], padding: Time(6, 25), frameDuration: frame).isEmpty)
    }

    @Test func removingCutsRipplesAllTargetedTracks() throws {
        let m = UUID(), link = UUID()
        let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try vt.overwrite(v); try at.overwrite(a)
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [vt, at])
        let cuts = [TimeRange(start: s(2), duration: s(1)), TimeRange(start: s(6), duration: s(2))]
        let removed = try tl.removeCuts(cuts, tracks: [vt.id, at.id])
        #expect(removed == s(3))
        for t in tl.tracks { #expect(t.end == s(7)); #expect(t.clips.count == 3) }
        #expect(tl.tracks[1].clips.map(\.source.start) == [.zero, s(3), s(8)])
        #expect(tl.tracks[1].clips.map(\.start) == [.zero, s(2), s(5)])
    }

    @Test func aLockedTrackRefusesTheWholeEdit() throws {
        let a = audio()
        var at = Track(kind: .audio); try at.overwrite(a)
        at.isLocked = true
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [at])
        let before = tl
        #expect(throws: (any Error).self) { try tl.removeCuts([TimeRange(start: s(2), duration: s(1))], tracks: [at.id]) }
        #expect(tl == before)
    }

    @Test func clipSourceRangeMapsThroughSpeed() {
        var c = audio(10, 10)
        #expect(c.timelineRange(forSource: TimeRange(start: s(2), duration: s(3))) == TimeRange(start: s(12), duration: s(3)))
        #expect(c.timelineRange(forSource: TimeRange(start: s(20), duration: s(3))) == nil)
        c.reversed = true
        #expect(c.timelineRange(forSource: TimeRange(start: s(2), duration: s(3))) == TimeRange(start: s(15), duration: s(3)))
    }
}
