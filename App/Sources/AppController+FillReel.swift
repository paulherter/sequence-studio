import AppKit
import SQCore
import SQEditorUI

// Sequence > Fill Reel…: the media items selected in the Project panel pour into the clips of the active sequence.
// The edit itself is `EditorSession.fillReel(with:intoCopy:)`; this file is the sheet and the status lines.
extension AppController {
    func wireFillReel() {
        guard let view = panels?.projectView else { return }
        view.canFillReel = { [weak self] in (self?.session.reelSlotCount ?? 0) > 0 }
        view.onFillReel = { [weak self] ids in self?.requestFillReel(media: ids) }
    }

    /// Menu enable state: slots to fill and at least one media item picked.
    var fillReelEnabled: Bool {
        session.reelSlotCount > 0 && !(panels?.projectView.selectedMediaIDs.isEmpty ?? true)
    }

    /// `media` nil: the Project panel selection, in row order (media i goes into slot i).
    func requestFillReel(media: [MediaRef.ID]? = nil) {
        let ids = media ?? panels?.projectView.selectedMediaIDs ?? []
        let slots = session.reelSlotCount
        guard slots > 0 else {
            shell.statusBar.flash("Fill Reel needs a sequence with clips on its first video track: they are the slots.", seconds: 4)
            return
        }
        let refs = ids.compactMap { session.project.media($0) }
        guard !refs.isEmpty else {
            shell.statusBar.flash("Select the media items for the slots in the Project panel first.", seconds: 4)
            return
        }
        let plan = FillReelPlan(slotCount: slots, items: refs.map {
            FillReelPlan.Item(id: $0.id, name: $0.name, isStill: $0.info?.isStill == true,
                              hasLength: ($0.info?.duration ?? $0.duration) != nil)
        })
        guard plan.canRun else {
            shell.statusBar.flash("None of these items can fill a slot: items without a known length are left out.", seconds: 4)
            return
        }
        let names = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        FillReelDialog.present(on: window, sequenceName: session.activeTimeline?.name ?? "Sequence", plan: plan, names: names) { [weak self] choice in
            guard let self, let choice else { return }
            guard let report = self.session.fillReel(with: plan.fillable, intoCopy: choice.intoCopy) else {
                self.shell.statusBar.flash(self.session.lastError ?? "Fill Reel did nothing.", seconds: 4)
                return
            }
            self.shell.statusBar.flash(FillReelPlan.resultText(report, intoCopy: choice.intoCopy), seconds: 5)
        }
    }
}
