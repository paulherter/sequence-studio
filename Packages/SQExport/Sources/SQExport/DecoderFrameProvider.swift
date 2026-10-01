import CoreVideo
import Dispatch
import Foundation
import SQCore
import SQMedia
import SQPlayback

/// Runs blocking AVAssetReader / VideoToolbox work on a dedicated serial queue instead of the cooperative pool.
final class QueueExecutor: TaskExecutor, @unchecked Sendable {
    let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Export-side `FrameProvider`: one `VTVideoDecoder` per media, decoding forward without reseeking for consecutive frames
/// (the decoder continues when a request starts right after the last decoded frame) and reseeking on jumps.
/// The last decoded frame is kept, so a repeated source frame (slow motion, frame-rate conversion) costs nothing.
/// Decoding runs on a dedicated queue per media (never on the cooperative pool). Media the resolver cannot open are
/// reported as offline (`nil`).
public actor DecoderFrameProvider: FrameProvider {
    private struct Entry {
        var decoder: VTVideoDecoder
        var index: SampleIndex
        var executor: QueueExecutor
        var lastIndex: Int?
        var lastFrame: DecodedFrame?
        /// A few recent frames by index (Frame Blending asks for a frame and its successor alternately).
        var recent: [Int: DecodedFrame] = [:]
    }
    private let resolver: any MediaResolver
    private let scale: DecodeScale
    private var entries: [UUID: Entry] = [:]
    private var failed: Set<UUID> = []
    /// Still-image media (decoded once by the resolver) and media known not to be stills.
    private var stills: [UUID: StillFrame] = [:]
    private var notStill: Set<UUID> = []

    private static let recentByteLimit = 256 << 20

    /// The media changed (relinked, proxy switched): forget its decoder, cached frames and still.
    public func invalidate(media: UUID) {
        entries[media] = nil; stills[media] = nil; failed.remove(media); notStill.remove(media)
    }

    public init(resolver: any MediaResolver, scale: DecodeScale = .full) {
        self.resolver = resolver; self.scale = scale
    }

    /// Decoder reseeks over all media so far (tests / diagnostics).
    public var reseeks: Int { entries.values.reduce(0) { $0 + $1.decoder.reseekCount } }

    private func entry(for media: UUID) -> Entry? {
        if let e = entries[media] { return e }
        if failed.contains(media) { return nil }
        do {
            let ex = QueueExecutor(label: "export.decode.\(media.uuidString.prefix(8))")
            // Opening an AVAsset / VT session can block: do it on the decode queue too.
            let resolver = self.resolver
            let d = try ex.queue.sync { try resolver.demuxer(for: media) }
            guard d.index.count > 0 else { failed.insert(media); return nil }
            let dec = try VTVideoDecoder(demuxer: d, media: media, scale: scale)
            let e = Entry(decoder: dec, index: d.index, executor: ex)
            entries[media] = e
            return e
        } catch {
            failed.insert(media)
            return nil
        }
    }

    private func still(for media: UUID) -> StillFrame? {
        if let s = stills[media] { return s }
        if notStill.contains(media) || failed.contains(media) { return nil }
        if let s = try? resolver.stillFrame(for: media) { stills[media] = s; return s }
        notStill.insert(media)
        return nil
    }

    public func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        if let s = still(for: media) { return ProvidedFrame(buffer: s.buffer, info: s.info) }
        guard let e = entry(for: media) else { return nil }
        try Task.checkCancellation()
        let all = e.index.entries
        // Frame presented at `sourceTime`, clamped to the media (a clip may run past its last frame).
        let idx = e.index.frame(at: sourceTime) ?? (sourceTime < all[0].pts ? 0 : all.count - 1)
        if let hit = e.recent[idx] {
            return ProvidedFrame(buffer: hit.pixelBuffer, info: e.decoder.info, start: all[idx].pts, duration: all[idx].duration)
        }
        if let last = e.lastFrame, e.lastIndex == idx {
            return ProvidedFrame(buffer: last.pixelBuffer, info: e.decoder.info, start: all[idx].pts, duration: all[idx].duration)
        }
        let dec = e.decoder
        let frames = try await withTaskExecutorPreference(e.executor) { try await dec.decode(idx...idx) }
        guard let f = frames.first else { return nil }
        entries[media]?.lastIndex = idx
        entries[media]?.lastFrame = f
        entries[media]?.recent[idx] = f
        // Bounded by count and by bytes (4K frames are large): the frame farthest from the current one goes first.
        while let e = entries[media]?.recent, e.count > 1,
              e.count > 3 || e.values.reduce(0, { $0 + CVPixelBufferGetDataSize($1.pixelBuffer) }) > Self.recentByteLimit,
              let far = e.keys.max(by: { abs($0 - idx) < abs($1 - idx) }) {
            entries[media]?.recent.removeValue(forKey: far)
        }
        return ProvidedFrame(buffer: f.pixelBuffer, info: e.decoder.info, start: all[idx].pts, duration: all[idx].duration)
    }
}
