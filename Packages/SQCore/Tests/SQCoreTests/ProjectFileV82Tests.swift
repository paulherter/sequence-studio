import Foundation
import Testing
@testable import SQCore

// v82: per-sequence channel layout. Defaults are not stored and keep the lower version.
struct ProjectFileV82Tests {
    private func project() -> Project {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        return Project(name: "P", timelines: [t])
    }
    private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    @Test func defaultsStoreNothingAndKeepTheLowerVersion() throws {
        var p = project()
        #expect(!p.containsV82Content)
        let before = try ProjectFile.encode(p)
        p.timelines[0].channelLayout = .mono
        p.timelines[0].channelLayout = .stereo
        #expect(try ProjectFile.encode(p) == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("channelLayout"))
        #expect(ProjectFile.writtenVersion(for: p) < 82)
    }

    @Test func settingsWriteV82AndRoundTrip() throws {
        var p = project()
        p.timelines[0].channelLayout = .mono
        #expect(ProjectFile.writtenVersion(for: p) == 82)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 82)
        for migrations in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: migrations)
            #expect(back == p)
            #expect(back.timelines[0].channelLayout == .mono)
        }
    }

    @Test func aV81BuildRefusesAV82File() throws {
        #expect(ProjectFile.currentVersion >= 82)
        var obj = try json(try ProjectFile.encode(project()))
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil)
        }
    }

    @Test func unknownValuesOpenAsDefaults() throws {
        var obj = try json(try JSONEncoder().encode(Timeline(name: "S", frameDuration: Time(1, 30))))
        obj["channelLayout"] = "surround"
        let t = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(t.channelLayout == .stereo)
    }

    @Test func settingsApplyAndRead() throws {
        var p = project()
        var s = p.timelines[0].settings
        s.channelLayout = .mono
        try p.setSettings(s, of: p.timelines[0].id)
        #expect(p.timelines[0].settings == s)
    }

    // MARK: Pixel shape

    @Test func squareShapeStoresNothingAndKeepsTheLowerVersion() throws {
        var p = project()
        let before = try ProjectFile.encode(p)
        p.timelines[0].format.pixelAspect = PixelAspect(2, 1)!
        p.timelines[0].format.pixelAspect = .square
        #expect(try ProjectFile.encode(p) == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("pixelAspect"))
        #expect(ProjectFile.writtenVersion(for: p) < 82)
    }

    @Test func nonSquareShapeWritesV82AndRoundTrips() throws {
        var p = project()
        p.timelines[0].format.pixelAspect = PixelAspect(4, 3)!
        #expect(p.containsV82Content)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 82)
        for migrations in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: migrations)
            #expect(back == p)
            #expect(back.timelines[0].format.pixelAspect == PixelAspect(4, 3)!)
        }
    }

    @Test func brokenShapeValuesOpenAsSquare() throws {
        for bad in [[0, 1], [1, 0], [-2, 1], [1, -1], [9, 1], [1, 9]] {
            var obj = try json(try JSONEncoder().encode(Timeline(name: "S", frameDuration: Time(1, 30))))
            var f = obj["format"] as! [String: Any]
            f["pixelAspect"] = ["num": bad[0], "den": bad[1]]
            obj["format"] = f
            let t = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: obj))
            #expect(t.format.pixelAspect == .square)
            #expect(t.format.pixelAspectStore == nil)
        }
    }

    @Test func aV81BuildRefusesAFileWithAShape() throws {
        var p = project()
        p.timelines[0].format.pixelAspect = PixelAspect(2, 1)!
        let version = try json(try ProjectFile.encode(p))["formatVersion"] as? Int
        // The gate is the file version: a reader whose newest version is 81 refuses 82 (see aV81BuildRefusesAV82File).
        #expect(version == 82)
    }

    @Test func monoLawAveragesAndNeverClips() {
        #expect(ChannelLayout.fold(1, 1) == 1)          // full-scale correlated input stays at full scale
        #expect(ChannelLayout.fold(-1, -1) == -1)
        #expect(ChannelLayout.fold(0.5, -0.5) == 0)
        #expect(ChannelLayout.fold(0.8, 0) == 0.4)
        #expect(ChannelLayout.stereo.channelCount == 2 && ChannelLayout.mono.channelCount == 1)
    }
}
