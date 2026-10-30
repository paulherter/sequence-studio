import Foundation
import Testing
@testable import SQCore

// Graphic EQ and the Noise Gate hold gate the file at v76: an older build would drop the EQ or close the gate too early.

@Suite struct ProjectFileV76AudioTests {
    private static func project(_ clip: Clip) throws -> Project {
        var t = Track(kind: .audio)
        try t.overwrite(clip)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])])
    }

    private static func add(_ c: inout Clip, _ kind: String) throws -> ClipEffect.ID {
        let id = c.addEffect(kind: kind)
        return try #require(id)
    }

    private static func audioClip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
    }

    @Test func currentVersionIsAtLeast76() { #expect(ProjectFile.currentVersion >= 76) }

    @Test func graphicEQDefaultsAreFlat() throws {
        var c = Self.audioClip()
        let id = try Self.add(&c, ClipEffect.audioGraphicEQKind)
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.audioGraphicEQKind))
        #expect(spec.params.count == 11)
        #expect(spec.params.dropLast().allSatisfy { $0.defaultValue == 0 && $0.range == -12...12 })
        #expect(c.audioFXSteps(atLocal: .zero).first { $0.id == id }?.stage == .graphicEQ(.flat))
        c.setParameter(id, ClipEffect.graphicEQBandKeys[5], to: 40)    // clamped to +12
        guard case .graphicEQ(let v) = c.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("no stage"); return }
        #expect(v[5] == 12 && v[4] == 0)
    }

    @Test func graphicEQWritesV76AndRoundTrips() throws {
        var c = Self.audioClip()
        let id = try Self.add(&c, ClipEffect.audioGraphicEQKind)
        c.setParameter(id, ClipEffect.graphicEQBandKeys[2], to: 4.5)
        let p = try Self.project(c)
        #expect(p.containsV76Content)
        #expect(ProjectFile.writtenVersion(for: p) == 76)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        let e = try #require(back.allClips().first?.effects.first)
        #expect(e.kind == ClipEffect.audioGraphicEQKind)
        #expect(e.scalar(ClipEffect.graphicEQBandKeys[2], atLocal: .zero) == 4.5)
    }

    @Test func gateHoldAboveZeroWritesV76AndRoundTrips() throws {
        var c = Self.audioClip()
        let id = try Self.add(&c, ClipEffect.audioNoiseGateKind)
        #expect(!(try Self.project(c)).containsV76Content)            // a stored hold of 0 is the old behavior
        c.setParameter(id, ClipEffect.gateHoldKey, to: 250)
        let p = try Self.project(c)
        #expect(ProjectFile.writtenVersion(for: p) == 76)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        guard case .noiseGate(_, _, _, _, let hold) = back.allClips()[0].audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("no gate"); return }
        #expect(hold == 250)
    }

    @Test func oldGateWithoutHoldKeyOpensWithZeroHoldAndKeepsItsVersion() throws {
        var c = Self.audioClip()
        let id = try Self.add(&c, ClipEffect.audioNoiseGateKind)
        c.effects[c.effects.firstIndex { $0.id == id }!].parameters[ClipEffect.gateHoldKey] = nil     // a file written before v76
        let p = try Self.project(c)
        #expect(!p.containsV76Content)
        #expect(ProjectFile.writtenVersion(for: p) < 76)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        #expect(back.allClips()[0].audioFXSteps(atLocal: .zero)[0].stage
                == .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 100, rangeDB: 60, holdMs: 0))
    }
}
