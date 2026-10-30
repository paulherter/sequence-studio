import AppKit
import SQCore
import SQEditorUI

/// Volume rubber band: every drag is one undo step; right-click on a key offers Delete Keyframe.
extension EditorPanels {
    func wireVolumeLine() {
        let gesture = TimelineLineGesture(name: "Volume", replace: { [weak self] clip, name, continues in
            self?.session.replaceClip(clip, name: name, continuesGesture: continues)
        }, end: { [weak self] in self?.session.endGesture() })
        timelineView.onVolumeEdit = { clip, phase in gesture.handle(clip, phase) }
    }

    func volumeKeyItems(clip: Clip.ID, key: UUID) -> [SQMenuItem] {
        TimelineSideMenus.volumeKey { [weak self] in
            guard let self, var c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            c.removeVolumeKey(key)
            session.replaceClip(c, name: "Delete Keyframe", continuesGesture: false)
        }
    }

    func fadeCurveItems(clip: Clip.ID, handle: FadeHandle, current: FadeCurve?) -> [SQMenuItem] {
        TimelineSideMenus.fadeCurve(current: current) { [weak self] curve in
            guard let self, var c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            c.setAudioFadeCurve(curve, head: handle == .head)
            session.replaceClip(c, name: "Fade Curve", continuesGesture: false)
        }
    }
}
