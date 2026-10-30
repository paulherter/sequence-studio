import AVFoundation
import CoreMedia
import Foundation
import SQAudioFX
import SQCore
import Synchronization

/// Decodes an audio file with AVAssetReader; the reader's converter delivers Float32 non-interleaved stereo at
/// `sampleRate` (sample-rate conversion and channel up/down-mix happen there, upstream of the mixer).
/// Keeps a small cache of 1 s blocks; sequential forward reads continue the reader, backward or distant reads restart it.
public final class AssetAudioSource: AudioSource, @unchecked Sendable {
    public let sampleRate: Int
    public let isMono: Bool
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let state = Mutex(State())

    private struct Block { var left: [Float], right: [Float]; var complete = false }
    private struct State {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var readerStart: Int64 = 0      // first frame the current reader delivers
        var cursor: Int64 = 0           // next frame the reader will deliver
        var ended = false               // the current reader hit the end
        var total: Int64?               // total frame count, known once a reader delivered data up to the end
        var pastEnd: Int64?             // a restart at this frame found nothing: the media ends at or before it
        var blocks: [Int64: Block] = [:]
    }
    private static let maxCachedBlocks = 6

    /// Throws `MediaError.unreadable` when the file has no audio track.
    public static func open(url: URL, sampleRate: Int) async throws -> AssetAudioSource {
        try await open(url: url, sampleRate: sampleRate, channelMap: nil)
    }

    /// F7.10: `channelMap` picks the channels of the first audio track that feed each side (nil = the file's layout,
    /// the reader's own stereo mix). A map that names the file's layout anyway is read the plain way.
    public static func open(url: URL, sampleRate: Int, channelMap: AudioChannelMap?) async throws -> AssetAudioSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.unreadable }
        var channels = 2
        var order = SurroundFoldDown.ChannelOrder.smpte
        if let d = try? await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            order = foldOrder(of: d)
        }
        let end = await endFrame(of: track, sampleRate: sampleRate)
        return make(asset: asset, track: track, channels: channels, sampleRate: sampleRate, channelMap: channelMap, end: end,
                    foldOrder: order)
    }

    /// The frame (at `sampleRate`) where the track's time range ends; nil when the track names none. AVAssetReader can
    /// deliver a decoder tail past it (an MP3 ends 560 samples late in about one read of four), so reads stop here.
    static func endFrame(of track: AVAssetTrack, sampleRate: Int) async -> Int64? {
        guard let range = try? await track.load(.timeRange), range.isValid, range.duration.isNumeric,
              range.duration > .zero else { return nil }
        let end = range.end.convertScale(Int32(sampleRate), method: .roundTowardNegativeInfinity)
        return end.value > 0 ? Int64(end.value) : nil
    }

    /// Channel order of a 5.1 track from its layout tag (anything unknown reads as WAV / SMPTE order).
    static func foldOrder(of d: CMAudioFormatDescription) -> SurroundFoldDown.ChannelOrder {
        var size = 0
        guard let p = CMAudioFormatDescriptionGetChannelLayout(d, sizeOut: &size) else { return .smpte }
        switch p.pointee.mChannelLayoutTag {
        case kAudioChannelLayoutTag_MPEG_5_1_D, kAudioChannelLayoutTag_AAC_5_1: return .aac
        case kAudioChannelLayoutTag_MPEG_5_1_C: return .film
        default: return .smpte
        }
    }

    /// One track of `asset` with `channels` channels. `gain` overrides the map's own level (a track that is one part of a
    /// multi-track sum); `keepRoute` reads the channels through the route even where the plain read would give the same.
    static func make(asset: AVURLAsset, track: AVAssetTrack, channels: Int, sampleRate: Int, channelMap: AudioChannelMap?,
                     gain: Float? = nil, keepRoute: Bool = false, end: Int64? = nil,
                     foldOrder: SurroundFoldDown.ChannelOrder = .smpte) -> AssetAudioSource {
        var route = channelMap?.fitting(channels: channels)
        if !keepRoute, (channels == 2 && route == .stereo(0, 1)) || (channels == 1 && route == .mono(0)) { route = nil }
        let s = AssetAudioSource(asset: asset, track: track, sampleRate: sampleRate, isMono: route?.isCentered ?? (channels == 1),
                                 route: route, end: end)
        s.gainOverride = gain
        // 5.1 read as the file layout: fold down with the BS.775 matrix here, so preview and export hear the same.
        if route == nil, channels == SurroundFoldDown.channelCount { s.fold = foldOrder }
        return s
    }

    private var gainOverride: Float?

    /// Set for a 5.1 track read without a channel map: the reader delivers its six channels and `consume` folds them.
    private var fold: SurroundFoldDown.ChannelOrder?

    /// Chosen channels: the reader then delivers the track's own channels (interleaved) and `consume` mixes the sides.
    private let route: AudioChannelMap?

    /// Frames from here on are past the track's time range (`endFrame(of:sampleRate:)`): dropped as they arrive.
    private let end: Int64?

    private init(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Int, isMono: Bool, route: AudioChannelMap?, end: Int64?) {
        self.asset = asset; self.track = track; self.sampleRate = sampleRate; self.isMono = isMono; self.route = route
        self.end = end
    }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard sourceFrame >= 0, count > 0, channel == 0 || channel == 1 else { return 0 }
        let bs = Int64(sampleRate)
        return try state.withLock { st in
            var done = 0
            while done < count {
                let f = sourceFrame + Int64(done)
                let b = f / bs
                guard try ensure(block: b, &st), let blk = st.blocks[b] else { break }
                let inBlock = Int(f - b * bs)
                // The final block of a file only holds `total - b*bs` valid frames.
                let valid = Int(min(bs, max(0, (st.total ?? Int64.max) - b * bs)))
                let n = min(count - done, valid - inBlock)
                if n <= 0 { break }
                let data = channel == 0 ? blk.left : blk.right
                data.withUnsafeBufferPointer { buffer.advanced(by: done).update(from: $0.baseAddress! + inBlock, count: n) }
                done += n
            }
            return done
        }
    }

    // MARK: decoding (state lock held)

    private func restart(at frame: Int64, _ st: inout State) throws {
        st.reader?.cancelReading()
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
        ]
        if route != nil || fold != nil {       // the track's own channels, unmixed, in one interleaved buffer
            settings[AVNumberOfChannelsKey] = nil
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate)),
                                       duration: .positiveInfinity)
        guard reader.canAdd(output) else { throw MediaError.unreadable }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.decodeFailed(OSStatus((reader.error as NSError?)?.code ?? -1))
        }
        st.reader = reader; st.output = output
        st.readerStart = frame; st.cursor = frame; st.ended = false
        st.blocks = st.blocks.filter { $0.value.complete }
    }

    /// Makes block `b` available. False when `b` lies entirely past the end of the media.
    private func ensure(block b: Int64, _ st: inout State) throws -> Bool {
        let bs = Int64(sampleRate)
        if let blk = st.blocks[b], blk.complete { return true }
        let start = b * bs
        if let total = st.total, start >= total { return false }
        if let pe = st.pastEnd, start >= pe { return false }
        // A block that is missing behind the cursor (evicted) needs a fresh reader; a partial block at the cursor does not.
        if st.reader == nil || start < st.readerStart || start > st.cursor + 4 * bs || (st.blocks[b] == nil && start < st.cursor) {
            try restart(at: start, &st)
        }
        while st.cursor < (b + 1) * bs && !st.ended {
            guard let output = st.output, let sb = output.copyNextSampleBuffer() else {
                if let r = st.reader, r.status == .failed {
                    throw MediaError.decodeFailed(OSStatus((r.error as NSError?)?.code ?? -1))
                }
                st.ended = true
                if st.cursor > st.readerStart { st.total = st.cursor }
                else { st.pastEnd = min(st.pastEnd ?? st.readerStart, st.readerStart) }   // restart landed past the end
                break
            }
            try consume(sb, &st)
        }
        for (k, var blk) in st.blocks where !blk.complete && ((k + 1) * bs <= st.cursor || st.ended) {
            blk.complete = true; st.blocks[k] = blk
        }
        if st.blocks.count > Self.maxCachedBlocks {
            let drop = st.blocks.keys.sorted { abs($0 - b) > abs($1 - b) }.prefix(st.blocks.count - Self.maxCachedBlocks)
            for k in drop { st.blocks[k] = nil }
        }
        return st.blocks[b] != nil && (st.total ?? Int64.max) > start && st.cursor > start
    }

    private func consume(_ sb: CMSampleBuffer, _ st: inout State) throws {
        var n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).convertScale(Int32(sampleRate), method: .default)
        var frame = Int64(pts.value)
        // A decoder tail past the track's end is dropped (n counts from the buffer's start, as `skip` does).
        if let end { n = Int(max(0, min(Int64(n), end - frame))) }
        var skip = 0
        if frame < st.cursor { skip = Int(st.cursor - frame); frame = st.cursor }   // lead-in before the requested range
        if skip >= n { return }
        var bbuf: CMBlockBuffer?
        var listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        if route != nil || fold != nil {       // the track's own channel count: ask how large the list is
            var needed = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            if needed > 0 { listSize = needed }     // the exact size: a larger list is refused for an interleaved buffer
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var size = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: abl, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &bbuf)
        guard status == noErr else { throw MediaError.decodeFailed(status) }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        if let route {
            // One interleaved buffer, or one buffer per channel.
            let planar = buffers.count > 1
            let nch = planar ? buffers.count : Int(buffers.first?.mNumberChannels ?? 0)
            guard nch > route.highestChannel, buffers.allSatisfy({ $0.mData != nil })
            else { throw MediaError.unsupportedCodec("audio layout") }
            let bs = Int64(sampleRate), gain = gainOverride ?? route.gain
            func sample(_ i: Int, _ c: Int) -> Float {
                planar ? buffers[c].mData!.assumingMemoryBound(to: Float.self)[i]
                       : buffers[0].mData!.assumingMemoryBound(to: Float.self)[i * nch + c]
            }
            for i in skip..<n {
                let f = frame + Int64(i - skip)
                let b = f / bs, o = Int(f - b * bs)
                if st.blocks[b] == nil {
                    st.blocks[b] = Block(left: [Float](repeating: 0, count: sampleRate), right: [Float](repeating: 0, count: sampleRate))
                }
                var l: Float = 0, r: Float = 0
                for c in route.left { l += sample(i, c) }
                for c in route.right { r += sample(i, c) }
                st.blocks[b]!.left[o] = l * gain; st.blocks[b]!.right[o] = r * gain
            }
            st.cursor = frame + Int64(n - skip)
            withExtendedLifetime(bbuf) {}
            return
        }
        if let order = fold {
            let planar = buffers.count > 1
            let nch = planar ? buffers.count : Int(buffers.first?.mNumberChannels ?? 0)
            guard nch == SurroundFoldDown.channelCount, buffers.allSatisfy({ $0.mData != nil })
            else { throw MediaError.unsupportedCodec("audio layout") }
            let bs = Int64(sampleRate)
            var inter = [Float](repeating: 0, count: nch)
            for i in skip..<n {
                for c in 0..<nch {
                    inter[c] = planar ? buffers[c].mData!.assumingMemoryBound(to: Float.self)[i]
                                      : buffers[0].mData!.assumingMemoryBound(to: Float.self)[i * nch + c]
                }
                let out = SurroundFoldDown.fold(interleaved: inter, order: order) ?? [0, 0]
                let f = frame + Int64(i - skip)
                let b = f / bs, o = Int(f - b * bs)
                if st.blocks[b] == nil {
                    st.blocks[b] = Block(left: [Float](repeating: 0, count: sampleRate), right: [Float](repeating: 0, count: sampleRate))
                }
                st.blocks[b]!.left[o] = out[0]; st.blocks[b]!.right[o] = out[1]
            }
            st.cursor = frame + Int64(n - skip)
            withExtendedLifetime(bbuf) {}
            return
        }
        guard buffers.count == 2,
              let lp = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let rp = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { throw MediaError.unsupportedCodec("audio layout") }
        let bs = Int64(sampleRate)
        // A gap between cursor and `frame` stays zero (blocks are zero-initialized).
        for i in skip..<n {
            let f = frame + Int64(i - skip)
            let b = f / bs, o = Int(f - b * bs)
            if st.blocks[b] == nil {
                st.blocks[b] = Block(left: [Float](repeating: 0, count: sampleRate), right: [Float](repeating: 0, count: sampleRate))
            }
            st.blocks[b]!.left[o] = lp[i]; st.blocks[b]!.right[o] = rp[i]
        }
        st.cursor = frame + Int64(n - skip)
        withExtendedLifetime(bbuf) {}
    }
}
