import Foundation
import Testing
@testable import SQCore

/// Audit C18: one audio role. A clip's role is its own tag, else its track's role (`Timeline.role(of:)`), and Live Ducking,
/// Auto Duck (Bake) and Match Loudness all read it.
@Suite struct AudioRoleTests {
    static func clip(_ start: Int64, _ len: Int64, tag: AudioTag? = nil) -> Clip {
        var c = LiveDuckingTests.clip(start, len); c.audioTag = tag; return c
    }
    static func track(_ role: AudioTag?, _ clips: [Clip]) -> Track {
        var t = Track(kind: .audio, clips: clips); t.audioRole = role; return t
    }
    static func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
    let live = LiveDucking(amountDB: 12, fade: Time(1, 2))

    /// Every combination of clip tag and track role resolves to tag ?? role.
    @Test func resolutionTable() {
        let options: [AudioTag?] = [nil, .dialogue, .music, .sfx]
        for tag in options {
            for role in options {
                let c = Self.clip(0, 5, tag: tag)
                let tr = Self.track(role, [c])
                let t = Self.timeline([tr])
                let expected = tag ?? role
                #expect(tr.role(of: c) == expected, "tag \(String(describing: tag)) role \(String(describing: role))")
                #expect(t.role(of: c) == expected, "tag \(String(describing: tag)) role \(String(describing: role))")
            }
        }
    }

    @Test func clipNotInTheTimelineFallsBackToItsTag() {
        let t = Self.timeline([Self.track(.music, [Self.clip(0, 5)])])
        #expect(t.role(of: Self.clip(0, 5, tag: .sfx)) == .sfx)
        #expect(t.role(of: Self.clip(0, 5)) == nil)
    }

    // MARK: Live Ducking

    /// A Music-tagged clip on a track without a role is now live-ducked (before: never).
    @Test func liveDucksMusicTaggedClipOnTrackWithoutRole() {
        let music = Self.clip(0, 100, tag: .music)
        let t = Self.timeline([Self.track(.dialogue, [Self.clip(10, 5)]), Self.track(nil, [music, Self.clip(200, 10)])])
        #expect(LiveDucking.duckedClipIDs(in: t) == [music.id])               // the untagged neighbor stays untouched
        #expect(LiveDucking.dialogueRanges(in: t) == [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
    }

    /// A Dialogue-tagged clip ducks the music even on a track without a role, and a tag beats the track role both ways.
    @Test func clipTagOverridesTrackRoleInLiveDucking() {
        let speech = Self.clip(10, 5, tag: .dialogue)            // on a Music track: speaks, is not ducked
        let bed = Self.clip(0, 100)                              // untagged on a Music track: ducked
        let sting = Self.clip(40, 2, tag: .sfx)                  // SFX-tagged on a Music track: neither
        let t = Self.timeline([Self.track(.music, [bed]), Self.track(nil, [speech]), Self.track(.music, [sting])])
        #expect(LiveDucking.duckedClipIDs(in: t) == [bed.id])
        #expect(LiveDucking.dialogueRanges(in: t) == [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        #expect(LiveDucking.dialogueMedia(in: t) == [speech.media])
    }

    @Test func untaggedClipsOnRoleTracksBehaveAsBefore() {
        let t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        #expect(LiveDucking.duckedClipIDs(in: t) == [t.tracks[1].clips[0].id])
        #expect(LiveDucking.dialogueRanges(in: t) == [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
    }

    @Test func excludedTrackTakesNoPartForAnyOfItsClips() {
        var t = Self.timeline([Self.track(nil, [Self.clip(10, 5, tag: .dialogue)]), Self.track(nil, [Self.clip(0, 100, tag: .music)])])
        t.tracks[0].isExcludedFromLiveDucking = true
        t.tracks[1].isExcludedFromLiveDucking = true
        #expect(LiveDucking.dialogueRanges(in: t).isEmpty)
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty)
    }

    /// The bake keys the tagged clip only; its track has no Music role, so it is not excluded: the keys take the clip out of
    /// live ducking (`ducks(_:on:)`), never ducked twice.
    @Test func bakeDucksTaggedMusicClipOnTrackWithoutRole() {
        let music = Self.clip(0, 100, tag: .music), other = Self.clip(200, 10)
        var t = Self.timeline([Self.track(.dialogue, [Self.clip(10, 5)]), Self.track(nil, [music, other])])
        let ranges = LiveDucking.dialogueRanges(in: t)
        #expect(live.bake(into: &t) > 0)
        let baked = t.tracks[1].clips.first { $0.id == music.id }!
        #expect(abs(baked.animation.volume.value(atLocal: Time(12, 1)) - Double(live.gain(at: Time(12, 1), ranges: ranges))) < 1e-5)
        #expect(t.tracks[1].clips.first { $0.id == other.id }!.duckKeyIDs.isEmpty)
        #expect(t.tracks.allSatisfy { !$0.isExcludedFromLiveDucking })
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty && LiveDucking.clipsDuckingTwice(in: t).isEmpty)
    }

    /// Review finding 3: a Music-tagged bed on a Dialogue track is keyed, the track is never excluded, and untagged VO on it
    /// still ducks the music elsewhere.
    @Test func bakeNeverExcludesADialogueTrack() {
        let bed = Self.clip(50, 20, tag: .music), vo = Self.clip(10, 5)
        let other = Self.clip(0, 100), speech = Self.clip(55, 5)          // speech on a second Dialogue track, under the bed
        var t = Self.timeline([Self.track(.dialogue, [vo, bed]), Self.track(.music, [other]), Self.track(.dialogue, [speech])])
        #expect(live.bake(into: &t) > 0)
        #expect(!t.tracks[0].isExcludedFromLiveDucking && t.tracks[1].isExcludedFromLiveDucking && !t.tracks[2].isExcludedFromLiveDucking)
        #expect(!t.tracks[0].clips.first { $0.id == bed.id }!.duckKeyIDs.isEmpty)
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty)                       // bed keyed, Music track baked
        // A new Music bed added later is ducked live by the untagged VO on the Dialogue track.
        var t2 = t
        t2.tracks.append(Self.track(.music, [Self.clip(0, 30)]))
        #expect(LiveDucking.dialogueRanges(in: t2).first == TimeRange(start: Time(10, 1), duration: Time(5, 1)))
        #expect(LiveDucking.duckedClipIDs(in: t2) == [t2.tracks[3].clips[0].id])
    }

    /// Review finding 5: role-only projects bake exactly as before: every Music-role track still in live ducking is excluded,
    /// also one without clips.
    @Test func bakeExcludesEveryMusicRoleTrackAsBefore() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        t.tracks.append(Self.track(.music, []))
        #expect(live.bake(into: &t) > 0)
        #expect(t.tracks[1].isExcludedFromLiveDucking && t.tracks[2].isExcludedFromLiveDucking)
        #expect(!t.tracks[0].isExcludedFromLiveDucking)
    }

    /// Keys on a Music-role track still duck twice (old behavior, warned); keys on a tagged clip elsewhere take it out of live.
    @Test func clipsDuckingTwiceFollowTheClipRole() throws {
        var tagged = Self.clip(0, 100, tag: .music)
        tagged.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        var onMusic = Self.clip(0, 100)
        onMusic.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        let t = Self.timeline([Self.track(.dialogue, [Self.clip(10, 5)]), Self.track(nil, [tagged]), Self.track(.music, [onMusic])])
        #expect(LiveDucking.clipsDuckingTwice(in: t) == [onMusic.id])
        #expect(LiveDucking.duckedClipIDs(in: t) == [onMusic.id])
    }

    /// Review finding 2: the per-block duck work of the mix (windowed dialogue ranges + the per-segment role check) on a long
    /// timeline (8 tracks x 300 clips) stays far below a 10 ms audio block.
    @Test func perBlockDuckWorkIsCheap() {
        var tracks: [Track] = []
        for k in 0..<8 {
            let role: AudioTag? = k < 3 ? .dialogue : k < 6 ? .music : nil
            tracks.append(Self.track(role, (0..<300).map { Self.clip(Int64($0 * 4), 3, tag: $0 % 7 == 0 ? .music : nil) }))
        }
        let t = Self.timeline(tracks)
        let probe = t.tracks[4].clips[150], probeTrack = t.tracks[4]
        var hits = 0
        // Per block since the duck index (built once per timeline revision in `AudioFeeder.setTimeline`): binary search over
        // the dialogue candidates, one set lookup per segment, into a reused buffer.
        let index = LiveDuckingIndex(t)
        var buf: [TimeRange] = []
        buf.reserveCapacity(64)
        let ms = SQTiming.bestPerIterationMs(iterations: 200) {
            let w = TimeRange(start: Time(600, 1), duration: Time(1, 100))
            index.dialogueRanges(in: t, window: w, silences: nil, into: &buf)
            hits &+= buf.count
            for _ in 0..<16 where index.ducks(clip: probe.id) { hits &+= 1 }
        }
        // The C18 per-block walk (every clip's role field, then the window), what the block did before the index.
        let walk = SQTiming.bestPerIterationMs(iterations: 200) {
            let w = TimeRange(start: Time(600, 1), duration: Time(1, 100))
            hits &+= LiveDucking.dialogueRanges(in: t, window: w).count
            for _ in 0..<16 where LiveDucking.ducks(probe, on: probeTrack) { hits &+= 1 }
        }
        // Reference: the pre-C18 per-block work (dialogue-role tracks only, whole clips copied), same timeline.
        let old = SQTiming.bestPerIterationMs(iterations: 200) {
            let w = TimeRange(start: Time(600, 1), duration: Time(1, 100))
            let audio = t.tracks.filter { $0.kind == .audio && !$0.isMuted }
            for track in audio where track.audioRole == .dialogue {
                for c in track.clips where c.isEnabled && !c.isGenerator {
                    if c.timeline.end < w.start || c.timeline.start > w.end { continue }
                    hits &+= 1
                }
            }
        }
        print("PERF live duck per block (2400 clips): \(String(format: "%.4f", ms)) ms indexed, walk \(String(format: "%.4f", walk)) ms, pre-C18 \(String(format: "%.4f", old)) ms")
        #expect(hits > 0)
        #expect(index.ducks(clip: probe.id) == LiveDucking.ducks(probe, on: probeTrack))
        #expect(ms <= old)                            // no more than the pre-C18 cost (measured: far below it)
    }

    // MARK: Match Loudness

    /// An untagged clip on a Music track gets the Music target (before: Dialogue); a tag still wins.
    @Test func matchLoudnessTargetFollowsTheRole() {
        let untagged = Self.clip(0, 5), sfx = Self.clip(10, 5, tag: .sfx), loose = Self.clip(20, 5)
        let t = Self.timeline([Self.track(.music, [untagged, sfx]), Self.track(nil, [loose])])
        #expect(AudioGain.targetLUFS(for: untagged, in: t) == AudioTag.music.targetLUFS)
        #expect(AudioGain.targetLUFS(for: sfx, in: t) == AudioTag.sfx.targetLUFS)
        #expect(AudioGain.targetLUFS(for: loose, in: t) == AudioTag.dialogue.targetLUFS)   // no role anywhere: dialogue default
    }

    /// The Gain sheet's loudness row starts at the shared role target of the selection, dialogue's when roles differ.
    @Test func loudnessRowTargetIsTheSelectionsRoleTarget() {
        let m1 = Self.clip(0, 5), m2 = Self.clip(10, 5, tag: .sfx), d = Self.clip(20, 5, tag: .dialogue)
        let t = Self.timeline([Self.track(.music, [m1, m2]), Self.track(.dialogue, [d])])
        #expect(AudioGain.targetLUFS(for: [m1, m2], in: t) == -20)
        #expect(AudioGain.targetLUFS(for: [m1, d], in: t) == -14)
        #expect(AudioGain.targetLUFS(for: [], in: t) == -14)
        #expect(DeliveryPlatform.allCases.allSatisfy { $0.loudnessGroup.targetLUFS == AudioTag.dialogue.targetLUFS })
    }
}
