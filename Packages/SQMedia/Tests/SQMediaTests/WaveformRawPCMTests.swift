import AVFoundation
import CoreMedia
import Foundation
import SQCore
import Testing
@testable import SQMedia

/// Waveforms of integer PCM (camera MP4 / MOV, WAV, AIFF) read the stored samples without the float converter
/// (docs/PLAYBACK-PERF.md "Import: waveforms of PCM audio"). The peaks must be exactly those of the converter path, which
/// is frozen as `WaveformSpeedTests.Legacy.buildAsset`.
@Suite(.serialized) struct WaveformRawPCMTests {
    struct Kind: Sendable, CustomStringConvertible {
        var ext: String, bits: Int, bigEndian: Bool, channels: Int, float = false
        var description: String { "\(ext) \(bits) bit \(bigEndian ? "BE" : "LE") \(channels) ch\(float ? " float" : "")" }
    }

    /// 1.3 s of noise with full-scale and silent stretches, written as integer (or float) PCM.
    private func write(_ k: Kind) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rawpcm-\(UUID().uuidString).\(k.ext)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: k.channels,
            AVLinearPCMBitDepthKey: k.bits, AVLinearPCMIsFloatKey: k.float, AVLinearPCMIsBigEndianKey: k.bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = 62_400
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for c in 0..<k.channels {
            let p = buffer.floatChannelData![c]
            for i in 0..<frames {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
                switch i / 4_800 % 4 {
                case 0: p[i] = noise * 0.4
                case 1: p[i] = i % 2 == c % 2 ? 1 : -1          // full scale both ways
                case 2: p[i] = 0
                default: p[i] = noise
                }
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func plan(_ url: URL) async throws -> WaveformBuilder.RawPCM? {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        return await WaveformBuilder.rawPlan(track)
    }

    @Test(.serialized, arguments: [
        Kind(ext: "wav", bits: 16, bigEndian: false, channels: 2),
        Kind(ext: "wav", bits: 16, bigEndian: false, channels: 1),
        Kind(ext: "aiff", bits: 16, bigEndian: true, channels: 2),
        Kind(ext: "wav", bits: 24, bigEndian: false, channels: 2),
        Kind(ext: "aiff", bits: 24, bigEndian: true, channels: 1),
        Kind(ext: "caf", bits: 16, bigEndian: true, channels: 2),
    ])
    func integerPCMIsReadRawWithTheConvertersPeaks(kind: Kind) async throws {
        let url = try write(kind)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await plan(url) == WaveformBuilder.RawPCM(bytes: kind.bits / 8, bigEndian: kind.bigEndian))
        let new = try await WaveformBuilder.build(url: url, cache: nil)
        let old = try await WaveformSpeedTests.Legacy.buildAsset(url)
        #expect(new == old)
        #expect(new.totalFrames == 62_400)
        // Full scale shows as full scale (the scale factor is the converter's).
        let peak = new.bucket(level: 0, index: 4_800 / new.baseBucketSize + 1, channel: 0)
        #expect(peak.min == -1)
    }

    /// The same PCM passed through into a QuickTime movie (optionally with a small H.264 track interleaved, as in a camera
    /// file), so the audio lies in chunks between video samples.
    private func mux(_ wav: URL, video: Bool, fileType: AVFileType = .mov, ext: String = "mov", end: CMTime? = nil) async throws -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rawpcm-mux-\(UUID().uuidString).\(ext)")
        let asset = AVURLAsset(url: wav)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        #expect(reader.startReading())
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fd)
        guard writer.canAdd(audioIn) else { return nil }
        writer.add(audioIn)
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var videoIn: AVAssetWriterInput?
        if video {
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
            v.expectsMediaDataInRealTime = false
            writer.add(v); videoIn = v
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64])
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var frame = 0, audioDone = false
        while !audioDone || (video && frame < 40) {
            if !audioDone, audioIn.isReadyForMoreMediaData {
                if let sb = out.copyNextSampleBuffer() { audioIn.append(sb) } else { audioIn.markAsFinished(); audioDone = true }
            }
            if let v = videoIn, let a = adaptor, frame < 40, v.isReadyForMoreMediaData {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
                let b = try #require(pb)
                CVPixelBufferLockBaseAddress(b, [])
                memset(CVPixelBufferGetBaseAddress(b), Int32(frame * 5), CVPixelBufferGetDataSize(b))
                CVPixelBufferUnlockBaseAddress(b, [])
                a.append(b, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
                frame += 1
                if frame == 40 { v.markAsFinished() }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// PCM inside a movie is read chunk by chunk from the file (no reader), with the converter's peaks bit for bit.
    @Test(.serialized, arguments: [
        Kind(ext: "wav", bits: 16, bigEndian: false, channels: 2),
        Kind(ext: "aiff", bits: 16, bigEndian: true, channels: 2),
        Kind(ext: "wav", bits: 24, bigEndian: false, channels: 2),
        Kind(ext: "aiff", bits: 24, bigEndian: true, channels: 1),
    ])
    func pcmInAMovieIsReadByChunks(kind: Kind) async throws {
        let wav = try write(kind)
        defer { try? FileManager.default.removeItem(at: wav) }
        for video in [true, false] {
            let mov = try #require(try await mux(wav, video: video))
            defer { try? FileManager.default.removeItem(at: mov) }
            let raw = try #require(try await plan(mov))
            let track = try #require(try await AVURLAsset(url: mov).loadTracks(withMediaType: .audio).first)
            #expect(try await track.load(.canProvideSampleCursors))
            let bytes = try await track.load(.totalSampleDataLength)
            let frameBytes = Int64(raw.bytes * kind.channels)
            #expect(bytes == 62_400 * frameBytes)
            let chunks = try WaveformBuilder.readChunks(url: mov, track: track, channels: kind.channels, rate: 48_000, raw: raw,
                                                        expectedFrames: bytes / frameBytes, baseBucketSize: WaveformData.defaultBaseBucketSize,
                                                        isCancelled: { false })
            let old = try await WaveformSpeedTests.Legacy.buildAsset(mov)
            #expect(chunks == old, "\(kind) video \(video): chunk path taken and equal")
            #expect(try await WaveformBuilder.build(url: mov, cache: nil) == old)
            #expect(old == (try await WaveformSpeedTests.Legacy.buildAsset(wav)))
            // A wrong length (as if a chunk were missing) falls back instead of returning short peaks.
            #expect(try WaveformBuilder.readChunks(url: mov, track: track, channels: kind.channels, rate: 48_000, raw: raw,
                                                   expectedFrames: bytes / frameBytes + 1, baseBucketSize: 256, isCancelled: { false }) == nil)
        }
    }

    /// A movie whose edit ends before its stored audio (a cut tail): the chunk path would read the cut frames too, so it is
    /// not taken; the build gives the converter's peaks of the edit only.
    @Test func editShorterThanTheMediaKeepsTheReader() async throws {
        let kind = Kind(ext: "wav", bits: 16, bigEndian: false, channels: 2)
        let wav = try write(kind)
        defer { try? FileManager.default.removeItem(at: wav) }
        let mov = try #require(try await mux(wav, video: false, end: CMTime(value: 48_000, timescale: 48_000)))
        defer { try? FileManager.default.removeItem(at: mov) }
        let track = try #require(try await AVURLAsset(url: mov).loadTracks(withMediaType: .audio).first)
        let bytes = try await track.load(.totalSampleDataLength)
        let edit = try await track.load(.timeRange)
        #expect(bytes == 62_400 * 4, "the cut tail stays stored")
        #expect(edit.duration.seconds < 1.3)
        #expect(WaveformBuilder.storedFramesPlayed(dataLength: bytes, frameBytes: 4, edit: edit.duration, rate: 48_000) == nil)
        let old = try await WaveformSpeedTests.Legacy.buildAsset(mov)
        let new = try await WaveformBuilder.build(url: mov, cache: nil)
        #expect(new == old)
        #expect(new.totalFrames < 62_400)
    }

    @Test func storedFramesPlayedNeedsTheExactEdit() {
        let f = WaveformBuilder.storedFramesPlayed
        #expect(f(48_000 * 4, 4, CMTime(value: 1, timescale: 1), 48_000) == 48_000)
        #expect(f(48_000 * 4, 4, CMTime(value: 600, timescale: 600), 48_000) == 48_000)
        #expect(f(48_000 * 4, 4, CMTime(value: 599, timescale: 600), 48_000) == nil)
        #expect(f(48_000 * 4 + 2, 4, CMTime(value: 1, timescale: 1), 48_000) == nil)
        #expect(f(0, 4, CMTime(value: 1, timescale: 1), 48_000) == nil)
        #expect(f(Int64.max - 3, 4, CMTime(value: Int64.max / 2, timescale: 1_000_000_000), 48_000) == nil)
        #expect(f(48_000 * 4, 4, .indefinite, 48_000) == nil)
    }

    /// Big chunks are read in pieces (same peaks), and a chunk table pointing past the end of the file falls back to the
    /// reader instead of allocating or crashing.
    @Test func chunkPiecesAndACorruptTable() async throws {
        let kind = Kind(ext: "wav", bits: 24, bigEndian: false, channels: 2)
        let wav = try write(kind)
        defer { try? FileManager.default.removeItem(at: wav) }
        let mov = try #require(try await mux(wav, video: true))
        defer { try? FileManager.default.removeItem(at: mov) }
        let raw = try #require(try await plan(mov))
        let track = try #require(try await AVURLAsset(url: mov).loadTracks(withMediaType: .audio).first)
        let old = try await WaveformSpeedTests.Legacy.buildAsset(mov)
        #expect(try WaveformBuilder.readChunks(url: mov, track: track, channels: 2, rate: 48_000, raw: raw, expectedFrames: 62_400,
                                               baseBucketSize: WaveformData.defaultBaseBucketSize, maxPieceBytes: 1000,
                                               isCancelled: { false }) == old)
        // Point every chunk offset (stco) far past the end of the file.
        var data = try Data(contentsOf: mov)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rawpcm-bad-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: bad) }
        var patched = 0
        var at = data.startIndex
        while let r = data.range(of: Data("stco".utf8), in: at..<data.endIndex) {
            let count = data[r.upperBound + 4 ..< r.upperBound + 8].reduce(0) { $0 << 8 | Int($1) }
            for e in 0..<count {
                let o = r.upperBound + 8 + e * 4
                data.replaceSubrange(o ..< o + 4, with: [0x7F, 0xFF, 0x00, 0x00])
            }
            patched += 1
            at = r.upperBound
        }
        #expect(patched > 0)
        try data.write(to: bad)
        let badTrack = try #require(try await AVURLAsset(url: bad).loadTracks(withMediaType: .audio).first)
        #expect(try WaveformBuilder.readChunks(url: bad, track: badTrack, channels: 2, rate: 48_000, raw: raw, expectedFrames: 62_400,
                                               baseBucketSize: 256, isCancelled: { false }) == nil)
        _ = try? await WaveformBuilder.build(url: bad, cache: nil)          // the reader may fail; it must not crash
    }

    @Test func otherFormatsKeepTheConverter() async throws {
        for kind in [Kind(ext: "wav", bits: 32, bigEndian: false, channels: 2, float: true),
                     Kind(ext: "wav", bits: 32, bigEndian: false, channels: 2)] {
            let url = try write(kind)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try await plan(url) == nil, "\(kind)")
            #expect(try await WaveformBuilder.build(url: url, cache: nil) == (try await WaveformSpeedTests.Legacy.buildAsset(url)))
        }
    }

    @Test func layoutNeedsPackedSignedInterleavedIntegers() {
        func asbd(bits: UInt32, flags: AudioFormatFlags, channels: UInt32 = 2, rate: Double = 48_000,
                  id: AudioFormatID = kAudioFormatLinearPCM) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: rate, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: bits / 8 * channels,
                                        mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels, mChannelsPerFrame: channels,
                                        mBitsPerChannel: bits, mReserved: 0)
        }
        let packed = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: packed)) == .init(bytes: 2, bigEndian: false))
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: packed | kAudioFormatFlagIsBigEndian)) == .init(bytes: 2, bigEndian: true))
        #expect(WaveformBuilder.rawLayout(asbd(bits: 24, flags: packed)) == .init(bytes: 3, bigEndian: false))
        #expect(WaveformBuilder.rawLayout(asbd(bits: 32, flags: packed)) == nil)
        #expect(WaveformBuilder.rawLayout(asbd(bits: 8, flags: packed)) == nil)
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: kAudioFormatFlagIsPacked)) == nil)               // unsigned
        #expect(WaveformBuilder.rawLayout(asbd(bits: 32, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)) == nil)
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: packed | kAudioFormatFlagIsNonInterleaved)) == nil)
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: packed, rate: 44_100.5)) == nil)                 // the converter resamples
        #expect(WaveformBuilder.rawLayout(asbd(bits: 16, flags: packed, id: kAudioFormatMPEG4AAC)) == nil)
    }

    /// `RawConverter` against the plain per-sample formulation (integer from its bytes, times a power of two): same buckets,
    /// bit for bit, for every width and byte order, the extremes included, over pieces of odd lengths.
    @Test(arguments: [(2, false), (2, true), (3, false), (3, true)])
    func converterEqualsPerSampleReference(width: Int, bigEndian: Bool) {
        let channels = 2
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
        let pieces = [1, 7, 256, 255, 1031, 3]
        var conv = WaveformBuilder.RawConverter(raw: .init(bytes: width, bigEndian: bigEndian), channels: channels)
        var got = PeakAccumulator(channels: channels, bucketSize: 64), want = PeakAccumulator(channels: channels, bucketSize: 64)
        for (n, frames) in pieces.enumerated() {
            var data = (0..<frames * channels * width).map { _ in next() }
            if n == 1 { data = data.enumerated().map { $0.offset % 4 < 2 ? 0x80 : 0x7F } }      // extremes
            if n == 2 { data = data.enumerated().map { _ in 0xFF } }
            conv.add(frames: frames, to: &got) { dst in data.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: data.count) } }
            var floats = [Float](repeating: 0, count: frames * channels)
            for i in 0..<frames * channels {
                let b = Array(data[i * width..<(i + 1) * width])
                let be = bigEndian ? b : Array(b.reversed())
                var v: Int32 = Int32(Int8(bitPattern: be[0]))
                for k in 1..<width { v = v << 8 | Int32(be[k]) }
                floats[i] = Float(v) * (width == 2 ? 1 / 32_768 : 1 / 8_388_608)
            }
            floats.withUnsafeBufferPointer { want.add(interleaved: $0.baseAddress!, frames: frames) }
        }
        #expect(got.finish() == want.finish())
    }
}
