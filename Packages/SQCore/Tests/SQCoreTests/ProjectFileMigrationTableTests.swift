import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectFileMigrationTableTests {
    @Test func tableHasExactlyOneStepPerOlderVersion() {
        let keys = ProjectFile.migrations.keys.sorted()
        #expect(keys == Array(1..<ProjectFile.currentVersion))
        #expect(ProjectFile.migrations[21] != nil)
    }

    @Test func realStepsAreAllInsideTheTable() {
        for k in ProjectFile.realMigrations.keys { #expect(k >= 1 && k < ProjectFile.currentVersion, "step \(k)") }
    }

    @Test func aFileAtEveryOlderVersionReachesTheCurrentOne() throws {
        let clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        for v in 1..<ProjectFile.currentVersion {
            var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            obj["formatVersion"] = v
            let old = try JSONSerialization.data(withJSONObject: obj)
            let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
            #expect(back.timelines.count == 1, "from v\(v)")
        }
    }
}
