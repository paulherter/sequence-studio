import Foundation
import Testing
@testable import SQCore

// v93: per-clip log handling (`LogMode`), `TargetSpace` and the HDR conform switch on the footage interpretation.

private func project(_ f: ClipFootageColor) -> Project {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    c.footageColor = f
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 25)),
                                                    tracks: [Track(kind: .video, clips: [c])])])
}

@Suite struct ProjectFileV93Tests {
    @Test func defaultsWriteNoKeysAndNoBump() throws {
        let p = project(ClipFootageColor())
        #expect(ProjectFile.v93Version == 93 && ProjectFile.currentVersion >= 93)
        #expect(!p.containsV93Content && ProjectFile.writtenVersion(for: p) < 93)
        let s = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        for k in ["logMode", "targetSpace", "hdrConform"] { #expect(!s.contains(k)) }
    }

    @Test func nonDefaultRoundTripsAsV93() throws {
        var f = ClipFootageColor()
        f.logMode = .builtIn; f.targetSpace = .rec2020PQ; f.hdrConform = false
        let p = project(f)
        #expect(p.containsV93Content && ProjectFile.writtenVersion(for: p) == 93)
        let data = try ProjectFile.encode(p)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m).timelines[0].tracks[0].clips[0]
            #expect(back.footageColor == f)
            #expect(back.color.logMode == .builtIn && back.color.targetSpace == .rec2020PQ && !back.color.hdrConform)
        }
    }

    @Test func eachFieldAloneGatesTheVersion() {
        var a = ClipFootageColor(); a.logMode = .off
        var b = ClipFootageColor(); b.targetSpace = .rec2020HLG
        var c = ClipFootageColor(); c.hdrConform = false
        for f in [a, b, c] { #expect(project(f).containsV93Content) }
    }

    @Test func inspectorEditWritesTheFields() {
        var clip = project(ClipFootageColor()).timelines[0].tracks[0].clips[0]
        let base = clip.color
        var edited = base
        edited.logMode = .off; edited.targetSpace = .rec2020; edited.hdrConform = false
        let ok = clip.setColor(edited, editedFrom: base, atLocal: .zero)
        #expect(ok)
        #expect(clip.footageColor.logMode == .off && clip.footageColor.targetSpace == .rec2020 && !clip.footageColor.hdrConform)
    }

    @Test func offTreatsLogAsDisplayReferred() {
        var c = ClipColor(source: .appleLog)
        #expect(c.effectiveSource(mediaSpace: nil) == .appleLog)
        c.logMode = .off
        #expect(c.effectiveSource(mediaSpace: nil) == .rec709)
        c.source = nil
        #expect(c.effectiveSource(mediaSpace: .logC4WideGamut4) == .rec709)
        // HDR transfer curves are not log: the mode does not touch them (hdrConform is their switch).
        #expect(c.effectiveSource(mediaSpace: .hlgBT2020) == .hlgBT2020)
        #expect(c.effectiveSource(mediaSpace: .pqBT2020) == .pqBT2020)
        #expect(ColorSpaceID.sLog3SGamut3Cine.isLog && !ColorSpaceID.rec709.isLog)
    }

    @Test func builtInIgnoresTheInputLUTOfTheFirstEffect() {
        var c = ClipColor()
        #expect(c.usesInputLUT)
        c.logMode = .builtIn
        #expect(!c.usesInputLUT)
        c.logMode = .off
        #expect(!c.usesInputLUT)
    }
}
