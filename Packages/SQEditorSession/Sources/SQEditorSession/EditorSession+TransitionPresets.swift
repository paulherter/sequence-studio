import Foundation
import SQUIKit
import SQCore
import SQLibrary

/// Transition presets (kind, length, alignment, easing, style): save the selected transition, apply to a transition or a cut.
extension EditorSession {
    /// A Library preset item for `preset` (kind `.transition`, current payload version).
    public static func transitionPresetItem(name: String, preset: TransitionPreset) throws -> PresetItem {
        PresetItem(kind: .transition, name: name, payload: try preset.payload(), payloadVersion: TransitionPreset.payloadVersion)
    }

    /// Preset from the selected transition; nil when none is selected (or it is gone).
    public func presetFromSelectedTransition() -> TransitionPreset? {
        guard let id = selectedTransition, let info = transitionInfo(id) else { return nil }
        return TransitionPreset.capture(from: info.transition)
    }

    /// Applies a `.transition` preset: to the selected transition (changed in place), else at the selected edit(s), the edges
    /// of the selected clips, or the edit nearest the playhead (`edges` as in `applyDefaultTransitions`). One undo step.
    /// False (with a fresh `lastError`) for another kind, an unreadable payload, no cut found or a refused edit.
    @discardableResult
    public func applyTransitionPreset(_ item: PresetItem, edges: EdgeSelection?) -> Bool {
        guard item.kind == .transition else { setError("“\(item.name)” is not a transition preset."); return false }
        let preset: TransitionPreset
        do { preset = try TransitionPreset(payload: item.payload, version: item.payloadVersion) } catch {
            setError("“\(item.name)” was made by a newer version of Sequence Studio or is damaged.")
            return false
        }
        let name = "Apply Transition Preset “\(item.name)”"
        if let id = selectedTransition, activeTimeline?.transition(id) != nil {
            // Re-applying an identical preset changes nothing: not a failure, no message (as for effect presets).
            do { try performTimeline(name) { try $0.applyTransitionPreset(preset, to: id) } } catch {
                setError(Self.message(for: error)); return false
            }
            return true
        }
        guard let t = activeTimeline else { return false }
        let targets = TransitionTargets.resolve(in: t, kinds: [preset.trackKind], edges: edges, selection: selection, playhead: playhead,
                                                clipEdgesOnly: preset.kind.isElement)
        let bothEnds = preset.kind.isElement ? Self.clipsWithBothEnds(targets) : []
        guard !targets.isEmpty else {
            setError(SQL10n.format(preset.trackKind == .audio ? "Target an audio track, or select an edit, to apply “%@”."
                                                           : "Target a track, or select an edit, to apply “%@”.", item.name))
            return false
        }
        var made: Transition.ID?
        let ok = attempt(name) { tl in
            var applied = 0
            for target in targets {
                var p = preset
                if let c = target.point.elementClip, bothEnds.contains(c), let clip = tl.track(target.track)?.clips.first(where: { $0.id == c }) {
                    p.duration = Timeline.elementDuration(p.duration, clipDuration: clip.duration, bothEnds: true,
                                                          frameDuration: tl.format.frameDuration)
                }
                guard let id = try? tl.addTransition(preset: p, point: target.point, track: target.track) else { continue }
                made = id; applied += 1
            }
            if applied == 0 { throw EditError.insufficientMedia }
        }
        if ok, targets.count == 1, let made { selectTransition(made) }
        return ok
    }
}
