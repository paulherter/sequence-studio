import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import SQCore

public enum WaveformBuilder {
    /// Bumped whenever the peaks a build produces change, so `WaveformDiskCache` entries of older builds miss.
    public static let peaksVersion = 1

    /// Reads the first audio track as float PCM at its native rate and builds the peak pyramid.
    /// Honors task cancellation.
    /// The read loop runs on `BlockingLane.media`, never on the cooperative pool: one build per long clip used to block a
    /// pool thread each, and with as many clips as cores every other `await` in the app stalled (import hang 2026-10-03).
    /// `cache` (default: the app's disk cache): a file built before (same path, size and date) is read back instead.
    /// Builds started inside `BlockingLane.$urgent.withValue(true)` go ahead of the waiting ones.
    public static func build(url: URL, baseBucketSize: Int = WaveformData.defaultBaseBucketSize,
                             cache: WaveformDiskCache? = WaveformDiskCache.shared) async throws -> WaveformData {
        try Task.checkCancellation()
        if let cache, let hit = cache.load(url: url, baseBucketSize: baseBucketSize) { return hit }
        if WebMFile.isWebM(url) {
            return try await BlockingLane.media.run { isCancelled in
                let wf = try buildWebM(url: url, baseBucketSize: baseBucketSize, isCancelled: isCancelled)
                cache?.store(wf, url: url, baseBucketSize: baseBucketSize)
                return wf
            }
        }
        if MXFFile.isMXF(url) {
            return try await BlockingLane.media.run { isCancelled in
                let wf = try buildMXF(url: url, baseBucketSize: baseBucketSize, isCancelled: isCancelled)
                cache?.store(wf, url: url, baseBucketSize: baseBucketSize)
                return wf
            }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WaveformError.noAudioTrack }
        let formats = try await track.load(.formatDescriptions)
        guard let desc = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0
        else { throw WaveformError.noAudioTrack }
        let channels = Int(asbd.mChannelsPerFrame)
        let rate = Int(asbd.mSampleRate.rounded())
        let raw = await rawPlan(track)
        // Integer PCM in a file with a sample table: read its chunks directly (falls back to the reader).
        var chunkFrames: Int64?
        if let raw, chunksEnabled, (try? await track.load(.canProvideSampleCursors)) == true,
           let bytes = try? await track.load(.totalSampleDataLength), let edit = try? await track.load(.timeRange) {
            chunkFrames = storedFramesPlayed(dataLength: bytes, frameBytes: raw.bytes * channels, edit: edit.duration, rate: rate)
        }
        nonisolated(unsafe) let audioTrack = track      // loaded and immutable; only read on the lane
        return try await BlockingLane.media.run { [chunkFrames] isCancelled in
            if let raw, let chunkFrames,
               let wf = try readChunks(url: url, track: audioTrack, channels: channels, rate: rate, raw: raw,
                                       expectedFrames: chunkFrames, baseBucketSize: baseBucketSize, isCancelled: isCancelled) {
                cache?.store(wf, url: url, baseBucketSize: baseBucketSize)
                return wf
            }
            let wf = try read(asset: asset, track: audioTrack, channels: channels, rate: rate, raw: raw,
                              baseBucketSize: baseBucketSize, isCancelled: isCancelled)
            cache?.store(wf, url: url, baseBucketSize: baseBucketSize)
            return wf
        }
    }

    /// F7.10: the peaks of the channels chosen for the media item, so the waveform shows what the clip plays: one lane
    /// when both sides get the same signal, two otherwise. nil map = `build(url:baseBucketSize:cache:)`, unchanged.
    /// Reads through `AudioSources.open` (the source playback uses) at the file's rate, start to end, on the media lane.
    public static func build(url: URL, channelMap: AudioChannelMap?, expectedChannels: Int? = nil, baseBucketSize: Int = WaveformData.defaultBaseBucketSize,
                             cache: WaveformDiskCache? = WaveformDiskCache.shared) async throws -> WaveformData {
        guard let channelMap else { return try await build(url: url, baseBucketSize: baseBucketSize, cache: cache) }
        try Task.checkCancellation()
        if let cache, let hit = cache.load(url: url, baseBucketSize: baseBucketSize, channelMap: channelMap) { return hit }
        let rate = try await nativeRate(url)
        let src: any AudioSource
        do { src = try await AudioSources.open(url: url, sampleRate: rate, channelMap: channelMap, expectedChannels: expectedChannels) }
        catch { throw WaveformError.readFailed("\(error)") }
        return try await BlockingLane.media.run { isCancelled in
            let lanes = src.isMono ? 1 : 2
            var acc = PeakAccumulator(channels: lanes, bucketSize: baseBucketSize)
            var l = [Float](repeating: 0, count: rate), r = l
            var at: Int64 = 0
            while true {
                if isCancelled() { throw CancellationError() }
                let n = try l.withUnsafeMutableBufferPointer { try src.read(from: at, count: rate, into: $0.baseAddress!, channel: 0) }
                guard n > 0 else { break }
                if lanes == 2 {
                    r.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                    _ = try r.withUnsafeMutableBufferPointer { try src.read(from: at, count: n, into: $0.baseAddress!, channel: 1) }
                }
                l.withUnsafeBufferPointer { lp in
                    r.withUnsafeBufferPointer { rp in
                        acc.add(planar: lanes == 1 ? [lp.baseAddress!] : [lp.baseAddress!, rp.baseAddress!], frames: n)
                    }
                }
                at += Int64(n)
                if n < rate { break }
            }
            guard acc.frames > 0 else { throw WaveformError.noAudioTrack }
            let wf = pyramid(acc, rate: rate)
            cache?.store(wf, url: url, baseBucketSize: baseBucketSize, channelMap: channelMap)
            return wf
        }
    }

    /// Sample rate of the file's (first) audio.
    private static func nativeRate(_ url: URL) async throws -> Int {
        if WebMFile.isWebM(url) {
            guard let t = try WebMFile.open(url).track(.audio) else { throw WaveformError.noAudioTrack }
            return t.codecID == "A_OPUS" ? 48_000 : max(8_000, Int(t.sampleRate.rounded()))
        }
        if MXFFile.isMXF(url) {
            let file: MXFFile
            do { file = try MXFFile.open(url) } catch { throw WaveformError.readFailed("\(error)") }
            guard let rate = file.soundTracks.first?.sound?.sampleRate, rate > 0 else { throw WaveformError.noAudioTrack }
            return rate
        }
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
              let desc = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee, asbd.mSampleRate > 0
        else { throw WaveformError.noAudioTrack }
        return Int(asbd.mSampleRate.rounded())
    }

    /// Stored integer PCM that `read` takes as it lies in the file (docs/PLAYBACK-PERF.md "Import: waveforms of PCM audio").
    struct RawPCM: Equatable, Sendable {
        /// Bytes per sample: 2 or 3.
        var bytes: Int
        var bigEndian: Bool
    }

    /// `SQ_WAVEFORM_RAW=0` sends integer PCM through the float converter like everything else (A/B bench only).
    static let rawEnabled = ProcessInfo.processInfo.environment["SQ_WAVEFORM_RAW"] != "0"

    /// Packed signed 16 or 24 bit interleaved PCM at a whole sample rate: what the float converter turns into
    /// sample / 2^(bits-1) and nothing else (no resampling, no channel mapping), so the stored bytes give the same peaks.
    static func rawLayout(_ a: AudioStreamBasicDescription) -> RawPCM? {
        let f = a.mFormatFlags
        guard a.mFormatID == kAudioFormatLinearPCM, f & kAudioFormatFlagIsSignedInteger != 0, f & kAudioFormatFlagIsPacked != 0,
              f & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved) == 0,
              a.mBitsPerChannel == 16 || a.mBitsPerChannel == 24, a.mChannelsPerFrame > 0,
              a.mBytesPerFrame == a.mBitsPerChannel / 8 * a.mChannelsPerFrame, a.mFramesPerPacket == 1,
              a.mSampleRate == a.mSampleRate.rounded()
        else { return nil }
        return RawPCM(bytes: Int(a.mBitsPerChannel / 8), bigEndian: f & kAudioFormatFlagIsBigEndian != 0)
    }

    /// The raw layout of a track that plays its stored samples start to end, once, at speed 1 (one sample description,
    /// one edit from media time 0): only then is "every stored sample" what the converter path reads. nil = use the converter.
    static func rawPlan(_ track: AVAssetTrack) async -> RawPCM? {
        guard rawEnabled, let formats = try? await track.load(.formatDescriptions), formats.count == 1,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formats[0])?.pointee, let layout = rawLayout(asbd),
              let segments = try? await track.load(.segments), segments.count == 1, let s = segments.first, !s.isEmpty,
              s.timeMapping.source.start == .zero, s.timeMapping.target.start == .zero,
              s.timeMapping.source.duration == s.timeMapping.target.duration,
              let range = try? await track.load(.timeRange), range.start == .zero, s.timeMapping.source.duration == range.duration
        else { return nil }
        return layout
    }

    /// Integer PCM as stored: no converter, the samples go from the file's bytes to floats here (same values: an integer
    /// times a power of two is exact). Falls back to the converter when the reader does not hand out the stored layout.
    private static func readRaw(asset: AVURLAsset, track: AVAssetTrack, channels: Int, rate: Int, raw: RawPCM, baseBucketSize: Int,
                                isCancelled: () -> Bool) throws -> WaveformData? {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }

        var acc = PeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        let frameBytes = raw.bytes * channels
        var conv = RawConverter(raw: raw, channels: channels)
        while let sb = out.copyNextSampleBuffer() {
            if isCancelled() { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let n = length / frameBytes
            if n == 0 { continue }
            // A buffer that is not whole frames, or carries a trim, is not "the stored samples": let the converter do it.
            guard length == n * frameBytes, CMSampleBufferGetNumSamples(sb) == n,
                  CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) == nil,
                  CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, attachmentModeOut: nil) == nil
            else { reader.cancelReading(); return nil }
            try conv.add(frames: n, to: &acc) { dst in
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: dst)
                guard status == kCMBlockBufferNoErr else { throw WaveformError.readFailed("copy \(status)") }
            }
        }
        if reader.status == .failed { return nil }
        if isCancelled() { throw CancellationError() }
        return pyramid(acc, rate: rate)
    }

    /// Stored integer PCM bytes to floats (an integer times a power of two: exact) into a peak accumulator. Buffers are kept
    /// between calls. Shared by the reader path and the chunk path, so both give the same peaks bit for bit.
    struct RawConverter {
        let raw: RawPCM, channels: Int
        private var bytes: [UInt8] = [], ints16: [Int16] = [], ints32: [Int32] = [], floats: [Float] = []
        init(raw: RawPCM, channels: Int) { self.raw = raw; self.channels = channels }

        /// `fill` writes the `frames` stored frames (raw bytes, `frames * bytes * channels` of them) to the pointer it gets.
        mutating func add(frames n: Int, to acc: inout PeakAccumulator, fill: (UnsafeMutableRawPointer) throws -> Void) rethrows {
            let count = n * channels, length = count * raw.bytes
            if floats.count < count { floats = [Float](repeating: 0, count: count) }
            if raw.bytes == 2 {
                if ints16.count < count { ints16 = [Int16](repeating: 0, count: count) }
                try ints16.withUnsafeMutableBytes { try fill($0.baseAddress!) }
                if raw.bigEndian {
                    ints16.withUnsafeMutableBufferPointer { p in for i in 0..<count { p[i] = Int16(bigEndian: p[i]) } }
                }
                ints16.withUnsafeBufferPointer { src in
                    floats.withUnsafeMutableBufferPointer { vDSP_vflt16(src.baseAddress!, 1, $0.baseAddress!, 1, vDSP_Length(count)) }
                }
            } else {
                if bytes.count < length { bytes = [UInt8](repeating: 0, count: length) }
                if ints32.count < count { ints32 = [Int32](repeating: 0, count: count) }
                try bytes.withUnsafeMutableBytes { try fill($0.baseAddress!) }
                let (lo, hi) = raw.bigEndian ? (2, 0) : (0, 2)
                bytes.withUnsafeBufferPointer { b in
                    ints32.withUnsafeMutableBufferPointer { p in
                        for i in 0..<count {
                            let o = i * 3
                            p[i] = Int32(Int8(bitPattern: b[o + hi])) << 16 | Int32(b[o + 1]) << 8 | Int32(b[o + lo])
                        }
                    }
                }
                ints32.withUnsafeBufferPointer { src in
                    floats.withUnsafeMutableBufferPointer { vDSP_vflt32(src.baseAddress!, 1, $0.baseAddress!, 1, vDSP_Length(count)) }
                }
            }
            var scale: Float = raw.bytes == 2 ? 1 / 32_768 : 1 / 8_388_608
            floats.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(count)) }
            floats.withUnsafeBufferPointer { acc.add(interleaved: $0.baseAddress!, frames: n) }
        }
    }

    /// `SQ_WAVEFORM_CHUNKS=0`: integer PCM in a QuickTime / MP4 file goes through `AVAssetReader` again (A/B bench only).
    static let chunksEnabled = ProcessInfo.processInfo.environment["SQ_WAVEFORM_CHUNKS"] != "0"

    /// The frame count of the stored samples when the track's one edit plays exactly all of them (`dataLength` bytes of
    /// `frameBytes` frames, edit `edit` long at `rate`); nil when the edit is shorter or longer than the media (a cut tail
    /// or head: the reader trims it, the chunk path would not) or the numbers do not fit.
    static func storedFramesPlayed(dataLength: Int64, frameBytes: Int, edit: CMTime, rate: Int) -> Int64? {
        guard frameBytes > 0, dataLength > 0, dataLength % Int64(frameBytes) == 0, edit.isNumeric, edit.timescale > 0,
              edit.value > 0, rate > 0 else { return nil }
        let frames = dataLength / Int64(frameBytes)
        // frames / rate == value / timescale, exactly (no overflow).
        let (a, o1) = frames.multipliedReportingOverflow(by: Int64(edit.timescale))
        let (b, o2) = edit.value.multipliedReportingOverflow(by: Int64(rate))
        guard !o1, !o2, a == b else { return nil }
        return frames
    }

    /// Largest single `pread` of the chunk path; a bigger chunk is read in whole-frame pieces of at most this size.
    static let maxChunkPieceBytes = 4 << 20

    /// Integer PCM read straight from the file, chunk by chunk through the track's sample table (`AVSampleCursor` storage
    /// ranges, one `pread` each), so the build no longer waits for the asset reader to hand out the audio that lies between
    /// the video samples (docs/PLAYBACK-PERF.md "Import: waveform chunk reads"). Same bytes, same converter: same peaks.
    /// nil (the caller then uses the reader) for anything that is not plain whole-frame chunks in this one file, or when the
    /// frames read are not the track's length.
    static func readChunks(url: URL, track: AVAssetTrack, channels: Int, rate: Int, raw: RawPCM, expectedFrames: Int64,
                           baseBucketSize: Int, maxPieceBytes: Int = maxChunkPieceBytes,
                           isCancelled: () -> Bool) throws -> WaveformData? {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let fileSize = Int64(st.st_size)
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let frameBytes = raw.bytes * channels
        var acc = PeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        var conv = RawConverter(raw: raw, channels: channels)
        var total: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            guard cursor.currentSampleIndexInChunk == 0,
                  let where_ = cursor.currentChunkStorageURL, where_.standardizedFileURL.resolvingSymlinksInPath() == file
            else { return nil }
            let info = cursor.currentChunkInfo, range = cursor.currentChunkStorageRange
            let n = info.chunkSampleCount
            // A chunk table that does not fit the file (corrupt or hostile) falls back before anything is allocated.
            let (bytes, overflow) = n.multipliedReportingOverflow(by: Int64(frameBytes))
            guard n > 0, !overflow, info.chunkHasUniformSampleSizes.boolValue, info.chunkHasUniformFormatDescriptions.boolValue,
                  range.offset >= 0, range.length == bytes, range.offset <= fileSize, bytes <= fileSize - range.offset,
                  total + n <= expectedFrames else { return nil }
            let pieceFrames = max(1, maxPieceBytes / frameBytes)
            var done: Int64 = 0
            while done < n {
                let k = Int(min(Int64(pieceFrames), n - done)), start = range.offset + done * Int64(frameBytes)
                var failed = false
                conv.add(frames: k, to: &acc) { dst in
                    let length = k * frameBytes
                    var got = 0
                    while got < length {
                        let r = pread(fd, dst + got, length - got, off_t(start) + off_t(got))
                        if r <= 0 { failed = true; return }
                        got += r
                    }
                }
                if failed { return nil }
                done += Int64(k)
            }
            total += n
            if cursor.stepInDecodeOrder(byCount: n) != n { break }
        }
        guard total == expectedFrames else { return nil }
        if isCancelled() { throw CancellationError() }
        return pyramid(acc, rate: rate)
    }

    private static func read(asset: AVURLAsset, track: AVAssetTrack, channels: Int, rate: Int, raw: RawPCM? = nil, baseBucketSize: Int,
                             isCancelled: () -> Bool) throws -> WaveformData {
        if let raw, let wf = try readRaw(asset: asset, track: track, channels: channels, rate: rate, raw: raw,
                                         baseBucketSize: baseBucketSize, isCancelled: isCancelled) { return wf }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw WaveformError.readFailed("cannot add output") }
        reader.add(out)
        guard reader.startReading() else { throw WaveformError.readFailed(reader.error?.localizedDescription ?? "startReading") }

        var acc = PeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        var scratch: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            if isCancelled() { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / (4 * channels)
            if n == 0 { continue }
            // Read the samples in place when the block is one aligned piece (it is from the PCM converter); copy otherwise.
            var length = 0
            var data: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &data) == kCMBlockBufferNoErr,
               let data, length >= n * channels * 4, Int(bitPattern: data) % MemoryLayout<Float>.alignment == 0 {
                acc.add(interleaved: UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), frames: n)
                continue
            }
            if scratch.count < n * channels { scratch = [Float](repeating: 0, count: n * channels) }
            let status = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * channels * 4, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw WaveformError.readFailed("copy \(status)") }
            scratch.withUnsafeBufferPointer { acc.add(interleaved: $0.baseAddress!, frames: n) }
        }
        if reader.status == .failed { throw WaveformError.readFailed(reader.error?.localizedDescription ?? "read") }
        if isCancelled() { throw CancellationError() }
        return pyramid(acc, rate: rate)
    }

    private static func pyramid(_ acc: PeakAccumulator, rate: Int) -> WaveformData {
        var acc = acc
        let frames = acc.frames, channels = acc.channels
        var levels = [acc.finish()]
        while levels[levels.count - 1].count / (2 * channels) > 2 {
            levels.append(mip(levels[levels.count - 1], channels: channels))
        }
        return WaveformData(sampleRate: rate, channelCount: channels, totalFrames: frames, baseBucketSize: acc.bucketSize, levels: levels)
    }

    /// WebM audio (Opus / Vorbis) through `WebMAudioSource` at its native rate, streamed start to end (no block cache).
    static func buildWebM(url: URL, baseBucketSize: Int, isCancelled: () -> Bool = { false }) throws -> WaveformData {
        let file = try WebMFile.open(url)
        guard let t = file.track(.audio) else { throw WaveformError.noAudioTrack }
        let rate = t.codecID == "A_OPUS" ? 48_000 : max(8_000, Int(t.sampleRate.rounded()))
        let src: WebMAudioSource
        do { src = try WebMAudioSource(file: file, sampleRate: rate) } catch { throw WaveformError.readFailed("\(error)") }
        let channels = src.isMono ? 1 : 2
        var acc = PeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        try src.streamAll(isCancelled: isCancelled) { left, right, n in
            if channels == 1 { acc.add(planar: [left], frames: n) } else { acc.add(planar: [left, right], frames: n) }
        }
        return pyramid(acc, rate: rate)
    }

    /// MXF PCM: the same stereo mix playback hears (first two source channels, or mono).
    static func buildMXF(url: URL, baseBucketSize: Int, isCancelled: () -> Bool = { false }) throws -> WaveformData {
        let file: MXFFile
        do { file = try MXFFile.open(url) } catch { throw WaveformError.readFailed("\(error)") }
        guard let rate = file.soundTracks.first?.sound?.sampleRate else { throw WaveformError.noAudioTrack }
        let src: MXFAudioSource
        do { src = try MXFAudioSource(file: file, sampleRate: rate) } catch { throw WaveformError.readFailed("\(error)") }
        let channels = src.isMono ? 1 : 2
        var acc = PeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        try src.streamAll(isCancelled: isCancelled) { left, right, n in
            if channels == 1 { acc.add(planar: [left], frames: n) } else { acc.add(planar: [left, right], frames: n) }
        }
        return pyramid(acc, rate: rate)
    }

    /// Halves the bucket count: bucket i = merge of buckets 2i and 2i+1.
    static func mip(_ src: [Float], channels: Int) -> [Float] { PeakPyramid.mip(src, channels: channels) }
}
