import AppKit
import SQCore
import SQEditorUI

/// Transitions in the shell: timeline callbacks, Effect Controls for a selected transition, "Set Transition Duration",
/// and the context menus on a transition and on a cut.
extension EditorPanels {
    func wireTransitions() {
        let tv = timelineView
        tv.onTransitionSelect = { [weak self] id, keep in self?.session.selectTransition(id, keepClips: keep) }
        tv.onTransitionDoubleClick = { [weak self] id in self?.setTransitionDuration(id) }
        tv.onTransitionChange = { [weak self] id, change, continues in
            guard let self else { return }
            session.stopPlayback()
            session.setTransition(id, duration: change.duration, alignment: change.alignment,
                                  customBefore: change.alignment == .custom ? change.customBefore : nil, continuesGesture: continues)
        }
        tv.onDropTransition = { [weak self] kind, track, point, alignment in
            guard let self else { return }
            session.stopPlayback()
            session.addTransition(kind: kind, track: track, point: point, alignment: alignment)
        }
        tv.onDropElementTransition = { [weak self] kind, track, clip, edges in
            guard let self else { return }
            session.stopPlayback()
            session.addElementTransition(kind: kind, track: track, clip: clip, edges: edges)
        }
        // Transition layer (DECISIONS 2026-10-05): drop on an empty track spot, center marker and end drags.
        tv.transitionLayerDuration = { [weak self] kind in self?.session.transitionLayerDuration(kind) ?? Time(20, 30) }
        tv.onDropTransitionLayer = { [weak self] kind, target in
            guard let self else { return }
            session.stopPlayback()
            session.addTransitionLayer(kind: kind, track: target.track, start: target.start, duration: target.duration, cut: target.cut)
        }
        tv.onTransitionLayerCut = { [weak self] id, time, continues in
            guard let self else { return }
            session.stopPlayback()
            session.moveTransitionLayerCut(id, to: time, continuesGesture: continues)
        }
        tv.onTransitionLayerResize = { [weak self] id, edge, delta, symmetric, continues in
            guard let self else { return .zero }
            session.stopPlayback()
            return session.resizeTransitionLayer(id, edge: edge, by: delta, symmetric: symmetric, continuesGesture: continues)
        }
        // The edits go through the shared `TransitionControlsActions` (to the selected layer clip, else the edge transition).
        let act = transitionActions
        act.onStatus = { [weak self] m in self?.onStatus?(m) }
        transitionView.onKind = { act.setKind($0) }
        transitionView.onSavePreset = { [weak self] in self?.saveSelectedTransitionAsPreset() }
        // FB-W: user default of the shown transition's kind.
        transitionView.onUseAsDefault = { [weak self] in act.useAsDefault(); self?.syncTransitions(.selection) }
        transitionView.onReset = { act.reset() }
        transitionView.onResetDefaultToFactory = { [weak self] in act.resetDefaultToFactory(); self?.syncTransitions(.selection) }
        transitionView.onElementParam = { act.setElementParam($0, $1) }
        transitionView.onElementParamLive = { act.setElementParamLive($0, $1, continuesGesture: $2) }
        transitionView.onDuration = { act.setDuration($0) }
        transitionView.onAlignment = { act.setAlignment($0) }
        transitionView.onEasing = { act.setEasing($0) }
        transitionView.onEditCurve = { [weak self] anchor in
            guard let self, let source = act.easeSource() else { return }
            transitionCurvePopover?.close()
            let pop = EasingCurvePopover.make(source: source)
            transitionCurvePopover = pop
            pop.onClose = { [weak self, weak pop] in if self?.transitionCurvePopover === pop { self?.transitionCurvePopover = nil } }
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
        transitionView.onDirection = { act.setDirection($0) }
        transitionView.onReversed = { act.setReversed($0) }
        transitionView.onSoftness = { act.setSoftness($0, continuesGesture: $1) }
        transitionView.onMotionBlur = { act.setMotionBlur($0, continuesGesture: $1) }
        transitionView.onColor = { act.setColor($0, continuesGesture: $1) }
        transitionView.onBorderWidth = { act.setBorderWidth($0, continuesGesture: $1) }
        transitionView.onBorderColor = { act.setBorderColor($0, continuesGesture: $1) }
        transitionView.onStingerMedia = { act.setStingerMedia($0) }
        transitionView.onStingerCut = { act.setStingerCut($0, continuesGesture: $1) }
    }

    /// The one selected clip when it is a transition layer (and no clip-edge transition is selected).
    var selectedTransitionLayer: Clip.ID? { transitionActions.selectedLayer }

    /// Keeps the timeline selection and Effect Controls in step with the session.
    func syncTransitions(_ change: EditorSession.Change) {
        guard change.contains(.selection) || change.contains(.project) else { return }
        timelineView.setSelectedTransition(session.selectedTransition, notify: false)
        if let shown = transitionActions.shown() {
            transitionView.update(transition: shown.transition, resolved: shown.resolved, frameDuration: shown.frameDuration,
                                  stingerMedia: shown.stingerMedia.map { (id: $0.id, name: $0.name) },
                                  hasUserDefault: shown.hasUserDefault, isLayer: shown.isLayer)
            effectContainer.showsTransition = true
        } else if effectContainer.showsTransition {
            effectContainer.showsTransition = false
        }
    }

    func setTransitionDuration(_ id: Transition.ID) {
        guard let info = session.transitionInfo(id), let fd = session.activeTimeline?.frameDuration else { return }
        TransitionDurationSheet.present(on: timelineView.window, name: info.transition.kind.name,
                                        duration: info.resolved?.duration ?? info.transition.duration, frameDuration: fd) { [weak self] d in
            self?.session.setTransition(id, duration: d)
        }
    }

    /// Name sheet for the selected transition, then saves it to the Library as a transition preset.
    func saveSelectedTransitionAsPreset() {
        guard let preset = session.presetFromSelectedTransition() else { return }
        TransitionPresetSheet.present(on: timelineView.window, defaultName: preset.kind.name) { [weak self] name in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await libraryModel.savePreset(EditorSession.transitionPresetItem(name: name, preset: preset))
                    onStatus?(SQL10n.format("Saved transition preset “%@”.", name))
                } catch {
                    onStatus?(SQL10n.format("The preset could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// Right-click on a transition box (selects it): Set Duration…, Save as Preset…, Delete.
    func transitionItems(at p: CGPoint) -> [SQMenuItem]? {
        let tv = timelineView
        guard let hit = TransitionLayout.hitTest(p, in: tv.timeline, geometry: tv.geometry) else { return nil }
        tv.setSelectedTransition(hit.id)
        return TimelineSideMenus.transition(
            setDuration: { [weak self] in self?.setTransitionDuration(hit.id) },
            saveAsPreset: { [weak self] in
                self?.session.selectTransition(hit.id)
                self?.saveSelectedTransitionAsPreset()
            },
            delete: { [weak self] in self?.session.removeTransition(hit.id) })
    }

    /// A cut (right-click on a clip's head or tail): Apply Default Transitions at that edit goes on top of the clip menu.
    func editPointItems(at p: CGPoint) -> [SQMenuItem] {
        let tv = timelineView
        guard case .clip(let id, let zone) = tv.geometry.hitTest(p, in: tv.timeline), zone != .body,
              let track = tv.timeline.tracks.first(where: { $0.clips.contains { $0.id == id } }), !track.isLocked else { return [] }
        let ref = EdgeRef(clip: id, edge: zone == .head ? .head : .tail)
        let scope: EditorSession.TransitionScope = track.kind == .video ? .video : .audio
        return [SQMenuItem(title: "Apply Default Transitions") { [weak self] in
            self?.session.applyDefaultTransitions(scope: scope, edges: EdgeSelection(edges: [ref]))
        }, .separator]
    }
}
