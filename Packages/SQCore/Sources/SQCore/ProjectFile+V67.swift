import Foundation

// v67: Fast Cut (ClipAttachment.swift): `Timeline.editMode` (written only when `.magnetic`) and `Clip.attachment` (written
// only when set). A v66 build would open a Fast Cut sequence as Normal and drop every attachment on the next save; at v67 it
// refuses the file with `ProjectFileError.newerVersion` instead. Normal-only projects store neither key and keep the lowest
// version that holds their content (byte-identical to v66 output apart from `appFormat`).

extension Project {
    /// Any sequence (nested ones included) is in Fast Cut, or any clip carries an attachment: the file must be v67.
    public var containsV67Content: Bool {
        timelines.contains { tl in
            tl.editMode == .magnetic || tl.tracks.contains { $0.clips.contains { $0.attachment != nil } }
        }
    }
}
