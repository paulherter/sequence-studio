import Foundation

extension AudioGain {
    /// Below this the clip counts as silent: nothing to match (BS.1770 absolute gate).
    public static let silentLUFS = -70.0

    /// Match Loudness: the Audio Gain (dB) that brings a clip whose source measures `measuredLUFS` (integrated, before
    /// any gain) to `targetLUFS`. nil for silence or an unmeasured clip, so the caller leaves it unchanged. Clamped to
    /// the Audio Gain limits.
    public static func matchLoudness(measuredLUFS: Double?, targetLUFS: Double) -> Double? {
        guard let m = measuredLUFS, m.isFinite, m > silentLUFS else { return nil }
        return min(max(targetLUFS - m, minGainDB), maxGainDB)
    }

    /// Integrated loudness target for a clip of `t`: its role's default (clip tag, else track role), else dialogue's.
    public static func targetLUFS(for clip: Clip, in t: Timeline) -> Double { (t.role(of: clip) ?? .dialogue).targetLUFS }

    /// The one target a loudness row starts at for `clips`: their shared role target, dialogue's when the roles differ.
    public static func targetLUFS(for clips: [Clip], in t: Timeline) -> Double {
        let targets = Set(clips.map { targetLUFS(for: $0, in: t) })
        return targets.count == 1 ? targets.first! : AudioTag.dialogue.targetLUFS
    }
}
