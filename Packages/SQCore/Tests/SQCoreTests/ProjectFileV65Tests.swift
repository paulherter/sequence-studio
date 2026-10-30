import Foundation
import Testing
@testable import SQCore

// v65: Picture masks (`MaskSource.picture`, `ClipMask.pictureTrack` / `pictureChannel`). A v64 build would read the mask as
// a full-frame path (nothing cut) and drop the link on save; at v65 it refuses the file instead. Files without picture masks
// are written exactly as before.

private func clipWith(_ masks: [ClipMask]) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                 start: .zero, mediaDuration: Time(20, 1))
    c.masks = masks
    return c
}

private func project(_ clip: Clip) throws -> Project {
    var t = Track(kind: .video)
    try t.overwrite(clip)
    let matte = Track(kind: .video)
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                   tracks: [t, matte])])
}

@Suite struct ProjectFileV65Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v65Version == 65)
        #expect(ProjectFile.currentVersion >= 65)
    }

    @Test func pictureMaskWritesV65AndRoundTrips() throws {
        var m = ClipMask.makePicture(track: UUID())
        m.pictureChannel = .brightness
        let p = try project(clipWith([m]))
        #expect(p.containsV65Content)
        #expect(ProjectFile.writtenVersion(for: p) == 65)
        let data = try ProjectFile.encode(p)
        #expect(try ProjectFile.decode(data, migrations: nil) == p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 65)
        // Not picked yet (no track) still gates: the source alone is new.
        #expect(try project(clipWith([ClipMask.makePicture(track: nil)])).containsV65Content)
        // Graphics clips' masks count too.
        var g = clipWith([ClipMask.makePicture(track: UUID())])
        g.graphics = GraphicsDocument(layers: [GraphicsLayer(name: "L", content: .shape(kind: .rectangle))])
        #expect(try project(g).containsV65Content)
    }

    @Test func projectsWithoutThemKeepTheirVersionAndBytes() throws {
        let plain = try project(clipWith([ClipMask.make(.rectangle, name: "Mask (1)")]))
        #expect(!plain.containsV65Content)
        #expect(ProjectFile.writtenVersion(for: plain) < 65)
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(plain)) as? [String: Any])
        obj["appFormat"] = 64
        let asV64 = try JSONSerialization.data(withJSONObject: obj)
        #expect(try ProjectFile.decode(asV64, migrations: ProjectFile.migrations) == plain)
        let json = String(decoding: try ProjectFile.encode(plain), as: UTF8.self)
        #expect(!json.contains("picture"))
    }

    @Test func v65WinsOverOlderGates() throws {
        var c = clipWith([ClipMask.makePicture(track: UUID())])
        c.effects = [ClipEffect(kind: ClipEffect.outlineKind)]
        #expect(ProjectFile.writtenVersion(for: try project(c)) == 65)
    }

    @Test func v64FileStillOpens() throws {
        let p = try project(clipWith([]))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 64
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    /// What a v64 build does with a v65 file: refuses it (the newer-file refusal, here one version past this build).
    @Test func olderBuildRefusesANewerFile() throws {
        let p = try project(clipWith([ClipMask.makePicture(track: UUID())]))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
