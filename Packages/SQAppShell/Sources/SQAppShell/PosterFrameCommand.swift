import Foundation
import SQCore
import SQEditorSession

/// Set Poster Frame (Cmd+P) and Clear Poster Frame (Option+P) on the shared UI, as the Mac `ProjectPanelView.setPosterFrame`
/// does it: the poster of the selected clip is the Source monitor's frame of that clip; Clear goes back to the automatic
/// poster (the first frame) for every selected clip.
/// shortcut: no hovered-frame poster (the shared Project list has no hover scrub yet); add it with the hover pass.
public enum PosterFrameCommand {
    /// Applies the command; the line for the status bar when nothing changed for a reason the user should hear.
    @MainActor
    public static func run(clear: Bool, selected: [BinItemRef], source: (media: MediaRef.ID, time: Time)?,
                           model: ProjectPanelModel) -> String? {
        let ids = selected.compactMap { if case .media(let id) = $0 { id } else { nil } }
        guard !ids.isEmpty else { return "Select a clip first." }
        if clear { _ = model.setPoster(nil, for: ids.map { .media($0) }); return nil }
        if let source, ids.contains(source.media) { _ = model.setPoster(source.time, for: [.media(source.media)]); return nil }
        return "Open the clip in the Source monitor, park on the frame and press Cmd+P."
    }
}
