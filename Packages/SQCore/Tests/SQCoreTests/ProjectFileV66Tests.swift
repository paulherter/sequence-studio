import Foundation
import Testing
@testable import SQCore

// v66: Sequence Volume (`Timeline.masterVolumeDB`, the output level of the whole sequence after every track). A v65 build
// would play and export such a sequence at 0 dB and drop the level on save; at v66 it refuses the file instead. Sequences at
// 0 dB are written exactly as before (no key, lowest version).

private func project(master: Double = 0, nested: Double = 0) -> Project {
    var top = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                       tracks: [Track(kind: .audio)])
    top.masterVolumeDB = master
    var inner = Timeline(name: "N", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)))
    inner.masterVolumeDB = nested
    return Project(name: "P", timelines: [top, inner])
}

@Suite struct ProjectFileV66Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v66Version == 66)
        #expect(ProjectFile.currentVersion >= 66)
    }

    @Test func defaultIsZeroAndStoresNoKey() throws {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        #expect(t.masterVolumeDB == 0)
        #expect(t.masterGain == 1)
        t.masterVolumeDB = -3
        t.masterVolumeDB = 0
        #expect(t == Timeline(id: t.id, name: "S", frameDuration: Time(1, 30)))
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        #expect(!json.contains("masterVolumeDB"))
    }

    @Test func setterClampsToTheFaderRange() {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        t.setMasterVolume(99)
        #expect(t.masterVolumeDB == TrackPan.maxVolumeDB)
        t.setMasterVolume(-500)
        #expect(t.masterVolumeDB == TrackPan.minVolumeDB)
        #expect(t.masterGain == 0)
        t.setMasterVolume(-6.0206)
        #expect(abs(t.masterGain - 0.5) < 1e-4)
        t.setMasterVolume(.nan)
        #expect(t.masterVolumeDB == 0)
        // The property itself clamps too: -inf is silence (the floor), +inf the top, out of range values the ends.
        t.masterVolumeDB = -.infinity
        #expect(t.masterVolumeDB == TrackPan.minVolumeDB && t.masterGain == 0)
        t.masterVolumeDB = .infinity
        #expect(t.masterVolumeDB == TrackPan.maxVolumeDB)
        t.masterVolumeDB = -1e9
        #expect(t.masterVolumeDB == TrackPan.minVolumeDB)
        t.masterVolumeDB = .nan
        #expect(t.masterVolumeDB == 0)
    }

    /// A hand-edited or foreign file with an out-of-range level decodes clamped (JSON has no inf: huge numbers stand in).
    @Test func decodeClampsOutOfRangeLevels() throws {
        let t = Timeline(name: "S", frameDuration: Time(1, 30))
        var obj = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(t)) as? [String: Any])
        for (raw, want) in [(-1e300, TrackPan.minVolumeDB), (1e300, TrackPan.maxVolumeDB), (-3.5, -3.5), (0.0, 0.0)] {
            obj["masterVolumeDB"] = raw
            let back = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: obj))
            #expect(back.masterVolumeDB == want)
        }
    }

    @Test func sequenceVolumeWritesV66AndRoundTrips() throws {
        for p in [project(master: -6), project(nested: 4.5)] {
            #expect(p.containsV66Content)
            #expect(ProjectFile.writtenVersion(for: p) == 66)
            let data = try ProjectFile.encode(p)
            let back = try ProjectFile.decode(data, migrations: nil)
            #expect(back == p)
            #expect(back.timelines.map(\.masterVolumeDB) == p.timelines.map(\.masterVolumeDB))
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(obj["formatVersion"] as? Int == 66)
        }
    }

    @Test func projectsAtZeroKeepTheirVersionAndBytes() throws {
        let plain = project()
        #expect(!plain.containsV66Content)
        #expect(ProjectFile.writtenVersion(for: plain) < 66)
        let data = try ProjectFile.encode(plain)
        #expect(!String(decoding: data, as: UTF8.self).contains("masterVolumeDB"))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["appFormat"] = 65
        let asV65 = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(asV65, migrations: ProjectFile.migrations)
        #expect(back == plain)
        #expect(back.timelines.allSatisfy { $0.masterVolumeDB == 0 })
    }

    @Test func v66WinsOverOlderGates() throws {
        var p = project(master: -2)
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                     start: .zero, mediaDuration: Time(20, 1))
        c.masks = [ClipMask.makePicture(track: UUID())]
        var v = Track(kind: .video)
        try v.overwrite(c)
        p.timelines[0].tracks.append(v)
        #expect(p.containsV65Content)
        #expect(ProjectFile.writtenVersion(for: p) == 66)
    }

    @Test func v65FileStillOpensAtZero() throws {
        let p = project()
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 65
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    /// What a v65 build does with a v66 file: refuses it (the newer-file refusal, here one version past this build).
    @Test func olderBuildRefusesANewerFile() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(project(master: -6))) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
