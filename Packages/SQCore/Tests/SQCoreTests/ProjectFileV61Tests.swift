import Foundation
import Testing
@testable import SQCore

// v61: Halftone, Tile and Kaleidoscope effect kinds (landed after the v59 gate, missing from the v60 list). A v60 build
// would show them inert and strip them on save; at v61 it refuses the file instead.

private func clipWith(_ kind: String?) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                 start: .zero, mediaDuration: Time(20, 1))
    if let kind { c.effects = [ClipEffect(kind: kind)] }
    return c
}

private func project(_ clip: Clip) throws -> Project {
    var t = Track(kind: .video)
    try t.overwrite(clip)
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                   tracks: [t])])
}

@Suite struct ProjectFileV61Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v61Version == 61)
        #expect(ProjectFile.currentVersion >= 61)
        #expect(ClipEffect.v61Kinds == ["halftone", "tile", "kaleidoscope"])
    }

    @Test func newKindsWriteV61AndRoundTrip() throws {
        for kind in ClipEffect.v61Kinds.sorted() {
            let p = try project(clipWith(kind))
            #expect(p.containsV61Content, "\(kind)")
            #expect(ProjectFile.writtenVersion(for: p) == 61)
            #expect(try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil) == p)

            var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
            layer.effects = [ClipEffect(kind: kind)]
            var g = clipWith(nil)
            g.graphics = GraphicsDocument(layers: [layer])
            #expect(try project(g).containsV61Content, "layer \(kind)")
        }
    }

    @Test func projectsWithoutThemKeepTheirVersion() throws {
        let plain = try project(clipWith(nil))
        #expect(!plain.containsV61Content)
        #expect(ProjectFile.writtenVersion(for: plain) == ProjectFile.stabilizeVersion)
        let blur = try project(clipWith(ClipEffect.gaussianBlurKind))
        #expect(!blur.containsV61Content)
        // v60 content still writes v60.
        let glitch = try project(clipWith("glitchDisplace"))
        #expect(ProjectFile.writtenVersion(for: glitch) == 60)
    }

    @Test func v61WinsOverV60WhenBothPresent() throws {
        var c = clipWith("glitchDisplace")
        c.effects.append(ClipEffect(kind: ClipEffect.kaleidoscopeKind))
        #expect(ProjectFile.writtenVersion(for: try project(c)) == 61)
    }
}
