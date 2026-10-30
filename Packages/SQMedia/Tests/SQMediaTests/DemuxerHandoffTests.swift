import Foundation
import SQMediaTestSupport
import Testing
@testable import SQMedia

// Import speed (PLAYBACK-PERF "Import speed"): the probe's demuxer is handed to the first open of the same file once.
@Suite(.serialized) struct DemuxerHandoffTests {
    @Test func probedDemuxerIsTakenOnceForTheSameFile() async throws {
        var spec = TestClipSpec(); spec.frameCount = 30
        let url = try await TestClipWriter.write(spec)
        DemuxerHandoff.removeAll()
        let (_, info) = try await MediaImporter.probe(url)
        let d = try #require(DemuxerHandoff.take(url))
        #expect(d is AVDemuxer)
        #expect(d.index.count == 30 && info.video != nil)
        #expect(DemuxerHandoff.take(url) == nil)                  // taken once
    }

    @Test func changedFileOrExpiredEntryIsNotHandedOut() async throws {
        let url = try await TestClipWriter.write(TestClipSpec())
        DemuxerHandoff.removeAll()
        let d = try await AVDemuxer(url: url)
        DemuxerHandoff.store(d, for: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        #expect(DemuxerHandoff.take(url) == nil)                  // modified since the probe
        DemuxerHandoff.store(d, for: url, now: Date(timeIntervalSinceNow: -DemuxerHandoff.lifetime - 1))
        #expect(DemuxerHandoff.take(url) == nil)                  // expired
        #expect(DemuxerHandoff.count == 0)
    }
}
