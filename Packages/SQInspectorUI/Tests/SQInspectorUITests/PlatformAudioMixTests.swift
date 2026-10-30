import Testing
import AppKit
import SQCore
import SQAudioFX
import SQMedia
import SQPlayback
@testable import SQInspectorUI

@MainActor
@Suite struct TrackRoleInspectorTests {
    @Test func pickingARoleLoadsItsVoicedPresetInOneUndoStep() {
        let m = TrackAudioInspectorModel()
        var begins = 0, ends = 0, roles: [AudioTag?] = [], changes: [TrackAudioPreset] = []
        m.onBeginChange = { begins += 1 }; m.onEndChange = { ends += 1 }
        m.onRoleChange = { roles.append($0) }; m.onChange = { changes.append($0) }
        m.setRole(.dialogue)
        #expect(m.role == .dialogue)
        #expect(m.selectedPresetID == "builtin.role.dialogue")
        #expect(m.compressor == TrackAudioPreset.forRole(.dialogue).compressor)
        #expect(m.noiseReduction == TrackAudioPreset.forRole(.dialogue).noiseReduction)
        #expect(!m.isModified)
        #expect(begins == 1 && ends == 1)
        #expect(roles == [.dialogue])
        #expect(changes.isEmpty)        // the role is not reported as an explicit preset
    }

    @Test func theRolePresetIsListedOnlyWhileTheRoleIsSet() {
        let m = TrackAudioInspectorModel()
        m.setRole(.music)
        #expect(m.presets.map(\.id) == ["builtin.off", "builtin.voice", "builtin.music", "builtin.role.music"])
        m.setRole(nil)
        #expect(m.presets.map(\.id) == ["builtin.off", "builtin.voice", "builtin.music"])
        #expect(m.selectedPresetID == TrackAudioPreset.off.id)
    }

    @Test func pickingTheSameRoleAgainDoesNothing() {
        let m = TrackAudioInspectorModel(role: .sfx)
        #expect(m.selectedPresetID == "builtin.role.sfx")
        var calls = 0
        m.onRoleChange = { _ in calls += 1 }
        m.setRole(.sfx)
        #expect(calls == 0)
    }

    @Test func rolePopupTitles() {
        #expect(TrackAudioInspectorModel.roleTitles == ["None", "Dialogue", "Music", "SFX"])
    }
}

@Suite struct LoudnessTargetTests {
    @Test func defaultTargetIsMinus14LUFSAndMinus1DBTP() {
        let t = LoudnessTarget.default
        #expect(t.lufs == -14 && t.truePeakDB == -1)
        #expect(LoudnessTarget(delivery: nil) == .default)
    }

    @Test func followsTheSequenceDeliveryTarget() {
        let d = DeliveryTarget(platform: .youtube, targetLUFS: -16, truePeakDB: -2)
        let t = LoudnessTarget(delivery: d)
        #expect(t.lufs == -16 && t.truePeakDB == -2)
    }

    @Test func labelNamesTheTarget() {
        #expect(LoudnessTarget.default.label == "Target -14 LUFS / -1 dBTP")
        #expect(LoudnessTarget(lufs: -16.5, truePeakDB: -1.5).label == "Target -16.5 LUFS / -1.5 dBTP")
    }

    @Test func overTargetAndOverCeiling() {
        let t = LoudnessTarget.default
        #expect(t.isOverTarget(-12.9) && !t.isOverTarget(-13.1) && !t.isOverTarget(nil))
        #expect(t.isOverCeiling(-0.5) && !t.isOverCeiling(-1) && !t.isOverCeiling(-.infinity))
    }

    @MainActor @Test func meterViewKeepsItsTarget() {
        let v = LoudnessMeterView()
        #expect(v.target == .default)
        v.target = LoudnessTarget(lufs: -16, truePeakDB: -2)
        #expect(v.target.lufs == -16)
    }
}

@MainActor @Suite struct TrackRoleSessionTests {
    @Test func roleIsSavedOnTheTrackInOneUndoStep() {
        let tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        let id = sess.activeTimeline!.tracks[1].id
        let depth = sess.undoDepth
        #expect(sess.setTrackAudioRole(id, role: .music))
        #expect(sess.activeTimeline!.tracks[1].audioRole == .music && sess.undoDepth == depth + 1)
        #expect(!sess.setTrackAudioRole(id, role: .music))                                  // unchanged: no step
        #expect(!sess.setTrackAudioRole(sess.activeTimeline!.tracks[0].id, role: .dialogue))  // video track: refused
        sess.undo()
        #expect(sess.activeTimeline!.tracks[1].audioRole == nil)
    }
}

@MainActor @Suite struct TrackRoleUndoTests {
    @Test func undoOfTheRoleRestoresInspectorAndEngine() throws {
        let c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        var tr = Track(kind: .audio)
        try tr.overwrite(c)
        tr.audioRole = .music
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [tr])]))
        let id = sess.activeTimeline!.tracks[0].id
        let feeder = AudioFeeder(timeline: sess.activeTimeline!, ring: RingBuffer(capacity: 1 << 12), blockFrames: 256) { _ in
            MemoryAudioSource(mono: [0]) }
        let view = ClipSectionsView(session: sess)
        view.onAudioPresetChange = { feeder.setPreset(track: $0, preset: $1) }
        func refresh() { view.sync([.project]); feeder.setTimeline(sess.activeTimeline!) }
        sess.select(clips: [c.id])
        refresh()
        let model = try #require(view.audioModels[id])
        #expect(model.role == .music)

        model.setBand(0) { $0.gainDB = 5 }          // hand tweak: explicit preset
        #expect(view.audioPresets[id] != nil)
        model.setRole(.dialogue)
        refresh()
        #expect(view.audioPresets[id] == nil)        // the role is not stored as an explicit preset
        #expect(feeder.effectivePreset(track: id) == .forRole(.dialogue))

        sess.undo()
        refresh()
        #expect(model.role == .music && model.selectedPresetID == "builtin.role.music")
        #expect(feeder.effectivePreset(track: id) == .forRole(.music))

        model.setRole(.dialogue)                     // picking it again works
        refresh()
        #expect(sess.activeTimeline!.tracks[0].audioRole == .dialogue)
        #expect(feeder.effectivePreset(track: id) == .forRole(.dialogue))
    }
}
