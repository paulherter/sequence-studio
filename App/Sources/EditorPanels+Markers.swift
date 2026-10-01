import AppKit
import SSCore
import SSEditorUI

/// Marker dialog (name, colour, comment) and the ruler context menu.
extension EditorPanels {
    func editMarker(_ id: Marker.ID) {
        guard let window = timelineView.window, let m = session.activeTimeline?.markers.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Marker"
        let name = NSTextField(frame: .zero)
        name.stringValue = m.name
        name.placeholderString = "Name"
        let color = NSPopUpButton(frame: .zero, pullsDown: false)
        for c in MarkerColor.allCases { color.addItem(withTitle: c.rawValue.capitalized) }
        color.selectItem(withTitle: m.color.rawValue.capitalized)
        let comment = NSTextField(frame: .zero)
        comment.stringValue = m.comment
        comment.placeholderString = "Comment"
        func row(_ title: String, _ view: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: title)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let s = NSStackView(views: [l, view])
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        let stack = NSStackView(views: [row("Name", name), row("Color", color), row("Comment", comment)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 92)
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true
        comment.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Marker")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    let c = MarkerColor.allCases.first { $0.rawValue.capitalized == color.titleOfSelectedItem } ?? m.color
                    self.session.editMarker(id, name: name.stringValue, color: c, comment: comment.stringValue)
                case .alertThirdButtonReturn: self.session.deleteMarker(id)
                default: break
                }
            }
        }
    }

    /// Right-click in the ruler: marker commands at the pointer (Premiere: Add Marker, Edit/Delete Marker, Clear In/Out).
    func rulerMenu(at p: CGPoint) -> NSMenu? {
        let tv = timelineView
        let t = tv.geometry.time(atX: p.x)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let m = tv.markerID(at: p) {
            menu.addItem(BlockMenuItem("Edit Marker…") { [weak self] in self?.editMarker(m) })
            menu.addItem(BlockMenuItem("Delete Marker") { [weak self] in self?.session.deleteMarker(m) })
        } else {
            menu.addItem(BlockMenuItem("Add Marker") { [weak self] in
                guard let self else { return }
                session.seek(to: t)
                if let r = session.markAtPlayhead(), r.openEdit { editMarker(r.id) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("Clear In and Out", enabled: session.activeTimeline?.inOut != nil) { [weak self] in
            self?.session.clearInOut()
        })
        return menu
    }
}
