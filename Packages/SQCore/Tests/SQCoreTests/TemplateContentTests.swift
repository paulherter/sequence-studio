import Foundation
import Testing
@testable import SQCore

/// A template keeps the media-free part of the sequence (titles, emoji, adjustment layers and their element transitions),
/// so a new project starts with the maintainer's title already in place and only the text is replaced.
@Suite struct TemplateContentTests {
    private let fd = Time(1, 30)

    /// V1 talking head (media), V2 + V3 title lines (text generators, Move In on V2), V4 emoji, A1 music; one marker.
    private func templateSequence() throws -> (Project, Timeline.ID, line1: Clip.ID, line2: Clip.ID, media: Clip.ID) {
        let tl = Timeline(name: "Template", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                          tracks: Timeline.defaultTracks(video: 4, audio: 1))
        var p = Project(name: "P", timelines: [tl])
        let v = tl.tracks.filter { $0.kind == .video }.map(\.id)
        let a = tl.tracks.filter { $0.kind == .audio }.map(\.id)
        let mediaID = UUID()
        let head = Clip(name: "Head", media: mediaID, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let music = Clip(name: "Music", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        try p.edit(tl.id) { t in
            try t.tracks[0].overwrite(head)
            let ai = t.tracks.firstIndex { $0.id == a[0] }!
            try t.tracks[ai].overwrite(music)
            t.markers.append(Marker(time: Time(1, 1), name: "m"))
            t.tracks[1].name = "Title"
        }
        let l1 = try p.addGeneratorClip(kind: GeneratorRef.text, payload: Data("one".utf8), name: "Line 1", in: tl.id, at: .zero,
                                        track: v[1], duration: Time(3, 1))
        let l2 = try p.addGeneratorClip(kind: GeneratorRef.text, payload: Data("two".utf8), name: "Line 2", in: tl.id, at: .zero,
                                        track: v[2], duration: Time(3, 1))
        _ = try p.addGeneratorClip(kind: GeneratorRef.text, payload: Data("emoji".utf8), name: "Emoji", in: tl.id, at: .zero,
                                   track: v[3], duration: Time(3, 1))
        try p.edit(tl.id) { t in
            _ = try t.addElementTransitions(kind: .move, track: v[1], clip: l1, edges: [.head], duration: Time(15, 30))
        }
        return (p, tl.id, l1, l2, head.id)
    }

    @Test func capturingKeepsGeneratorClipsAndDropsMedia() throws {
        let (p, id, l1, l2, head) = try templateSequence()
        let tl = try #require(p.timelines.first { $0.id == id })
        let t = ProjectTemplate(capturing: tl, name: "Mine")
        let content = try #require(t.content)
        let clips = content.tracks.flatMap(\.clips)
        #expect(Set(clips.map(\.id)) == Set([l1, l2]).union(clips.filter { $0.name == "Emoji" }.map(\.id)))
        #expect(clips.count == 3)
        #expect(!clips.contains { $0.id == head })
        #expect(clips.allSatisfy { $0.generator != nil })
        // Track layout stays (names too), element transitions on kept clips stay, markers go.
        #expect(content.tracks.count == tl.tracks.count)
        #expect(content.tracks[1].name == "Title")
        #expect(content.tracks.flatMap(\.transitions).count == 1)
        #expect(content.markers.isEmpty)
        #expect(t.hasContent)
    }

    @Test func emptySequenceCapturesNoContent() {
        let tl = Timeline(name: "S", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                          tracks: Timeline.defaultTracks(video: 2, audio: 2))
        let t = ProjectTemplate(capturing: tl, name: "Plain")
        #expect(t.content == nil)
        #expect(!t.hasContent)
    }

    @Test func newProjectStartsWithTheTitleClips() throws {
        let (p, id, l1, _, _) = try templateSequence()
        let t = ProjectTemplate(capturing: try #require(p.timelines.first { $0.id == id }), name: "Mine")
        let made = t.makeProject(name: "Video 12")
        let tl = try #require(made.timelines.first)
        #expect(made.name == "Video 12")
        #expect(tl.id != id)
        #expect(tl.name == "Sequence 01")
        #expect(tl.formatLocked)
        #expect(tl.format.height == 1920)
        #expect(tl.tracks.filter { $0.kind == .video }.count == 4)
        #expect(tl.tracks.filter { $0.kind == .audio }.count == 1)
        #expect(tl.tracks.flatMap(\.clips).count == 3)
        #expect(tl.tracks.flatMap(\.clips).contains { $0.id == l1 })
        #expect(tl.tracks.flatMap(\.transitions).count == 1)
        #expect(tl.inOut == nil)
    }

    @Test func contentRoundTripsThroughTheTemplateFolder() throws {
        let (p, id, _, _, _) = try templateSequence()
        let t = ProjectTemplate(capturing: try #require(p.timelines.first { $0.id == id }), name: "Mine")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tplc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = TemplateFolder(url: dir)
        try folder.save(t)
        let back = try #require(folder.load().first)
        #expect(back == t)
        #expect(back.makeProject(name: "x").timelines[0].tracks.flatMap(\.clips).count == 3)
    }

    @Test func unreadableContentKeepsTheTemplate() throws {
        // A newer build may store content this build cannot read: the template still loads, just without the clips.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectTemplate.vertical)) as! [String: Any]
        json["content"] = ["garbage": true]
        let data = try JSONSerialization.data(withJSONObject: json)
        let t = try JSONDecoder().decode(ProjectTemplate.self, from: data)
        #expect(t.content == nil)
        #expect(t.format == ProjectTemplate.vertical.format)
    }

    @Test func summaryNamesTheClips() throws {
        let (p, id, _, _, _) = try templateSequence()
        let t = ProjectTemplate(capturing: try #require(p.timelines.first { $0.id == id }), name: "Mine")
        #expect(t.summary.contains("3 graphics"))
    }
}
