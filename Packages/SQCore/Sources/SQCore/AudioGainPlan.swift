import Foundation

/// What the Audio Gain dialog does to the selected audio clips (Premiere: Set Gain to, Adjust Gain by,
/// Normalize Max Peak to, Normalize All Peaks to).
public enum AudioGainChoice: Sendable, Equatable {
    case set(Double)
    case adjust(Double)
    case normalizeEach(targetDB: Double)
    case normalizeTogether(targetDB: Double)
    /// Integrated loudness (LUFS) of each clip, measured from its source, brought to the target by Audio Gain.
    case normalizeLoudness(targetLUFS: Double)
}

/// The Audio Gain dialog's logic, shared by the Mac sheet and the portable shell form.
public enum AudioGainPlan {
    public struct Item: Sendable, Equatable {
        public var id: Clip.ID
        public var name: String
        /// Gain the clip has now.
        public var gainDB: Double
        /// Linear sample peak of the clip's source range; nil when unknown (waveform not read yet).
        public var peak: Double?
        /// Loudest Volume level of the clip (linear; its keys included): the normalized output peak is
        /// `peak x volume x gain`, so the target is reached after the Volume line, not before it.
        public var volume: Double
        /// Integrated loudness of the source range in LUFS (before gain and Volume); nil while it is not measured.
        public var lufs: Double?
        public init(id: Clip.ID, name: String, gainDB: Double, peak: Double?, volume: Double = 1, lufs: Double? = nil) {
            self.id = id; self.name = name; self.gainDB = gainDB; self.peak = peak; self.volume = volume; self.lufs = lufs
        }
        /// Peak as heard before the Audio Gain stage.
        var effectivePeak: Double? { peak.map { $0 * volume } }
    }

    /// The dialog's rows in order: Set, Adjust, Normalize Max Peak, Normalize All Peaks, Normalize Loudness.
    public static func choice(index: Int, value v: Double) -> AudioGainChoice {
        [.set(v), .adjust(v), .normalizeEach(targetDB: v), .normalizeTogether(targetDB: v), .normalizeLoudness(targetLUFS: v)][index]
    }

    /// New gain per clip. Clips that cannot change (silent, peak unknown) are left out.
    public static func plan(_ choice: AudioGainChoice, items: [Item]) -> [Clip.ID: Double] {
        var out: [Clip.ID: Double] = [:]
        switch choice {
        case .set(let v): for i in items { out[i.id] = AudioGain.apply(.set(v), to: i.gainDB, peak: nil) }
        case .adjust(let d): for i in items { out[i.id] = AudioGain.apply(.adjust(d), to: i.gainDB, peak: nil) }
        case .normalizeEach(let t):
            for i in items { if let g = AudioGain.apply(.normalize(targetDB: t), to: i.gainDB, peak: i.effectivePeak) { out[i.id] = g } }
        case .normalizeLoudness(let t):
            for i in items { if let g = AudioGain.matchLoudness(measuredLUFS: i.lufs, targetLUFS: t) { out[i.id] = g } }
        case .normalizeTogether(let t):
            let known = items.filter { $0.effectivePeak != nil }
            if let gains = AudioGain.normalizeTogether(peaks: known.map { $0.effectivePeak! }, targetDB: t) {
                for (i, g) in zip(known, gains) { out[i.id] = g }
            }
        }
        return out
    }

    /// Clips whose peak (after Volume) would end above 0 dBFS with the gain `choice` gives them. Clips without a peak count
    /// as fine (nothing is known).
    public static func clippingClips(_ choice: AudioGainChoice, items: [Item]) -> [Clip.ID] {
        let gains = plan(choice, items: items)
        return items.compactMap { i in
            guard let g = gains[i.id], let p = i.effectivePeak else { return nil }
            return p * AudioGain.linear(fromDB: g) > 1.0005 ? i.id : nil
        }
    }

    /// Loudest Volume level of a clip: its constant level, or the highest key.
    public static func volumePeak(of clip: Clip) -> Double {
        let v = clip.animation.volume
        return v.track.isEmpty ? max(v.value, 0) : max(v.track.keys.map(\.value).max() ?? v.value, 0)
    }

    /// Loudest peak among `items` in dB (nil when none is known).
    public static func loudestDB(of items: [Item]) -> Double? {
        items.compactMap(\.effectivePeak).max().map { AudioGain.db(fromLinear: $0) }
    }

    /// "Loudness: -23.4 LUFS" (a range for several clips), "measuring..." while the measurement runs.
    public static func loudnessText(items: [Item], measuring: Bool) -> String {
        let values = items.compactMap(\.lufs).filter { $0 > AudioGain.silentLUFS }
        if values.isEmpty { return measuring ? "Loudness: measuring..." : "Loudness: silent or unknown" }
        func f(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "\u{2212}") }
        let lo = values.min()!, hi = values.max()!
        let head = f(lo) == f(hi) ? f(lo) : "\(f(lo)) to \(f(hi))"
        return "Loudness: \(head) LUFS" + (measuring ? " (measuring...)" : "")
    }

    /// One line when the chosen gain pushes clips above 0 dB, nil otherwise.
    public static func warningText(choice: AudioGainChoice, items: [Item]) -> String? {
        let n = clippingClips(choice, items: items).count
        guard n > 0 else { return nil }
        return n == 1 ? "1 clip would peak above 0 dB." : "\(n) clips would peak above 0 dB."
    }

    /// Clip name (or clip count) plus the peak amplitude, for one clip as well as for several.
    public static func infoText(items: [Item]) -> String {
        let head = items.count == 1 ? items[0].name : "\(items.count) clips"
        return head + (loudestDB(of: items).map { String(format: "\nPeak amplitude: %.1f dB", $0) } ?? "")
    }

    /// Explains the two peak modes; shown only when several clips are selected, nil for one clip.
    public static func peakModeNote(itemCount: Int) -> String? {
        itemCount > 1 ? "Max Peak: each clip is raised on its own. All Peaks: one gain for all, the balance between clips stays." : nil
    }
}
