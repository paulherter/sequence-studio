import AppKit
import SQCore
import SQEditorUI

/// Trim mode (TL-08 / TL-09): the two-up monitor over the Program viewer, opened by a double-click on an edit or Ctrl+Shift+T.
extension EditorPanels {
    func wireTrimMode() {
        trimModel.onChange = { [weak self] in self?.syncTrimMode() }
    }

    /// Ctrl+Shift+T: on at the edit nearest the playhead, or off. False when there is no edit or no engine.
    func toggleTrimMode() -> Bool {
        if trimModel.isActive { exitTrimMode(); return true }
        session.stopPlayback()
        guard prepareTrimView() else { return false }
        return trimModel.enterNearestPlayhead()
    }

    func enterTrimMode(_ point: TrimPoint, pointerBefore: Bool) {
        session.stopPlayback()
        guard prepareTrimView() else { onStatus?("Trim mode needs a Metal-capable display."); return }
        trimModel.enter(point, pointerBefore: pointerBefore)
    }

    func exitTrimMode() {
        trimModel.exit()
        trimView?.release()
    }

    /// The view is made once, on first use, with its two engines (none without a Metal device).
    private func prepareTrimView() -> Bool {
        if trimView != nil { return true }
        guard let engines = makeTrimEngines?() else { return false }
        let v = TrimMonitorView(model: trimModel, session: session, beforeEngine: engines.0, afterEngine: engines.1)
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = monitorView.viewerSlot.bounds
        v.autoresizingMask = [.width, .height]
        monitorView.viewerSlot.addSubview(v)
        v.onDone = { [weak self] in self?.exitTrimMode() }
        v.onRelease = { [weak self] in self?.releaseTrimCache?() }
        trimView = v
        return true
    }

    /// Model changed: refresh the view and show the edit and the trimmed side as the timeline's edge selection.
    private func syncTrimMode() {
        trimView?.refresh()
        guard let p = trimModel.point else { return }
        var edges: [EdgeRef] = []
        switch trimModel.side {
        case .outgoing: if let o = p.outgoing { edges = [EdgeRef(clip: o, edge: .tail)] }
        case .incoming: if let i = p.incoming { edges = [EdgeRef(clip: i, edge: .head)] }
        case .roll: if let o = p.outgoing, let i = p.incoming { edges = [EdgeRef(clip: o, edge: .tail), EdgeRef(clip: i, edge: .head)] }
        }
        guard !edges.isEmpty else { return }
        timelineView.selectEdges(EdgeSelection(edges: edges, ripple: trimModel.side != .roll))
    }
}
