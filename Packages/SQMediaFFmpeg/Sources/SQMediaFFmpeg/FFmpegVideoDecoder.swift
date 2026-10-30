import CSQFFmpeg
import Foundation
import SQCore
import SQFrame
import SQMedia
import SQMediaFFmpegCore
import Synchronization

/// `VideoDecoding` over FFmpeg: D3D11VA hardware decode (frames stay D3D11 textures, `FFmpegFrame`), software when the
/// GPU cannot decode the stream (or `hardware` is off). Frame-accurate: a seek starts at the GOP's sync sample and
/// every decoded picture is matched to its frame by pts; forward playback continues without flushing.
public final class FFmpegVideoDecoder: VideoDecoding, @unchecked Sendable {
    public let info: VideoTrackInfo
    public let media: UUID
    private let demuxer: FFmpegDemuxer
    private let extraHWFrames: Int
    private let colorSpace: SQFrameColorSpace
    private let fullRange: Bool

    private struct State {
        var decoder: OpaquePointer?
        var hardware: Bool
        var cursor: FFmpegDecodeCursor?
        /// Pictures decoded past the previous range (reorder delay), by presentation index.
        var carry: [Int: DecodedFrame] = [:]
    }
    private let state: Mutex<State>
    /// Mirror of `State.hardware` behind its own lock: a decode holds `state` for its whole run (up to a GOP, over a
    /// second backwards), and the main thread asks `isHardware` on every pause (proxy lookup).
    private let hardwareFlag: Mutex<Bool>

    /// Frames handed out beyond the decoder's own reference pictures before the D3D11 texture pool runs dry.
    /// shortcut: a fixed pool headroom; upgrade to copying into the renderer's own textures when playback holds more.
    public static let defaultExtraHWFrames = 16

    public init(demuxer: FFmpegDemuxer, media: UUID = UUID(), hardware: Bool = true,
                extraHWFrames: Int = FFmpegVideoDecoder.defaultExtraHWFrames) throws {
        self.demuxer = demuxer; self.media = media; self.extraHWFrames = extraHWFrames
        info = demuxer.trackInfo
        (colorSpace, fullRange) = Self.color(demuxer.raw)
        var dec: OpaquePointer?
        var hw = false
        // Streams no PC hardware decoder takes (4:2:2, 4:4:4, 10-bit H.264, ProRes...) open the software decoder at once.
        let gpuCan = FFmpegHardwareDecode.supports(codec: demuxer.formatDescription.codec,
                                                   pixelFormat: FFmpegDemuxer.string(demuxer.raw.pixFmt))
        if hardware && gpuCan { dec = try? Self.open(demuxer, hardware: true, extra: extraHWFrames); hw = dec != nil }
        if dec == nil { dec = try Self.open(demuxer, hardware: false, extra: 0) }
        state = Mutex(State(decoder: dec, hardware: hw))
        hardwareFlag = Mutex(hw)
    }

    deinit { state.withLock { s in if let d = s.decoder { sq_dec_close(d) } } }

    /// Never waits for a running decode.
    public var isHardware: Bool { hardwareFlag.withLock { $0 } }
    public var decoderName: String {
        state.withLock { s in s.decoder.map { String(cString: sq_dec_name($0)) } ?? "none" }
    }

    private static func open(_ d: FFmpegDemuxer, hardware: Bool, extra: Int) throws -> OpaquePointer {
        var out: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        let extradata = d.formatDescription.extradata
        let r = extradata.withUnsafeBufferPointer { e in
            sq_dec_open(d.formatDescription.codec, e.baseAddress, Int32(e.count), d.raw.width, d.raw.height, d.raw.tbNum,
                        d.raw.tbDen, hardware ? 1 : 0, Int32(extra), &out, &err, Int32(err.count))
        }
        guard r == 0, let out else { throw FFmpegError.from("decoder", r, err) }
        return out
    }

    public func invalidate() {
        state.withLock { s in
            if let d = s.decoder { sq_dec_flush(d) }
            s.cursor = nil
            s.carry.removeAll()
        }
    }

    public func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        try decode(range, deliver: nil)
    }

    public func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try decode(range, deliver: Optional(deliver))
    }

    /// Blocking decode under the state lock. A hardware failure mid-stream reopens the software decoder and retries once.
    private func decode(_ range: ClosedRange<Int>, deliver: (@Sendable (DecodedFrame) -> Void)?) throws -> [DecodedFrame] {
        let count = demuxer.index.count
        guard count > 0 else { return [] }
        let r = max(0, range.lowerBound)...min(count - 1, range.upperBound)
        guard r.lowerBound <= r.upperBound else { return [] }
        return try state.withLock { s in
            do { return try decodeLocked(r, &s, deliver) } catch where s.hardware && error is FFmpegError {
                if let d = s.decoder { sq_dec_close(d) }
                s.decoder = try Self.open(demuxer, hardware: false, extra: 0)
                s.hardware = false
                hardwareFlag.withLock { $0 = false }
                s.cursor = nil
                s.carry.removeAll()
                return try decodeLocked(r, &s, deliver)
            }
        }
    }

    private func decodeLocked(_ range: ClosedRange<Int>, _ s: inout State,
                              _ deliver: (@Sendable (DecodedFrame) -> Void)?) throws -> [DecodedFrame] {
        guard let dec = s.decoder else { throw FFmpegError.message("decoder closed") }
        let index = demuxer.index
        let plan = FFmpegDecodePlan.start(for: range, in: index, cursor: s.cursor, carried: Set(s.carry.keys))
        if plan.flush {
            sq_dec_flush(dec)
            s.carry.removeAll()
        }
        var wanted = FFmpegDecodePlan.wanted(range, in: index)
        var results: [Int: DecodedFrame] = [:]
        var delivered = Set<Int>()
        for (i, f) in s.carry where range.contains(i) { results[i] = f; wanted.remove(i) }
        s.carry = s.carry.filter { $0.key > range.upperBound }

        var ordinal = plan.ordinal
        var sentEnd = false
        var ended = false
        let packets = sq_demux_packets(demuxer.handle)!

        func take(_ frame: OpaquePointer) {
            let storage = FFmpegFrame(handle: frame)
            guard let i = demuxer.table.presentationIndex(ofTicks: storage.ptsTicks) else { return }
            let entry = index.entries[i]
            let decoded = DecodedFrame(media: media, duration: entry.duration, frame: makeFrame(storage, pts: entry.pts))
            if range.contains(i) {
                guard wanted.remove(i) != nil else { return }
                if let deliver { deliver(decoded); delivered.insert(i) } else { results[i] = decoded }
            } else if i > range.upperBound, s.carry.count < 8 {
                s.carry[i] = decoded
            }
        }

        /// Receives every picture the decoder has ready. Throws on decode errors.
        func drain() throws {
            while true {
                var frame: OpaquePointer?
                let r = sq_dec_receive(dec, &frame)
                if r == 0, let frame { take(frame); continue }
                if r == 2 { ended = true; return }
                if r == 1 { return }
                throw FFmpegError.failed("decode", r)
            }
        }

        while !wanted.isEmpty && !ended {
            try Task.checkCancellation()
            if ordinal < demuxer.packetCount {
                let p = packets[ordinal]
                let sample = try demuxer.sample(ordinal: ordinal)
                var r = sample.data.withUnsafeBufferPointer { sq_dec_send(dec, $0.baseAddress, Int32($0.count), p.pts, p.dts, p.duration, p.key) }
                if r == 1 {                                   // decoder full: take pictures out, then send again
                    try drain()
                    r = sample.data.withUnsafeBufferPointer { sq_dec_send(dec, $0.baseAddress, Int32($0.count), p.pts, p.dts, p.duration, p.key) }
                }
                guard r == 0 else { throw FFmpegError.failed("send sample \(ordinal)", r) }
                ordinal += 1
            } else if !sentEnd {
                let r = sq_dec_send(dec, nil, 0, 0, 0, 0, 0)
                guard r == 0 else { throw FFmpegError.failed("drain", r) }
                sentEnd = true
            } else {
                break
            }
            try drain()
        }
        // After end of stream the decoder needs a flush before new input: the next call seeks.
        s.cursor = sentEnd ? nil : FFmpegDecodeCursor(nextOrdinal: ordinal, lastPresented: range.upperBound)
        if sentEnd { sq_dec_flush(dec) }
        if !wanted.isEmpty, !Task.isCancelled {
            throw FFmpegError.message("frames \(wanted.sorted().prefix(4)) of \(range) were not decoded")
        }
        return results.keys.sorted().compactMap { delivered.contains($0) ? nil : results[$0] }
    }

    private func makeFrame(_ storage: FFmpegFrame, pts: Time) -> SQFrame {
        let deep = info.bitDepth > 8
        let format: SQFramePixelFormat = deep ? (fullRange ? .p010FullRange : .p010) : (fullRange ? .nv12FullRange : .nv12)
        return SQFrame(width: storage.width, height: storage.height, pixelFormat: format, colorSpace: colorSpace,
                       presentationTime: pts, storage: storage)
    }

    /// FFmpeg's AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace / AVColorRange values to the neutral tags.
    static func color(_ i: SQFFVideoInfo) -> (SQFrameColorSpace, Bool) {
        let full = i.colorRange == 2
        switch (i.colorPrimaries, i.colorTransfer, i.colorMatrix) {
        case (9, 16, _), (_, 16, 9): return (.rec2020PQ, full)
        case (9, 18, _), (_, 18, 9): return (.rec2020HLG, full)
        case (9, _, _), (_, _, 9), (_, _, 10): return (.rec2020, full)
        case (1, _, _), (_, _, 1): return (.rec709, full)
        case (5, _, _), (6, _, _), (_, _, 5), (_, _, 6): return (.rec601, full)
        default: return (.unspecified, full)
        }
    }
}
