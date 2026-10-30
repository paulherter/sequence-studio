import AVFoundation
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import SQText
import Testing
@testable import SQExport

@Suite(.serialized) struct RenderCacheSegmentWriterTests {
    @Test func rendersOneSegmentToAnIntraFileOfTheRightLength() async throws {
        var spec = TestClipSpec()
        spec.width = 320; spec.height = 180; spec.frameCount = 90
        let src = try await TestClipWriter.write(spec)
        let id = UUID()
        let resolver = StaticMediaResolver(demuxers: [id: try await AVDemuxer(url: src)])
        let fd = Time(1, 30)
        let video = Clip(name: "v", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "HI", style: TextStyle(size: 60, weight: .bold)), animations: nil)
        let text = Clip(name: "text", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                        start: Time(1, 2), generator: ref)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [video]), Track(kind: .video, clips: [text])])
        let segs = RenderCachePlan.segments(of: tl, context: RenderCacheContext(rendererID: "t", workingSpace: "rec709"))
        let heavy = try #require(segs.first { $0.isHeavy })
        #expect(heavy.range == TimeRange(start: Time(1, 2), duration: Time(1, 1)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await RenderCacheSegmentWriter.write(segment: heavy, timeline: tl, sequences: [:], resolver: resolver, to: url)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 320 && Int(size.height) == 180)
        let secs = try await asset.load(.duration).seconds
        #expect(abs(secs - 1.0) < 0.05)
    }
}
