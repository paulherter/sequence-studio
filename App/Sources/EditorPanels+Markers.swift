import AppKit
import SQCore
import SQEditorUI
import SQEditorSession

/// Marker dialog (name, color, comment) and the ruler context menu.
extension EditorPanels {
    /// Range-marker host wiring: duration drags are one undo step, the beat snap level comes from the user default.
    func wireMarkerRange() {
        timelineView.beatSnapLevel = BeatSnapLevel.stored()
        timelineView.onMarkerDurationChanged = { [weak self] id, d in self?.session.setMarkerDuration(id, to: d) }
    }

    func editMarker(_ id: Marker.ID) {
        guard let window = timelineView.window, let m = session.activeTimeline?.markers.first(where: { $0.id == id }) else { return }
        let alert = SQDialog()
        alert.messageText = "Marker"
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
        let fd = session.activeTimeline?.frameDuration ?? Time(1, 30)
        let duration = SQDialog.makeField(MarkersPanelModel.timecode(m.duration, frameDuration: fd), placeholder: "00:00:00:00", width: 240)
        alert.accessoryView = SQDialogForm(rows: [SQDialog.formRow("Name", name), SQDialog.formRow("Color", color),
                                                  SQDialog.formRow("Duration", duration), SQDialog.formRow("Comment", comment)])
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
                    let d = MarkersPanelModel.parseTimecode(duration.stringValue, frameDuration: fd) ?? m.duration
                    self.session.editMarker(id, name: name.stringValue, color: c, comment: comment.stringValue, duration: d)
                case .third: self.session.deleteMarker(id)
                default: break
                }
            }
        }
    }

    /// Right-click in the ruler: marker commands at the pointer, then Mark In / Out and Remove In and Out (keys shown), Delete Marker last.
    func rulerItems(at p: CGPoint) -> [SQMenuItem] {
        let tv = timelineView
        let t = tv.geometry.time(atX: p.x)
        let marker = tv.markerID(at: p)
        let eq = CommandMap.current.binding(for: .addMarker).flatMap(TimelineMenuItem.keyEquivalent)
        let level = timelineView.beatSnapLevel
        func levelItem(_ l: BeatSnapLevel, _ title: String) -> SQMenuItem {
            SQMenuItem(title: title, isChecked: level == l) { [weak self] in
                self?.timelineView.beatSnapLevel = l
                l.store()
            }
        }
        let beatSnap = SQMenuItem(title: "Beat Snap", submenu: [levelItem(.everyBeat, "Every Beat"), levelItem(.barsOnly, "Bars Only")])
        return TimelineSideMenus.ruler(
            hasMarkerAtPointer: marker != nil,
            entries: RulerRangeEntry.entries(hasInOut: session.activeTimeline?.inOut != nil),
            addMarkerShortcut: eq.map { SQMenuShortcut.glyphs(key: $0.key, modifiers: $0.modifiers) } ?? "",
            addMarker: { [weak self] in
                guard let self else { return }
                session.seek(to: t)
                if let r = session.markAtPlayhead(), r.openEdit { editMarker(r.id) }
            },
            editMarker: { [weak self] in if let marker { self?.editMarker(marker) } },
            range: { [weak self] command in
                guard let session = self?.session else { return }
                switch command {
                case .markIn: session.markIn()
                case .markOut: session.markOut()
                default: session.clearInOut()
                }
            },
            deleteMarker: { [weak self] in if let marker { self?.session.deleteMarker(marker) } }) + [.separator, beatSnap]
    }
}
