import Foundation
import Testing
@testable import SQCore

// v63: `GraphicsLayer.follow` (G11 Follow). A v62 build would drop the field on decode and draw the follower where it was
// authored; at v63 it refuses the file instead.

private func project(_ layers: [GraphicsLayer]) throws -> Project {
    let v1 = Track(kind: .video)
    let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
    var p = Project(name: "P", timelines: [t])
    _ = try p.addGraphicsClip(in: t.id, at: .zero, track: v1.id, duration: Time(3, 1), layers: layers)
    return p
}

private func follower(_ follow: GraphicsFollow?) -> [GraphicsLayer] {
    let a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    var b = GraphicsLayer.shape(.ellipse, canvasWidth: 1920, canvasHeight: 1080)
    b.follow = follow.map { f in var f = f; if case .layer = f.target { f.target = .layer(id: a.id) }; return f }
    return [a, b]
}

@Suite struct ProjectFileV63Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v63Version == 63)
        #expect(ProjectFile.currentVersion >= 63)
    }

    @Test func followWritesV63AndRoundTrips() throws {
        let p = try project(follower(GraphicsFollow(target: .layer(id: UUID()), edges: [.left, .right], padding: 24)))
        #expect(p.containsV63Content)
        #expect(ProjectFile.writtenVersion(for: p) == 63)
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 63)
        #expect(obj["appFormat"] as? Int == ProjectFile.currentVersion)
        let frame = try project(follower(GraphicsFollow(target: .frame)))
        #expect(ProjectFile.writtenVersion(for: frame) == 63)
    }

    @Test func graphicsWithoutFollowKeepTheirVersion() throws {
        let p = try project(follower(nil))
        #expect(!p.containsV63Content)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.graphicsVersion)
        // The key is absent from the file, so the bytes equal what a v62 build wrote.
        let json = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!json.contains("follow"))
    }

    @Test func v63WinsOverV62() throws {
        var p = try project(follower(GraphicsFollow(target: .frame)))
        try p.edit(p.timelines[0].id) { t in
            var c = t.tracks[0].clips[0]
            c.templateSlots = [TemplateSlot(name: "Text 1", kind: .text, layer: UUID(), graphicsLayer: UUID(), path: "template.text",
                                            value: .text("Hi"))]
            try t.replaceClip(c)
        }
        #expect(p.containsV62Content && p.containsV63Content)
        #expect(ProjectFile.writtenVersion(for: p) == 63)
    }

    /// A v62 file (graphics without the field) opens and reads the same.
    @Test func v62FileStillOpens() throws {
        let p = try project(follower(nil))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 62
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    @Test func olderBuildRefusesANewerFile() throws {
        let p = try project(follower(GraphicsFollow(target: .frame)))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
