import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQPlayback

/// Preview render cache, the render step: writes one segment of a sequence to an intra-coded file (ProRes 422 LT in a .mov,
/// sequence size, no audio, no caption burn-in) through the same compositor path as an export, so cached playback shows
/// exactly what an export would. The file is removed again on failure or cancel.
public enum RenderCacheSegmentWriter {
    /// The compositor's working space (working-linear, Rec.709 primaries, 1.0 = reference white; see `DisplayView`).
    /// shortcut: a constant, since the compositor has one fixed working space; becomes the project's choice when it has one.
    public static let compositorWorkingSpace = "linear-rec709-ref100"

    public static func settings(for timeline: Timeline, segment: RenderCacheSegment) -> ExportSettings {
        settings(for: timeline, range: segment.range)
    }

    static func settings(for timeline: Timeline, range: TimeRange) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = .prores422LT
        s.video.width = timeline.format.width
        s.video.height = timeline.format.height
        s.video.frameDuration = timeline.format.frameDuration
        s.video.pixelAspect = timeline.format.pixelAspect
        s.audio.enabled = false
        s.range = .inOut(range)
        return s
    }

    /// The working space part of the segment key (`RenderCacheContext.workingSpace`): the compositor's space plus everything
    /// of the cache file's own encoding that the picture depends on (codec, bit depth, pixel format, output color, HDR
    /// handling). A change to any of them gives every segment a new key, so no file of the old pipeline is read again.
    public static func workingSpace(for timeline: Timeline) -> String {
        let s = settings(for: timeline, range: TimeRange(start: .zero, duration: timeline.format.frameDuration))
        let c = s.color
        return [compositorWorkingSpace, s.video.codec.rawValue, "\(s.video.bitDepth)bit", "\(s.sourcePixelFormat)",
                "\(c.primaries.rawValue)-\(c.transfer.rawValue)-\(c.matrix.rawValue)",
                s.hdrToSDR.map { "\($0)" } ?? "sdr", s.hdrDelivery.map { "\($0)" } ?? "-"].joined(separator: "/")
    }

    /// Whether an export with `settings` may read cached segments instead of compositing them, picture for picture the
    /// same as playback with the cache: only when it renders the sequence's own frames (size, rate, pixel shape, no format
    /// variant) into a picture the cache file holds (Rec.709 SDR, no alpha, no HDR handling) and the delivery is not of a
    /// higher quality than the cache's ProRes 422 LT (a ProRes 422 / HQ / 4444 master or an image sequence renders fresh).
    public static func mayReuse(_ settings: ExportSettings, timeline: Timeline) -> Bool {
        let v = settings.video, f = timeline.format
        guard v.width == f.width, v.height == f.height, v.frameDuration == f.frameDuration,
              v.pixelAspect == f.pixelAspect, settings.variant == nil,
              settings.frameOutput == nil, settings.audioOnly == nil, !v.preservesAlpha,
              settings.hdrToSDR == nil, settings.hdrDelivery == nil, settings.color == .rec709 else { return false }
        switch v.codec {
        case .h264, .hevc, .prores422LT, .prores422Proxy: return true
        case .prores422, .prores422HQ, .prores4444: return false
        }
    }

    /// - Parameter pending: the pending-writes tier: keeps the frames handed to the encoder (around its anchor) so
    ///   playback can show them the moment the segment goes live, before a single one is read back from the file.
    public static func write(segment: RenderCacheSegment, timeline: Timeline, sequences: [Timeline.ID: Timeline],
                             resolver: any MediaResolver, to url: URL,
                             pending: RenderCachePendingFrames? = nil) async throws {
        let s = settings(for: timeline, segment: segment)
        // Background work: decoding runs at utility, below the playback decoders (userInitiated).
        let sources = try ExportSourceBuilder.make(timeline: timeline, sequences: sequences, settings: s, resolver: resolver,
                                                   decodeQoS: .utility)
        let video: any FrameSource = pending.map { p in
            TappedFrameSource(inner: sources.video, offset: 0) { i, pb in p.add(pb, at: s.video.frameDuration * Int64(i), duration: s.video.frameDuration) }
        } ?? sources.video
        do {
            try await ExportWriter.export(video: video, audio: nil, settings: s, to: url, progress: { _ in })
        } catch {
            try? FileManager.default.removeItem(at: url)
            pending?.discard()
            throw error
        }
    }
}

/// Hands every frame a source renders to `tap` (index in the whole source) and passes it on unchanged; keeps the source's
/// parallel segments.
struct TappedFrameSource: SegmentableFrameSource {
    let inner: any FrameSource
    let offset: Int
    let tap: @Sendable (Int, CVPixelBuffer) -> Void
    init(inner: any FrameSource, offset: Int, tap: @escaping @Sendable (Int, CVPixelBuffer) -> Void) {
        self.inner = inner; self.offset = offset; self.tap = tap
    }
    var frameCount: Int { inner.frameCount }
    var frameDuration: Time { inner.frameDuration }
    var isSegmentable: Bool { (inner as? any SegmentableFrameSource)?.isSegmentable ?? false }
    func frame(at index: Int) async throws -> CVPixelBuffer {
        let pb = try await inner.frame(at: index)
        tap(offset + index, pb)
        return pb
    }
    func segment(_ range: Range<Int>) throws -> any FrameSource {
        guard let s = inner as? any SegmentableFrameSource else { return self }
        return TappedFrameSource(inner: try s.segment(range), offset: offset + range.lowerBound, tap: tap)
    }
}

/// Preview render cache, pending-writes tier (F1 FCP study: an in-flight image cache so a just-rendered frame is readable
/// before it is on disk): the frames of one segment as they leave the compositor, at file time (0 = segment start), at
/// most `byteBudget` of them, the ones nearest `anchor` (the playhead inside the segment) kept. The controller hands them
/// to the playback frame cache when the segment goes live, so the parked frame and the first frames of a play show at
/// once instead of waiting for the file to be opened and decoded. These are the encoder's input: the file holds the same
/// picture after ProRes 422 LT, so playback switches between the two without a visible step.
public final class RenderCachePendingFrames: @unchecked Sendable {
    public static let defaultByteBudget = 256 << 20

    public let media: UUID
    public let anchor: Time
    public let byteBudget: Int
    private let lock = NSLock()
    private var frames: [Time: DecodedFrame] = [:]
    private var bytes = 0

    public init(media: UUID, anchor: Time = .zero, byteBudget: Int = defaultByteBudget) {
        self.media = media; self.anchor = anchor; self.byteBudget = max(0, byteBudget)
    }

    public var byteCount: Int { lock.withLock { bytes } }
    public var count: Int { lock.withLock { frames.count } }

    /// Keeps the frame unless the budget is full of frames nearer the anchor. Only IOSurface-backed buffers (the ones the
    /// monitor can draw) are kept.
    public func add(_ pb: CVPixelBuffer, at t: Time, duration: Time) {
        guard CVPixelBufferGetIOSurface(pb) != nil else { return }
        let f = DecodedFrame(media: media, pts: t, duration: duration, pixelBuffer: pb)
        let cost = f.byteCost
        guard cost <= byteBudget else { return }
        let anchor = self.anchor
        func distance(_ x: Time) -> Time { x < anchor ? anchor - x : x - anchor }
        lock.withLock {
            if let old = frames.removeValue(forKey: t) { bytes -= old.byteCost }
            frames[t] = f; bytes += cost
            while bytes > byteBudget, let far = frames.keys.max(by: { (distance($0), $0) < (distance($1), $1) }) {
                bytes -= frames.removeValue(forKey: far)?.byteCost ?? 0
            }
        }
    }

    /// The kept frames in time order; the tier is empty afterwards.
    public func take() -> [DecodedFrame] {
        lock.withLock {
            let out = frames.values.sorted { $0.pts < $1.pts }
            frames = [:]; bytes = 0
            return out
        }
    }

    func discard() { _ = take() }
}
