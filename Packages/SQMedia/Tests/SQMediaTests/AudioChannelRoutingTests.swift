import Foundation
import SQCore
import Testing
@testable import SQMedia

// F7.10: the channel map of a media item decides which file channels reach the left and right side. Verified by sample
// values: channel c of the test files holds the constant (c + 1) / 10.

/// A 16 bit PCM WAV, half a second at 48 kHz, channel c = (c + 1) / 10 on every frame.
private func writeWAV(channels: Int, frames: Int = 24_000) throws -> URL {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    var pcm: [UInt8] = []
    pcm.reserveCapacity(frames * channels * 2)
    let values = (0..<channels).map { le(Int16((Double($0 + 1) / 10 * 32768).rounded())) }
    for _ in 0..<frames { for c in 0..<channels { pcm += values[c] } }
    var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVEfmt ".utf8) + le(UInt32(16))
    d += le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(48_000)) + le(UInt32(48_000 * channels * 2))
    d += le(UInt16(channels * 2)) + le(UInt16(16)) + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-channels-\(UUID().uuidString).wav")
    try Data(d).write(to: url)
    return url
}

private func sides(_ s: any AudioSource, from: Int64 = 1000, count: Int = 256) throws -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: -9, count: count), r = l
    #expect(try s.read(from: from, count: count, into: &l, channel: 0) == count)
    #expect(try s.read(from: from, count: count, into: &r, channel: 1) == count)
    return (l, r)
}

private func allNear(_ a: [Float], _ v: Float, _ eps: Float = 2e-4) -> Bool { a.allSatisfy { abs($0 - v) <= eps } }

@Suite struct AudioChannelRoutingTests {
    @Test func fourChannelFileRoutesTheChosenChannels() async throws {
        let url = try writeWAV(channels: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let g = Float(0.5).squareRoot()

        let mono = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(2))
        #expect(mono.isMono)
        var s = try sides(mono)
        #expect(allNear(s.l, 0.3) && allNear(s.r, 0.3))

        let stereo = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(2, 3))
        #expect(!stereo.isMono)
        s = try sides(stereo)
        #expect(allNear(s.l, 0.3) && allNear(s.r, 0.4))

        let dual = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .dualMono(0, 3))
        #expect(dual.isMono)
        s = try sides(dual)
        #expect(allNear(s.l, 0.5 * g) && allNear(s.r, 0.5 * g))

        // The first channel alone on both sides (one microphone on channel 1), across a block boundary and at the end.
        let first = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(0))
        s = try sides(first, from: 23_000, count: 1000)
        #expect(allNear(s.l, 0.1) && allNear(s.r, 0.1))
        var past = [Float](repeating: 0, count: 100)
        #expect(try first.read(from: 23_950, count: 100, into: &past, channel: 0) == 50)

        // Another output rate: the reader converts, the channels stay apart.
        let half = try await AudioSources.open(url: url, sampleRate: 24_000, channelMap: .stereo(3, 0))
        s = try sides(half, from: 2000, count: 200)
        #expect(allNear(s.l, 0.4, 2e-3) && allNear(s.r, 0.1, 2e-3))
    }

    /// More than two channels: a map that fits the six channels is applied, one naming a channel the file lacks is
    /// refused and the file layout plays (the same samples as no map), not a partial sum.
    @Test func sixChannelFileAppliesAFittingMapAndRefusesOneThatDoesNot() async throws {
        let url = try writeWAV(channels: 6, frames: 4_800)
        defer { try? FileManager.default.removeItem(at: url) }
        let fits = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(4, 5))
        var s = try sides(fits, from: 100, count: 256)
        #expect(allNear(s.l, 0.5) && allNear(s.r, 0.6))

        let plain = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: nil)
        let plainSides = try sides(plain, from: 100, count: 256)
        let lacking = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(4, 6))
        s = try sides(lacking, from: 100, count: 256)
        #expect(lacking.isMono == plain.isMono)
        #expect(s.l == plainSides.l && s.r == plainSides.r)
        #expect(!allNear(s.r, 0.7))
    }

    @Test func noMapAndTheFileLayoutReadTheSameSamples() async throws {
        let url = try writeWAV(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try sides(try await AssetAudioSource.open(url: url, sampleRate: 48_000))
        #expect(allNear(plain.l, 0.1) && allNear(plain.r, 0.2))
        let unset = try sides(try await AudioSources.open(url: url, sampleRate: 48_000))
        #expect(unset.l == plain.l && unset.r == plain.r)
        let named = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(0, 1))
        let same = try sides(named)
        #expect(same.l == plain.l && same.r == plain.r && !named.isMono)

        let swapped = try sides(try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(1, 0)))
        #expect(allNear(swapped.l, 0.2) && allNear(swapped.r, 0.1))
        let right = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(1))
        let r = try sides(right)
        #expect(right.isMono && allNear(r.l, 0.2) && allNear(r.r, 0.2))
        // A map for channels the file lacks keeps what exists of it.
        let partly = try sides(try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .dualMono(1, 7)))
        #expect(allNear(partly.l, 0.2) && allNear(partly.r, 0.2))
    }

    @Test func mappedSourceOverTwoSides() throws {
        let base = MemoryAudioSource(left: [Float](repeating: 0.25, count: 500), right: [Float](repeating: -0.5, count: 500))
        #expect(ChannelMappedSource.wrap(base, map: nil) as AnyObject === base)
        #expect(ChannelMappedSource.wrap(base, map: .stereo(0, 1)) as AnyObject === base)
        #expect(ChannelMappedSource.wrap(base, map: .stereo(4, 5)) as AnyObject === base)

        let right = ChannelMappedSource.wrap(base, map: .mono(1))
        var s = try sides(right, from: 100, count: 64)
        #expect(right.isMono && allNear(s.l, -0.5, 0) && allNear(s.r, -0.5, 0))

        let swapped = ChannelMappedSource.wrap(base, map: .stereo(1, 0))
        s = try sides(swapped, from: 0, count: 64)
        #expect(!swapped.isMono && allNear(s.l, -0.5, 0) && allNear(s.r, 0.25, 0))

        let both = ChannelMappedSource.wrap(base, map: .dualMono(0, 1))
        s = try sides(both, from: 0, count: 64)
        let sum = (Float(0.25) - 0.5) * Float(0.5).squareRoot()
        #expect(both.isMono && allNear(s.l, sum, 1e-7) && allNear(s.r, sum, 1e-7))
        // Reads end where the base ends.
        var tail = [Float](repeating: 9, count: 100)
        #expect(try both.read(from: 450, count: 100, into: &tail, channel: 0) == 50)

        let leftOnly = ChannelMappedSource.wrap(base, map: AudioChannelMap(left: [0], right: []))
        s = try sides(leftOnly, from: 0, count: 64)
        #expect(allNear(s.l, 0.25, 0) && allNear(s.r, 0, 0))
    }

    @Test func mxfMonoTracksRouteThroughTheSameEntry() async throws {
        var fx = MXFFixture()
        fx.frames = (0..<12).map { H264TestStream.frame(.init(), luma: 40 + 20 * ($0 % 8), idrID: $0 & 1) }
        fx.audioTracks = 4
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-channels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.MXF")
        try fx.build().write(to: url)
        func expected(_ c: Int, _ n: Int) -> Float { Float(MXFFixture.sample(c, n)) / Float(1 << 23) }
        let g = Float(0.5).squareRoot()

        // No map: channels 1 + 2 in the center, as before.
        var s = try sides(try await AudioSources.open(url: url, sampleRate: 48_000), from: 5000, count: 64)
        for i in 0..<64 { #expect(abs(s.l[i] - (expected(0, 5000 + i) + expected(1, 5000 + i)) * g) < 1e-6) }
        #expect(s.r == s.l)

        let third = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(2))
        s = try sides(third, from: 5000, count: 64)
        #expect(third.isMono && s.l == (5000..<5064).map { expected(2, $0) } && s.r == s.l)

        let pair = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(2, 3))
        s = try sides(pair, from: 1900, count: 100)
        #expect(!pair.isMono && s.l == (1900..<2000).map { expected(2, $0) } && s.r == (1900..<2000).map { expected(3, $0) })

        let dual = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .dualMono(2, 3))
        s = try sides(dual, from: 5000, count: 64)
        for i in 0..<64 { #expect(abs(s.l[i] - (expected(2, 5000 + i) + expected(3, 5000 + i)) * g) < 1e-6) }
        #expect(dual.isMono && s.r == s.l)
    }

    /// Review F7.10: a map kept over a relink to a file with fewer channels must not silence the file.
    @Test func mxfMapTheFileCannotPlayFallsBackToTheFileLayout() async throws {
        var fx = MXFFixture()
        fx.frames = (0..<12).map { H264TestStream.frame(.init(), luma: 40 + 20 * ($0 % 8), idrID: $0 & 1) }
        fx.audioTracks = 2
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-channels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.MXF")
        try fx.build().write(to: url)

        let plain = try await AudioSources.open(url: url, sampleRate: 48_000)
        let p = try sides(plain, from: 5000, count: 64)
        #expect(p.l.contains { abs($0) > 1e-4 })
        for map in [AudioChannelMap.mono(3), .stereo(2, 3), .stereo(1, 2), .dualMono(2, 3)] {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: map)
            let s = try sides(src, from: 5000, count: 64)
            #expect(src.isMono == plain.isMono && s.l == p.l && s.r == p.r)
        }
        // A wave file likewise: Stereo 2 + 3 on two channels plays the file as it is, no dead side.
        let wav = try writeWAV(channels: 2)
        defer { try? FileManager.default.removeItem(at: wav) }
        let w = try sides(try await AudioSources.open(url: wav, sampleRate: 48_000), from: 100, count: 64)
        let m = try sides(try await AudioSources.open(url: wav, sampleRate: 48_000, channelMap: .stereo(1, 2)), from: 100, count: 64)
        #expect(m.l == w.l && m.r == w.r && w.r.contains { abs($0) > 1e-4 })
    }

    @Test func waveformShowsTheMappedChannels() async throws {
        let url = try writeWAV(channels: 4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-channels-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dir) }
        let cache = WaveformDiskCache(directory: dir, limitBytes: 1 << 24)

        let mono = try await WaveformBuilder.build(url: url, channelMap: .mono(3), cache: cache)
        #expect(mono.channelCount == 1 && mono.totalFrames == 24_000 && mono.sampleRate == 48_000)
        #expect(abs(mono.bucket(level: 0, index: 3, channel: 0).max - 0.4) < 2e-4)

        let pair = try await WaveformBuilder.build(url: url, channelMap: .stereo(0, 3), cache: cache)
        #expect(pair.channelCount == 2 && pair.totalFrames == 24_000)
        #expect(abs(pair.bucket(level: 0, index: 3, channel: 0).max - 0.1) < 2e-4)
        #expect(abs(pair.bucket(level: 0, index: 3, channel: 1).max - 0.4) < 2e-4)

        // Each map is its own disk entry, next to the file layout's; a second build reads it back.
        #expect(cache.load(url: url, baseBucketSize: WaveformData.defaultBaseBucketSize, channelMap: .mono(3)) == mono)
        #expect(cache.load(url: url, baseBucketSize: WaveformData.defaultBaseBucketSize, channelMap: .stereo(0, 3)) == pair)
        #expect(cache.load(url: url, baseBucketSize: WaveformData.defaultBaseBucketSize) == nil)
        #expect(try await WaveformBuilder.build(url: url, channelMap: .mono(3), cache: cache) == mono)

        // No map: the plain build, untouched.
        let plain = try await WaveformBuilder.build(url: url, cache: nil)
        #expect(try await WaveformBuilder.build(url: url, channelMap: nil, cache: nil) == plain)
    }
}
