import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQMedia

// F7.10 follow-up: a movie with several audio tracks counts its channels across all of them (track order, then channel
// order). Track k's channel c holds the constant (first + c + 1) / 10, so every sample says where it came from.

private func writeWAV(channels: Int, first: Int, frames: Int) throws -> URL {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    let values = (0..<channels).map { le(Int16((Double(first + $0 + 1) / 10 * 32768).rounded())) }
    var pcm: [UInt8] = []
    pcm.reserveCapacity(frames * channels * 2)
    for _ in 0..<frames { for c in 0..<channels { pcm += values[c] } }
    var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVEfmt ".utf8) + le(UInt32(16))
    d += le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(48_000)) + le(UInt32(48_000 * channels * 2))
    d += le(UInt16(channels * 2)) + le(UInt16(16)) + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mt-\(UUID().uuidString).wav")
    try Data(d).write(to: url)
    return url
}

/// A .mov holding one audio track per entry of `layout` (channels per track), `seconds` long.
private func writeMovie(layout: [Int], seconds: Int = 1, disabled: Set<Int> = []) async throws -> URL {
    var wavs: [URL] = []
    var first = 0
    for ch in layout { wavs.append(try writeWAV(channels: ch, first: first, frames: 48_000 * seconds)); first += ch }
    defer { for w in wavs { try? FileManager.default.removeItem(at: w) } }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mt-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var readers: [AVAssetReader] = []
    var inputs: [(AVAssetWriterInput, AVAssetReaderTrackOutput, Bool)] = []
    for (index, w) in wavs.enumerated() {
        let asset = AVURLAsset(url: w)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        #expect(reader.startReading())
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fd)
        if disabled.contains(index) { input.marksOutputTrackAsEnabled = false }
        writer.add(input)
        inputs.append((input, out, false))
        readers.append(reader)
    }
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    while inputs.contains(where: { !$0.2 }) {
        for i in inputs.indices where !inputs[i].2 && inputs[i].0.isReadyForMoreMediaData {
            if let sb = inputs[i].1.copyNextSampleBuffer() { inputs[i].0.append(sb) } else { inputs[i].0.markAsFinished(); inputs[i].2 = true }
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    await writer.finishWriting()
    withExtendedLifetime(readers) {}
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
    return url
}

private func sides(_ s: any AudioSource, from: Int64 = 1000, count: Int = 256) throws -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: -9, count: count), r = l
    #expect(try s.read(from: from, count: count, into: &l, channel: 0) == count)
    #expect(try s.read(from: from, count: count, into: &r, channel: 1) == count)
    return (l, r)
}

private func allNear(_ a: [Float], _ v: Float, _ eps: Float = 2e-4) -> Bool { a.allSatisfy { abs($0 - v) <= eps } }

@Suite(.serialized) struct MultiTrackAudioTests {
    @Test func mapPartsFollowTrackOrderThenChannelOrder() {
        // Tracks: mono (file channel 0), mono (1), stereo (2, 3).
        let counts = [1, 1, 2]
        let a = MultiTrackAudio.plan(map: .mono(1)!, counts: counts)
        #expect(a.map(\.track) == [1] && a[0].part == .mono(0))
        let b = MultiTrackAudio.plan(map: .stereo(0, 3)!, counts: counts)
        #expect(b.map(\.track) == [0, 2] && b[0].part.left == [0] && b[0].part.right.isEmpty && b[1].part.right == [1])
        #expect(MultiTrackAudio.plan(map: .mono(2)!, counts: counts).map(\.track) == [2])   // tracks nobody uses are not in the plan
    }

    @Test func probeCountsChannelsAcrossAllAudioTracks() async throws {
        let url = try await writeMovie(layout: [1, 1, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 4)
        #expect(info.audio?.firstTrackChannels == 1)
    }

    @Test func aDisabledTrackIsNeitherCountedNorRouted() async throws {
        // Tracks: mono (off), mono, stereo. Probe, playback and the proxy list all see [mono, stereo] = 3 channels.
        let url = try await writeMovie(layout: [1, 1, 2], disabled: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 3 && info.audio?.firstTrackChannels == 1)
        let all = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(all.count == 3)
        let usable = await MultiTrackAudio.usableTracks(all)
        #expect(usable.map(\.channels) == [1, 2])
        let listed = await UsableAudioTracks.tracks(all)
        #expect(listed.count == 2)
        // The only usable track is the second one (value 0.2), not the disabled first (0.1).
        let off = try await writeMovie(layout: [1, 1], disabled: [0])
        defer { try? FileManager.default.removeItem(at: off) }
        let single = try await AudioSources.open(url: off, sampleRate: 48_000, channelMap: nil)
        let heard = try sides(single)
        #expect(single.isMono && allNear(heard.l, 0.2))
    }

    @Test func channelsOfLaterTracksAreRouted() async throws {
        let url = try await writeMovie(layout: [1, 1, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let g = Float(0.5).squareRoot()

        let plain = try sides(try await AudioSources.open(url: url, sampleRate: 48_000))      // file layout: the first track
        #expect(allNear(plain.l, 0.1) && allNear(plain.r, 0.1))

        let second = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(1))
        #expect(second.isMono)
        var s = try sides(second)
        #expect(allNear(s.l, 0.2) && allNear(s.r, 0.2))

        let third = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(2, 3))
        s = try sides(third)
        #expect(allNear(s.l, 0.3) && allNear(s.r, 0.4))

        // Across tracks: track 1 on the left, the right channel of track 3 on the right; and two tracks in the center.
        let across = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(0, 3))
        s = try sides(across)
        #expect(allNear(s.l, 0.1) && allNear(s.r, 0.4))
        let dual = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .dualMono(1, 2))
        #expect(dual.isMono)
        s = try sides(dual)
        #expect(allNear(s.l, (0.2 + 0.3) * g) && allNear(s.r, (0.2 + 0.3) * g))

        // Past the end of the media nothing is delivered.
        var past = [Float](repeating: 0, count: 100)
        #expect(try across.read(from: 48_000 - 50, count: 100, into: &past, channel: 0) == 50)
    }

    @Test func aMapTheFileCannotPlayFallsBackToTheFirstTrack() async throws {
        let url = try await writeMovie(layout: [1, 1])
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try sides(try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(5)))
        #expect(allNear(s.l, 0.1))
    }

    /// Decode cost of a 4-track file against a single-track file with the same samples. Printed, not asserted (timing).
    @Test func decodeCostOfFourTracksAgainstOne() async throws {
        let seconds = 30
        let one = try await writeMovie(layout: [1], seconds: seconds)
        let four = try await writeMovie(layout: [1, 1, 1, 1], seconds: seconds)
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: four) }
        func time(_ url: URL, _ map: AudioChannelMap?) async throws -> Double {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: map)
            var buf = [Float](repeating: 0, count: 48_000)
            let t0 = ContinuousClock.now
            for sec in 0..<Int64(seconds) { _ = try src.read(from: sec * 48_000, count: 48_000, into: &buf, channel: 0) }
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let single = try await time(one, nil)
        let trackTwo = try await time(four, .mono(1))
        let all = try await time(four, AudioChannelMap(left: [0, 1, 2, 3], right: [0, 1, 2, 3]))
        print("MULTITRACK decode \(seconds)s: single track \(single) s, track 2 of 4 \(trackTwo) s, all 4 summed \(all) s")
        #expect(trackTwo < max(single * 3, 0.5))      // the unused tracks are not decoded: no 4x cost
    }

    @Test func aMapChosenAgainstAnotherChannelCountIsNotRouted() async throws {
        // Tracks mono (off), mono, mono: 2 usable channels now. The map names channel 2 (the third track, value 0.3).
        let url = try await writeMovie(layout: [1, 1, 1], disabled: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let current = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(1), expectedChannels: 2)
        let now = try sides(current)
        #expect(allNear(now.l, 0.3))
        // The item was probed when all three tracks counted: its map is stale, the file layout (0.2) plays.
        let stale = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(1), expectedChannels: 3)
        let old = try sides(stale)
        #expect(allNear(old.l, 0.2))
    }

    @Test func aSoleDisabledMonoTrackStaysMono() async throws {
        let url = try await writeMovie(layout: [1], disabled: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: nil)
        let heard = try sides(src)
        #expect(src.isMono && allNear(heard.l, 0.1))
    }

    /// The waveform is built from the channels the clip plays: a map chosen against another channel count is stale.
    @Test func aWaveformIgnoresAMapChosenAgainstAnotherChannelCount() async throws {
        let url = try await writeMovie(layout: [1, 1, 1], disabled: [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let current = try await WaveformBuilder.build(url: url, channelMap: .mono(1), expectedChannels: 2, cache: nil)
        let stale = try await WaveformBuilder.build(url: url, channelMap: .mono(1), expectedChannels: 3, cache: nil)
        let now = current.bucket(level: 0, index: 0, channel: 0).max
        let old = stale.bucket(level: 0, index: 0, channel: 0).max
        #expect(abs(now - 0.3) < 2e-3)
        #expect(abs(old - 0.2) < 2e-3)
    }

    /// WebM delivers two sides: a map that names a channel beyond them plays the unmapped default, never a partial sum.
    @Test func aMapBeyondTwoSidesOnWebMFallsBackToTheDefault() throws {
        struct Two: AudioSource {
            func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
                for i in 0..<count { buffer[i] = channel == 0 ? 0.1 : 0.2 }
                return count
            }
        }
        let beyond = ChannelMappedSource.wrap(Two(), map: .mono(3))
        let sum = ChannelMappedSource.wrap(Two(), map: AudioChannelMap(left: [0, 2], right: [0, 2]))
        for src in [beyond, sum] {
            let h = try sides(src)
            #expect(allNear(h.l, 0.1) && allNear(h.r, 0.2))
        }
        let inside = try sides(ChannelMappedSource.wrap(Two(), map: .mono(1)))
        #expect(allNear(inside.l, 0.2))
    }
}
