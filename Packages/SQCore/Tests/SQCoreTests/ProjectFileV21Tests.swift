import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectFileV21Tests {
    @Test func v21MigrationIsIdentity() throws {
        let obj: ProjectFile.JSONObject = ["formatVersion": 20, "project": ["name": "P"] as ProjectFile.JSONObject]
        let step = try #require(ProjectFile.migrations[20])
        let out = try step(obj)
        #expect(NSDictionary(dictionary: out).isEqual(to: obj))
    }

    @Test func captionStyleAndKaraokeSurviveASaveAndLoad() throws {
        var tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let word = CaptionWord(text: "hi", range: TimeRange(start: .zero, end: Time(1, 2)))
        let id = try tl.replaceCaptions([CaptionItem(lines: ["hi"], range: TimeRange(start: .zero, end: Time(1, 1)),
                                                     styleRef: "outline", styleOverridden: true, words: [word])])
        try tl.setCaptionStyle(styleRef: "tiktok", track: id)
        try tl.setCaptionKaraoke(KaraokeStyle(keepSpoken: true), track: id)
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        let t = try #require(back.timelines.first?.captionTracks.first)
        #expect(t.styleRef == "tiktok" && t.karaoke == KaraokeStyle(keepSpoken: true))
        #expect(t.items[0].styleOverridden && t.items[0].styleRef == "outline" && t.items[0].words == [word])
    }
}
