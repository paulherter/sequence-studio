import Foundation
import Testing
@testable import SQCore

/// The easing redesign (v44 linked curves) was reverted on this branch. Files written by builds that had it still hold
/// `Project.easings` and `easeLink` fields on keys, transitions and effects; they must keep opening (the shapes were
/// denormalised into the old fields, so nothing is lost but the link).
@Suite struct EasingRevertFileTests {
    static func project() -> Project {
        let keys = KeyframeTrack<Double>(keys: [
            Keyframe(time: .zero, value: 0, interpolation: .bezier),
            Keyframe(time: Time(1, 1), value: 1, interpolation: .bezier),
        ])
        let fx = ClipEffect(kind: "blur", parameters: ["radius": AnimatedProperty(0, track: keys)])
        var c = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        c.effects = [fx]
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c])])
        return Project(name: "P", timelines: [t])
    }

    /// Adds `easeLink` to every keyed object that looks like a key or an effect.
    static func injectLinks(_ any: Any, link: String) -> Any {
        if var d = any as? [String: Any] {
            for (k, v) in d { d[k] = injectLinks(v, link: link) }
            if d["time"] != nil || d["kind"] != nil { d["easeLink"] = ["id": link] }
            return d
        }
        if let a = any as? [Any] { return a.map { injectLinks($0, link: link) } }
        return any
    }

    @Test func aFileWithLinkedEasingsFromTheRedesignStillOpens() throws {
        let p = Self.project()
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        let link = UUID().uuidString
        var proj = try #require(obj["project"] as? [String: Any])
        proj = try #require(Self.injectLinks(proj, link: link) as? [String: Any])
        proj["easings"] = ["curves": [["id": ["id": link], "name": "Soft landing",
                                       "easing": ["out": ["influence": 0.5, "speed": 0], "in": ["influence": 0.5, "speed": 0]]]]]
        obj["project"] = proj
        obj["formatVersion"] = 46
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back == p)
        // Saving again drops the links and keeps the lowest version that holds the content.
        let again = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(back)) as? [String: Any])
        #expect((again["formatVersion"] as? Int ?? 99) < 44)
        #expect(!String(decoding: try ProjectFile.encode(back), as: UTF8.self).contains("easeLink"))
    }
}
