import Foundation

// MARK: - Scale and duplicate of selected keys (relative multi-key editing)

extension KeyframeTrack where V == Double {
    /// Scales the values of the selected keys about `pivot` (value space) by `factor`.
    /// Returns false when no selected key belongs to this track.
    @discardableResult
    public mutating func scaleValues(_ ids: Set<UUID>, by factor: Double, about pivot: Double) -> Bool {
        let targets = keys.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return false }
        for k in targets { set(k.id, value: pivot + (k.value - pivot) * factor) }
        return true
    }

    /// Scales about the mean of the selected values, so a group of keys keeps its center and grows or shrinks.
    @discardableResult
    public mutating func scaleValuesAboutMean(_ ids: Set<UUID>, by factor: Double) -> Bool {
        let targets = keys.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return false }
        let mean = targets.map(\.value).reduce(0, +) / Double(targets.count)
        return scaleValues(ids, by: factor, about: mean)
    }
}

extension KeyframeTrack {
    /// Copies the selected keys `offset` later (earlier when negative) with fresh ids and the same easing.
    /// A copy landing on a time held by another key replaces that key. Returns the ids of the copies.
    @discardableResult
    public mutating func duplicateKeys(_ ids: Set<UUID>, offset: Time) -> Set<UUID> {
        var copies: [Keyframe<V>] = []
        for k in keys where ids.contains(k.id) {
            var c = k; c.id = UUID(); c.time = k.time + offset
            copies.append(c)
        }
        for c in copies { insert(c) }
        return Set(copies.map(\.id))
    }
}

extension PropertyTrack {
    /// `KeyframeTrack.duplicateKeys` for any value type.
    @discardableResult
    public mutating func duplicateKeys(_ ids: Set<UUID>, offset: Time) -> Set<UUID> {
        switch self {
        case .scalar(var t): let r = t.duplicateKeys(ids, offset: offset); self = .scalar(t); return r
        case .vector(var t): let r = t.duplicateKeys(ids, offset: offset); self = .vector(t); return r
        case .color(var t): let r = t.duplicateKeys(ids, offset: offset); self = .color(t); return r
        case .path(var t): let r = t.duplicateKeys(ids, offset: offset); self = .path(t); return r
        }
    }
}
