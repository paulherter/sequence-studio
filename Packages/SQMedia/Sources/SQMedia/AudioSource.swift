import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Timeline-rate PCM access: Float32, non-interleaved, stereo, at the sample rate the source was opened with
/// (`SequenceFormat.audioSampleRate`, 48 kHz). Frame numbers are in that rate, relative to the media start.
public protocol AudioSource: Sendable {
    /// Copies up to `count` frames of `channel` (0 = left, 1 = right) starting at `sourceFrame` into `buffer`.
    /// Returns the number of frames written; fewer than `count` only at the end of the media (0 past the end).
    /// The caller zero-fills the rest. Blocking; call from the feeder thread, never from the render thread.
    func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int
}

/// In-memory stereo PCM. Used for tests and for short generated sources.
public final class MemoryAudioSource: AudioSource {
    public let left: [Float], right: [Float]
    public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    public convenience init(mono: [Float]) { self.init(left: mono, right: mono) }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        let data = channel == 0 ? left : right
        guard sourceFrame >= 0, sourceFrame < Int64(data.count), count > 0 else { return 0 }
        let n = min(count, data.count - Int(sourceFrame))
        data.withUnsafeBufferPointer { src in
            buffer.update(from: src.baseAddress! + Int(sourceFrame), count: n)
        }
        return n
    }
}

/// Decodes an audio file with AVAssetReader; the reader's converter delivers Float32 non-interleaved stereo at
/// `sampleRate` (sample-rate conversion and channel up/down-mix happen there, upstream of the mixer).
/// Keeps a small cache of 1 s blocks; sequential forward reads continue the reader, backward or distant reads restart it.
public final class AssetAudioSource: AudioSource, @unchecked Sendable {
    public let sampleRate: Int
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
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.unreadable }
        return AssetAudioSource(asset: asset, track: track, sampleRate: sampleRate)
    }

    private init(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Int) {
        self.asset = asset; self.track = track; self.sampleRate = sampleRate
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
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
        ])
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
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).convertScale(Int32(sampleRate), method: .default)
        var frame = Int64(pts.value)
        var skip = 0
        if frame < st.cursor { skip = Int(st.cursor - frame); frame = st.cursor }   // lead-in before the requested range
        if skip >= n { return }
        var bbuf: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var size = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: abl, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &bbuf)
        guard status == noErr else { throw MediaError.decodeFailed(status) }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count == 2,
              let lp = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let rp = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { throw MediaError.unsupportedCodec("audio layout") }
        let bs = Int64(sampleRate)
        // A gap between cursor and `frame` stays zero (blocks are zero-initialised).
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
