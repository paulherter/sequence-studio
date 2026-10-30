import Foundation
import SQCore

/// Which rubber band a key belongs to.
public enum LineKeyProperty: Hashable, Sendable { case opacity, volume }

/// One key on a clip's opacity or volume line, as selected in the timeline.
public struct LineKeyRef: Hashable, Sendable {
    public var clip: Clip.ID
    public var property: LineKeyProperty
    public var key: UUID
    public init(clip: Clip.ID, property: LineKeyProperty, key: UUID) {
        self.clip = clip; self.property = property; self.key = key
    }
}

extension EditorSession {
    /// Selects keys on the opacity / volume lines (a click on a key; Shift-click extends). Keys follow the clip selection:
    /// only keys of selected clips are kept, and changing the clip selection clears them. Frame nudges
    /// (`nudgeSelection`) then move these keys instead of the clips.
    public func selectLineKeys(_ keys: Set<LineKeyRef>) {
        let next = keys.filter { selection.contains($0.clip) }
        guard next != selectedLineKeys else { return }
        selectedLineKeys = next
        notify(.selection)
    }

    /// Moves the selected line keys by `n` frames in time, keeping their levels. Keys stay inside the clip and never cross
    /// or land on a neighbor. Returns false when no key is selected (the caller nudges clips instead).
    @discardableResult
    func nudgeLineKeys(frames n: Int) -> Bool {
        guard let t = activeTimeline else { return false }
        let refs = selectedLineKeys.filter { r in
            selection.contains(r.clip) && t.tracks.contains { $0.clips.contains { $0.id == r.clip } }
        }
        guard !refs.isEmpty, n != 0 else { return !refs.isEmpty }
        let d = t.frameDuration * Int64(n)
        let name = "Nudge Keyframes"
        return attempt(name) { tl in
            for clipID in Set(refs.map(\.clip)) {
                guard var c = tl.tracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { continue }
                for p in [LineKeyProperty.opacity, .volume] {
                    let ids = Set(refs.filter { $0.clip == clipID && $0.property == p }.map(\.key))
                    guard !ids.isEmpty else { continue }
                    Self.shiftKeys(ids, of: p, in: &c, by: d, frameDuration: tl.frameDuration)
                }
                try tl.replaceClip(c)
            }
        }
    }

    private static func shiftKeys(_ ids: Set<UUID>, of p: LineKeyProperty, in c: inout Clip, by d: Time, frameDuration: Time) {
        func keys() -> [Keyframe<Double>] { p == .opacity ? c.animation.opacity.track.keys : c.animation.volume.track.keys }
        // Leading keys first, so a run of selected keys moves as one block instead of tripping over itself.
        let order = keys().filter { ids.contains($0.id) }.map(\.id)
        for id in (d > .zero ? order.reversed() : order) {
            let all = keys()
            guard let i = all.firstIndex(where: { $0.id == id }) else { continue }
            var t = min(max(all[i].time + d, .zero), c.duration)
            if i > 0 { t = max(t, all[i - 1].time + Clip.minKeyGap) }
            if i + 1 < all.count { t = min(t, all[i + 1].time - Clip.minKeyGap) }
            switch p {
            case .opacity: c.moveOpacityKey(id, toLocal: t, value: all[i].value)
            case .volume: c.moveVolumeKey(id, toLocal: t, gainDB: AudioGain.db(fromLinear: all[i].value))
            }
        }
    }
}
