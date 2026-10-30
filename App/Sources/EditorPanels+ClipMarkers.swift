import AppKit
import SQCore
import SQEditorUI

/// Clip marker dialog (name, color, comment) and the flag context menu. Same dialog as the sequence marker's.
extension EditorPanels {
    func editClipMarker(_ clipID: Clip.ID, _ id: Marker.ID) {
        guard let window = timelineView.window,
              let clip = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }),
              let m = clip.markers?.first(where: { $0.id == id }) else { return }
        let alert = SQDialog()
        alert.messageText = "Clip Marker"
        let name = SQDialog.makeField(m.name, placeholder: "Name", width: 240)
        let color = SQPopup(frame: .zero, pullsDown: false)
        for c in MarkerColor.allCases { color.addItem(withTitle: c.rawValue.capitalized) }
        color.selectItem(withTitle: m.color.rawValue.capitalized)
        let comment = SQDialog.makeField(m.comment, placeholder: "Comment", width: 240)
        for item in color.itemArray {
            if let c = MarkerColor.allCases.first(where: { $0.rawValue.capitalized == item.title }) {
                item.image = SQMenuDot.image(color: Theme.Palette.marker(c))
            }
        }
        alert.accessoryView = SQDialogForm(rows: [SQDialog.formRow("Name", name), SQDialog.formRow("Color", color), SQDialog.formRow("Comment", comment)])
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.addButton("Delete Marker", role: .destructive, leading: true)
        alert.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .first:
                    let c = MarkerColor.allCases.first { $0.rawValue.capitalized == color.titleOfSelectedItem } ?? m.color
                    self.session.editClipMarker(id, on: clipID, name: name.stringValue, color: c, comment: comment.stringValue)
                case .third: self.session.deleteClipMarker(id, on: clipID)
                default: break
                }
            }
        }
    }

    /// Right-click on a clip marker flag.
    func clipMarkerItems(_ h: ClipMarkerFlags.Hit) -> [SQMenuItem] {
        [SQMenuItem(title: "Edit Clip Marker…", action: { [weak self] in self?.editClipMarker(h.clip, h.marker) }),
         .separator,
         SQMenuItem(title: "Delete Clip Marker", action: { [weak self] in self?.session.deleteClipMarker(h.marker, on: h.clip) })]
    }
}
