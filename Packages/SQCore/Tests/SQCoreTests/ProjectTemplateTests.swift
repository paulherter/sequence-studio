import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectTemplateTests {
    @Test func verticalTemplateIsOneStepToA916Project() throws {
        // One click on the 9:16 card: a single call yields a ready project (format set and locked, 3V + 3A).
        let t = try #require(ProjectTemplate.builtIn.first { $0.id == ProjectTemplate.vertical.id })
        let p = t.makeProject(name: "Reel")
        let tl = try #require(p.timelines.first)
        #expect(p.name == "Reel")
        #expect(tl.format.width == 1080 && tl.format.height == 1920)
        #expect(tl.formatLocked)
        #expect(tl.tracks.filter { $0.kind == .video }.count == 4)
        #expect(tl.tracks.filter { $0.kind == .audio }.count == 4)
        #expect(tl.deliveryTarget?.platform == .tiktok)
    }

    @Test func horizontalTemplateIs169() {
        let tl = ProjectTemplate.horizontal.makeProject(name: "x").timelines[0]
        #expect(tl.format.width == 1920 && tl.format.height == 1080)
    }

    @Test func variantsTemplateAddsVariants() {
        let tl = ProjectTemplate.variants.makeProject(name: "x").timelines[0]
        #expect(tl.format.height == 1920)
        #expect(tl.variants.map { [$0.width, $0.height] } == [[1920, 1080], [1080, 1080]])
    }

    @Test func builtInIDsAreUnique() {
        #expect(Set(ProjectTemplate.builtIn.map(\.id)).count == ProjectTemplate.builtIn.count)
    }

    @Test func templateFromTimelineRoundTrips() throws {
        var tl = Timeline(name: "S", format: SequenceFormat(width: 1080, height: 1350, frameDuration: Time(1, 25)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 4))
        try tl.addVariant(name: "Wide", width: 1920, height: 1080)
        let t = ProjectTemplate(capturing: tl, name: "Mine")
        let back = try JSONDecoder().decode(ProjectTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        let made = back.makeProject(name: "P").timelines[0]
        #expect(made.format.height == 1350 && made.format.frameDuration == Time(1, 25))
        #expect(made.tracks.filter { $0.kind == .audio }.count == 4)
        #expect(made.variants.count == 1)
    }

    @Test func trackCountsAreClamped() {
        var t = ProjectTemplate.vertical
        t.videoTracks = 99; t.audioTracks = -3
        let tl = t.makeProject(name: "x").timelines[0]
        #expect(tl.tracks.filter { $0.kind == .video }.count == ProjectTemplate.maxTracks)
        #expect(tl.tracks.filter { $0.kind == .audio }.isEmpty)
    }

    @Test func folderStoresAndListsUserTemplates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = TemplateFolder(url: dir)
        var t = ProjectTemplate.vertical; t.id = "user-1"; t.name = "Mine"
        try folder.save(t)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("bad.sqtemplate"))
        #expect(folder.load() == [t])        // unreadable files are skipped
        try folder.delete(t)
        #expect(folder.load().isEmpty)
    }
}

@Suite struct TemplateValidationTests {
    private func tmp() -> (TemplateFolder, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tplv-\(UUID().uuidString)")
        return (TemplateFolder(url: dir), dir)
    }

    @Test func invalidTemplatesAreRefused() {
        var t = ProjectTemplate.vertical
        t.id = "u1"
        #expect(throws: ProjectTemplate.Invalid.self) { var x = t; x.name = "  "; try x.validate() }
        #expect(throws: ProjectTemplate.Invalid.self) { var x = t; x.format.width = 0; try x.validate() }
        #expect(throws: ProjectTemplate.Invalid.self) { var x = t; x.format.height = -5; try x.validate() }
        #expect(throws: ProjectTemplate.Invalid.self) { var x = t; x.variants = [.init(name: "v", width: 0, height: 10)]; try x.validate() }
        #expect(throws: Never.self) { try t.validate() }
        let (f, dir) = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bad = t; bad.name = ""
        #expect(throws: ProjectTemplate.Invalid.self) { try f.save(bad) }
    }

    @Test func loadSkipsInvalidAndFixesCollidingIDs() throws {
        let (f, dir) = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ t: ProjectTemplate) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(t).write(to: dir.appendingPathComponent(name + ".sqtemplate"))
        }
        var a = ProjectTemplate.vertical; a.id = ProjectTemplate.horizontal.id; a.name = "A"       // collides with a built-in
        var b = ProjectTemplate.vertical; b.id = "dup"; b.name = "B"
        var c = ProjectTemplate.vertical; c.id = "dup"; c.name = "C"                                // collides with B
        var bad = ProjectTemplate.vertical; bad.id = "bad"; bad.format.width = 0
        try write("a", a); try write("b", b); try write("c", c); try write("bad", bad)
        let loaded = f.load()
        #expect(loaded.map(\.name) == ["A", "B", "C"])
        let ids = loaded.map(\.id) + ProjectTemplate.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite struct GhostTrackTests {
    @Test func addTrackCreatesTargetedFirstOfKind() {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks(video: 1, audio: 0))
        let a = tl.addTrack(kind: .audio)
        #expect(tl.track(a)?.isTargeted == true)
        let v = tl.addTrack(kind: .video)
        #expect(tl.track(v)?.isTargeted == false)
        #expect(tl.tracks.count == 3)
        #expect(tl.tracks.last?.id == v)
    }
}

@Suite struct TemplateNamingTests {
    @Test func freeNameCountsUpCaseInsensitively() {
        #expect(ProjectTemplate.freeName("Reel", taken: []) == "Reel")
        #expect(ProjectTemplate.freeName("Reel", taken: ["reel"]) == "Reel 2")
        #expect(ProjectTemplate.freeName("Reel", taken: ["Reel", "Reel 2"]) == "Reel 3")
        #expect(ProjectTemplate.freeName("  Reel ", taken: []) == "Reel")
    }

    @Test func builtInNamesAreTakenToo() {
        let n = ProjectTemplate.freeName(ProjectTemplate.vertical.name, taken: ProjectTemplate.builtIn.map(\.name))
        #expect(n != ProjectTemplate.vertical.name)
    }
}

@Suite struct TemplateRenameAndSequenceTests {
    @Test func renameKeepsIdAndRejectsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tplr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = TemplateFolder(url: dir)
        var t = ProjectTemplate.vertical; t.id = "user-r"; t.name = "Old"
        try folder.save(t)
        let renamed = try folder.rename(t, to: "  New  ")
        #expect(renamed.name == "New" && renamed.id == "user-r")
        #expect(folder.load().map(\.name) == ["New"])
        #expect(throws: ProjectTemplate.Invalid.emptyName) { try folder.rename(renamed, to: "  ") }
    }

    @Test func makeSequenceIsUnlockedAndNamed() {
        let tl = ProjectTemplate.variants.makeSequence(name: "Reel")
        #expect(tl.name == "Reel")
        #expect(tl.format == ProjectTemplate.variants.format)
        #expect(tl.variants.count == 2)
        #expect(!tl.formatLocked)
    }
}
