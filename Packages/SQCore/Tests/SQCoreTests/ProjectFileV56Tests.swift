import Foundation
import Testing
@testable import SQCore

// v56 gate: effect kinds and options added after the v55 gates (Dynamic Zoom, Date Stamp, Posterize Time, Video Denoise,
// Deflicker, Motion Blur FX, Luma Key, Gate Weave, Scanlines, Chroma Bleed, Tracking Noise, audio De-Reverb / De-Hum / Low Cut /
// Dialogue Leveler, De-Esser options, Crop softness, live ducking timing). Files without them keep their older version.

private let fd30 = Time(1, 30)

private func clip(_ kind: TrackKind, effects: [ClipEffect]) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero, effects: effects)
}

private func project(_ c: Clip, live: ProjectLiveDucking? = nil) throws -> Project {
    var tr = Track(kind: c.kind)
    try tr.overwrite(c)
    var p = Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                    tracks: [tr])])
    p.liveDucking = live
    return p
}

private let newKinds: [String] = [
    ClipEffect.dynamicZoomKind, ClipEffect.dateStampKind, ClipEffect.posterizeTimeKind, ClipEffect.videoDenoiseKind,
    ClipEffect.deflickerKind, ClipEffect.motionBlurKind, ClipEffect.lumaKeyKind, ClipEffect.gateWeaveKind,
    ClipEffect.scanlinesKind, ClipEffect.chromaBleedKind, ClipEffect.trackingNoiseKind,
    ClipEffect.audioDeReverbKind, ClipEffect.audioDeHumKind, ClipEffect.audioLowCutKind, ClipEffect.audioDialogueLevelerKind,
]

@Suite struct ProjectFileV56Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v56Version == 56)
        #expect(ProjectFile.currentVersion >= 56)
    }

    @Test func everyNewKindBumpsToV56AndRoundTrips() throws {
        for k in newKinds {
            let e = try #require(ClipEffect.make(kind: k), "\(k)")
            let p = try project(clip(k.hasPrefix("audio.") ? .audio : .video, effects: [e]))
            #expect(p.containsV56Content, "\(k)")
            #expect(ProjectFile.writtenVersion(for: p) == 56, "\(k)")
            let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
            #expect(back.timelines[0].tracks[0].clips[0].effects == [e], "\(k)")
        }
    }

    @Test func oldKindsKeepTheirVersion() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        let p = try project(clip(.video, effects: [e]))
        #expect(!p.containsV56Content)
        #expect(ProjectFile.writtenVersion(for: p) < 56)
        let a = try #require(ClipEffect.make(kind: ClipEffect.audioCompressorKind))
        #expect(ProjectFile.writtenVersion(for: try project(clip(.audio, effects: [a]))) == ProjectFile.audioEffectsVersion)
    }

    @Test func v56BeatsLowerGates() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.audioDeReverbKind))
        let a = try #require(ClipEffect.make(kind: ClipEffect.audioCompressorKind))
        #expect(ProjectFile.writtenVersion(for: try project(clip(.audio, effects: [a, e]))) == 56)
    }

    @Test func deEsserOptionsGateOnlyWhenChanged() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.audioDeEsserKind))
        #expect(!(try project(clip(.audio, effects: [e]))).containsV56Content)   // defaults sound as before
        e.parameters[ClipEffect.deEssRangeKey] = AnimatedProperty(2)
        #expect(ProjectFile.writtenVersion(for: try project(clip(.audio, effects: [e]))) == 56)
        var f = try #require(ClipEffect.make(kind: ClipEffect.audioDeEsserKind))
        f.parameters[ClipEffect.deEssListenKey] = AnimatedProperty(1)
        #expect(try project(clip(.audio, effects: [f])).containsV56Content)
    }

    @Test func cropSoftnessGatesOnlyWhenSet() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.cropKind))
        #expect(!(try project(clip(.video, effects: [e]))).containsV56Content)
        e.parameters[ClipEffect.cropSoftnessKey] = AnimatedProperty(12)
        #expect(ProjectFile.writtenVersion(for: try project(clip(.video, effects: [e]))) == 56)
    }

    @Test func duckTimingBumpsOnlyWhenNotClassic() throws {
        let c = clip(.video, effects: [])
        #expect(ProjectFile.writtenVersion(for: try project(c, live: ProjectLiveDucking(isOn: true))) == ProjectFile.colorMatchVersion)
        let p = try project(c, live: ProjectLiveDucking(isOn: true, timing: .resolve))
        #expect(ProjectFile.writtenVersion(for: p) == 56)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.liveDucking?.timing == .resolve)
    }

    @Test func graphicsLayerEffectsCount() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.scanlinesKind))
        var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
        layer.effects = [e]
        var c = clip(.video, effects: [])
        c.graphics = GraphicsDocument(layers: [layer])
        #expect(try project(c).containsV56Content)
    }

    /// The written version is above anything an older build supports, so it reports "newer version" instead of dropping data.
    @Test func olderBuildRefusesAV56File() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.dynamicZoomKind))
        let data = try ProjectFile.encode(try project(clip(.video, effects: [e])))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 56)
        var older = obj
        older["formatVersion"] = ProjectFile.currentVersion + 1
        let bumped = try JSONSerialization.data(withJSONObject: older)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(bumped, migrations: nil)
        }
    }
}
