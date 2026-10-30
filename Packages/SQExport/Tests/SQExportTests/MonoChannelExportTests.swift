import Testing
import Foundation
import AVFoundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// Channels (v82): a Mono sequence delivers one channel to the export and the writer settings ask for one channel;
/// Stereo stays two channels.
@Suite struct MonoChannelExportTests {
    private static let n = 24_000

    private static func timeline(_ layout: ChannelLayout, media m: UUID) -> Timeline {
        let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(Int64(n), 48_000)), start: .zero)
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .audio, clips: [c])])
        t.channelLayout = layout
        return t
    }

    private static func render(_ layout: ChannelLayout) async throws -> AudioChunk {
        let m = UUID()
        let sig = (0..<n).map { _ in Float(0.9) }
        let src = TimelineAudioSource(timeline: timeline(layout, media: m), range: TimeRange(start: .zero, duration: Time(1, 2)),
                                      resolver: StaticMediaResolver(audio: [m: MemoryAudioSource(mono: sig)]))
        var all: [Float] = []
        var ch = 0
        while let chunk = try await src.nextChunk(maxFrames: 3_000) { all += chunk.samples; ch = chunk.channels }
        #expect(ch == src.channels)
        return AudioChunk(samples: all, channels: ch)
    }

    @Test func monoSequenceDeliversOneChannelOfTheFoldedMix() async throws {
        let mono = try await Self.render(.mono), stereo = try await Self.render(.stereo)
        #expect(mono.channels == 1 && stereo.channels == 2)
        #expect(mono.frameCount == stereo.frameCount)
        // The centered source has L == R, so (L + R) / 2 equals either channel: Mono is the Stereo mix, one channel.
        var worst: Float = 0
        for i in 0..<mono.frameCount {
            worst = max(worst, abs(mono.samples[i] - stereo.samples[2 * i]), abs(stereo.samples[2 * i] - stereo.samples[2 * i + 1]))
        }
        #expect(worst < 1e-6)
        #expect(mono.samples.contains { abs($0) > 0.1 })
    }

    @Test func playbackFeederDeliversDualMonoAverage() {
        let m = UUID(), src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: Self.n))
        func run(_ layout: ChannelLayout) -> (l: [Float], r: [Float]) {
            var t = Self.timeline(layout, media: m)
            t.tracks[0].pan = -1   // hard left: stereo carries the signal on L only
            let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 16), blockFrames: 256) { _ in src }
            f.declickFrames = 0
            f.seek(to: 0, reverse: false)
            _ = f.fill(maxBlocks: 20)
            var l = [Float](repeating: 0, count: 4_096), r = l
            l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
                _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: 4_096) } }
            return (l, r)
        }
        let st = run(.stereo), mo = run(.mono)
        let i = 2_000
        #expect(st.l[i] > 0.1 && abs(st.r[i]) < 1e-6)
        #expect(abs(mo.l[i] - st.l[i] / 2) < 1e-6 && mo.l[i] == mo.r[i])
    }

    @Test func writerSettingsFollowTheSourceChannels() {
        var a = AudioSettings(); a.channels = 2
        for codec in [AudioCodec.aac, .pcm] {
            a.codec = codec
            #expect(ExportWriter.audioOutputSettings(a, sourceChannels: 1)[AVNumberOfChannelsKey] as? Int == 1)
            #expect(ExportWriter.audioOutputSettings(a, sourceChannels: 2)[AVNumberOfChannelsKey] as? Int == 2)
            #expect(ExportWriter.audioOutputSettings(a)[AVNumberOfChannelsKey] as? Int == 2)
        }
    }
}
