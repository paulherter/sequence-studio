import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import SQCore
import SQMedia
import SQExport
import SQPlayback
import SQRender
@testable import SQEditorSession

// Preview render cache: the resolver serves the fake media ID of a cached segment from its .mov, opens it once, and
// forgets it when the file is removed.

private final class FileDemux: Demuxing, @unchecked Sendable {
    let url: URL
    let index = SampleIndex(entries: [SampleIndex.Entry(pts: .zero, dts: .zero, duration: Time(1, 30), isSync: true, decodeOrdinal: 0)])
    let formatDescription: CMFormatDescription
    init(_ url: URL) {
        self.url = url
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
                                       extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
    }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] { [] }
}

@Suite struct RenderCacheResolverTests {
    @Test func theFakeMediaIsServedFromTheCacheFileAndOpenedOnce() throws {
        let opens = Mutex(0)
        let resolver = ProjectMediaResolver(demuxer: { u in opens.withLock { $0 += 1 }; return FileDemux(u) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString).mov")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let media = RenderCacheMedia.id(forKey: "00000000000000010000000000000002")

        #expect(throws: (any Error).self) { _ = try resolver.demuxer(for: media) }
        resolver.setRenderCacheFile(media: media, url: file)
        let a = try resolver.demuxer(for: media)
        let b = try resolver.demuxer(for: media)
        #expect((a as? FileDemux)?.url == file)
        #expect(a as AnyObject === b as AnyObject)
        #expect(opens.withLock { $0 } == 1)

        resolver.removeRenderCacheFile(media: media)
        #expect(throws: (any Error).self) { _ = try resolver.demuxer(for: media) }
    }
}

private final class CacheTestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

@Suite @MainActor struct RenderCacheControllerTests {
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rcc-\(UUID().uuidString)", isDirectory: true) }
    private func timeline(effects: Bool = true) -> Timeline {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero,
                        effects: effects ? [ClipEffect(kind: ClipEffect.gaussianBlurKind)] : [])
        return Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])
    }

    private func make(_ dir: URL, clock: CacheTestClock, playing: Bool = false,
                      render: @escaping RenderCacheController.Renderer) -> (RenderCacheController, ProjectMediaResolver) {
        let resolver = ProjectMediaResolver(demuxer: { FileDemux($0) })
        let inputs = RenderCacheController.Inputs(playhead: { .zero }, isPlaying: { playing }, droppedFrames: { 0 },
                                                  now: { clock.now })
        let c = RenderCacheController(directory: dir, byteCap: 1 << 30, media: resolver, inputs: inputs, render: render)
        c.configure(enabled: true, directory: dir, byteCap: 1 << 30)
        return (c, resolver)
    }

    @Test func rendersWhenIdleThenPlaybackGetsTheSpan() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, resolver) = make(dir, clock: clock) { _, _, _, url, _ in try Data("mov".utf8).write(to: url) }
        var changed = 0
        c.onSpansChanged = { changed += 1 }
        let t = timeline()
        #expect(c.spans(for: t, sequences: [:]).isEmpty)
        clock.now += 0.1; c.tick(); await c.waitForJob()
        #expect(c.stats.rendered == 0)                       // an edit was just pushed: still within the idle delay
        clock.now += 5; c.tick(); await c.waitForJob()
        #expect(c.stats.rendered == 1)
        #expect(changed == 1)
        let spans = c.spans(for: t, sequences: [:])
        #expect(spans.count == 1 && spans[0].range == TimeRange(start: .zero, duration: Time(4, 1)))
        #expect(c.stats.spansInUse == 1)
        #expect(c.stats.bytes == 3)
        _ = try resolver.demuxer(for: spans[0].media)         // the resolver serves the cache file

        c.tick()                                              // nothing left to render
        #expect(c.stats.rendered == 1)
        #expect(c.spans(for: timeline(effects: false), sequences: [:]).isEmpty)     // edited: no span for the new content
    }

    @Test func playingOrDisabledRendersNothing() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock, playing: true) { _, _, _, url, _ in try Data("mov".utf8).write(to: url) }
        _ = c.spans(for: timeline(), sequences: [:])
        clock.now += 10; c.tick(); await c.waitForJob()
        #expect(c.stats.rendered == 0)
        c.configure(enabled: false, directory: dir, byteCap: 1 << 30)
        #expect(c.spans(for: timeline(), sequences: [:]).isEmpty)
    }

    @Test func anEditCancelsTheRunningJobAndLeavesNoFile() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock) { _, _, _, url, _ in
            try Data("partial".utf8).write(to: url)
            while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
        }
        _ = c.spans(for: timeline(), sequences: [:])
        clock.now += 10; c.tick()                             // job starts
        _ = c.spans(for: timeline(effects: false), sequences: [:])
        c.tick()                                              // the segment is gone: job canceled
        await c.waitForJob()
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.stats.rendered == 0)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".mov") }.isEmpty)
    }

    @Test func theSessionPushesTheSpansToTheEngineButKeepsThemOutOfTheProject() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock) { _, _, _, url, _ in try Data("mov".utf8).write(to: url) }
        let engine = StubProgramEngine()
        let ses = EditorSession(project: Project(name: "P", timelines: [timeline()]), fileURL: nil, engine: engine)
        ses.renderCache = c
        ses.pushTimeline(force: true)
        #expect(engine.timelines.last?.renderCacheSpans.isEmpty == true)
        clock.now += 10; c.tick(); await c.waitForJob()
        #expect(engine.timelines.last?.renderCacheSpans.count == 1)         // onSpansChanged pushed again
        #expect(ses.pushedTimeline?.renderCacheSpans.isEmpty == true)
        #expect(ses.activeTimeline?.renderCacheSpans.isEmpty == true)
    }

    @Test func exportSpansAreThePlaybackSpansWithoutCountingAsAnEdit() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock) { _, _, _, url, _ in try Data("mov".utf8).write(to: url) }
        let t = timeline()
        _ = c.spans(for: t, sequences: [:])
        #expect(c.exportSpans(for: t, sequences: [:]).isEmpty)
        clock.now += 10; c.tick(); await c.waitForJob()
        let spans = c.spans(for: t, sequences: [:])
        #expect(spans.count == 1)
        #expect(c.exportSpans(for: t, sequences: [:]) == spans)
        // Another sequence's export: its own (no) spans, and the pushed sequence is not replaced.
        #expect(c.exportSpans(for: timeline(effects: false), sequences: [:]).isEmpty)
        #expect(c.spans(for: t, sequences: [:]) == spans)
    }

    @Test func pendingFramesOfAFinishedSegmentAreSeeded() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock) { _, _, _, url, pending in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
            for i in 0..<3 { pending.add(pb!, at: Time(Int64(i), 30), duration: Time(1, 30)) }
            try Data("mov".utf8).write(to: url)
        }
        var seeded: [DecodedFrame] = []
        c.seedFrames = { seeded = $0 }
        let t = timeline()
        _ = c.spans(for: t, sequences: [:])
        clock.now += 10; c.tick(); await c.waitForJob()
        let span = try #require(c.spans(for: t, sequences: [:]).first)
        #expect(seeded.count == 3)
        #expect(seeded.allSatisfy { $0.media == span.media })
    }

    @Test func keyHasTheRealWorkingSpaceAndTheMediaInterpretation() {
        let resolver = ProjectMediaResolver(demuxer: { FileDemux($0) })
        let t = timeline()
        let real = RenderCacheController.segments(of: t, sequences: [:], media: resolver).map(\.key)
        let old = RenderCachePlan.segments(of: t, context: RenderCacheContext(rendererID: "x", workingSpace: "default")).map(\.key)
        #expect(Set(real).isDisjoint(with: old))
        // Media interpretation is part of the stamp: another input color space gives another key.
        let id = t.tracks[0].clips[0].media
        func ref(_ cs: ColorSpaceID?) -> MediaRef {
            var info = MediaInfo(duration: Time(4, 1))
            info.detectedColorSpace = cs
            return MediaRef(id: id, name: "c", path: "/nowhere/c.mov", fingerprint: MediaFingerprint(size: 1),
                            duration: Time(4, 1), info: info)
        }
        resolver.update([ref(nil)])
        let a = RenderCacheController.mediaStamp(resolver, id)
        resolver.update([ref(.rec709)])
        let b = RenderCacheController.mediaStamp(resolver, id)
        #expect(a != b)
        #expect(RenderCacheController.mediaStamp(resolver, id) == b)
    }

    @Test func aDisplayViewChangePushesAgain() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = CacheTestClock()
        let (c, _) = make(dir, clock: clock) { _, _, _, url, _ in try Data("mov".utf8).write(to: url) }
        var view = DisplayView.sdr
        c.displayView = { view }
        var pushes = 0
        c.onSpansChanged = { pushes += 1 }
        _ = c.spans(for: timeline(), sequences: [:])
        clock.now += 10; c.tick(); await c.waitForJob()
        let afterRender = pushes
        c.tick()
        #expect(pushes == afterRender)
        view = .displayP3
        c.tick()
        #expect(pushes == afterRender + 1)
    }
}
