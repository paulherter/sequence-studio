import Foundation

/// "Extend to sequence end" (ProjectFile v49): an Adjustment Layer that follows the end of the cut, so a grade that lives
/// on one layer keeps covering the sequence as it grows or shrinks. The editor session applies it after every edit
/// (`Project.extendAdjustmentLayersToSequenceEnd`), inside the same undo step as the edit.
extension Clip {
    /// Only meaningful on Adjustment Layers.
    public var extendsToSequenceEnd: Bool {
        get { extendsToEndStore == true }
        set { extendsToEndStore = newValue ? true : nil }
    }
}

extension Project {
    /// Switches the flag (Adjustment Layers only; any other clip is left alone) and applies it right away.
    public mutating func setExtendToSequenceEnd(_ on: Bool, clip id: Clip.ID) {
        var found = false
        forEachClipInPlace { c in
            if c.id == id, c.isAdjustment { c.extendsToSequenceEnd = on; found = true }
        }
        if found { extendAdjustmentLayersToSequenceEnd() }
    }

    /// Trims the tail of every flagged Adjustment Layer to the end of the rest of its sequence (the latest end of any clip
    /// that is not itself a flagged layer). Growing stops at the next clip on the layer's track; a locked track, a
    /// sequence with nothing else in it, or an end at or before the layer's start leaves the layer as it is.
    public mutating func extendAdjustmentLayersToSequenceEnd() {
        for ti in timelines.indices where timelines[ti].tracks.contains(where: { $0.clips.contains(where: \.extendsToSequenceEnd) }) {
            let others = timelines[ti].tracks.flatMap(\.clips).filter { !$0.extendsToSequenceEnd }
            guard let target = others.map({ $0.timeline.end }).max() else { continue }
            let layers = timelines[ti].tracks.flatMap(\.clips).filter { $0.extendsToSequenceEnd && $0.isAdjustment }
            for layer in layers {
                guard target > layer.start, layer.timeline.end != target else { continue }
                _ = try? timelines[ti].trim(layer.id, edge: .tail, by: target - layer.timeline.end)
            }
        }
    }

    /// Any flagged Adjustment Layer: the file needs v49.
    public var containsExtendedAdjustments: Bool {
        allClips().contains { $0.extendsToSequenceEnd && $0.isAdjustment }
    }
}
