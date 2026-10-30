import Foundation
import Metal
import Testing
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

private let fd = Time(1, 30)

/// A file whose media info is the project's (the test clip itself is progressive; only the info calls it interlaced).
private struct FieldFileResolver: MediaResolver {
    let id: UUID
    let source: any Demuxing
    let url: URL
    let colorResolver: LayerColorResolver?

    init(id: UUID, source: any Demuxing, url: URL, info: MediaInfo) {
        self.id = id; self.source = source; self.url = url
        colorResolver = LayerColorResolver(lutProvider: nil) { m in m == id ? info : nil }
    }

    func demuxer(for media: UUID) throws -> any Demuxing {
        guard media == id else { throw MediaResolverError.unknownMedia(media) }
        return source
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
    func fileURL(for media: UUID) -> URL? { media == id ? url : nil }
}

/// Person mattes of interlaced media are precomputed from the frames its decoder shows (deinterlaced with the media
/// item's field order) and stored under a key that names that order; the render loop reads that same key. Progressive
/// media and an item with Deinterlace off keep the key they always had.
@Suite(.serialized) @MainActor struct SubjectMatteFieldsPlaybackTests {
    @Test(arguments: [0, 1, 2]) func readAndPrecomputeAgreeOnTheKey(_ variant: Int) async throws {
        let order: FieldOrder? = variant == 0 ? nil : .topFirst
        let off = variant == 2
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await TestClipWriter.write(TestClipSpec())
        let media = UUID()
        let video = VideoTrackInfo(width: 320, height: 180, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd,
                                   isVariableFrameRate: false, fieldOrder: order, deinterlaceOff: off)
        let resolver = FieldFileResolver(id: media, source: try await AVDemuxer(url: url), url: url,
                                         info: MediaInfo(duration: fd * 60, video: video))
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        var clip = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                        start: .zero, mediaDuration: fd * 60)
        clip.masks = [ClipMask.makeSubject(name: "Subject")]
        engine.setTimeline(Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        let plain = SubjectMattePrecompute.cacheKey(media: media, path: url.path)
        let fields = SubjectMattePrecompute.cacheKey(media: media, path: url.path, deinterlace: .topFirst)
        let expected = variant == 1 ? fields : plain, other = variant == 1 ? plain : fields
        let store = engine.loop.subjectPrecompute.store
        defer { store.remove(key: plain); store.remove(key: fields) }
        engine.seek(to: fd * 37)
        await engine.waitForDecodes()
        engine.tick()
        await engine.loop.subjectPrecompute.waitUntilIdle()
        await engine.loop.subjects.waitUntilIdle()
        #expect(store.times(key: expected).count == 60)
        #expect(store.times(key: other).isEmpty)
        // The read finds what the request stored: a later frame is drawn without a live Vision run.
        let live = engine.loop.subjects.segmentations
        engine.seek(to: fd * 44)
        await engine.waitForDecodes()
        engine.tick()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.segmentations == live)
    }
}
