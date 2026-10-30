import AppKit
import SQCore
import SQMonitorUI
import SQTimelineUI

/// Slip drag: first and last frame of the clip side by side over the Program viewer while the mouse is down.
extension EditorPanels {
    /// Called on every gesture step; `two` is nil when no Slip drag runs (mouse up or cancel).
    func syncSlipTwoUp(_ two: SlipTwoUp?, preview: Timeline) {
        guard let two else { slipView?.hide(); return }
        guard prepareSlipView() else { return }
        let sequences = session.pushedSnapshot?.sequences ?? [:]
        slipView?.show(timeline: preview, sequences: sequences, headTime: two.headTime, tailTime: two.tailTime,
                       offsetFrames: SlipTwoUpLayout.wholeFrames(two.offset, frameDuration: preview.frameDuration), settingsFrom: session.engine)
    }

    private func prepareSlipView() -> Bool {
        if slipView != nil { return true }
        guard let engines = makeSlipEngines?() else { return false }
        let v = SlipTwoUpView(headEngine: engines.0, tailEngine: engines.1)
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = monitorView.viewerSlot.bounds
        v.autoresizingMask = [.width, .height]
        monitorView.viewerSlot.addSubview(v)
        v.onRelease = { [weak self] in self?.releaseSlipCache?() }
        slipView = v
        return true
    }
}
