import Foundation
import Testing
@testable import SQCore

/// N4 TwoStyleText: v31 adds the optional `TextStyle.secondLine` inside text payloads. Identity step.
@Suite struct TwoStyleTextFileTests {
    @Test func v31IsCurrentAndV30ToV31IsIdentity() throws {
        #expect(ProjectFile.currentVersion >= 31)
        #expect(ProjectFile.realMigrations[30] == nil)
        let obj: ProjectFile.JSONObject = ["formatVersion": 30, "project": ["name": "P"] as ProjectFile.JSONObject]
        let step = try #require(ProjectFile.migrations[30])
        let out = try step(obj)
        #expect(jsonEqual(out, obj))
    }

    @Test func aV30FileWithATextClipKeepsItsPayloadBytes() throws {
        let payload = Data(#"{"template":{"formatVersion":3,"name":"t","style":{"size":48},"text":"Hi"}}"#.utf8)
        var clip = Clip(name: "Text", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        clip.generator = GeneratorRef(kind: GeneratorRef.text, payload: payload, payloadVersion: 1)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 30
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines.first?.tracks.first?.clips.first?.generator?.payload == payload)
    }
}
