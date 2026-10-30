import Dispatch
import Foundation
import SQAudioFX
import SQCore
import SQMedia
import SQPlayback

/// Offline audio for export: the timeline mixed by `AudioFeeder` (clip/nest volume, per-track FX presets, latency
/// compensation, nested sequences) at 48 kHz stereo, read in order from `range.start`. Rewindable, so loudness
/// normalization can measure first. All blocking source reads run on one dedicated queue (not the cooperative pool).
public final class TimelineAudioSource: RewindableAudioSource, @unchecked Sendable {
    public let sampleRate = 48_000
    /// 2, or 1 for a Mono sequence (`Timeline.channelLayout`): the feeder already folded the mix to dual mono, so the
    /// export keeps one of the two identical channels.
    public let channels: Int
    /// Frames this source delivers in total (`range.duration` at 48 kHz, rounded up).
    public let totalFrames: Int

    private let feeder: AudioFeeder
    private let ring: RingBuffer
    private let startFrame: Int64
    private let queue = DispatchQueue(label: "export.audio.mix", qos: .userInitiated)
    // Touched on `queue` only.
    private var produced = 0          // frames handed out
    private var skipped = 0           // FX latency frames still to drop
    private var needsSeek = true

    public init(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], range: TimeRange,
                presets: [Track.ID: TrackAudioPreset] = [:], liveDucking: ProjectLiveDucking? = nil,
                dialogueSilences: (any DialogueSilenceProvider)? = nil,
                roleBusGainsDB: [AudioTag: Double] = [:], resolver: any MediaResolver) {
        let rate = Int64(48_000)
        func ceilFrames(_ t: Time) -> Int64 {
            let n = Int128(t.value) * Int128(rate), d = Int128(t.timescale)
            return Int64(n / d + (n % d > 0 ? 1 : 0))
        }
        channels = timeline.channelLayout.channelCount
        startFrame = ceilFrames(range.start)
        totalFrames = max(0, Int(ceilFrames(range.end) - startFrame))
        ring = RingBuffer(capacity: 1 << 15)
        feeder = AudioFeeder(timeline: timeline, ring: ring, sampleRate: 48_000, blockFrames: 1024) { try resolver.audio(for: $0) }
        feeder.declickFrames = AudioDeClick.currentFadeFrames(sampleRate: 48_000)   // same setting as playback
        feeder.liveDucking = LiveDucking.current()   // N8: same live ducking as playback
        feeder.projectLiveDucking = liveDucking      // N8b: the project's own setting wins, as in playback
        // N8b: the same dialogue pauses as playback, computed inline so every export run hears the same duck.
        feeder.dialogueSilences = (dialogueSilences as? WaveformSilences)?.forExport ?? dialogueSilences
        feeder.roleBusGainsDB = roleBusGainsDB       // same role buses as playback (one mix in `AudioFeeder.renderBlock`)
        feeder.setTimeline(timeline, sequences: sequences)
        feeder.setTracks(presets)
    }

    public func rewind() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.produced = 0; self.needsSeek = true; c.resume() }
        }
    }

    public func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        try Task.checkCancellation()
        return await withCheckedContinuation { (c: CheckedContinuation<AudioChunk?, Never>) in
            queue.async { c.resume(returning: self.produce(maxFrames)) }
        }
    }

    private func produce(_ maxFrames: Int) -> AudioChunk? {
        if needsSeek {
            needsSeek = false
            feeder.seek(to: startFrame, reverse: false)
            _ = feeder.fill(maxBlocks: 1)     // the feeder applies the new generation (flush, FX reset, latency) here
            skipped = feeder.flushed.latency
        }
        let want = min(maxFrames, totalFrames - produced)
        guard want > 0 else { return nil }
        var l = [Float](repeating: 0, count: want), r = l
        var got = 0
        while got < want {
            if ring.availableToRead == 0 {
                if feeder.fill(maxBlocks: 4) == 0 && ring.availableToRead == 0 { break }
            }
            let n = min(want - got, ring.availableToRead)
            if skipped > 0 {
                let drop = min(skipped, n)
                var tl = [Float](repeating: 0, count: drop), tr = tl
                tl.withUnsafeMutableBufferPointer { a in tr.withUnsafeMutableBufferPointer { b in
                    if let pa = a.baseAddress, let pb = b.baseAddress { _ = ring.pop(left: pa, right: pb, count: drop) } } }
                skipped -= drop
                continue
            }
            l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
                if let pa = a.baseAddress, let pb = b.baseAddress { _ = ring.pop(left: pa + got, right: pb + got, count: n) } } }
            got += n
        }
        produced += got
        guard got > 0 else { return nil }
        if channels == 1 { return AudioChunk(samples: Array(l[0..<got]), channels: 1) }
        var out = [Float](repeating: 0, count: got * 2)
        for i in 0..<got { out[2 * i] = l[i]; out[2 * i + 1] = r[i] }
        return AudioChunk(samples: out, channels: 2)
    }
}
