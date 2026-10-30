import AppKit
import SQCore
import SQEditorUI

/// Time Remapping speed band: every drag is one undo step; right-click on a key or transition offers its delete, and on a
/// transition the curve popover (Bezier speed, W4.4).
extension EditorPanels {
    func wireSpeedBand() {
        timelineView.onSpeedEdit = { [weak self] edit in self?.session.applySpeedEdit(edit) }
    }

    /// `speedKeyHit` reports a right-click on a transition's span and on its center handle both as `.ramp`, so both get it.
    func speedKeyItems(clip: Clip.ID, hit: SpeedBandKeyHit, at p: CGPoint) -> [SQMenuItem] {
        var isRamp = false, segment = 0
        if case .ramp(let i) = hit.hit { isRamp = true; segment = i }
        return TimelineSideMenus.speedKey(deleteTitle: hit.title, isRamp: isRamp,
                                          curve: { [weak self] in self?.showSpeedCurve(clip: clip, segment: segment, at: p) },
                                          delete: { [weak self] in self?.session.deleteSpeedKey(clip: clip, hit: hit) })
    }

    /// Right-click on the band line: a point at the click (the Add Speed Point command works at the playhead).
    func speedPointItems(clip: Clip.ID, at p: CGPoint) -> [SQMenuItem] {
        TimelineSideMenus.speedPoint { [weak self] in
            guard let self, let c = self.session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            let local = self.timelineView.geometry.time(atX: p.x) - c.start
            self.session.addSpeedKey(clip: clip, atLocal: local)
        }
    }

    private func showSpeedCurve(clip: Clip.ID, segment: Int, at p: CGPoint) {
        SpeedKeyMenuTarget.shared.popover?.close()
        let pop = EasingCurvePopover.make(source: SpeedRampEaseSource(session: session, clip: clip, segment: segment))
        SpeedKeyMenuTarget.shared.popover = pop
        pop.onClose = { [weak pop] in if SpeedKeyMenuTarget.shared.popover === pop { SpeedKeyMenuTarget.shared.popover = nil } }
        pop.show(relativeTo: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4), of: timelineView, preferredEdge: .maxY)
    }
}

@MainActor
final class SpeedKeyMenuTarget: NSObject {
    static let shared = SpeedKeyMenuTarget()
    /// The open speed curve popover (kept alive only while shown, so it does not keep the session alive).
    var popover: SQPopover?
}
