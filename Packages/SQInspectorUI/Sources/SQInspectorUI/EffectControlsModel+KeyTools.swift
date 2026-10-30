import Foundation
import SQCore

/// Graph Editor key tools on the selected keys: roving, time scale, value scale and the Keyframe Velocity numbers.
extension EffectControlsModel {
    /// Speed or Value graph of one row: its own choice, else the panel default.
    public func graphMode(for p: EffectProperty) -> GraphMode { graphModeByProperty[p] ?? graphMode }

    /// The mode toggle of one row's graph changes only that row; the panel default stays.
    public func setGraphMode(_ mode: GraphMode, for p: EffectProperty) { graphModeByProperty[p] = mode }

    /// Roving keys: the selected position keys between fixed keys are re-timed so the motion runs at one speed.
    /// Scale and Anchor are vectors too but have no path, so they are left alone. Returns true when a key moved.
    @discardableResult
    public func roveSelectedKeys() -> Bool {
        guard let c = workingClip ?? clip, !selection.isEmpty else { return false }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        var changed = false
        let skip: Set<PropertyID> = [EffectProperty.scale.id, EffectProperty.anchor.id]
        for (p, t) in s.tracks {
            guard !skip.contains(p), case .vector(var v) = t else { continue }
            let ids = Set(selection.filter { $0.property == p }.map(\.keyID))
            if !ids.isEmpty, v.rove(ids) { s.tracks[p] = .vector(v); changed = true }
        }
        guard changed else { return false }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Rove Keyframes")
        return true
    }

    /// Time scale of the selected keys about the earliest one (`num / den` of their distance to it).
    @discardableResult
    public func scaleSelectionTime(by num: Int64, over den: Int64) -> Bool {
        guard let c = workingClip ?? clip, !selection.isEmpty else { return false }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        let times = s.groups().filter { !$0.members.isDisjoint(with: selection) }.map(\.time)
        guard let pivot = times.min() else { return false }
        var changed = false
        for (p, t) in s.tracks {
            let ids = Set(selection.filter { $0.property == p }.map(\.keyID))
            guard !ids.isEmpty else { continue }
            var t = t
            if t.scaleTimes(ids, by: num, over: den, about: pivot) { s.tracks[p] = t; changed = true }
        }
        guard changed else { return false }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Scale Keyframe Time")
        return true
    }

    /// The Velocity numbers of one selected key side in display units per second (nil without a speed to show).
    public func graphVelocity(of m: SummaryMember, side: KeySide) -> (speed: Double, influence: Double, unit: String)? {
        guard let c = graphEditorCurves().first(where: { $0.property == m.property }),
              let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }), h.segmentSeconds > 0 else { return nil }
        return (h.speed * c.scale, h.influence, c.unit)
    }

    /// Sets speed (display units per second) and influence (0...1) on `side` of every selected key. Each key keeps
    /// the sign of its own segment, so the dialog's number is a magnitude.
    @discardableResult
    public func setGraphVelocity(speed: Double, influence: Double, side: KeySide) -> Bool {
        guard let c = workingClip ?? clip, !selection.isEmpty else { return false }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        var n = 0
        let curves = graphEditorCurves()
        for m in selection {
            guard let curve = curves.first(where: { $0.property == m.property }),
                  let h = curve.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }),
                  h.segmentSeconds > 0, curve.scale > 0 else { continue }
            let avg = abs(h.span) / h.segmentSeconds
            let sign: Double = h.span < 0 ? -1 : 1
            guard let eh = KeyVelocity.handle(speed: abs(speed) / curve.scale * sign, influence: influence, averageSpeed: avg * sign)
            else { continue }
            n += s.setHandle(eh, side: side, on: [m])
        }
        guard n > 0 else { return false }
        var out = c
        write(s.tracks, into: &out)
        commit(out, "Set Keyframe Velocity")
        return true
    }
}

/// Text of the speed and influence readout shown while hovering or dragging a Graph Editor handle.
public enum GraphHandleReadout {
    public static func text(title: String, speed: Double, influence: Double, unit: String) -> String {
        "\(title)\n\(ControlsNumberText.format(speed, decimals: 2)) \(unit)/s · \(ControlsNumberText.format(influence * 100, decimals: 0)) %"
    }
}
