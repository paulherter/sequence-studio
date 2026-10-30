import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct RoleOffsetTests {
    @Test func musicClipGetsTheLongerOffset() {
        func c(_ start: Int64, _ kind: TrackKind, tag: AudioTag? = nil) -> Clip {
            var c = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: Time(5, 1), duration: Time(10, 1)),
                         start: Time(start, 1), mediaDuration: Time(60, 1))
            c.audioTag = tag
            return c
        }
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        try! v.overwrite(c(0, .video)); try! v.overwrite(c(10, .video))
        try! a.overwrite(c(0, .audio, tag: .music)); try! a.overwrite(c(10, .audio, tag: .music))
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v, a])
        let ses = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        ses.seek(to: Time(10, 1))
        #expect(ses.offsetSplitEdit(.jCut, defaults: .standard))
        #expect(ses.activeTimeline!.tracks[1].clips[1].start == Time(10, 1) - Time(1, 30) * 15)
    }
}

@Suite struct AudioRoleDefaultsTests {
    let fd = Time(1, 30)

    @Test func standardOffsetsAndLengthsDifferPerRole() {
        let d = AudioRoleDefaults.standard
        #expect(d.splitOffset(for: .dialogue, frameDuration: fd) == fd * 8)   // 0.25 s = 7.5 frames
        #expect(d.splitOffset(for: nil, frameDuration: fd) == fd * 8)
        #expect(d.splitOffset(for: .music, frameDuration: fd) == fd * 15)     // 0.5 s
        #expect(d.transitionDuration(for: .dialogue, fallbackSeconds: 1, frameDuration: fd) == fd * 3)
        #expect(d.transitionDuration(for: .music, fallbackSeconds: 1, frameDuration: fd) == fd * 30)
        #expect(d.transitionDuration(for: nil, fallbackSeconds: 2, frameDuration: fd) == fd * 60)
    }

    @Test func roundTripAndRejectsBadValues() {
        let suite = UserDefaults(suiteName: "AudioRoleDefaultsTests-\(UUID())")!
        var d = AudioRoleDefaults.standard
        d.splitOffsetSeconds[.sfx] = 0.75
        d.crossfadeKind = .constantGain
        d.save(to: suite)
        suite.set(-3.0, forKey: AudioRoleDefaults.Key.splitOffset(.music))
        suite.set("crossDissolve", forKey: "unused")
        let l = AudioRoleDefaults.load(from: suite)
        #expect(l.splitOffsetSeconds[.sfx] == 0.75)
        #expect(l.splitOffsetSeconds[.music] == 0.5)
        #expect(l.crossfadeKind == .constantGain)
        suite.set("crossDissolve", forKey: AudioRoleDefaults.Key.crossfadeKind)
        #expect(AudioRoleDefaults.load(from: suite).crossfadeKind == .constantPower)
    }
}
