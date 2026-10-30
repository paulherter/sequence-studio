import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor private func makeSession() -> EditorSession {
    var music = Track(kind: .audio); music.audioRole = .music
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), music])
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

/// N8b: the project's live ducking setting and the per-track opt-out are one undo step each and reach the engine.
@MainActor @Suite struct LiveDuckingSessionTests {
    @Test func projectSettingIsOneUndoStepAndReachesTheEngine() throws {
        let ses = makeSession()
        let engine = try #require(ses.engine as? StubProgramEngine)
        let on = ProjectLiveDucking(isOn: true, amountDB: 12)
        ses.setProjectLiveDucking(on)
        #expect(ses.project.liveDucking == on)
        #expect(ses.effectiveLiveDucking?.amountDB == 12)
        #expect(engine.projectDuckings.last == on)
        #expect(ses.undo())
        #expect(ses.project.liveDucking == nil)
        #expect(engine.projectDuckings.last == .some(nil))
        ses.setProjectLiveDucking(ProjectLiveDucking(isOn: false))
        #expect(ses.effectiveLiveDucking == nil)
    }

    @Test func trackOptOutIsOneUndoStep() {
        let ses = makeSession()
        let music = ses.activeTimeline!.tracks[1].id
        let video = ses.activeTimeline!.tracks[0].id
        #expect(!ses.setTrackExcludedFromLiveDucking(video, true))
        #expect(ses.setTrackExcludedFromLiveDucking(music, true))
        #expect(ses.activeTimeline!.tracks[1].isExcludedFromLiveDucking)
        #expect(!ses.setTrackExcludedFromLiveDucking(music, true))
        #expect(ses.undo())
        #expect(!ses.activeTimeline!.tracks[1].isExcludedFromLiveDucking)
    }

    @Test func bakeWritesKeysExcludesTheMusicTrackAndIsOneUndoStep() throws {
        func clip(_ start: Int64, _ len: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(len, 1)), start: Time(start, 1))
        }
        var dialogue = Track(kind: .audio, clips: [clip(10, 5)]); dialogue.audioRole = .dialogue
        var music = Track(kind: .audio, clips: [clip(0, 60)]); music.audioRole = .music
        let musicID = music.id
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [dialogue, music])
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        #expect(ses.bakeLiveDucking(LiveDucking(amountDB: 0)) == 0)       // off: nothing to bake
        ses.setProjectLiveDucking(ProjectLiveDucking(isOn: true, amountDB: 12))
        let added = ses.bakeLiveDucking()
        #expect(added > 0)
        let baked = try #require(ses.activeTimeline?.tracks.first { $0.id == musicID })
        #expect(baked.isExcludedFromLiveDucking)
        #expect(baked.clips[0].duckKeyIDs.count == added)
        #expect(ses.undo())
        let back = try #require(ses.activeTimeline?.tracks.first { $0.id == musicID })
        #expect(!back.isExcludedFromLiveDucking && back.clips[0].animation.volume.track.isEmpty)
    }

    private func clip(_ start: Int64, _ len: Int64) -> Clip {
        Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(len, 1)), start: Time(start, 1))
    }

    @Test func bakeLiveDuckToKeysWithLiveOnWritesTheLiveKeysAndNeverDucksTwice() throws {
        var dialogue = Track(kind: .audio, clips: [clip(10, 5)]); dialogue.audioRole = .dialogue
        var music = Track(kind: .audio, clips: [clip(0, 60)]); music.audioRole = .music
        let musicID = music.id
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [dialogue, music])
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        let live = LiveDucking(amountDB: 12, fade: Time(1, 2))
        let depth = ses.undoDepth
        let n = ses.bakeLiveDuckToKeys(live: live)
        #expect(n > 0 && ses.undoDepth == depth + 1)                          // one undo step, keys + track exclusion together
        let tl = try #require(ses.activeTimeline)
        #expect(tl.tracks.first { $0.id == musicID }?.isExcludedFromLiveDucking == true)
        #expect(LiveDucking.duckedClipIDs(in: tl).isEmpty && LiveDucking.clipsDuckingTwice(in: tl).isEmpty)
        let c = try #require(tl.tracks.first { $0.id == musicID }?.clips.first)
        #expect(abs(c.animation.volume.value(atLocal: Time(12, 1)) - pow(10, -12.0 / 20)) < 1e-6)
        #expect(ses.undo())
        let back = try #require(ses.activeTimeline?.tracks.first { $0.id == musicID })
        #expect(!back.isExcludedFromLiveDucking && back.clips[0].animation.volume.track.keys.isEmpty)
    }

    /// Audit C18: a Music-tagged clip on a track without a role is live-ducked (role = tag ?? track role), so the bake keys it
    /// once with the live amount; the keys take it out of live ducking (its track has no Music role, so nothing is excluded).
    @Test func taggedMusicClipOnAnotherTrackIsBakedOnceAndLeavesLiveDuckingByItsKeys() throws {
        var d = clip(10, 5); d.audioTag = .dialogue
        var voice = Track(kind: .audio, clips: [d]); voice.audioRole = .dialogue
        var bed = clip(0, 60); bed.audioTag = .music
        let other = Track(kind: .audio, clips: [bed])                              // no role: the clip tag makes it Music
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [voice, other])
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        let n = ses.bakeLiveDuckToKeys(live: LiveDucking(amountDB: 9, fade: Time(1, 2)))
        #expect(n > 0)
        let c = try #require(ses.activeTimeline?.tracks[1].clips.first)
        #expect(abs(c.animation.volume.value(atLocal: Time(12, 1)) - pow(10, -9.0 / 20)) < 1e-6)   // one duck, not two
        #expect(c.duckKeyIDs.count == n)
        let tl = try #require(ses.activeTimeline)
        #expect(tl.tracks.allSatisfy { !$0.isExcludedFromLiveDucking })
        #expect(LiveDucking.duckedClipIDs(in: tl).isEmpty)
        // Bake Again gives the same keys (the same live ranges).
        let before = c.animation.volume
        #expect(ses.bakeLiveDuckToKeys(live: LiveDucking(amountDB: 9, fade: Time(1, 2))) == n)
        let again = try #require(ses.activeTimeline?.tracks[1].clips.first)
        for probe in [Time(9, 1), Time(12, 1), Time(31, 2), Time(20, 1)] {
            #expect(abs(again.animation.volume.value(atLocal: probe) - before.value(atLocal: probe)) < 1e-9)
        }
    }

    /// Audit C18: with live ducking off (old Auto Duck), an untagged clip on a Music-role track is a target and untagged clips
    /// on a Dialogue-role track duck it.
    @Test func autoDuckUsesTrackRoleForUntaggedClips() throws {
        var voice = Track(kind: .audio, clips: [clip(10, 5)]); voice.audioRole = .dialogue
        var music = Track(kind: .audio, clips: [clip(0, 60)]); music.audioRole = .music
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [voice, music])
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        #expect(ses.musicDuckTargets.map(\.id) == [t.tracks[1].clips[0].id])
        #expect(ses.dialogueRanges { _ in [] } == [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        ses.setProjectLiveDucking(ProjectLiveDucking(isOn: false))                // project setting off beats Preferences
        let n = ses.bakeLiveDuckToKeys(live: nil, amountDB: 12, fade: Time(1, 2))
        #expect(n > 0)
        let c = try #require(ses.activeTimeline?.tracks[1].clips.first)
        #expect(abs(c.animation.volume.value(atLocal: Time(12, 1)) - pow(10, -12.0 / 20)) < 1e-6)
        #expect(ses.activeTimeline?.tracks.allSatisfy { !$0.isExcludedFromLiveDucking } == true)   // live off: nothing excluded
    }

    @Test func oldAutoDuckKeysUnderLiveDuckingAreReportedAndRemovedInOneStep() throws {
        var dialogue = Track(kind: .audio, clips: [clip(10, 5)]); dialogue.audioRole = .dialogue
        var m = clip(0, 60)
        m.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        var music = Track(kind: .audio, clips: [m]); music.audioRole = .music
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [dialogue, music])
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        #expect(ses.clipsDuckingTwice.isEmpty)                                    // live ducking off: nothing doubles
        ses.setProjectLiveDucking(ProjectLiveDucking(isOn: true, amountDB: 12))
        #expect(ses.clipsDuckingTwice == [m.id])
        let depth = ses.undoDepth
        #expect(ses.removeKeysDuckingTwice() == 1 && ses.undoDepth == depth + 1)
        #expect(ses.clipsDuckingTwice.isEmpty)
        #expect(ses.activeTimeline?.tracks[1].clips[0].animation.volume.track.keys.isEmpty == true)
        #expect(ses.activeTimeline?.tracks[1].isExcludedFromLiveDucking == false)  // live ducking stays the one duck
        #expect(ses.undo() && ses.clipsDuckingTwice == [m.id])
    }

    @Test func choicesListPreferencesOffAndAmounts() {
        let c = ProjectLiveDuckingChoices.choices(current: nil, preferences: nil)
        #expect(c[0].title == "Use Preferences (Off)" && c[0].setting == nil)
        #expect(c[1].setting?.isOn == false)
        #expect(c.count == 2 + LiveDucking.amountChoices.count)
        let odd = ProjectLiveDucking(isOn: true, amountDB: 7.5)
        let c2 = ProjectLiveDuckingChoices.choices(current: odd, preferences: nil)
        #expect(c2.contains { $0.title == "Duck Music by 7.5 dB" })
        #expect(c2[ProjectLiveDuckingChoices.index(of: odd, in: c2)].setting == odd)
        #expect(ProjectLiveDuckingChoices.index(of: ProjectLiveDucking(isOn: false, amountDB: 9), in: c2) == 1)
        #expect(ProjectLiveDuckingChoices.index(of: nil, in: c2) == 0)
    }
}
