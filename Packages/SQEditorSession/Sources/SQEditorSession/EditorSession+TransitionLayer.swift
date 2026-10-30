import Foundation
import SQCore

/// Transition layers (DECISIONS 2026-10-05) as user actions: every call is one undo step; a drag coalesces into one.
extension EditorSession {
    /// The layer as a `Transition` (for Effect Controls) with its resolved form; nil for another clip.
    public func transitionLayerInfo(_ id: Clip.ID) -> (track: Track.ID, transition: Transition, resolved: ResolvedTransition)? {
        guard let t = activeTimeline, let ti = t.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              let c = t.tracks[ti].clips.first(where: { $0.id == id }), let l = c.transitionLayer,
              let r = c.resolvedTransitionLayer(frameDuration: t.format.frameDuration) else { return nil }
        var tr = Transition(id: id, kind: l.kind, duration: r.span.duration, alignment: r.alignment, customBefore: r.before,
                            outgoing: nil, incoming: nil)
        tr.easing = l.easing; tr.direction = l.direction; tr.reversed = l.reversed; tr.softness = l.softness; tr.motionBlur = l.motionBlur
        tr.params = l.params
        return (t.tracks[ti].id, tr, r)
    }

    /// Length a layer of `kind` gets when dropped: the user default of the kind, else the factory length.
    public func transitionLayerDuration(_ kind: TransitionKind, defaults: TransitionDefaults = .load()) -> Time {
        let fd = activeTimeline?.format.frameDuration ?? Time(1, 30)
        return effectDefaults.transition(kind)?.duration ?? Self.factoryTransitionDuration(kind, frameDuration: fd, defaults: defaults)
    }

    /// Places a transition layer `[start, start + duration)` on `track` with its cut at `cut` (drop from the Effects panel).
    /// The user default's look of the kind is applied. One undo step; selects the new clip. A refusal goes to `lastError`.
    @discardableResult
    public func addTransitionLayer(kind: TransitionKind, track: Track.ID, start: Time, duration: Time, cut: Time) -> Clip.ID? {
        guard let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        let user = effectDefaults.transition(kind)
        var made: Clip.ID?
        do {
            try perform("Add \(kind.name) Layer") { p in
                let id = try p.addTransitionLayer(kind: kind, in: tl, at: start, track: track, duration: duration)
                try p.edit(tl) { t in
                    try t.setTransitionLayerCut(id, to: cut)
                    // The user's default look of the kind, else the factory look (DECISIONS 2026-10-06).
                    try t.setTransitionLayer(id) { l in
                        guard let user else { l.applyFactoryLook(); return }
                        l.easing = user.easing; l.direction = user.direction; l.softness = user.softness; l.motionBlur = user.motionBlur
                        if kind.isZoomThrough { l.params = user.params }
                    }
                }
                made = id
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let made { select(clips: [made]) }
        return made
    }

    /// Center marker drag: moves the cut to `time` (snapped and clamped by the model).
    @discardableResult
    public func moveTransitionLayerCut(_ id: Clip.ID, to time: Time, continuesGesture: Bool) -> Bool {
        if !continuesGesture { gestureCounter += 1 }
        return attempt("Move Transition Cut", coalescing: "layerCut:\(id):\(gestureCounter)") { try $0.setTransitionLayerCut(id, to: time) }
    }

    /// End drag: moves `edge` by `delta` (positive = right); `symmetric` moves the other end the opposite way. Returns how far
    /// the edge moved (the view keeps the sum, so a drag back from a limit works).
    @discardableResult
    public func resizeTransitionLayer(_ id: Clip.ID, edge: ClipEdge, by delta: Time, symmetric: Bool, continuesGesture: Bool) -> Time {
        if !continuesGesture { gestureCounter += 1 }
        var moved = Time.zero
        _ = attempt("Resize Transition Layer", coalescing: "layerSize:\(id):\(gestureCounter)") {
            moved = try $0.resizeTransitionLayer(id, edge: edge, by: delta, symmetric: symmetric)
        }
        return moved
    }

    @discardableResult
    public func setTransitionLayerKind(_ id: Clip.ID, _ kind: TransitionKind) -> Bool {
        guard kind.isLayerKind else { setError("\(kind.name) cannot be a transition layer."); return false }
        return attempt("Change Transition Layer") { try $0.setTransitionLayer(id) { $0.changeKind(to: kind) } }
    }

    @discardableResult
    public func setTransitionLayerDuration(_ id: Clip.ID, _ duration: Time) -> Bool {
        attempt("Transition Layer Duration") { try $0.setTransitionLayerDuration(id, duration) }
    }

    @discardableResult
    public func setTransitionLayerAlignment(_ id: Clip.ID, _ alignment: TransitionAlignment) -> Bool {
        attempt("Transition Layer Alignment") { try $0.setTransitionLayerAlignment(id, alignment) }
    }

    /// A parameter of the layer's kind (Zoom In / Out's Amount), as `setTransitionParams` for a transition.
    @discardableResult
    public func setTransitionLayerParam(_ id: Clip.ID, _ key: String, _ value: Double, continuesGesture: Bool = false) -> Bool {
        setTransitionLayerStyle(id, "Amount", continuesGesture: continuesGesture) { $0.setParam(key, value) }
    }

    /// Easing / direction / softness / motion blur (`name` = the undo name's property).
    @discardableResult
    public func setTransitionLayerStyle(_ id: Clip.ID, _ name: String, continuesGesture: Bool,
                                        _ change: @escaping (inout TransitionLayer) -> Void) -> Bool {
        if !continuesGesture { gestureCounter += 1 }
        return attempt("Transition Layer \(name)", coalescing: "layerStyle:\(id):\(gestureCounter)") { try $0.setTransitionLayer(id, change) }
    }
}
