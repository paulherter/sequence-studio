import Foundation
import Testing
@testable import SQCore

// v64: Trails, Outline and Long Shadow effect kinds. A v63 build would show them inert and strip them on save; at v64 it
// refuses the file instead. Files without them are written exactly as before.

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

@Suite struct ProjectFileV64Tests {
    @Test func versionConstantAndKinds() {
        #expect(ProjectFile.v64Version == 64)
        #expect(ProjectFile.currentVersion >= 64)
        #expect(ClipEffect.v64Kinds == [ClipEffect.trailsKind, ClipEffect.outlineKind, ClipEffect.longShadowKind])
    }

    @Test func newKindsWriteV64AndRoundTrip() throws {
        for kind in ClipEffect.v64Kinds.sorted() {
            let p = try project(clipWith(kind))
            #expect(p.containsV64Content, "\(kind)")
            #expect(ProjectFile.writtenVersion(for: p) == 64)
            let data = try ProjectFile.encode(p)
            #expect(try ProjectFile.decode(data, migrations: nil) == p)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(obj["formatVersion"] as? Int == 64)
            #expect(obj["appFormat"] as? Int == ProjectFile.currentVersion)

            var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
            layer.effects = [ClipEffect(kind: kind)]
            var g = clipWith(nil)
            g.graphics = GraphicsDocument(layers: [layer])
            #expect(try project(g).containsV64Content, "layer \(kind)")
        }
    }

    /// Without the new kinds nothing changes: the same version and the same bytes as a v63 build writes.
    @Test func projectsWithoutThemKeepTheirVersionAndBytes() throws {
        let plain = try project(clipWith(nil))
        #expect(!plain.containsV64Content)
        #expect(ProjectFile.writtenVersion(for: plain) == ProjectFile.stabilizeVersion)
        let glow = try project(clipWith(ClipEffect.glowKind))
        #expect(!glow.containsV64Content)
        #expect(ProjectFile.writtenVersion(for: try project(clipWith("kaleidoscope"))) == 61)
        // The only byte that could differ is appFormat (the writing build), which a v63 build ignores on read.
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(glow)) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == ProjectFile.writtenVersion(for: glow))
        obj["appFormat"] = 63
        let asV63 = try JSONSerialization.data(withJSONObject: obj)
        #expect(try ProjectFile.decode(asV63, migrations: ProjectFile.migrations) == glow)
    }

    @Test func v64WinsOverOlderGates() throws {
        var c = clipWith("kaleidoscope")
        c.effects.append(ClipEffect(kind: ClipEffect.outlineKind))
        #expect(ProjectFile.writtenVersion(for: try project(c)) == 64)
    }

    /// A v63 file (no new kinds) opens and reads the same.
    @Test func v63FileStillOpens() throws {
        let p = try project(clipWith(ClipEffect.glowKind))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 63
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    @Test func olderBuildRefusesANewerFile() throws {
        let p = try project(clipWith(ClipEffect.trailsKind))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
