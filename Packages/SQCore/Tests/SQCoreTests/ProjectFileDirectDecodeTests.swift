import Foundation
import Testing
@testable import SQCore

/// Open speed (PLAYBACK-PERF "UI speed"): a file whose remaining migrations are all identity is decoded straight from its
/// bytes (one JSON pass instead of parse, re-serialize, decode), with the same result as the migration path.
@Suite struct ProjectFileDirectDecodeTests {
    func sample() throws -> Project {
        let m = MediaRef(name: "a.mov", path: "/x/a.mov", bookmark: Data([1, 2, 3]),
                         fingerprint: MediaFingerprint(size: 42, modified: Date(timeIntervalSince1970: 1_700_000_000.25), headHash: "ab"),
                         duration: Time(1001, 30000))
        var c = Clip(name: "v ✓", media: m.id, kind: .video, source: TimeRange(start: Time(1001, 30000), duration: Time(2002, 30000)),
                     start: Time(0, 1), mediaDuration: m.duration)
        c.animation.opacity.value = 0.123456789012345
        var vt = Track(kind: .video)
        try vt.overwrite(c)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1001, 30000), tracks: [vt])])
        p.add(m)
        return p
    }

    @Test func currentFilesDecodeDirectlyWithTheSameResult() throws {
        let data = try ProjectFile.encode(sample())
        let direct = try #require(ProjectFile.decodeDirect(data))
        #expect(direct == (try ProjectFile.decode(data, migrations: ProjectFile.migrations)))
        #expect(try ProjectFile.decode(data, migrations: nil) == direct)
    }

    @Test func filesNeedingARealMigrationTakeTheMigrationPath() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectFile.encode(sample())) as? ProjectFile.JSONObject)
        obj["formatVersion"] = ProjectFile.identityMigrationsFrom - 1
        #expect(ProjectFile.decodeDirect(try JSONSerialization.data(withJSONObject: obj)) == nil)
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(ProjectFile.decodeDirect(newer) == nil)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(newer, migrations: nil)
        }
        #expect(ProjectFile.decodeDirect(Data("{\"formatVersion\":51,\"project\":5}".utf8)) == nil)
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.decode(Data("{\"formatVersion\":51,\"project\":5}".utf8), migrations: nil) }
    }

    /// The direct path relies on every step from `identityMigrationsFrom` on leaving the object as it is.
    @Test func everyStepFromTheIdentityVersionOnIsIdentity() throws {
        let obj = try #require(try JSONSerialization.jsonObject(with: ProjectFile.encode(sample())) as? ProjectFile.JSONObject)
        let before = try JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)
        for v in ProjectFile.identityMigrationsFrom..<ProjectFile.currentVersion {
            let step = try #require(ProjectFile.migrations[v])
            #expect(try JSONSerialization.data(withJSONObject: step(obj), options: .sortedKeys) == before, "v\(v)")
        }
    }
}
