import Foundation
import Synchronization
import SQCore
import SQMedia
import SQAudioFX

/// N8b: dialogue pauses for live ducking, read from the media's decoded waveform (the app's waveform cache pushes them in
/// with `setWaveform`). Same detection as the baked Auto Duck: the level as heard (`ClipLevels`), -35 dB, at least 0.6 s.
///
/// Playback asks from the mix thread, so the default instance never computes there: a clip it has not analyzed yet is
/// queued on a utility queue and reported as unknown (nil: the whole clip ducks) until the result is in. Export needs the
/// same answer on every run, so it uses `forExport`, which shares the waveforms and results but computes inline.
public final class WaveformSilences: DialogueSilenceProvider {
    public static let thresholdDB = -35.0
    public static let minimumLength = Time(3, 5)

    /// Most results kept; past this the oldest half is dropped (`prune` removes deleted clips on every timeline change).
    public static let maxEntries = 512

    /// A result for one clip value: `fingerprint` is the clip's hash (edits change it), not the whole clip, so a cached
    /// entry holds no keyframe arrays alive.
    private struct Entry: Sendable { var media: UUID; var fingerprint: Int; var fader: Double; var silences: [TimeRange]; var serial: UInt64 }
    private struct State: Sendable {
        var waveforms: [UUID: WaveformData] = [:]
        var results: [Clip.ID: Entry] = [:]
        var queued: Set<Clip.ID> = []
        /// Bumped per `setWaveform`, so a background result of a replaced waveform is not stored.
        var generation: [UUID: Int] = [:]
        var serial: UInt64 = 0
    }
    private final class Store: Sendable {
        let state = Mutex(State())
        let queue = DispatchQueue(label: "sq.live-duck.silences", qos: .utility)
    }

    private let store: Store
    private let computesInline: Bool

    /// `computesInline`: compute a missing result on the calling thread (export, tests) instead of in the background.
    public init(computesInline: Bool = false) {
        store = Store(); self.computesInline = computesInline
    }
    private init(store: Store, computesInline: Bool) { self.store = store; self.computesInline = computesInline }

    /// Same waveforms and results, computing inline: for export, so it never depends on background timing.
    public var forExport: WaveformSilences { WaveformSilences(store: store, computesInline: true) }

    /// A waveform arrived (or nil: the media was relinked / forgotten). Results of that media are dropped.
    public func setWaveform(_ data: WaveformData?, for media: UUID) {
        store.state.withLock { s in
            s.waveforms[media] = data
            s.generation[media, default: 0] += 1
            s.results = s.results.filter { $0.value.media != media }
        }
    }

    public func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]? {
        enum Next { case hit([TimeRange]), unknown, compute(WaveformData, Int) }
        let fingerprint = clip.hashValue
        let next: Next = store.state.withLock { s in
            if let e = s.results[clip.id], e.fader == trackVolumeDB, e.fingerprint == fingerprint { return .hit(e.silences) }
            guard let data = s.waveforms[clip.media] else { return .unknown }
            let gen = s.generation[clip.media, default: 0]
            if computesInline { return .compute(data, gen) }
            if s.queued.insert(clip.id).inserted { return .compute(data, gen) }
            return .unknown
        }
        switch next {
        case .hit(let r): return r
        case .unknown: return nil
        case .compute(let data, let gen):
            if computesInline {
                return remember(clip, fingerprint, trackVolumeDB, gen, Self.pauses(of: clip, in: data, trackVolumeDB: trackVolumeDB))
            }
            store.queue.async { [self] in
                let r = Self.pauses(of: clip, in: data, trackVolumeDB: trackVolumeDB)
                store.state.withLock { $0.queued.remove(clip.id) }
                _ = remember(clip, fingerprint, trackVolumeDB, gen, r)
            }
            return nil
        }
    }

    /// Blocks until the queued work is done (tests).
    func waitUntilIdle() { store.queue.sync {} }

    /// Drops the results of clips not in `ids` (deleted or replaced); call when the timeline changes.
    public func prune(keeping ids: Set<Clip.ID>) {
        store.state.withLock { s in
            if s.results.keys.contains(where: { !ids.contains($0) }) { s.results = s.results.filter { ids.contains($0.key) } }
        }
    }

    /// Number of cached results (tests).
    var cachedCount: Int { store.state.withLock { $0.results.count } }

    /// Stores a result only while the waveform is still the one it was computed from (not relinked meanwhile).
    private func remember(_ clip: Clip, _ fingerprint: Int, _ fader: Double, _ gen: Int, _ r: [TimeRange]) -> [TimeRange] {
        store.state.withLock { s in
            guard s.generation[clip.media, default: 0] == gen, s.waveforms[clip.media] != nil else { return }
            s.serial &+= 1
            s.results[clip.id] = Entry(media: clip.media, fingerprint: fingerprint, fader: fader, silences: r, serial: s.serial)
            if s.results.count > Self.maxEntries {               // bounded: drop the oldest half
                let cut = s.results.values.map(\.serial).sorted()[s.results.count / 2]
                s.results = s.results.filter { $0.value.serial >= cut }
            }
        }
        return r
    }

    /// Pauses of `clip` in timeline time as heard (time mapping, Audio Gain, volume line, track fader), from `data`.
    /// The baked Auto Duck and Remove Silences use this too.
    public static func pauses(of clip: Clip, in data: WaveformData, trackVolumeDB: Double = 0,
                              thresholdDB: Double = thresholdDB, minimumLength: Time = minimumLength) -> [TimeRange] {
        let (levels, window) = ClipLevels.audible(of: clip, trackVolumeDB: trackVolumeDB) { r in
            data.peaks(in: r, buckets: 1).reduce(Float(0)) { m, ch in
                guard let p = ch.first else { return m }
                return max(m, abs(p.min), abs(p.max))
            }
        }
        return SilenceDetector.silences(levels: levels, window: window, thresholdDB: thresholdDB, minimumLength: minimumLength)
            .map { TimeRange(start: clip.start + $0.start, duration: $0.duration) }
    }
}
