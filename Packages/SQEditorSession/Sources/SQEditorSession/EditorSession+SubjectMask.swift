import Foundation
import SQCore

/// W9.8 SubjectMask: Clip > Video Options > Add Subject Mask. The mask's shape is the person matte the renderer segments
/// per frame (playback fast/balanced, export accurate); saving such a project writes ProjectFile v37.
extension EditorSession {
    /// Selected (or playhead) video clips the edit would change: unlocked track, takes a subject mask, has none yet.
    private var subjectMaskTargets: [Clip.ID] {
        guard let t = activeTimeline else { return [] }
        return t.subjectMaskTargets(commandClips(kind: .video).map(\.id))
    }

    public var addSubjectMaskEnabled: Bool { !subjectMaskTargets.isEmpty }

    /// Adds a Subject mask to each target clip, one undo step "Add Subject Mask". False when nothing changed.
    @discardableResult
    public func addSubjectMask() -> Bool {
        let ids = subjectMaskTargets
        guard !ids.isEmpty else { return false }
        return attempt("Add Subject Mask") { _ = try $0.addSubjectMask(ids) }
    }
}
