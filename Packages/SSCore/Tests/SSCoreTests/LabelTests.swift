import Foundation
import Testing
@testable import SSCore

@Suite struct LabelTests {
    func media(_ name: String, video: Bool, audio: Bool, label: LabelColor? = nil) -> MediaRef {
        let v = video ? VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                       nominalFrameDuration: Time(1001, 30000), isVariableFrameRate: false) : nil
        let a = audio ? AudioTrackInfo(sampleRate: 48000, channels: 2, codec: "aac") : nil
        return MediaRef(name: name, path: "/x/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                        info: MediaInfo(duration: Time(10, 1), video: v, audio: a), label: label)
    }

    func clip(_ m: MediaRef, kind: TrackKind) -> Clip {
        Clip(name: m.name, media: m.id, kind: kind, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
    }

    @Test func sixteenPremiereLabelsInOrder() {
        #expect(LabelColor.allCases.map(\.displayName) == ["Violet", "Iris", "Caribbean", "Lavender", "Cerulean", "Forest", "Rose", "Mango",
                                                           "Purple", "Blue", "Teal", "Magenta", "Tan", "Green", "Brown", "Yellow"])
    }

    @Test func mediaKindsAndDefaults() {
        #expect(media("a", video: true, audio: true).kind == .videoAudio)
        #expect(media("a", video: true, audio: false).kind == .video)
        #expect(media("a", video: false, audio: true).kind == .audio)
        #expect(media("a", video: false, audio: true).defaultLabel == .green)
        #expect(media("a", video: true, audio: true).defaultLabel == .blue)
        let img = MediaRef(name: "p.PNG", path: "/x/p.PNG", fingerprint: MediaFingerprint(size: 1))
        #expect(img.kind == .image)
        #expect(img.effectiveLabel == .violet)
        #expect(media("a", video: true, audio: true, label: .rose).effectiveLabel == .rose)
    }

    @Test func clipInheritsMediaThenTypeDefault() {
        let plain = media("p", video: true, audio: true), tagged = media("t", video: true, audio: true, label: .yellow)
        let p = Project(name: "P", media: [plain, tagged])
        let r = p.labelResolver
        #expect(r.label(for: clip(plain, kind: .video)) == .blue)
        #expect(r.label(for: clip(plain, kind: .audio)) == .green)
        #expect(r.label(for: clip(tagged, kind: .video)) == .yellow)
        #expect(r.label(for: clip(tagged, kind: .audio)) == .yellow)
        var own = clip(tagged, kind: .video); own.label = .teal
        #expect(r.label(for: own) == .teal)
    }

    @Test func nestedAndGeneratorDefaults() {
        let inner = Timeline(name: "Inner", frameDuration: Time(1, 30))
        var p = Project(name: "P", timelines: [inner])
        var nested = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                          start: .zero, sequence: inner.id)
        #expect(p.labelResolver.label(for: nested) == .mango)
        p.timelines[0].label = .cerulean
        #expect(p.labelResolver.label(for: nested) == .cerulean)
        nested.label = .brown
        #expect(p.labelResolver.label(for: nested) == .brown)
        let text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                        generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
        #expect(p.labelResolver.label(for: text) == .magenta)
    }

    @Test func sequenceLabelDefaultsDependOnNesting() {
        let inner = Timeline(name: "Inner", frameDuration: Time(1, 30))
        let nestedClip = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                              start: .zero, sequence: inner.id)
        let outer = Timeline(name: "Outer", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [nestedClip])])
        let p = Project(name: "P", timelines: [outer, inner])
        #expect(p.label(of: .sequence(outer.id)) == .forest)
        #expect(p.label(of: .sequence(inner.id)) == .mango)
    }

    @Test func setLabelAppliesToSelectionAndIgnoresBins() {
        let a = media("a", video: true, audio: true), b = media("b", video: false, audio: true)
        var p = Project(name: "P", media: [a, b], timelines: [Timeline(name: "S", frameDuration: Time(1, 30))])
        let s = p.timelines[0].id
        let first = p.setLabel(.rose, for: [.media(a.id), .sequence(s), .bin(p.rootBin.id)])
        #expect(first)
        #expect(p.media(a.id)?.label == .rose && p.timelines[0].label == .rose && p.media(b.id)?.label == nil)
        let again = p.setLabel(.rose, for: [.media(a.id)])            // unchanged -> false
        #expect(!again)
        #expect(p.items(withLabel: .rose).count == 2)
        #expect(p.items(withLabel: .green) == [.media(b.id)])
        let reset = p.setLabel(nil, for: [.media(a.id)])
        #expect(reset && p.media(a.id)?.label == nil)
    }

    @Test func labelsSurviveCodableAndOldFilesHaveNone() throws {
        var m = media("a", video: true, audio: true, label: .lavender)
        var c = clip(m, kind: .video); c.label = .tan
        var t = Timeline(name: "T", frameDuration: Time(1, 30)); t.label = .iris
        let enc = JSONEncoder(), dec = JSONDecoder()
        #expect(try dec.decode(MediaRef.self, from: enc.encode(m)).label == .lavender)
        #expect(try dec.decode(Clip.self, from: enc.encode(c)).label == .tan)
        #expect(try dec.decode(Timeline.self, from: enc.encode(t)).label == .iris)
        m.label = nil; c.label = nil; t.label = nil
        #expect(!String(decoding: try enc.encode(m), as: UTF8.self).contains("label"))
        #expect(try dec.decode(Clip.self, from: enc.encode(c)).label == nil)
        #expect(try dec.decode(Timeline.self, from: enc.encode(t)).label == nil)
    }

    @Test func v7ProjectMigratesToV8Unchanged() throws {
        let obj: ProjectFile.JSONObject = ["formatVersion": 7, "project": ["x": 1]]
        let out = try ProjectFile.migrateV7toV8(obj)
        #expect((out["project"] as? [String: Int]) == ["x": 1])
    }
}
