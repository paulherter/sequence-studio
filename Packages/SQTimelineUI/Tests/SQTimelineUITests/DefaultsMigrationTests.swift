import Foundation
import Testing
@testable import SQTimelineUI

@Suite struct DefaultsMigrationTests {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "sq-migration-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    @Test func copiesLegacyKeysAndRemovesTheOldOnes() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let seq = UUID()
        let blob = Data("{\"a\":40}".utf8)
        d.set(blob, forKey: "ss.trackHeights.\(seq.uuidString)")
        d.set(true, forKey: "ss.other")
        d.set(1, forKey: "unrelated")
        #expect(DefaultsMigration.migrateLegacyKeys(in: d) == 2)
        #expect(d.data(forKey: TrackHeightStore.key(seq)) == blob)
        #expect(d.bool(forKey: "sq.other"))
        #expect(d.object(forKey: "ss.trackHeights.\(seq.uuidString)") == nil)
        #expect(d.object(forKey: "ss.other") == nil)
        #expect(d.integer(forKey: "unrelated") == 1)
        #expect(DefaultsMigration.migrateLegacyKeys(in: d) == 0)
    }

    @Test func anExistingNewKeyWins() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        d.set("old", forKey: "ss.k"); d.set("new", forKey: "sq.k")
        DefaultsMigration.migrateLegacyKeys(in: d)
        #expect(d.string(forKey: "sq.k") == "new")
        #expect(d.object(forKey: "ss.k") == nil)
    }

    @Test func migratedHeightsLoadThroughTheStore() throws {
        let (d, cleanup) = try defaults(); defer { cleanup() }
        let seq = UUID(), track = UUID()
        let raw = try JSONEncoder().encode([track.uuidString: 40.0])
        d.set(raw, forKey: "ss.trackHeights.\(seq.uuidString)")
        DefaultsMigration.migrateLegacyKeys(in: d)
        #expect(TrackHeightStore(defaults: d).load(seq)[track] == 40)
    }
}
