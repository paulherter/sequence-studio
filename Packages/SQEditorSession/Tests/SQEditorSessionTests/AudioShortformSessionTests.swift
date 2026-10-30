import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@MainActor @Suite struct AudioShortformSessionTests {
    /// Video v (linked to audio a), music m, dialogue d, a third audio x.
    private func make() -> (EditorSession, v: Clip, a: Clip, m: Clip, d: Clip, x: Clip) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        var d = Clip(name: "d", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        let x = Clip(name: "x", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        a.audioTag = nil; m.audioTag = .music; d.audioTag = .dialogue
        var vt = Track(kind: .video), t1 = Track(kind: .audio), t2 = Track(kind: .audio), t3 = Track(kind: .audio), t4 = Track(kind: .audio)
        try! vt.overwrite(v); try! t1.overwrite(a); try! t2.overwrite(m); try! t3.overwrite(d); try! t4.overwrite(x)
        let tl = Timeline(name: "T", frameDuration: fd, tracks: [vt, t1, t2, t3, t4])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), v, a, m, d, x)
    }
    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    @Test func bracketKeysRaiseThreeClipsInOneUndoStep() {
        let (sess, v, a, m, d, _) = make()
        sess.select(clips: [v.id, a.id, m.id, d.id], captions: [])
        let depth = sess.undoDepth
        #expect(sess.nudgeAudioGain(byDB: 1))
        #expect(sess.undoDepth == depth + 1)
        #expect([a, m, d].allSatisfy { clip(sess, $0.id).audioGainDB == 1 })
        #expect(clip(sess, v.id).audioGainDB == 0)                           // video ignored
        #expect(sess.nudgeAudioGain(byDB: 6))
        #expect(clip(sess, a.id).audioGainDB == 7)
        sess.undo(); sess.undo()
        #expect([a, m, d].allSatisfy { clip(sess, $0.id).audioGainDB == 0 })
    }

    @Test func gainStopsAtTheFloorAndDoesNotMute() {
        let (sess, _, a, _, _, _) = make()
        sess.select(clips: [a.id], captions: [])
        for _ in 0..<40 { sess.nudgeAudioGain(byDB: -6) }
        let g = clip(sess, a.id).audioGainDB
        #expect(g == AudioGain.minGainDB)
        #expect(sess.nudgeAudioGain(byDB: 1))
        #expect(clip(sess, a.id).audioGainDB == AudioGain.minGainDB + 1)
        let (s2, v, _, _, _, _) = make()
        s2.select(clips: [v.id], captions: [])
        #expect(!s2.nudgeAudioGain(byDB: 1))                                  // only a video clip: nothing to do
    }

    @Test func trackMixIsClampedAndOneUndoStep() {
        let (sess, _, _, _, _, _) = make()
        let id = sess.activeTimeline!.tracks[1].id
        let depth = sess.undoDepth
        #expect(sess.setTrackMix(id, volumeDB: -200, pan: 4))
        let t = sess.activeTimeline!.tracks[1]
        #expect(t.volumeDB == TrackPan.minVolumeDB && t.pan == 1 && sess.undoDepth == depth + 1)
        #expect(!sess.setTrackMix(sess.activeTimeline!.tracks[0].id, volumeDB: -3, pan: 0))   // video track: refused
        sess.undo()
        #expect(sess.activeTimeline!.tracks[1].volumeDB == 0 && sess.activeTimeline!.tracks[1].pan == 0)
    }

    @Test func trackMixIgnoresNaNAndUnchangedValuesMakeNoUndoStep() {
        let (sess, _, _, _, _, _) = make()
        let id = sess.activeTimeline!.tracks[1].id
        let depth = sess.undoDepth
        #expect(!sess.setTrackMix(id, volumeDB: 0, pan: 0))                    // nothing changes: no undo step
        #expect(sess.undoDepth == depth)
        #expect(!sess.setTrackMix(id, volumeDB: .nan, pan: .nan))              // NaN reads as 0 dB / center (it would also break saving)
        #expect(sess.activeTimeline!.tracks[1].volumeDB == 0 && sess.activeTimeline!.tracks[1].pan == 0)
        #expect(sess.undoDepth == depth)
    }

    @Test func sequenceVolumeIsOneClampedUndoStep() {
        let (sess, _, _, _, _, _) = make()
        let depth = sess.undoDepth
        #expect(sess.setSequenceVolume(-6))
        #expect(sess.activeTimeline!.masterVolumeDB == -6 && sess.undoDepth == depth + 1)
        #expect(sess.setSequenceVolume(40))
        #expect(sess.activeTimeline!.masterVolumeDB == TrackPan.maxVolumeDB)
        #expect(!sess.setSequenceVolume(TrackPan.maxVolumeDB))       // unchanged: no undo step
        #expect(sess.undoDepth == depth + 2)
        sess.undo(); sess.undo()
        #expect(sess.activeTimeline!.masterVolumeDB == 0)
    }

    @Test func sequenceVolumeKeysAtThePlayheadAndFlattensBack() {
        let (sess, _, _, _, _, _) = make()
        let depth = sess.undoDepth
        sess.seekSequence(to: s(1))
        #expect(sess.setSequenceVolume(-12, animate: true))
        #expect(sess.activeTimeline!.isMasterVolumeKeyed && sess.activeTimeline!.masterVolumeDB(at: s(1)) == -12)
        sess.seekSequence(to: s(3))
        #expect(sess.setSequenceVolume(0, animate: true))
        #expect(sess.activeTimeline!.masterVolumeDB(at: s(2)) == -6)
        #expect(sess.undoDepth == depth + 2)
        #expect(sess.setSequenceVolume(-3, animate: false))          // unticked: keys go, the level stays constant
        #expect(!sess.activeTimeline!.isMasterVolumeKeyed && sess.activeTimeline!.masterVolumeDB == -3)
        sess.undo(); sess.undo(); sess.undo()
        #expect(!sess.activeTimeline!.isMasterVolumeKeyed && sess.activeTimeline!.masterVolumeDB == 0)
    }

    private func role(_ s: EditorSession, track i: Int) -> AudioTag? { s.activeTimeline!.tracks[i].audioRole }

    @Test func tagOnAWholeTrackSetsTheTrackRole() {
        // x is the only clip of its track: selecting it selects the whole track, so the Tag is the track's role (C18).
        let (sess, _, _, _, _, x) = make()
        sess.select(clips: [x.id], captions: [])
        let depth = sess.undoDepth
        #expect(sess.toggleAudioTag(.sfx) && role(sess, track: 4) == .sfx && clip(sess, x.id).audioTag == nil)
        #expect(sess.undoDepth == depth + 1)
        #expect(sess.toggleAudioTag(.sfx) && role(sess, track: 4) == nil)                  // the same tag again removes it
        #expect(sess.toggleAudioTag(.music) && role(sess, track: 4) == .music)
        sess.undo(); sess.undo(); sess.undo()
        #expect(role(sess, track: 4) == nil)
    }

    @Test func lockedTrackIsNeverWholeSoItsClipsGetOwnTags() {
        let (sess, _, _, _, _, x) = make()
        #expect(sess.attempt("lock") { t in t.tracks[4].isLocked = true })
        sess.select(clips: [x.id], captions: [])
        let wholeIDs = EditorSession.wholeTracks(of: [x.id], in: sess.activeTimeline!)
        #expect(!wholeIDs.contains(sess.activeTimeline!.tracks[4].id))
    }

    @Test func tagOnSomeClipsOfATrackTagsTheClips() throws {
        let (sess, _, _, _, _, x) = make()
        let x2 = Clip(name: "x2", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(20))
        #expect(sess.attempt("add") { t in try t.tracks[4].overwrite(x2) })
        sess.select(clips: [x.id], captions: [])                                            // x2 stays unselected
        #expect(sess.toggleAudioTag(.sfx) && clip(sess, x.id).audioTag == .sfx && role(sess, track: 4) == nil)
        #expect(sess.toggleAudioTag(.sfx) && clip(sess, x.id).audioTag == nil)
        // Selecting both makes it the track's role again and drops the clip tag the first one had.
        #expect(sess.toggleAudioTag(.music) && clip(sess, x.id).audioTag == .music)
        sess.select(clips: [x.id, x2.id], captions: [])
        #expect(sess.toggleAudioTag(.dialogue) && role(sess, track: 4) == .dialogue)
        #expect(clip(sess, x.id).audioTag == nil && clip(sess, x2.id).audioTag == nil)
    }

    @Test func tagOnSeveralTracksSplitsByCoverage() {
        // m and d sit alone on their tracks (whole tracks), x on a third: one Tag command, one undo step.
        let (sess, _, _, m, d, x) = make()
        sess.select(clips: [m.id, d.id, x.id], captions: [])
        let depth = sess.undoDepth
        #expect(sess.toggleAudioTag(.sfx))
        #expect(role(sess, track: 2) == .sfx && role(sess, track: 3) == .sfx && role(sess, track: 4) == .sfx)
        #expect(clip(sess, m.id).audioTag == nil && clip(sess, d.id).audioTag == nil)
        #expect(sess.undoDepth == depth + 1)
    }

    @Test func tagMenuShowsWhereTheRoleComesFrom() {
        let (sess, _, _, m, _, x) = make()
        sess.select(clips: [x.id], captions: [])
        #expect(sess.audioTagMenuState(.music) == AudioTagMenuState(checked: false, inherited: false))
        #expect(sess.toggleAudioTag(.music))                                   // whole track: x inherits the track's role
        let inherited = sess.audioTagMenuState(.music)
        #expect(inherited.checked && inherited.inherited)
        #expect(inherited.title(for: .music) == "Music (inherits track role)")
        #expect(sess.audioTagMenuState(.sfx).title(for: .sfx) == "SFX")
        // A clip with its own tag shows a plain check mark.
        sess.select(clips: [m.id], captions: [])
        let own = sess.audioTagMenuState(.music)
        #expect(own.checked && !own.inherited && own.title(for: .music) == "Music")
        sess.select(clips: [], captions: [])
        #expect(sess.audioTagMenuState(.music) == AudioTagMenuState(checked: false, inherited: false))
    }

    @Test func removingATagThatWouldNotRemoveTheRoleIsDisabled() {
        let (sess, _, _, _, _, x) = make()
        let x2 = Clip(name: "x2", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(20))
        #expect(sess.attempt("setup") { t in try t.tracks[4].overwrite(x2); t.tracks[4].audioRole = .music })
        // Partial selection, the clip inherits Music: there is no "no role" tag to give it, so the checked item is disabled.
        sess.select(clips: [x.id], captions: [])
        let inherited = sess.audioTagMenuState(.music)
        #expect(inherited.checked && inherited.inherited && !inherited.enabled)
        let depth = sess.undoDepth
        #expect(!sess.toggleAudioTag(.music) && sess.undoDepth == depth)
        // Its own tag equal to the track role: clearing it would leave Music in place, so also disabled.
        #expect(sess.attempt("tag") { t in var c = t.tracks[4].clips[0]; c.audioTag = .music; try t.replaceClip(c) })
        #expect(!sess.audioTagMenuState(.music).enabled && !sess.toggleAudioTag(.music))
        // A different role is still a normal, enabled choice.
        #expect(sess.audioTagMenuState(.sfx).enabled && !sess.audioTagMenuState(.sfx).checked)
        #expect(sess.toggleAudioTag(.sfx) && clip(sess, x.id).audioTag == .sfx)
        // Removing it would hand the clip back to the track's Music: a re-role, so the item is disabled (pick Music instead).
        #expect(!sess.audioTagMenuState(.sfx).enabled && !sess.toggleAudioTag(.sfx))
        #expect(sess.toggleAudioTag(.music) && clip(sess, x.id).audioTag == .music)
    }

    @Test func removingAClipTagOnAWholeTrackNeverReRolesTheClips() {
        // Clips tagged Dialogue on a Music-role track: Remove Dialogue would turn them into Music, so it is disabled.
        let (sess, _, _, _, _, x) = make()
        #expect(sess.attempt("setup") { t in
            var c = t.tracks[4].clips[0]; c.audioTag = .dialogue; try t.replaceClip(c); t.tracks[4].audioRole = .music
        })
        sess.select(clips: [x.id], captions: [])                              // the whole track
        let st = sess.audioTagMenuState(.dialogue)
        #expect(st.checked && !st.inherited && !st.enabled)
        let depth = sess.undoDepth
        #expect(!sess.toggleAudioTag(.dialogue) && sess.undoDepth == depth)
        #expect(clip(sess, x.id).audioTag == .dialogue && role(sess, track: 4) == .music)
    }

    @Test func autoDuckLowersMusicOnlyWhereDialogueIsAndRerunReplaces() {
        let (sess, _, _, m, _, _) = make()
        sess.select(clips: [], captions: [])
        let depth = sess.undoDepth
        // The dialogue clip is silent from 4 s on.
        let n = sess.bakeLiveDuckToKeys(live: LiveDucking(amountDB: 0), clipSilences: { _ in [TimeRange(start: s(4), duration: s(6))] }, amountDB: 12, fade: Time(1, 2))
        #expect(n > 0 && sess.undoDepth == depth + 1)
        let c = clip(sess, m.id)
        #expect(c.volume(at: s(2)) < 0.3 && c.volume(at: s(8)) == 1)
        let n2 = sess.bakeLiveDuckToKeys(live: LiveDucking(amountDB: 0), clipSilences: { _ in [TimeRange(start: s(0), duration: s(6))] }, amountDB: 12, fade: Time(1, 2))
        let c2 = clip(sess, m.id)
        #expect(c2.volume(at: s(2)) == 1 && c2.volume(at: s(8)) < 0.3)
        #expect(c2.animation.volume.track.keys.count == n2)
    }

    @Test func bakedDuckKeysAreCurrentUntilDialogueOrKeysChange() {
        let (sess, _, _, m, _, _) = make()
        sess.select(clips: [], captions: [])
        let live = LiveDucking(amountDB: 0)
        let quiet: (Clip) -> [TimeRange] = { _ in [TimeRange(start: s(4), duration: s(6))] }
        // Nothing baked yet: nothing to overwrite.
        #expect(sess.clipsWithChangedDuckKeys(live: live, clipSilences: quiet, amountDB: 12, fade: Time(1, 2)).isEmpty)
        #expect(sess.bakeLiveDuckToKeys(live: live, clipSilences: quiet, amountDB: 12, fade: Time(1, 2)) > 0)
        // Same dialogue: current.
        #expect(sess.clipsWithChangedDuckKeys(live: live, clipSilences: quiet, amountDB: 12, fade: Time(1, 2)).isEmpty)
        // Dialogue edited (the clip is now silent from 0 s): the keys are stale.
        let moved: (Clip) -> [TimeRange] = { _ in [TimeRange(start: s(0), duration: s(6))] }
        #expect(sess.clipsWithChangedDuckKeys(live: live, clipSilences: moved, amountDB: 12, fade: Time(1, 2)) == [m.id])
        // Asking does not change the sequence or the undo stack.
        let depth = sess.undoDepth, before = sess.activeTimeline!
        _ = sess.clipsWithChangedDuckKeys(live: live, clipSilences: moved, amountDB: 12, fade: Time(1, 2))
        #expect(sess.undoDepth == depth && sess.activeTimeline! == before)
    }

    @Test func handEditedDuckKeyIsReportedBeforeBakeAgain() {
        let (sess, _, _, m, _, _) = make()
        sess.select(clips: [], captions: [])
        let live = LiveDucking(amountDB: 0)
        let quiet: (Clip) -> [TimeRange] = { _ in [TimeRange(start: s(4), duration: s(6))] }
        #expect(sess.bakeLiveDuckToKeys(live: live, clipSilences: quiet, amountDB: 12, fade: Time(1, 2)) > 0)
        #expect(sess.attempt("hand edit") { t in
            var c = t.tracks.flatMap(\.clips).first { $0.id == m.id }!
            c.animation.volume.track.update(c.duckKeyIDs[0]) { $0.value = 0.9 }
            try t.replaceClip(c)
        })
        #expect(sess.clipsWithChangedDuckKeys(live: live, clipSilences: quiet, amountDB: 12, fade: Time(1, 2)) == [m.id])
    }

    @Test func noDialogueNoDuck() {
        let (sess, _, _, m, d, _) = make()
        sess.select(clips: [d.id], captions: [])
        sess.toggleAudioTag(.dialogue)                                       // untag the only dialogue clip
        let depth = sess.undoDepth
        #expect(sess.bakeLiveDuckToKeys(live: LiveDucking(amountDB: 0)) == 0)
        #expect(clip(sess, m.id).animation.volume.track.isEmpty && sess.undoDepth == depth)
    }

    @Test func removingSilencesIsOneUndoStepOnLinkedTracks() {
        let (sess, v, a, _, _, _) = make()
        sess.select(clips: [a.id], captions: [])
        let cuts = sess.silenceCuts(for: [a], silences: { _ in [TimeRange(start: s(2), duration: s(2)), TimeRange(start: s(6), duration: s(3))] },
                                    padding: Time(1, 10))
        #expect(cuts.count == 2)
        let depth = sess.undoDepth
        #expect(sess.removeSilences(cuts: cuts, from: [a]))
        #expect(sess.undoDepth == depth + 1)
        let tl = sess.activeTimeline!
        let removed = cuts.reduce(Time.zero) { $0 + $1.duration }
        #expect(tl.tracks[0].end == s(10) - removed && tl.tracks[1].end == s(10) - removed)    // the picture was cut as well
        #expect(v.id != a.id)
        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].end == s(10))
    }
}

@Suite struct AudioShortformHelpersTests {
    @Test func activeRangesAreTheClipMinusPauses() {
        let r = AudioShortform.activeRanges(of: TimeRange(start: s(10), duration: s(10)),
                                            silences: [TimeRange(start: s(12), duration: s(2)), TimeRange(start: s(18), duration: s(5))])
        #expect(r == [TimeRange(start: s(10), duration: s(2)), TimeRange(start: s(14), duration: s(4))])
        #expect(AudioShortform.activeRanges(of: TimeRange(start: .zero, duration: s(4)), silences: []) == [TimeRange(start: .zero, duration: s(4))])
    }

    @Test func mergedJoinsOverlaps() {
        let r = AudioShortform.merged([TimeRange(start: s(5), duration: s(2)), TimeRange(start: s(1), duration: s(2)), TimeRange(start: s(2), duration: s(2)),
                                       TimeRange(start: s(7), duration: s(1))])
        #expect(r == [TimeRange(start: s(1), duration: s(3)), TimeRange(start: s(5), duration: s(3))])
    }

    @Test func silencesComeFromWaveformPeaks() {
        // Mono, 1000 frames/s, 10 buckets of 1000 frames each = 1 s per bucket: loud, quiet x3, loud.
        let peaks: [Float] = [-0.5, 0.5, -0.001, 0.001, -0.001, 0.001, -0.001, 0.001, -0.5, 0.5]
        let data = WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 5000, baseBucketSize: 1000, levels: [peaks])
        let clip = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(20))
        let r = AudioShortform.silences(of: clip, in: data, thresholdDB: -40, minimumLength: Time(1, 1))
        #expect(r.count == 1)
        #expect(r[0].start == s(21) && r[0].end == s(24))
    }
}
