import Foundation
import Testing
@testable import SQCore

// G11 review: a title or project template whose graphics follow another layer is written in a format a build without
// Follow refuses (title template) or drops the content of (project template), never draws wrongly. Without Follow the
// bytes stay as before.

private func project(follow: Bool) throws -> (Project, Timeline.ID, Clip.ID) {
    let title = GraphicsLayer(name: "Title", content: .text(ref: GeneratorRef(kind: GeneratorRef.text, payload: Data("{}".utf8))))
    var box = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    if follow { box.follow = GraphicsFollow(target: .layer(id: title.id), padding: 24) }
    let v1 = Track(kind: .video)
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
    var p = Project(name: "P", timelines: [tl])
    let id = try p.addGraphicsClip(in: tl.id, at: .zero, track: v1.id, duration: Time(5, 1), layers: [box, title])
    return (p, tl.id, id)
}

private func json(_ v: some Encodable) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
}

@Suite struct TemplateFollowFormatTests {
    @Test func titleTemplateWithFollowIsFormat3AndRefusedByAnOlderBuild() throws {
        let (p, tl, id) = try project(follow: true)
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "Box title")
        #expect(t.content.containsFollow)
        #expect(try json(t)["formatVersion"] as? Int == 3)
        #expect(try JSONDecoder().decode(TitleTemplate.self, from: JSONEncoder().encode(t)) == t)
        // A build that reads an older format refuses a newer one.
        let err = #expect(throws: TitleTemplateError.self) {
            var o = try json(t); o["formatVersion"] = TitleTemplate.formatVersion + 1
            _ = try JSONDecoder().decode(TitleTemplate.self, from: JSONSerialization.data(withJSONObject: o))
        }
        #expect(err == .newerFormat(found: TitleTemplate.formatVersion + 1, supported: TitleTemplate.formatVersion))
        #expect(TitleTemplate.formatVersion >= 3)          // 4 since Fast Cut attachments

        let (p0, tl0, id0) = try project(follow: false)
        let plain = try TitleTemplate.capture(clips: [id0], in: tl0, of: p0, name: "Plain")
        #expect(plain.writtenFormatVersion < 3)
    }

    @Test func projectTemplateWithFollowWritesItsContentWhereAnOlderBuildDropsIt() throws {
        let (p, tl, _) = try project(follow: true)
        let t = ProjectTemplate(capturing: p.timeline(tl)!, name: "Box")
        let o = try json(t)
        #expect(o["formatVersion"] as? Int == 2)
        #expect(o["content"] == nil && o["contentV2"] != nil)     // a build without Follow sees no content (empty sequence)
        let back = try JSONDecoder().decode(ProjectTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t && back.content?.containsFollow == true)
        // A newer format than this build reads: the content is dropped, the template still loads.
        var newer = o; newer["formatVersion"] = ProjectTemplate.formatVersion + 1
        let n = try JSONDecoder().decode(ProjectTemplate.self, from: JSONSerialization.data(withJSONObject: newer))
        #expect(n.content == nil && n.name == "Box")

        let (p0, tl0, _) = try project(follow: false)
        let plain = try json(ProjectTemplate(capturing: p0.timeline(tl0)!, name: "Plain"))
        #expect(plain["formatVersion"] == nil && plain["content"] != nil && plain["contentV2"] == nil)
    }
}
