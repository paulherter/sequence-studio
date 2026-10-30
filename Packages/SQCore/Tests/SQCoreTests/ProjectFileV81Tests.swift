import Foundation
import Testing
@testable import SQCore

// v81: per-sequence timecode start / display and preview quality. Defaults are not stored and keep the lower version.
struct ProjectFileV81Tests {
    private func project() -> Project {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        return Project(name: "P", timelines: [t])
    }
    private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    @Test func defaultsStoreNothingAndKeepTheLowerVersion() throws {
        var p = project()
        #expect(!p.containsV81Content)
        let before = try ProjectFile.encode(p)
        p.timelines[0].timecodeStart = Time(3600, 1)
        p.timelines[0].timecodeStart = .zero
        p.timelines[0].timecodeDisplay = .frames
        p.timelines[0].timecodeDisplay = .timecode
        p.timelines[0].previewQuality = .half
        p.timelines[0].previewQuality = nil
        #expect(try ProjectFile.encode(p) == before)
        let text = String(decoding: before, as: UTF8.self)
        #expect(!text.contains("timecodeStart") && !text.contains("previewQuality"))
        #expect(ProjectFile.writtenVersion(for: p) < 81)
    }

    @Test func settingsWriteV81AndRoundTrip() throws {
        var p = project()
        p.timelines[0].timecodeStart = Time(3600, 1)
        p.timelines[0].timecodeDisplay = .frames
        p.timelines[0].previewQuality = .quarter
        #expect(ProjectFile.writtenVersion(for: p) == 81)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 81)
        for migrations in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: migrations)
            #expect(back == p)
            #expect(back.timelines[0].timecodeStart == Time(3600, 1) && back.timelines[0].timecodeDisplay == .frames)
            #expect(back.timelines[0].previewQuality == .quarter)
        }
    }

    @Test func startIsNeverNegativeAndSnapsToAFrame() {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        t.timecodeStart = Time(-5, 1)
        #expect(t.timecodeStart == .zero)
        t.timecodeStart = Time(7, 60)   // 3.5 frames
        #expect(t.timecodeStart.frameIndex(frameDuration: Time(1, 30)) >= 3)
        #expect(t.timecodeStart == Time(1, 30) * t.timecodeStart.frameIndex(frameDuration: Time(1, 30)))
    }

    @Test func unknownValuesOpenAsDefaults() throws {
        var obj = try json(try JSONEncoder().encode(Timeline(name: "S", frameDuration: Time(1, 30))))
        obj["timecodeDisplay"] = "feet"; obj["previewQuality"] = "eighth"
        let t = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(t.timecodeDisplay == .timecode && t.previewQuality == nil)
    }

    @Test func settingsApplyAndRead() throws {
        var p = project()
        var s = p.timelines[0].settings
        s.timecodeStart = Time(36, 1); s.timecodeDisplay = .frames; s.previewQuality = .half
        try p.setSettings(s, of: p.timelines[0].id)
        #expect(p.timelines[0].settings == s)
    }
}
