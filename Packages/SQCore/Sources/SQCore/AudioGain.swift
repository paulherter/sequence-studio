import Foundation

/// Audio Gain (Premiere: Clip > Audio Options > Audio Gain, key G) and the maths around it. Pure, no media access:
/// the caller supplies the clip's source peak for the normalise modes.
public enum AudioGain {
    /// dB shown for silence (linear 0), same as the Volume level in Effect Controls.
    public static let silenceDB = -60.0
    public static let minGainDB = -96.0
    public static let maxGainDB = 96.0
    /// Volume level limit (Premiere's Level goes to +15 dB).
    public static let maxVolumeDB = 15.0

    public static func db(fromLinear v: Double) -> Double {
        v <= 0 ? silenceDB : max(20 * log10(v), silenceDB)
    }

    /// Silence (or below) is exactly 0.
    public static func linear(fromDB d: Double) -> Double { d <= silenceDB ? 0 : pow(10, d / 20) }

    public enum Mode: Sendable, Equatable {
        /// Gain becomes this value.
        case set(Double)
        /// Gain changes by this many dB.
        case adjust(Double)
        /// Gain makes the source's peak reach this level.
        case normalize(targetDB: Double)
    }

    /// New gain in dB of one clip. `peak` is the linear sample peak of the clip's source range (needed to normalise).
    /// nil when normalising silence or without a peak.
    public static func apply(_ mode: Mode, to current: Double, peak: Double?) -> Double? {
        func clamp(_ v: Double) -> Double { min(max(v, minGainDB), maxGainDB) }
        switch mode {
        case .set(let v): return clamp(v)
        case .adjust(let d): return clamp(current + d)
        case .normalize(let target):
            guard let p = peak, p > 0 else { return nil }
            return clamp(target - db(fromLinear: p))
        }
    }

    /// "Normalize All Peaks": one gain for all clips so the loudest peak reaches the target; the balance between
    /// the clips stays as it was. One value per input (all equal); nil when everything is silent.
    public static func normalizeTogether(peaks: [Double], targetDB: Double) -> [Double]? {
        guard let loudest = peaks.max(), loudest > 0 else { return nil }
        let g = min(max(targetDB - db(fromLinear: loudest), minGainDB), maxGainDB)
        return peaks.map { _ in g }
    }
}

// MARK: Volume line (the rubber band on an audio clip)

extension Clip {
    /// Raises or lowers the volume line at clip-local time `t` by `deltaDB`, like dragging the rubber band there:
    /// without keys the whole clip's level; with keys the segment under `t` (both of its keys), or the first / last
    /// key when `t` is before / after all of them.
    public mutating func shiftVolumeLine(atLocal t: Time, byDB deltaDB: Double) {
        guard abs(deltaDB) > 1e-6 else { return }      // a click without movement changes nothing (no dB round trip)
        func shifted(_ v: Double) -> Double {
            AudioGain.linear(fromDB: min(AudioGain.db(fromLinear: v) + deltaDB, AudioGain.maxVolumeDB))
        }
        let keys = animation.volume.track.keys
        guard !keys.isEmpty else {
            animation.volume.value = shifted(animation.volume.value)
            return
        }
        let i = keys.lastIndex { $0.time <= t }
        let ids: [UUID]
        switch i {
        case nil: ids = [keys[0].id]
        case let n? where n == keys.count - 1: ids = [keys[n].id]
        case let n?: ids = [keys[n].id, keys[n + 1].id]
        }
        for id in ids { if let k = animation.volume.track.key(id: id) { animation.volume.track.set(id, value: shifted(k.value)) } }
    }

    /// Adds a volume key at clip-local `t` on the current line (the first key keeps the constant level). Returns its ID.
    @discardableResult
    public mutating func addVolumeKey(atLocal t: Time) -> UUID {
        let v = animation.volume.value(atLocal: t)
        let k = Keyframe<Double>(time: t, value: v)
        animation.volume.track.insert(k)
        return k.id
    }

    /// Closest two volume keys may get (one sample at 48 kHz).
    public static let minKeyGap = Time(1, 48_000)

    /// Moves a volume key to clip-local `time` (kept inside the clip) and level `gainDB` (silence below the floor,
    /// at most +15 dB).
    public mutating func moveVolumeKey(_ id: UUID, toLocal time: Time, gainDB: Double) {
        var t = min(max(time, .zero), duration)
        // A key never crosses or lands on its neighbours (that would reorder the line or delete the neighbour).
        let keys = animation.volume.track.keys
        if let i = keys.firstIndex(where: { $0.id == id }) {
            if i > 0 { t = max(t, keys[i - 1].time + Self.minKeyGap) }
            if i + 1 < keys.count { t = min(t, keys[i + 1].time - Self.minKeyGap) }
        }
        animation.volume.track.move(id, to: t)
        animation.volume.track.set(id, value: AudioGain.linear(fromDB: min(gainDB, AudioGain.maxVolumeDB)))
    }

    public mutating func removeVolumeKey(_ id: UUID) { animation.volume.track.remove(id) }
}
