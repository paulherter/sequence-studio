import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

/// Waveform speed-up 2026-10-04 (docs/PLAYBACK-PERF.md "Import waveforms"): the new peak paths must give exactly the
/// peaks of the old ones. The old code is frozen below (and `LegacyVorbisDecoder`) as the differential reference.
@Suite(.serialized) struct WaveformSpeedTests {
    static let media = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../TestMedia").standardized

    // MARK: frozen reference (the code before the speed-up)

    enum Legacy {
        static func flush(_ base: inout [Float], _ lo: inout [Float], _ hi: inout [Float]) {
            for c in 0..<lo.count { base.append(lo[c]); base.append(hi[c]); lo[c] = .greatestFiniteMagnitude; hi[c] = -.greatestFiniteMagnitude }
        }

        /// Old min/max loop over interleaved frames.
        static func peaks(_ chunks: [[Float]], channels: Int, bucket: Int) -> (base: [Float], frames: Int) {
            var base: [Float] = [], frames = 0, inBucket = 0
            var lo = [Float](repeating: .greatestFiniteMagnitude, count: channels)
            var hi = [Float](repeating: -.greatestFiniteMagnitude, count: channels)
            for s in chunks {
                let n = s.count / channels
                for f in 0..<n {
                    for c in 0..<channels {
                        let v = s[f * channels + c]
                        if v < lo[c] { lo[c] = v }
                        if v > hi[c] { hi[c] = v }
                    }
                    inBucket += 1
                    if inBucket == bucket { flush(&base, &lo, &hi); inBucket = 0 }
                }
                frames += n
            }
            if inBucket > 0 { flush(&base, &lo, &hi) }
            return (base, frames)
        }

        static func levels(_ base: [Float], channels: Int) -> [[Float]] {
            var levels = [base]
            while levels[levels.count - 1].count / (2 * channels) > 2 { levels.append(WaveformBuilder.mip(levels[levels.count - 1], channels: channels)) }
            return levels
        }

        /// Old AVAssetReader path (float interleaved output, copy, scalar loop).
        static func buildAsset(_ url: URL) async throws -> WaveformData {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WaveformError.noAudioTrack }
            let desc = try await track.load(.formatDescriptions).first!
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee
            let channels = Int(asbd.mChannelsPerFrame), rate = Int(asbd.mSampleRate.rounded())
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
            ])
            reader.add(out)
            reader.startReading()
            var chunks: [[Float]] = []
            while let sb = out.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(block) / (4 * channels)
                var s = [Float](repeating: 0, count: n * channels)
                _ = s.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * channels * 4, destination: $0.baseAddress!) }
                chunks.append(s)
            }
            let (base, frames) = peaks(chunks, channels: channels, bucket: WaveformData.defaultBaseBucketSize)
            return WaveformData(sampleRate: rate, channelCount: channels, totalFrames: frames, baseBucketSize: WaveformData.defaultBaseBucketSize,
                                levels: levels(base, channels: channels))
        }

        /// Old WebM path: per-channel `WebMAudioSource.read` in 16 384-frame chunks.
        static func buildWebM(_ url: URL) throws -> WaveformData {
            let file = try WebMFile.open(url)
            let t = file.track(.audio)!
            let rate = t.codecID == "A_OPUS" ? 48_000 : max(8_000, Int(t.sampleRate.rounded()))
            let src = try WebMAudioSource(file: file, sampleRate: rate)
            let channels = src.isMono ? 1 : 2
            let chunk = 16_384
            var bufs = (0..<channels).map { _ in [Float](repeating: 0, count: chunk) }
            var pos: Int64 = 0
            var chunks: [[Float]] = []
            while pos < src.totalFrames {
                var n = 0
                for c in 0..<channels { n = try bufs[c].withUnsafeMutableBufferPointer { try src.read(from: pos, count: chunk, into: $0.baseAddress!, channel: c) } }
                if n == 0 { break }
                var s = [Float](repeating: 0, count: n * channels)
                for f in 0..<n { for c in 0..<channels { s[f * channels + c] = bufs[c][f] } }
                chunks.append(s)
                pos += Int64(n)
            }
            let (base, frames) = peaks(chunks, channels: channels, bucket: WaveformData.defaultBaseBucketSize)
            return WaveformData(sampleRate: rate, channelCount: channels, totalFrames: frames, baseBucketSize: WaveformData.defaultBaseBucketSize,
                                levels: levels(base, channels: channels))
        }
    }

    // MARK: peak accumulator

    @Test(arguments: [1, 2, 6])
    func accumulatorMatchesScalarLoop(channels: Int) {
        var rng = SystemRandomNumberGenerator()
        // Odd chunk sizes so buckets straddle chunk boundaries; one chunk empty; a partial last bucket.
        let sizes = [0, 1, 255, 256, 257, 1000, 3, 4096, 77]
        let chunks = sizes.map { n in (0..<(n * channels)).map { _ in Float.random(in: -1...1, using: &rng) } }
        for bucket in [1, 7, 256] {
            let ref = Legacy.peaks(chunks, channels: channels, bucket: bucket)
            var acc = PeakAccumulator(channels: channels, bucketSize: bucket)
            for c in chunks { c.withUnsafeBufferPointer { acc.add(interleaved: $0.baseAddress!, frames: c.count / channels) } }
            #expect(acc.frames == ref.frames)
            #expect(acc.finish() == ref.base)
            // Planar input gives the same.
            var planar = PeakAccumulator(channels: channels, bucketSize: bucket)
            for c in chunks {
                let n = c.count / channels
                let ptrs = (0..<channels).map { ch in
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
                    for i in 0..<n { p[i] = c[i * channels + ch] }
                    return p
                }
                planar.add(planar: ptrs.map { UnsafePointer($0) }, frames: n)
                ptrs.forEach { $0.deallocate() }
            }
            #expect(planar.finish() == ref.base)
        }
    }

    // MARK: AVAssetReader path

    @Test func assetPathMatchesLegacy() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 75
        spec.audioClicks = [CMTime(value: 1, timescale: 2), CMTime(value: 17, timescale: 10)]
        let url = try await TestClipWriter.write(spec)
        let new = try await WaveformBuilder.build(url: url, cache: nil)
        #expect(new == (try await Legacy.buildAsset(url)))
    }

    /// Real files: `SQ_WAVEFORM_DIFF_DIR=<dir>` compares every audio-carrying media file under it (old vs new peaks).
    @Test func realMediaMatchesLegacy() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SQ_WAVEFORM_DIFF_DIR"] else { return }
        let exts: Set<String> = ["mp4", "mov", "m4v", "wav", "aif", "aiff", "mp3", "m4a", "webm"]
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
        var compared = 0
        while let u = e?.nextObject() as? URL {
            guard exts.contains(u.pathExtension.lowercased()) else { continue }
            let old: WaveformData
            do { old = WebMFile.isWebM(u) ? try Legacy.buildWebM(u) : try await Legacy.buildAsset(u) } catch { continue }
            let new = try await WaveformBuilder.build(url: u, cache: nil)
            #expect(new == old, "\(u.lastPathComponent)")
            compared += 1
        }
        print("realMediaMatchesLegacy: \(compared) files compared")
    }

    // MARK: WebM / Vorbis

    @Test(arguments: ["sample-vp9-vorbis-long.webm", "sample-vp9-vorbis.webm"])
    func vorbisDecoderMatchesLegacy(name: String) throws {
        let u = Self.media.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        let file = try WebMFile.open(u)
        let t = try #require(file.track(.audio))
        let new = try VorbisDecoder(codecPrivate: t.codecPrivate), old = try LegacyVorbisDecoder(codecPrivate: t.codecPrivate)
        var packets = 0
        for b in file.blocks(of: t.number) {
            let p = file.payload(b)
            let a = new.decode(p), e = old.decode(p)
            #expect(a.count == e.count)
            for (x, y) in zip(a, e) where x.map(\.bitPattern) != y.map(\.bitPattern) {
                Issue.record("packet \(packets) differs"); return
            }
            packets += 1
        }
        // Truncated and corrupt packets decode the same too (end-of-packet and invalid-code paths).
        new.reset(); old.reset()
        for (i, b) in file.blocks(of: t.number).prefix(200).enumerated() {
            var p = file.payload(b)
            if i % 3 == 1 { p = p.prefix(p.count * 2 / 3) }
            if i % 5 == 2, p.count > 4 { p[p.startIndex + p.count / 2] ^= 0x5A }
            let a = new.decode(p), e = old.decode(p)
            #expect(a.map { $0.map(\.bitPattern) } == e.map { $0.map(\.bitPattern) }, "damaged packet \(i)")
        }
        #expect(packets > 0)
    }

    @Test(arguments: ["sample-vp9-vorbis-long.webm", "sample-vp9-vorbis.webm"])
    func webmPathMatchesLegacy(name: String) async throws {
        let u = Self.media.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        #expect(try await WaveformBuilder.build(url: u, cache: nil) == (try Legacy.buildWebM(u)))
    }

    // MARK: disk cache

    @Test func diskCacheRoundTripAndInvalidation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-wfcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = WaveformDiskCache(directory: dir, limitBytes: 1 << 30, disk: .unchecked)
        var spec = TestClipSpec()
        spec.frameCount = 30
        spec.audioClicks = [CMTime(value: 1, timescale: 2)]
        let url = try await TestClipWriter.write(spec)
        #expect(cache.load(url: url, baseBucketSize: 256) == nil)
        let built = try await WaveformBuilder.build(url: url, cache: cache)
        #expect(cache.load(url: url, baseBucketSize: 256) == built)
        #expect(cache.load(url: url, baseBucketSize: 512) == nil)
        #expect(try await WaveformBuilder.build(url: url, cache: cache) == built)
        // A changed file (new modification date) misses.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(cache.load(url: url, baseBucketSize: 256) == nil)
    }

    @Test func diskCachePrunesOldestBeyondLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-wfcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wf = WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 256 * 1000, baseBucketSize: 256,
                              levels: [[Float](repeating: 0.5, count: 2000)])
        let size = wf.serialized().count
        let cache = WaveformDiskCache(directory: dir, limitBytes: size * 3 + size / 2, disk: .unchecked)
        var urls: [URL] = []
        for i in 0..<5 {
            let u = dir.appendingPathComponent("src\(i).wav")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([UInt8(i)]).write(to: u)
            urls.append(u)
            cache.store(wf, url: u, baseBucketSize: 256)
            // distinct ages
            if let f = cache.file(url: u, baseBucketSize: 256) {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))], ofItemAtPath: f.path)
            }
        }
        cache.prune()
        let kept = urls.map { cache.load(url: $0, baseBucketSize: 256) != nil }
        #expect(kept == [false, false, true, true, true])
    }

    @Test func serializationRoundTripsLargeData() throws {
        let first: [Float] = (0..<20_000).map { Float($0) * 0.001 - 7 }
        let second: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0, -0.0]
        let levels: [[Float]] = [first, second]
        let wf = WaveformData(sampleRate: 44_100, channelCount: 2, totalFrames: 1_234_567, baseBucketSize: 256, levels: levels)
        let back = try WaveformData(serialized: wf.serialized())
        let bits: [[UInt32]] = back.levels.map { l in l.map { $0.bitPattern } }
        let want: [[UInt32]] = levels.map { l in l.map { $0.bitPattern } }
        #expect(bits == want)
        #expect(back == wf)
    }

    @Test func diskCacheSkipsWritesBelowFloor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-wfcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wf = WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 256 * 10, baseBucketSize: 256,
                              levels: [[Float](repeating: 0.5, count: 20)])
        let low = CacheDiskPolicy(space: { _ in (free: 1 << 30, total: 256 << 30) })
        let ok = CacheDiskPolicy(space: { _ in (free: 100 << 30, total: 256 << 30) })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("a.wav")
        try Data([1]).write(to: src)
        WaveformDiskCache(directory: dir, limitBytes: 1 << 30, disk: low).store(wf, url: src, baseBucketSize: 256)
        #expect(WaveformDiskCache(directory: dir, limitBytes: 1 << 30, disk: ok).load(url: src, baseBucketSize: 256) == nil)
        let cache = WaveformDiskCache(directory: dir, limitBytes: 1 << 30, disk: ok)
        cache.store(wf, url: src, baseBucketSize: 256)
        #expect(cache.load(url: src, baseBucketSize: 256) != nil)
        WaveformDiskCache(directory: dir, limitBytes: 1 << 30, disk: low).store(wf, url: src, baseBucketSize: 256)
        #expect(cache.load(url: src, baseBucketSize: 256) == nil)       // low disk also frees the cache
    }
}
