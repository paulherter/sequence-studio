import Foundation
import SQCore

/// Speed-ramp presets, Hit on Beat, and the beat edits (Cut to Beats, Snap to Beats). One undo step each.
extension EditorSession {
    public enum SpeedPresetOutcome: Equatable, Sendable {
        case applied(clips: Int)
        case noClip
        /// Hit on Beat found no beat marker inside the clips.
        case noBeat
    }

    public var canApplySpeedPreset: Bool { !remappableSelection.isEmpty }
    public var hasBeatMarkers: Bool { !(activeTimeline?.beatTimes.isEmpty ?? true) }
    public var canEditToBeats: Bool { !selection.isEmpty && hasBeatMarkers }

    /// Applies `preset` to every selected video clip (the clip keeps its source range; its length follows the speeds).
    /// `onBeat`: the peak goes onto the beat marker nearest the clip's middle (clips without a beat inside are skipped).
    @discardableResult
    public func applySpeedPreset(_ preset: SpeedRampPreset, onBeat: Bool) -> SpeedPresetOutcome {
        guard let tl = activeTimeline else { return .noClip }
        let clips = remappableSelection
        guard !clips.isEmpty else { return .noClip }
        let fd = tl.frameDuration
        let beats = tl.beatTimes
        var plan: [(Clip.ID, SpeedKeys)] = []
        for c in clips {
            let base = SpeedKeys.of(c)
            var peak: Time?
            if onBeat {
                let mid2 = c.start + c.timeline.end      // twice the middle
                guard let beat = beats.filter({ $0 > c.start + fd && $0 < c.timeline.end - fd })
                    .min(by: { Self.gap($0 + $0, mid2) < Self.gap($1 + $1, mid2) }) else { continue }
                peak = beat - c.start
            }
            plan.append((c.id, preset.keys(for: base, frameDuration: fd, peakAt: peak)))
        }
        guard !plan.isEmpty else { return .noBeat }
        let name = onBeat ? "\(preset.title) Speed Ramp on Beat" : "\(preset.title) Speed Ramp"
        var done = 0
        attempt(name) { t in
            done = 0
            for (id, keys) in plan where t.tracks.lazy.flatMap(\.clips).contains(where: { $0.id == id }) {
                try t.magneticEditSpeedKeys(id, keepingKeys: true) { _ in keys }
                done += 1
            }
        }
        return done > 0 ? .applied(clips: done) : .noClip
    }

    private static func gap(_ a: Time, _ b: Time) -> Time { a > b ? a - b : b - a }

    /// Clip > Cut to Beats: cuts the selected clips (with their linked partners) at every beat marker inside them.
    /// Returns the number of cuts, or nil when the edit was refused.
    @discardableResult
    public func cutToBeats() -> Int? {
        let ids = selection
        var n = 0
        guard attempt("Cut to Beats", { n = try $0.cutToBeats(clips: ids) }) else { return n == 0 ? 0 : nil }
        return n
    }

    /// Clip > Snap to Beats: each selected clip's end moves to the nearest beat marker (ripple).
    @discardableResult
    public func snapToBeats() -> Int? {
        let ids = Array(selection)
        var n = 0
        guard attempt("Snap to Beats", { n = try $0.snapToBeats(clips: ids) }) else { return n == 0 ? 0 : nil }
        return n
    }
}
