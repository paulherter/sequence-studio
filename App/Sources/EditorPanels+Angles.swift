import AppKit
import SQCore
import SQEditorUI

extension EditorPanels {
    /// F7.16 rows (plus a separator) for the top of the clip menu: the angles of the Angles piece under the pointer
    /// (on its sound half: the sound's angle), Audio Follows Video, and Create Angles Clip… for a selection of clips.
    func angleMenuItems(at p: CGPoint) -> [SQMenuItem] {
        let tv = timelineView
        guard case .clip(let id, _) = tv.geometry.hitTest(p, in: tv.timeline) else { return [] }
        var rows: [SQMenuItem] = []
        if let s = session.angleMenuState(for: id) {
            let angles = s.names.enumerated().map { i, name in
                SQMenuItem(title: "\(i + 1)  \(name)", shortcut: !s.isAudio && i < 9 ? ProjectPanelMenus.shortcut(.switchAngle(i + 1)) : "",
                           isChecked: i == s.active) { [weak self] in self?.session.setAngle(i, on: id) }
            }
            rows.append(SQMenuItem(title: s.isAudio ? "Sound Angle" : "Angle", submenu: angles))
            rows.append(SQMenuItem(title: "Flatten Angles Clip") { [weak self] in self?.session.flattenAngles(clip: id) })
            if let follows = s.followsVideo {
                rows.append(SQMenuItem(title: "Audio Follows Video", isChecked: follows) { [weak self] in
                    self?.session.setAudioFollowsVideo(!follows, on: id)
                })
            }
        }
        if session.selection.contains(id), session.angleCandidatesOfSelection.count >= 2 {
            rows.append(SQMenuItem(title: "Create Angles Clip…") { [weak self] in self?.onCreateAnglesClip?() })
        }
        return rows.isEmpty ? [] : rows + [.separator]
    }
}
