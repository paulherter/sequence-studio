import Foundation
import SQCore

/// Clip > Split Screen: one command lays the selected video clips out in the frame. One undo step.
extension EditorSession {
    /// Length of the slide in and out of the animated variants.
    public static let defaultSplitAnimationDuration = Time(1, 2)

    /// Why `preset` cannot be applied to the current clips.
    public enum SplitScreenProblem: Equatable, Sendable { case tooFewClips(required: Int), sameTrack }

    /// nil when `preset` can be applied to the current clips.
    public func splitScreenProblem(_ preset: SplitLayoutPreset) -> SplitScreenProblem? {
        guard let t = activeTimeline else { return .tooFewClips(required: preset.cellCount) }
        let ids = Set(commandClips(kind: .video).map(\.id))
        let trackIndexes = t.tracks.indices.flatMap { i in t.tracks[i].clips.filter { ids.contains($0.id) }.map { _ in i } }
        if Set(trackIndexes).count != trackIndexes.count { return .sameTrack }
        return trackIndexes.count >= preset.cellCount ? nil : .tooFewClips(required: preset.cellCount)
    }

    /// Number of selected video clips beyond the preset's cells (they are left alone).
    public func splitScreenExtraClips(_ preset: SplitLayoutPreset) -> Int {
        max(commandClips(kind: .video).count - preset.cellCount, 0)
    }

    /// Lays the selected video clips (lowest track = first cell) out as `preset`: Scale and Position plus a Crop effect,
    /// all editable afterwards. `animated` adds slide in/out keys with an ease in/out; `gap` px of divider line.
    /// False when fewer clips than the preset needs are selected, or a track is locked.
    @discardableResult
    public func applySplitScreen(_ preset: SplitLayoutPreset, animated: Bool = false, gap: Double = 0) -> Bool {
        guard let tid = activeTimelineID else { return false }
        let ids = Set(commandClips(kind: .video).map(\.id))
        guard splitScreenProblem(preset) == nil else { return false }
        let animation = animated ? SplitAnimation(duration: Self.defaultSplitAnimationDuration) : nil
        var trial = project
        do {
            guard try trial.applySplitLayout(preset, to: ids, in: tid, gap: gap, animation: animation) > 0 else { return false }
            try perform("Split Screen") { $0 = trial }
        } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }
}
