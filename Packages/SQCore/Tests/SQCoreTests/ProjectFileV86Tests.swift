import Foundation
import Testing
@testable import SQCore

// v86: keyable Sequence Volume (`Timeline.masterVolumeKeys`, dB keys in sequence time). A v85 build would drop the keys and
// play the static level; at v86 it refuses the file. Sequences without keys keep their lowest version (no key written).

private func project(keys: [(Time, Double)] = [], level: Double = 0) -> Project {
    var top = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                       tracks: [Track(kind: .audio)])
    top.masterVolumeDB = level
    for (t, db) in keys { top.setMasterVolumeKey(at: t, db: db) }
    return Project(name: "P", timelines: [top])
}

@Suite struct ProjectFileV86Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v86Version == 86)
        #expect(ProjectFile.currentVersion >= 86)
    }

    @Test func noKeysKeepsLowestVersionAndNoKey() throws {
        let data = try ProjectFile.encode(project(level: -6))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 66)
        #expect(!String(decoding: data, as: UTF8.self).contains("masterVolumeKeys"))
    }

    @Test func keysWriteV86AndRoundTrip() throws {
        let p = project(keys: [(Time(0, 1), -20), (Time(2, 1), 0)], level: -3)
        let data = try ProjectFile.encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 86)
        for m in [nil, ProjectFile.migrations] {
            #expect(try ProjectFile.decode(data, migrations: m) == p)
        }
    }

    @Test func v85FileStillOpens() throws {
        let p = project(level: -6)
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 85
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try ProjectFile.decode(old, migrations: ProjectFile.migrations) == p)
    }

    @Test func levelInterpolatesBetweenKeys() {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        #expect(!t.isMasterVolumeKeyed)
        #expect(t.masterVolumeDB(at: Time(5, 1)) == 0 && t.masterGain(at: Time(5, 1)) == 1)
        t.masterVolumeDB = -6
        t.setMasterVolumeKey(at: Time(0, 1), db: -20)
        t.setMasterVolumeKey(at: Time(2, 1), db: 0)
        #expect(t.isMasterVolumeKeyed)
        #expect(t.masterVolumeDB(at: Time(0, 1)) == -20)
        #expect(abs(t.masterVolumeDB(at: Time(1, 1)) - -10) < 1e-6)
        #expect(t.masterVolumeDB(at: Time(9, 1)) == 0)        // held after the last key
        #expect(abs(t.masterGain(at: Time(1, 1)) - pow(10, -0.5)) < 1e-9)
        t.setMasterVolumeKey(at: Time(1, 1), db: 500)         // clamped to the fader range
        #expect(t.masterVolumeDB(at: Time(1, 1)) == TrackPan.maxVolumeDB)
    }

    @Test func clearingKeysKeepsTheStaticLevel() {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        t.setMasterVolumeKey(at: Time(0, 1), db: -20)
        t.clearMasterVolumeKeys(keeping: -12)
        #expect(!t.isMasterVolumeKeyed && t.masterVolumeDB == -12)
        #expect(t.masterGain(at: Time(3, 1)) == t.masterGain)
    }

    @Test func removingTheLastKeyUnkeys() {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        let id = t.setMasterVolumeKey(at: Time(0, 1), db: -20)
        t.removeMasterVolumeKey(id)
        #expect(t == Timeline(id: t.id, name: "S", frameDuration: Time(1, 30)))
    }
}
