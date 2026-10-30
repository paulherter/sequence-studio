import CoreVideo
import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQExport

/// A gray picture per frame with real sample positions: `pts` (start of each sample) may be variable frame rate.
/// `still` hands out one frame for every time (sample 0), like `DecoderFrameProvider` does for a still image.
private struct IndexedProvider: FrameProvider {
    var pts: [Time]
    var still = false
    var width = 96, height = 64

    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!)!, 128, CVPixelBufferGetBytesPerRow(pb!) * height)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let info = VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: !still)
        if still { return ProvidedFrame(buffer: pb!, info: info, sampleIndex: 0) }
        let i = max(0, (pts.lastIndex { $0 <= sourceTime }) ?? 0)
        let end = i + 1 < pts.count ? pts[i + 1] : pts[i] + Time(1, 30)
        return ProvidedFrame(buffer: pb!, info: info, start: pts[i], duration: end - pts[i], sampleIndex: i)
    }
}

/// W9.8: export segments clips with a subject mask (accurate quality) and leaves the others alone.
@Suite struct SubjectMaskExportTests {
    private let fd = Time(1, 30)
    private let media = UUID()

    private func source(masks: [ClipMask]) throws -> TimelineFrameSource {
        var c = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        c.masks = masks
        let tl = Timeline(name: "t", format: SequenceFormat(width: 128, height: 64, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [c])])
        return try TimelineFrameSource(timeline: tl, provider: SolidProvider(colors: [media: (40, 200, 90)], width: 128, height: 64),
                                       width: 128, height: 64, frameDuration: fd, frameCount: 3, renderAhead: false)
    }

    /// `ahead` off by default: these tests count the frames segmented, and rendering ahead segments the next one too.
    private func source(_ provider: IndexedProvider, clips: [Clip], frames: Int = 60, ahead: Bool = false,
                        mattes: ExportSubjectMattes? = nil) throws -> TimelineFrameSource {
        let tl = Timeline(name: "t", format: SequenceFormat(width: 128, height: 64, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: clips)])
        return try TimelineFrameSource(timeline: tl, provider: provider, width: 128, height: 64, frameDuration: fd, frameCount: frames,
                                       renderAhead: ahead, subjectMattes: mattes)
    }

    private let file = URL(fileURLWithPath: "/tmp/sq-export-subject-test.mov")

    /// Accurate mattes of every 1/30 s sample of the 2 s clip, as a finished earlier export would have left them.
    private func accurateStore(frames: Int = 60) -> MagicMatteStore {
        let store = MagicMatteStore(directory: nil)
        let key = SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .accurate)
        for i in 0..<frames { store.put(SubjectMatte(width: 4, height: 4, values: [Float](repeating: 1, count: 16)), key: key, pts: Double(i) / 30) }
        return store
    }

    /// Mattes of export quality that cover the clip are read: no Vision run.
    @Test func coveredClipReadsTheStoreInsteadOfSegmenting() async throws {
        let pts = (0..<120).map { Time(Int64($0), 30) }
        let ex = ExportSubjectMattes(store: accurateStore()) { [file] _ in file }
        let src = try source(IndexedProvider(pts: pts), clips: [subjectClip()], mattes: ex)
        for i in 0..<4 { _ = try await src.frame(at: i) }
        #expect(await src.subjectFrameIndices().isEmpty)
    }

    /// A hole in the stored frames, or mattes of another quality: segmented per frame as before, and stored for next time.
    @Test func uncoveredClipSegmentsAndStoresItsMattes() async throws {
        let pts = (0..<120).map { Time(Int64($0), 30) }
        let store = MagicMatteStore(directory: nil)
        let ex = ExportSubjectMattes(store: store) { [file] _ in file }
        let src = try source(IndexedProvider(pts: pts), clips: [subjectClip()], mattes: ex)
        for i in 0..<3 { _ = try await src.frame(at: i) }
        #expect(await src.subjectFrameIndices() == [0, 1, 2])
        let key = SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .accurate)
        #expect(store.times(key: key).count <= 3)
        let holed = accurateStore()
        let src2 = try source(IndexedProvider(pts: pts), clips: [subjectClip()],
                              mattes: ExportSubjectMattes(store: holed) { [file] _ in nil })
        _ = try await src2.frame(at: 0)
        #expect(await src2.subjectFrameIndices() == [0])
    }

    /// Rendering ahead segments the frames in order, each once (the frame ahead included).
    @Test func renderAheadSegmentsInFrameOrder() async throws {
        let pts = (0..<120).map { Time(Int64($0), 30) }
        let src = try source(IndexedProvider(pts: pts), clips: [subjectClip()], ahead: true)
        for i in 0..<4 { _ = try await src.frame(at: i) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await src.subjectFrameIndices() == [0, 1, 2, 3, 4])
    }

    private func subjectClip(start: Time = .zero, duration: Time = Time(2, 1), isStill: Bool = false) -> Clip {
        var c = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: duration), start: start,
                     isStill: isStill)
        c.masks = [ClipMask.makeSubject(name: "Subject")]
        return c
    }

    @Test func subjectMaskedClipIsSegmentedPerFrame() async throws {
        let src = try source(masks: [ClipMask.makeSubject(name: "Subject")])
        _ = try await src.frame(at: 0)
        _ = try await src.frame(at: 1)
        #expect(await src.subjectSegmentations() == 2)
    }

    @Test func invertedSubjectMaskOnAPictureWithoutPersonKeepsThePicture() async throws {
        var m = ClipMask.makeSubject(name: "Subject")
        m.inverted = true
        let src = try source(masks: [m])
        let pb = try await src.frame(at: 0)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + 32 * CVPixelBufferGetBytesPerRow(pb) + 64 * 4
        #expect(p[1] > 150, "g \(p[1])")
    }

    @Test func plainClipIsNotSegmented() async throws {
        let src = try source(masks: [ClipMask.make(.ellipse, name: "Mask 1")])
        _ = try await src.frame(at: 0)
        #expect(await src.subjectSegmentations() == 0)
    }

    /// Review #4: the smoother's frame index is the media sample (like playback), not floor(start / duration), which is
    /// wrong as soon as frame durations vary.
    @Test func variableFrameRateUsesTheSampleIndex() async throws {
        // Samples at 0, 1/30, 3/30 (a 2/30 frame), 4/30, 5/30 ...
        let pts = [Time.zero, Time(1, 30)] + (3..<40).map { Time(Int64($0), 30) }
        let src = try source(IndexedProvider(pts: pts), clips: [subjectClip()])
        _ = try await src.frame(at: 3)                       // source 3/30 = sample 2 (floor(3/30 / (1/30)) would say 3)
        #expect(await src.subjectFrameIndices() == [0, 1, 2])   // samples 0 and 1 warm the smoother up, then sample 2
    }

    /// Review #1: a still is one frame for playback and export alike (segmented once, sample 0).
    @Test func stillIsSegmentedOnce() async throws {
        let src = try source(IndexedProvider(pts: [], still: true), clips: [subjectClip(isStill: true)])
        for i in 0..<3 { _ = try await src.frame(at: i) }
        #expect(await src.subjectFrameIndices() == [0])
    }

    /// Review #5: a clip's tracker state goes when export moves past it.
    @Test func trackerStateIsReleasedPastTheClip() async throws {
        let pts = (0..<120).map { Time(Int64($0), 30) }
        let b = subjectClip(start: Time(1, 1), duration: Time(1, 1))
        let a = subjectClip(duration: Time(1, 1))
        let src = try source(IndexedProvider(pts: pts), clips: [a, b])
        // Keyed by clip and decoded source, like the Program monitor's scheduler (`SubjectMatteScheduler.Key`).
        func key(_ c: Clip) -> UUID { SubjectMatteScheduler.Key(clip: c.id, source: c.media).trackerKey }
        _ = try await src.frame(at: 5)
        #expect(await src.subjectKeys() == [key(a)])
        _ = try await src.frame(at: 40)
        #expect(await src.subjectKeys() == [key(b)])
    }

    /// Review #6: a parallel segment that starts inside a clip first runs a few earlier frames through the smoother, so
    /// the segment boundary does not pop.
    @Test func segmentWarmsUpTheSmootherBeforeItsFirstFrame() async throws {
        let pts = (0..<120).map { Time(Int64($0), 30) }
        let src = try source(IndexedProvider(pts: pts), clips: [subjectClip()])
        let seg = try #require(try src.segment(20..<22) as? TimelineFrameSource)
        _ = try await seg.frame(at: 0)
        _ = try await seg.frame(at: 1)
        let w = TimelineFrameSource.subjectWarmupFrames
        #expect(await seg.subjectFrameIndices() == Array((20 - w)...21))
        // At the clip's first frame there is nothing to warm up with.
        let head = try source(IndexedProvider(pts: pts), clips: [subjectClip()])
        _ = try await head.frame(at: 0)
        #expect(await head.subjectFrameIndices() == [0])
    }
}
