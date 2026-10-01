import AppKit
import SQCore
import SQEditorUI

/// Transitions in the shell: timeline callbacks, Effect Controls for a selected transition, "Set Transition Duration",
/// and the context menus on a transition and on a cut.
extension EditorPanels {
    func wireTransitions() {
        let tv = timelineView
        tv.onTransitionSelect = { [weak self] id in self?.session.selectTransition(id) }
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
        transitionView.onDuration = { [weak self] d in
            guard let self, let id = session.selectedTransition else { return }
            session.setTransition(id, duration: d)
        }
        transitionView.onAlignment = { [weak self] a in
            guard let self, let id = session.selectedTransition else { return }
            // A custom alignment keeps its offset; the named ones are fully described by the alignment itself.
            session.setTransition(id, alignment: a)
        }
    }

    /// Keeps the timeline selection and Effect Controls in step with the session.
    func syncTransitions(_ change: EditorSession.Change) {
        guard change.contains(.selection) || change.contains(.project) else { return }
        timelineView.setSelectedTransition(session.selectedTransition, notify: false)
        if let id = session.selectedTransition, let info = session.transitionInfo(id),
           let fd = session.activeTimeline?.frameDuration {
            transitionView.update(transition: info.transition, resolved: info.resolved, frameDuration: fd)
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

    /// Right-click on a transition box (selects it): Set Duration…, Clear.
    func transitionMenu(at p: CGPoint) -> NSMenu? {
        let tv = timelineView
        guard let hit = TransitionLayout.hitTest(p, in: tv.timeline, geometry: tv.geometry) else { return nil }
        tv.setSelectedTransition(hit.id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(BlockMenuItem("Set Transition Duration…") { [weak self] in self?.setTransitionDuration(hit.id) })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("Clear") { [weak self] in self?.session.removeTransition(hit.id) })
        return menu
    }

    /// A cut (right-click on a clip's head or tail): Apply Default Transitions at that edit goes on top of the clip menu.
    func addEditPointItems(to menu: NSMenu, at p: CGPoint) {
        let tv = timelineView
        guard case .clip(let id, let zone) = tv.geometry.hitTest(p, in: tv.timeline), zone != .body,
              let track = tv.timeline.tracks.first(where: { $0.clips.contains { $0.id == id } }), !track.isLocked else { return }
        let ref = EdgeRef(clip: id, edge: zone == .head ? .head : .tail)
        let scope: EditorSession.TransitionScope = track.kind == .video ? .video : .audio
        let item = BlockMenuItem("Apply Default Transitions") { [weak self] in
            self?.session.applyDefaultTransitions(scope: scope, edges: EdgeSelection(edges: [ref]))
        }
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
}
