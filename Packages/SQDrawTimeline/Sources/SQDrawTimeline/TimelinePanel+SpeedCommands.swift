import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// Clip menu speed commands that show or hide the speed band, translated from the Mac AppController+Speed.swift (the
/// band is view state, so the panel owns it; the edit itself is the session's).
extension TimelinePanel {
    /// Runs `c` when it is a speed band command: nil = not one of them (the host goes on), "" = done, else a status line.
    @MainActor public mutating func runSpeedCommand(_ c: EditorCommand, session: EditorSession) -> String? {
        let remappable = Set(session.remappableSelection.map(\.id))
        switch c {
        case .toggleTimeRemapping:               // Show Time Remapping: the band on the selected video clips, or off again
            guard !remappable.isEmpty else { return "Select a video clip first." }
            speedBandClips = remappable.isSubset(of: speedBandClips) ? speedBandClips.subtracting(remappable)
                                                                      : speedBandClips.union(remappable)
            return ""
        case .addSpeedPoint:
            guard session.addSpeedPointAtPlayhead() else {
                return "Select a video clip and put the playhead inside it, off an existing point."
            }
            speedBandClips.formUnion(remappable)
            return ""
        case .removeTimeRemapping:
            let ids = Set(session.retimableSelection.filter { $0.speedKeys != nil }.map(\.id))
            guard session.removeTimeRemapping() else { return "The selected clips have no time remapping." }
            speedBandClips.subtract(ids)
            return ""
        case .speedRampPreset(let preset, let onBeat):
            switch session.applySpeedPreset(preset, onBeat: onBeat) {
            case .noClip: return "Select a video clip first."
            case .noBeat: return "No beat marker inside the clip. Run Markers on Beat on the music first."
            case .applied: speedBandClips.formUnion(remappable); return ""
            }
        default:
            return nil
        }
    }
}
