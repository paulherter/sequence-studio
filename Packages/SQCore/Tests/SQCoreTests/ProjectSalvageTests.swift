import Foundation
import Testing
@testable import SQCore

// Project open salvage: a part of the file that does not decode is dropped and listed; the rest opens.
struct ProjectSalvageTests {
    private func clip(_ name: String, at s: Int, media: UUID = UUID(), effects: [ClipEffect] = []) -> Clip {
        var c = Clip(name: name, media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(Int64(s), 1))
        c.effects = effects
        return c
    }
    private func fixture() -> Project {
        let m = UUID()
        let cs = [clip("A", at: 0, media: m), clip("B", at: 2, media: m), clip("C", at: 4, media: m)]
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: cs)])
        let ref = MediaRef(id: m, name: "m.mov", path: "/x/m.mov", fingerprint: MediaFingerprint(size: 1))
        return Project(name: "P", media: [ref], timelines: [t])
    }
    private func object(_ p: Project) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as! [String: Any]
    }
    private func editClips(_ obj: inout [String: Any], _ edit: (inout [[String: Any]]) -> Void) {
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        var trs = tls[0]["tracks"] as! [[String: Any]]
        var cl = trs[0]["clips"] as! [[String: Any]]
        edit(&cl)
        trs[0]["clips"] = cl; tls[0]["tracks"] = trs; proj["timelines"] = tls; obj["project"] = proj
    }
    private func salvage(_ obj: [String: Any]) throws -> (project: Project, report: ProjectSalvageReport) {
        try ProjectFile.salvage(try JSONSerialization.data(withJSONObject: obj))
    }

    @Test func aGoodFileSalvagesWithAnEmptyReport() throws {
        let p = fixture()
        let r = try salvage(try object(p))
        #expect(r.report.isEmpty)
        #expect(r.project == p)
    }

    @Test func aBrokenClipIsDroppedAndListed() throws {
        var obj = try object(fixture())
        editClips(&obj) { $0[1]["kind"] = "hologram" }
        #expect(throws: (any Error).self) { try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil) }
        let r = try salvage(obj)
        #expect(r.project.timelines[0].tracks[0].clips.map(\.name) == ["A", "C"])
        #expect(r.report.dropped.count == 1)
        #expect(r.report.dropped[0].contains("B"))
        #expect(r.project.media.count == 1)
    }

    @Test func aBrokenEffectIsDroppedAndTheClipStays() throws {
        let c = clip("A", at: 0, effects: [ClipEffect(kind: ClipEffect.roundedCornersKind)])
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c])])
        var obj = try object(Project(name: "P", timelines: [t]))
        editClips(&obj) { cl in
            var effects = cl[0]["effects"] as! [[String: Any]]
            effects[0]["id"] = "not-a-uuid"
            cl[0]["effects"] = effects
        }
        let r = try salvage(obj)
        #expect(r.project.timelines[0].tracks[0].clips.count == 1)
        #expect(r.project.timelines[0].tracks[0].clips[0].effects.isEmpty)
        #expect(r.report.dropped.filter { $0.hasPrefix("Effect") }.count == 1)
    }

    @Test func aBrokenMediaItemBecomesAnOfflinePlaceholder() throws {
        let p = fixture()
        var obj = try object(p)
        var proj = obj["project"] as! [String: Any]
        var media = proj["media"] as! [[String: Any]]
        media[0]["fingerprint"] = "garbage"
        proj["media"] = media; obj["project"] = proj
        let r = try salvage(obj)
        #expect(r.project.media.count == 1)
        #expect(r.project.media[0].id == p.media[0].id)
        #expect(r.project.media[0].path == "/x/m.mov")
        #expect(r.project.timelines[0].tracks[0].clips.count == 3)
        #expect(r.report.dropped.count == 1)
    }

    @Test func aBrokenSequenceIsDroppedTheRestOpens() throws {
        var p = fixture()
        p.timelines.append(Timeline(name: "Second", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks()))
        var obj = try object(p)
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        tls[1]["format"] = "nope"
        proj["timelines"] = tls; obj["project"] = proj
        let r = try salvage(obj)
        #expect(r.project.timelines.map(\.name) == ["Main"])
        #expect(r.report.dropped.count == 1)
        #expect(r.report.dropped[0].contains("Second"))
    }

    @Test func aFileWithoutAProjectStaysCorrupt() throws {
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.salvage(Data("{}".utf8)) }
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.salvage(Data("nonsense".utf8)) }
    }

    @Test func aNewerFileIsStillRefused() throws {
        var obj = try object(fixture())
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try salvage(obj)
        }
    }

    @Test func readSalvagingNeverWritesTheOriginal() throws {
        var obj = try object(fixture())
        editClips(&obj) { $0[0]["kind"] = "hologram" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-\(UUID().uuidString).sqproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ProjectFile.fileName)
        let bytes = try JSONSerialization.data(withJSONObject: obj)
        try bytes.write(to: file)
        let r = try ProjectFile.readSalvaging(from: dir)
        #expect(r.report.dropped.count == 1)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [ProjectFile.fileName])
    }

    @Test func anAttachmentToADroppedClipIsCleared() throws {
        var obj = try object(fixture())
        editClips(&obj) { cl in
            cl[1]["kind"] = "hologram"                       // B is dropped
            cl[2]["attachment"] = ["host": cl[1]["id"] as! String, "point": cl[2]["start"]!]
        }
        let r = try salvage(obj)
        let clips = r.project.timelines[0].tracks[0].clips
        #expect(clips.map(\.name) == ["A", "C"])
        #expect(clips[1].attachment == nil)
    }

    @Test func aClipOfUnlistedMediaPointsAtAnOfflinePlaceholder() throws {
        var obj = try object(fixture())
        let stray = UUID()
        editClips(&obj) { cl in
            cl[0]["kind"] = "hologram"                       // forces the salvage path
            cl[2]["media"] = stray.uuidString
        }
        let r = try salvage(obj)
        #expect(r.project.media.contains { $0.id == stray })
        #expect(r.project.timelines[0].tracks[0].clips.count == 2)
    }

    @Test func aNestedSequenceClipOfADroppedSequenceIsDropped() throws {
        var p = fixture()
        let second = Timeline(name: "Second", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        p.timelines.append(second)
        var obj = try object(p)
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        tls[1]["format"] = "nope"                            // Second is dropped
        proj["timelines"] = tls; obj["project"] = proj
        editClips(&obj) { $0[1]["sequence"] = second.id.uuidString }
        let r = try salvage(obj)
        #expect(r.project.timelines.map(\.name) == ["Main"])
        #expect(r.project.timelines[0].tracks[0].clips.map(\.name) == ["A", "C"])
    }

    @Test func backUpDamagedKeepsTheOriginalAndNeverOverwritesABackup() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("bak-\(UUID().uuidString)")
        let pkg = parent.appendingPathComponent("P.sqproj")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("one".utf8).write(to: pkg.appendingPathComponent(ProjectFile.fileName))
        let a = try #require(try ProjectFile.backUpDamaged(package: pkg))
        try Data("two".utf8).write(to: pkg.appendingPathComponent(ProjectFile.fileName))
        let b = try #require(try ProjectFile.backUpDamaged(package: pkg))
        #expect(a != b)
        #expect(try Data(contentsOf: a) == Data("one".utf8))
        #expect(try Data(contentsOf: b) == Data("two".utf8))
    }
}
