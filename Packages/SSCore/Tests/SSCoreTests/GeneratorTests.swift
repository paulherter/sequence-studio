import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct GeneratorTests {
    private func project() -> (Project, Timeline.ID, Track.ID, Track.ID) {
        let v = Track(kind: .video), a = Track(kind: .audio)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v, a])
        return (Project(name: "P", timelines: [t]), t.id, v.id, a.id)
    }
    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }
    private let data = Data("hello".utf8)

    @Test func addPlacesGeneratorClip() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(2), track: v, duration: s(3))
        let c = clip(p, tl, id)
        #expect(c.generator == GeneratorRef(kind: "text", payload: data, payloadVersion: 1))
        #expect(c.clipSource == .generator(c.generator!))
        #expect(c.mediaDuration == nil && c.kind == .video && c.isGenerator)
        #expect(c.timeline == TimeRange(start: s(2), duration: s(3)))
        #expect(c.media == id && c.name == "Text")
    }

    @Test func addRefusals() throws {
        var (p, tl, v, a) = project()
        #expect(throws: EditError.wrongTrackKind) { try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: a, duration: s(1)) }
        #expect(throws: EditError.emptyClip) { try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: v, duration: Time(1, 60)) }
        #expect(throws: EditError.timelineNotFound) { try p.addGeneratorClip(kind: "text", payload: data, in: UUID(), at: s(0), track: v, duration: s(1)) }
        #expect(throws: EditError.clipNotFound) { try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: UUID(), duration: s(1)) }
        p.timelines[0].tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: v, duration: s(1)) }
    }

    @Test func updateReplacesPayloadOnly() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(2), track: v, duration: s(3))
        let before = clip(p, tl, id)
        try p.updateGenerator(clipID: id, payload: Data("new".utf8), payloadVersion: 2)
        var after = clip(p, tl, id)
        #expect(after.generator == GeneratorRef(kind: "text", payload: Data("new".utf8), payloadVersion: 2))
        after.generator = before.generator
        #expect(after == before)
        #expect(throws: EditError.clipNotFound) { try p.updateGenerator(clipID: UUID(), payload: data) }
    }

    @Test func updateRefusesMediaClip() throws {
        var (p, tl, v, _) = project()
        let m = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        try p.timelines[0].tracks[0].overwrite(m)
        _ = (tl, v)
        #expect(throws: EditError.clipNotFound) { try p.updateGenerator(clipID: m.id, payload: data) }
    }

    @Test func layerCarriesGeneratorAndLocalTime() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(2), track: v, duration: s(4))
        let l = p.videoLayers(at: s(3), in: tl)
        #expect(l.count == 1)
        #expect(l[0].clip == id && l[0].generator?.kind == "text")
        #expect(l[0].localTime == s(1) && l[0].sourceTime == s(1))
        #expect(p.videoLayers(at: s(6), in: tl).isEmpty)
    }

    @Test func mediaLayerHasNoGenerator() throws {
        var (p, tl, _, _) = project()
        let m = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(2)), start: s(1))
        try p.timelines[0].tracks[0].overwrite(m)
        let l = p.videoLayers(at: Time(3, 2), in: tl)[0]
        #expect(l.generator == nil && l.sourceTime == Time(21, 2) && l.localTime == Time(1, 2))
    }

    @Test func animationUsesClipLocalTime() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(2), track: v, duration: s(4))
        var c = clip(p, tl, id)
        c.animation.opacity.track.insert(Keyframe(time: .zero, value: 0))
        c.animation.opacity.track.insert(Keyframe(time: s(2), value: 1))
        p.timelines[0].tracks[0].replace(c)
        #expect(p.videoLayers(at: s(3), in: tl)[0].transform.opacity == 0.5)
    }

    @Test func tailAndHeadTrimUnbounded() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(5), track: v, duration: s(2))
        var t = p.timelines[0]
        #expect(try t.trim(id, edge: .tail, by: s(100)) == s(100))
        #expect(try t.trim(id, edge: .head, by: s(-3)) == s(-3))      // source.start goes below 0
        let c = t.tracks[0].clips[0]
        #expect(c.start == s(2) && c.source.start == s(-3) && c.source.duration == s(105))
        #expect(try t.trim(id, edge: .head, by: s(-50)) == s(-2))     // timeline start 0 still limits
        p.timelines[0] = t
    }

    @Test func trimRefusesUnderOneFrame() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(5), track: v, duration: s(2))
        var t = p.timelines[0]
        #expect(throws: EditError.emptyClip) { try t.trim(id, edge: .tail, by: s(-2)) }
        let got = try t.trim(id, edge: .tail, by: .zero - s(2) + Time(1, 30))
        #expect(got == .zero - s(2) + Time(1, 30))
        #expect(t.tracks[0].clips[0].source.duration == Time(1, 30))
    }

    @Test func rippleTrimHeadUnbounded() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(5), track: v, duration: s(2))
        var t = p.timelines[0]
        #expect(try t.rippleTrim(id, edge: .head, by: s(-4)) == s(-4))
        #expect(t.tracks[0].clips[0].source.duration == s(6))
    }

    @Test func splitKeepsGenerator() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: v, duration: s(4))
        var t = p.timelines[0]
        try t.tracks[0].split(at: s(2))
        #expect(t.tracks[0].clips.count == 2 && t.tracks[0].clips.allSatisfy { $0.generator?.payload == data })
        p.timelines[0] = t
    }

    @Test func slipIsNoOpForGenerator() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(0), track: v, duration: s(4))
        var t = p.timelines[0]
        #expect(try t.slip(id, by: s(1)) == .zero)
    }

    @Test func insideNestedSequence() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, in: tl, at: s(1), track: v, duration: s(4))
        let seq = try p.nest(clips: [id], in: tl)
        let l = p.videoLayers(at: s(2), in: tl)
        #expect(l.count == 1 && l[0].generator?.kind == "text" && l[0].groups.first?.sequence == seq)
        #expect(l[0].localTime == s(1))
    }

    @Test func codableRoundTripAndV6File() throws {
        var (p, tl, v, _) = project()
        let id = try p.addGeneratorClip(kind: "text", payload: data, payloadVersion: 3, in: tl, at: s(1), track: v, duration: s(4))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ssproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectFile.write(p, to: dir)
        let q = try ProjectFile.read(from: dir)
        #expect(clip(q, tl, id).generator == GeneratorRef(kind: "text", payload: data, payloadVersion: 3))
        #expect(q == p)
    }

    @Test func v5FileMigratesIdentity() throws {
        let obj: ProjectFile.JSONObject = ["formatVersion": 5, "project": ["x": 1]]
        let out = try ProjectFile.migrations[5]!(obj)
        #expect((out["project"] as? ProjectFile.JSONObject)?["x"] as? Int == 1)
    }
}
