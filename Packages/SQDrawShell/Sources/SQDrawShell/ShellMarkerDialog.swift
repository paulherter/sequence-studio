import Foundation
import SQCore
import SQEditorSession
import SQDrawKit

/// The Mac marker sheet (`EditorPanels.editMarker`) as a shell form: Name, Color, Duration (sequence markers), Comment;
/// OK, Cancel and a leading Delete Marker. Shared by the Mac shared UI and Windows (timeline request `.marker` /
/// `.clipMarker`, Add and Edit Marker, Edit Marker).
extension ShellHost {
    /// Opens the dialog for a sequence marker (`clip == nil`) or a clip marker. False when the marker is gone.
    @discardableResult
    public func editMarker(_ id: Marker.ID, clip: Clip.ID? = nil) -> Bool {
        guard let d = Self.markerDialog(id, clip: clip, session: session) else { return false }
        spawn { [weak self] in
            guard let self else { return }
            let r = await ask(d)
            Self.applyMarkerDialog(d, response: r, id: id, clip: clip, session: session)
        }
        return true
    }

    static func findMarker(_ id: Marker.ID, clip: Clip.ID?, in t: Timeline) -> Marker? {
        if let clip { return t.tracks.lazy.flatMap(\.clips).first { $0.id == clip }?.markers?.first { $0.id == id } }
        return t.markers.first { $0.id == id }
    }

    static func markerDialog(_ id: Marker.ID, clip: Clip.ID?, session: EditorSession) -> ShellDialog? {
        guard let t = session.activeTimeline, let m = findMarker(id, clip: clip, in: t) else { return nil }
        let colors = MarkerColor.allCases
        var rows: [ShellForm.Row] = [.field(id: "name", label: "Name", value: m.name),
                                     .popup(id: "color", label: "Color", options: colors.map { $0.rawValue.capitalized },
                                            selected: colors.firstIndex(of: m.color) ?? 0)]
        if clip == nil {
            rows.append(.field(id: "duration", label: "Duration",
                               value: MarkersPanelModel.timecode(m.duration, frameDuration: t.frameDuration)))
        }
        rows.append(.field(id: "comment", label: "Comment", value: m.comment))
        let d = ShellDialog(clip == nil ? "Marker" : "Clip Marker")
        let form = ShellForm(rows)
        form.popupStyles["color"] = .init(dots: colors.map { DrawTheme.marker($0).rgbHex })   // the Mac popup's color dots
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        d.addButton("Delete Marker", role: .destructive, leading: true)
        return d
    }

    /// OK writes name, color, comment (and duration for sequence markers) as one undo step; Delete Marker removes it.
    static func applyMarkerDialog(_ d: ShellDialog, response r: ShellDialog.Response, id: Marker.ID, clip: Clip.ID?,
                                  session: EditorSession) {
        guard let f = d.form, let t = session.activeTimeline, let m = findMarker(id, clip: clip, in: t) else { return }
        if r == .third {
            if let clip { session.deleteClipMarker(id, on: clip) } else { session.deleteMarker(id) }
            return
        }
        guard r == .first else { return }
        let colors = MarkerColor.allCases
        let name = f.text("name") ?? m.name, comment = f.text("comment") ?? m.comment
        let color = f.index("color").flatMap { colors.indices.contains($0) ? colors[$0] : nil } ?? m.color
        if let clip {
            session.editClipMarker(id, on: clip, name: name, color: color, comment: comment)
        } else {
            let dur = f.text("duration").flatMap { MarkersPanelModel.parseTimecode($0, frameDuration: t.frameDuration) } ?? m.duration
            session.editMarker(id, name: name, color: color, comment: comment, duration: dur)
        }
    }
}
