import AppKit
import SSCore
import SSMedia

/// What the Audio Gain dialog does to the selected audio clips (Premiere: Set Gain to, Adjust Gain by,
/// Normalize Max Peak to, Normalize All Peaks to).
public enum AudioGainChoice: Sendable, Equatable {
    case set(Double)
    case adjust(Double)
    case normalizeEach(targetDB: Double)
    case normalizeTogether(targetDB: Double)
}

public enum AudioGainPlan {
    public struct Item: Sendable, Equatable {
        public var id: Clip.ID
        public var name: String
        /// Gain the clip has now.
        public var gainDB: Double
        /// Linear sample peak of the clip's source range; nil when unknown (waveform not read yet).
        public var peak: Double?
        /// Loudest Volume level of the clip (linear; its keys included): the normalised output peak is
        /// `peak x volume x gain`, so the target is reached after the Volume line, not before it.
        public var volume: Double
        public init(id: Clip.ID, name: String, gainDB: Double, peak: Double?, volume: Double = 1) {
            self.id = id; self.name = name; self.gainDB = gainDB; self.peak = peak; self.volume = volume
        }
        /// Peak as heard before the Audio Gain stage.
        var effectivePeak: Double? { peak.map { $0 * volume } }
    }

    /// New gain per clip. Clips that cannot change (silent, peak unknown) are left out.
    public static func plan(_ choice: AudioGainChoice, items: [Item]) -> [Clip.ID: Double] {
        var out: [Clip.ID: Double] = [:]
        switch choice {
        case .set(let v): for i in items { out[i.id] = AudioGain.apply(.set(v), to: i.gainDB, peak: nil) }
        case .adjust(let d): for i in items { out[i.id] = AudioGain.apply(.adjust(d), to: i.gainDB, peak: nil) }
        case .normalizeEach(let t):
            for i in items { if let g = AudioGain.apply(.normalize(targetDB: t), to: i.gainDB, peak: i.effectivePeak) { out[i.id] = g } }
        case .normalizeTogether(let t):
            let known = items.filter { $0.effectivePeak != nil }
            if let gains = AudioGain.normalizeTogether(peaks: known.map { $0.effectivePeak! }, targetDB: t) {
                for (i, g) in zip(known, gains) { out[i.id] = g }
            }
        }
        return out
    }

    /// Loudest sample of the clip's source range as linear 0...1 (nil without waveform data).
    public static func peak(of data: WaveformData, source: TimeRange) -> Double {
        let p = data.peaks(in: source, buckets: 1)
        return p.reduce(0.0) { m, ch in max(m, ch.map { Double(max(abs($0.min), abs($0.max))) }.max() ?? 0) }
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
}

/// The Audio Gain sheet (key G). Opens with the current choice "Adjust Gain by 0 dB" like Premiere does for a
/// clip that has no gain yet.
@MainActor
public enum AudioGainDialog {
    private enum Row: Int, CaseIterable { case set, adjust, normalizeEach, normalizeTogether }

    public static func present(on window: NSWindow, items: [AudioGainPlan.Item], completion: @escaping @MainActor (AudioGainChoice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Audio Gain"
        let loudest = AudioGainPlan.loudestDB(of: items)
        alert.informativeText = items.count == 1 ? items[0].name : "\(items.count) clips"
            + (loudest.map { String(format: "\nPeak amplitude: %.1f dB", $0) } ?? "")

        let titles = ["Set Gain to", "Adjust Gain by", "Normalize Max Peak to", "Normalize All Peaks to"]
        let radios = titles.enumerated().map { i, t -> NSButton in
            let b = NSButton(radioButtonWithTitle: t, target: nil, action: nil)
            b.tag = i
            return b
        }
        let fields = Row.allCases.map { _ -> NSTextField in
            let f = NSTextField(string: "0")
            f.alignment = .right; f.widthAnchor.constraint(equalToConstant: 60).isActive = true
            return f
        }
        fields[0].stringValue = String(format: "%g", items.count == 1 ? (items[0].gainDB * 10).rounded() / 10 : 0)
        fields[2].stringValue = "0"; fields[3].stringValue = "0"
        final class Group: NSObject {
            var radios: [NSButton] = []
            @objc func pick(_ s: NSButton) { for r in radios { r.state = r === s ? .on : .off } }
        }
        let group = Group(); group.radios = radios
        for r in radios { r.target = group; r.action = #selector(Group.pick(_:)) }
        radios[1].state = .on

        func row(_ i: Int) -> [NSView] { [radios[i], fields[i], NSTextField(labelWithString: "dB")] }
        let grid = NSGridView(views: (0..<4).map(row))
        grid.rowSpacing = 6; grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(group) {}
                guard response == .alertFirstButtonReturn, let i = radios.firstIndex(where: { $0.state == .on }) else { completion(nil); return }
                let v = fields[i].doubleValue
                completion([.set(v), .adjust(v), .normalizeEach(targetDB: v), .normalizeTogether(targetDB: v)][i])
            }
        }
    }
}
