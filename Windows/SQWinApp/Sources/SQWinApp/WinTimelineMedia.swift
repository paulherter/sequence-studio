import Foundation
import SQCore
import SQDrawKit
import SQDrawTimeline
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import Synchronization

/// The Timeline panel's media on Windows: waveforms decoded with FFmpeg and turned into peaks by the portable
/// `PeakPyramid` (the Mac reads them through `Waveform.build` and vDSP); thumbnails decoded with FFmpeg (software) on one
/// worker thread and packed into the shared `ThumbnailAtlas` (image slot `thumbnailSlot`, the renderer uploads it).
/// shortcut: no disk cache for peaks or thumbnails; add one when large projects reopen slowly.
/// Kept here because the panel holds its media source weakly.
@MainActor var winTimelineMedia: WinTimelineMedia?

final class WinTimelineMedia: TimelineMediaSource, Sendable {
    /// Image slot of the thumbnail atlas (the scopes take 2 and 3).
    static let thumbnailSlot = 0
    /// Thumbnail requests kept waiting; older ones drop when the view moved on.
    static let maxPending = 64

    private let paths: PathStore
    /// Dialogue pauses for the live duck, from the same peaks the lanes draw (playback, the duck curve and export read it).
    let silences = WaveformSilences()
    private let state = Mutex<(ready: [UUID: WaveformData], started: Set<UUID>)>(([:], []))

    private struct Thumbs {
        var atlas = ThumbnailAtlas(slot: WinTimelineMedia.thumbnailSlot)
        var pending: [ThumbnailAtlas.Key] = []
        var queued: Set<ThumbnailAtlas.Key> = []
        /// Media without a decodable video track (audio, missing or broken files): no more requests.
        var failed: Set<UUID> = []
        var workerRunning = false
    }
    private let thumbs = Mutex(Thumbs())

    init(paths: PathStore) { self.paths = paths }

    func waveform(media: UUID) -> WaveformData? {
        let (ready, start) = state.withLock { s -> (WaveformData?, Bool) in
            if let w = s.ready[media] { return (w, false) }
            return (nil, s.started.insert(media).inserted)
        }
        if start, let path = paths.path(media) {
            Thread.detachNewThread { [self] in
                guard let src = try? FFmpegAudioSource(url: URL(fileURLWithPath: path)),
                      let wf = try? PeakPyramid.waveform(from: src, sampleRate: 48_000) else { return }
                state.withLock { $0.ready[media] = wf }
                silences.setWaveform(wf, for: media)
            }
        }
        return ready
    }

    /// Relinked media: its waveform and thumbnails are read again from the new file (a missing file had failed).
    func forget(_ ids: Set<UUID>) {
        state.withLock { s in for id in ids { s.ready[id] = nil; s.started.remove(id) } }
        for id in ids { silences.setWaveform(nil, for: id) }
        thumbs.withLock { t in t.failed.subtract(ids) }
    }

    func isOffline(media: UUID) -> Bool {
        guard let p = paths.path(media) else { return false }
        return !FileManager.default.fileExists(atPath: p)
    }

    // MARK: Thumbnails

    func picture(media: UUID, at: Time?) -> TimelinePicture? {
        // The poster is the first frame (key 0), like a frame request at media time zero.
        let ms = at.map { Int(max($0.value, 0) * 1000 / $0.timescale) } ?? 0
        let key = ThumbnailAtlas.Key(media: media, frame: ms)
        let (picture, startWorker) = thumbs.withLock { t -> (TimelinePicture?, Bool) in
            if let p = t.atlas.picture(for: key) { return (p, false) }
            guard !t.failed.contains(media), !t.queued.contains(key) else { return (nil, false) }
            t.pending.append(key)
            t.queued.insert(key)
            if t.pending.count > Self.maxPending { t.queued.remove(t.pending.removeFirst()) }
            let start = !t.workerRunning
            t.workerRunning = true
            return (nil, start)
        }
        if startWorker { Thread.detachNewThread { [self] in thumbnailWorker() } }
        return picture
    }

    /// The atlas for the renderer: (slot, image, generation); upload when the generation changed.
    var thumbnailImage: (Int, RGBAImage, Int) {
        thumbs.withLock { (Self.thumbnailSlot, $0.atlas.image, $0.atlas.generation) }
    }

    private final class Decoder {
        let demuxer: FFmpegDemuxer
        let decoder: FFmpegVideoDecoder
        init(_ path: String, _ media: UUID) throws {
            demuxer = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
            decoder = try FFmpegVideoDecoder(demuxer: demuxer, media: media, hardware: false)
        }
    }

    /// Decodes the newest request first (the part of the timeline in view now) until the queue is empty.
    private func thumbnailWorker() {
        var decoders: [UUID: Decoder] = [:]
        while true {
            guard let key = thumbs.withLock({ t -> ThumbnailAtlas.Key? in
                guard let k = t.pending.popLast() else { t.workerRunning = false; return nil }
                return k
            }) else { return }
            let frame = decode(key, &decoders)
            thumbs.withLock { t in
                t.queued.remove(key)
                if let frame { t.atlas.insert(key, frame: frame) } else { t.failed.insert(key.media) }
            }
        }
    }

    private func decode(_ key: ThumbnailAtlas.Key, _ decoders: inout [UUID: Decoder]) -> RGBAImage? {
        guard let path = paths.path(key.media) else { return nil }
        let dec: Decoder
        if let d = decoders[key.media] { dec = d } else {
            guard let d = try? Decoder(path, key.media) else { return nil }
            decoders[key.media] = d; dec = d
        }
        let idx = dec.demuxer.index
        guard idx.count > 0 else { return nil }
        let first = idx.entries.first?.pts ?? .zero
        let t = Time(Int64(key.frame), 1000)
        let i = max(0, min(idx.count - 1, idx.frame(at: t + first) ?? (key.frame > 0 ? idx.count - 1 : 0)))
        // The decoder API is async; the worker thread waits for it.
        let box = Mutex<RGBAImage?>(nil)
        let done = DispatchSemaphore(value: 0)
        let decoder = dec.decoder
        Task.detached {
            defer { done.signal() }
            guard let f = try? await decoder.decode(i...i).first,
                  let ff = f.frame.storage as? FFmpegFrame, var bytes = try? ff.download() else { return }
            let w = f.frame.width, h = f.frame.height
            if bytes.count >= w * h * 3 { bytes = (0..<(w * h * 3 / 2)).map { bytes[$0 * 2 + 1] } }   // P010: high bytes
            let full = f.frame.pixelFormat == .nv12FullRange || f.frame.pixelFormat == .p010FullRange
            box.withLock { $0 = RGBAImage(nv12: bytes, width: w, height: h, fullRange: full) }
        }
        done.wait()
        return box.withLock { $0 }
    }
}
