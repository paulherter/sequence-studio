import Foundation
import Testing
@testable import SQCore

// v85: per-edge Follow padding (`GraphicsFollow.edgePadding`). A v84 build would drop it; at v85 it refuses the file.

private func project(_ follow: GraphicsFollow?) throws -> Project {
    let v1 = Track(kind: .video)
    let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
    var p = Project(name: "P", timelines: [t])
    var a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    a.setShapeSize(width: 200, height: 100)
    var b = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    b.follow = follow.map { f in var f = f; if case .layer = f.target { f.target = .layer(id: a.id) }; return f }
    _ = try p.addGraphicsClip(in: t.id, at: .zero, track: v1.id, duration: Time(3, 1), layers: [a, b])
    return p
}

@Suite struct ProjectFileV85Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v85Version == 85)
        #expect(ProjectFile.currentVersion >= 85)
    }

    @Test func edgePaddingWritesV85AndRoundTrips() throws {
        var f = GraphicsFollow(target: .layer(id: UUID()), padding: 10)
        f.setPadding(40, for: .left)
        #expect(f.edgePadding == GraphicsEdgePadding(left: 40, top: 10, right: 10, bottom: 10))
        let p = try project(f)
        let data = try ProjectFile.encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 85)
        for m in [nil, ProjectFile.migrations] {
            #expect(try ProjectFile.decode(data, migrations: m) == p)
        }
    }

    @Test func uniformFollowKeepsV63AndNoKey() throws {
        var f = GraphicsFollow(target: .frame, padding: 10)
        f.setPadding(40, for: .left)
        f.setPadding(10, for: .left)   // four equal values collapse
        #expect(f.edgePadding == nil && f.padding == 10)
        let data = try ProjectFile.encode(try project(f))
        #expect(!String(decoding: data, as: UTF8.self).contains("edgePadding"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 63)
    }

    /// A v84 file (one padding) opens and reads the same.
    @Test func v84FileStillOpens() throws {
        let p = try project(GraphicsFollow(target: .frame, padding: 24))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 84
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try ProjectFile.decode(old, migrations: ProjectFile.migrations) == p)
    }

    @Test func perEdgePaddingPlacesEachEdge() {
        var a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        a.setShapeSize(width: 200, height: 100)
        var b = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        var f = GraphicsFollow(target: .layer(id: a.id), padding: 10)
        f.edgePadding = GraphicsEdgePadding(left: 10, top: 20, right: 30, bottom: 40)
        b.follow = f
        let d = GraphicsDocument(layers: [a, b]).resolvingFollow(atLocal: .zero, canvas: Vec2(1920, 1080), text: nil)
        let r = d.bounds(of: b.id, atLocal: .zero, text: nil)
        let t = d.bounds(of: a.id, atLocal: .zero, text: nil)
        #expect(r != nil && t != nil)
        guard let r, let t else { return }
        #expect(abs(r.minX - (t.minX - 10)) < 1e-6 && abs(r.minY - (t.minY - 20)) < 1e-6)
        #expect(abs(r.maxX - (t.maxX + 30)) < 1e-6 && abs(r.maxY - (t.maxY + 40)) < 1e-6)
    }
}
