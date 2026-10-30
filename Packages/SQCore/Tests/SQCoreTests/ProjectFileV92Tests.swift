import Foundation
import Testing
@testable import SQCore

// v92: Motion's Anti-flicker Filter (`ClipAnimation.antiFlicker`, 0...1), written only when above 0 or keyed.

private func project(_ antiFlicker: Double?) -> Project {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    if let antiFlicker { c.animation.antiFlicker = AnimatedProperty(antiFlicker) }
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 25)),
                                                    tracks: [Track(kind: .video, clips: [c])])])
}

@Suite struct ProjectFileV92Tests {
    @Test func defaultWritesNoKeyAndNoVersionBump() throws {
        let p = project(nil)
        #expect(ProjectFile.v92Version == 92 && ProjectFile.currentVersion >= 92)
        #expect(!p.containsV92Content && ProjectFile.writtenVersion(for: p) < 92)
        #expect(!String(decoding: try ProjectFile.encode(p), as: UTF8.self).contains("antiFlicker"))
    }

    @Test func setValueWritesV92AndRoundTrips() throws {
        let p = project(0.6)
        #expect(p.containsV92Content && ProjectFile.writtenVersion(for: p) == 92)
        let data = try ProjectFile.encode(p)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m)
            #expect(back.timelines[0].tracks[0].clips[0].animation.antiFlicker.value == 0.6)
        }
    }

    @Test func keyedCountsAndFilterIsClamped() {
        var a = ClipAnimation()
        #expect(!a.isAntiFlickerSetOrKeyed && a.antiFlickerStrength(atLocal: .zero) == 0)
        a.antiFlicker = AnimatedProperty(3.0)
        #expect(a.antiFlickerStrength(atLocal: .zero) == 1)
        a.antiFlicker = AnimatedProperty(-1.0)
        #expect(a.antiFlickerStrength(atLocal: .zero) == 0)
        a.antiFlicker = AnimatedProperty(0.0)
        a.antiFlicker.track.keys = [Keyframe(time: .zero, value: 0.5)]
        #expect(a.isAntiFlickerSetOrKeyed)
    }

    @Test func replaceMotionCopiesIt() {
        var src = project(0.4).timelines[0].tracks[0].clips[0]
        var dst = project(nil).timelines[0].tracks[0].clips[0]
        dst.replaceMotion(with: src)
        #expect(dst.animation.antiFlicker.value == 0.4)
        src.animation.antiFlicker = AnimatedProperty(0.0)
        dst.replaceMotion(with: src)
        #expect(dst.animation.antiFlicker.value == 0)
    }
}

@Suite struct AntiFlickerEffectsTests {
    @Test func clipEffectsCarryTheStrengthOnlyWhenAboveZero() {
        var c = project(nil).timelines[0].tracks[0].clips[0]
        #expect(c.effects(at: .zero).antiFlicker == 0 && c.effects(at: .zero).isIdentity)
        c.animation.antiFlicker = AnimatedProperty(0.5)
        let fx = c.effects(at: .zero)
        #expect(fx.antiFlicker == 0.5 && !fx.isIdentity)
        c.animation.antiFlicker = AnimatedProperty(9.0)
        #expect(c.effects(at: .zero).antiFlicker == 1)
    }
}
