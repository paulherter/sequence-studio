import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQExport
import SQTimelineUI
import SQUIKit

/// The Marker List panel for both shared shells, translated from the Mac `MarkerIndexView` (and its wiring in
/// `EditorPanels+MarkerList`): a filter field and Export CSV on top, then the table (color dot, Time, Name, Length,
/// Comment) of `MarkerIndexModel`; a click goes to the marker, the row the playhead is in stays selected, an empty list
/// shows "No markers" / "No matches".
/// Coordinates: `frame` in window points, events arrive in pixels.
@MainActor
public final class MarkerListHost {
    public private(set) var model = MarkerIndexModel()
    public private(set) var frame: CGRect = .zero
    public private(set) var selectedRow: Int?
    public private(set) var scroll: CGFloat = 0
    var search = TextFieldControl()
    private var hovered: Int?
    private var exportHover = false, exportPressed = false
    private var reloadedFrom: Timeline?
    private let session: EditorSession
    private let shell: ShellHost
    private var exportWidth: CGFloat = 80

    // `MarkerIndexView` metrics: `Theme.Spacing.sm` padding, `Theme.Metrics.quietField` 22, `Theme.Row.list` 24.
    static let pad = CGFloat(DrawTheme.Spacing.sm), fieldHeight: CGFloat = 22, rowHeight: CGFloat = 24, headerHeight: CGFloat = 24
    /// Column widths (the last, Comment, takes the rest).
    static let columns: [(title: String, width: CGFloat)] = [("", 22), ("Time", 84), ("Name", 140), ("Length", 76), ("Comment", 200)]

    public init(session: EditorSession, shell: ShellHost) {
        self.session = session
        self.shell = shell
        search.alignment = .left
        search.quiet = true                     // `SQSearchField.setQuietPlaceholder`: the quiet fill, no outline (as the Library search)
        search.fontSize = CGFloat(DrawTheme.TypeSize.body)
        shell.factProviders.append { [weak self] f in if self?.search.isEditing == true { f.textEditing = true } }
        // File > Export Markers as CSV… runs here too (the Mac `AppController+MarkerList`).
        let next = shell.onCommand
        shell.onCommand = { [weak self] c in
            guard let self, c == .exportMarkersCSV else { return next?(c) ?? false }
            exportCSV()
            return true
        }
    }

    /// The Mac `exportMarkersCSV`: every marker of the sequence (`MarkerCSV`), written where the user picks.
    public func exportCSV() {
        guard let tl = session.activeTimeline else { shell.onStatus?(SQL10n.string("There is no sequence to export.")); return }
        guard !MarkerCSV.rows(for: tl).isEmpty else { shell.onStatus?(SQL10n.string("There are no markers to export.")); return }
        guard let url = (shell.files as? PanelFileChooser)?.chooseCSVLocation(suggestedName: "\(tl.name) Markers.csv") else { return }
        do {
            try MarkerCSV.export(tl).text.write(to: url, atomically: true, encoding: .utf8)
            shell.onStatus?(SQL10n.format("Exported %@.", url.lastPathComponent))
        } catch {
            shell.onStatus?(SQL10n.format("Could not write the CSV file: %@", SQL10n.errorText(error)))
        }
    }

    // MARK: Layout

    var fieldRect: CGRect { CGRect(x: frame.minX + Self.pad, y: frame.minY + Self.pad, width: max(60, exportRect.minX - frame.minX - 2 * Self.pad), height: Self.fieldHeight) }
    public var exportRect: CGRect { CGRect(x: frame.maxX - Self.pad - exportWidth, y: frame.minY + Self.pad, width: exportWidth, height: Self.fieldHeight) }
    var tableRect: CGRect {
        let top = frame.minY + Self.pad * 2 + Self.fieldHeight
        return CGRect(x: frame.minX, y: top, width: frame.width, height: max(frame.maxY - top, 0))
    }
    var listRect: CGRect {
        let t = tableRect
        return CGRect(x: t.minX, y: t.minY + Self.headerHeight, width: t.width, height: max(t.height - Self.headerHeight, 0))
    }
    var maxScroll: CGFloat { max(CGFloat(model.rows.count) * Self.rowHeight - listRect.height, 0) }

    func rowRect(_ i: Int) -> CGRect {
        CGRect(x: listRect.minX, y: listRect.minY + CGFloat(i) * Self.rowHeight - scroll, width: listRect.width, height: Self.rowHeight)
    }

    func row(at p: CGPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        let i = Int(((p.y - listRect.minY + scroll) / Self.rowHeight).rounded(.down))
        return model.rows.indices.contains(i) ? i : nil
    }

    /// Lays the panel into its dock card (nil: the tab is not shown); reloads when the sequence changed and follows the
    /// playhead (the Mac `syncMarkerList`).
    public func layout(_ card: CGRect?) {
        frame = card ?? .zero
        sync()
        scroll = min(scroll, maxScroll)
    }

    /// Keeps the list in step with the active sequence; the playhead's row is selected (no seek).
    public func sync() {
        guard let t = session.activeTimeline else { return }
        if reloadedFrom != t {
            model.reload(t)
            reloadedFrom = t
        }
        let now = model.currentRow(at: session.playhead)
        if now != selectedRow {
            selectedRow = now
            if let i = now { reveal(i) }
        }
    }

    private func reveal(_ i: Int) {
        let r = rowRect(i)
        if r.minY < listRect.minY { scroll -= listRect.minY - r.minY }
        else if r.maxY > listRect.maxY { scroll += r.maxY - listRect.maxY }
        scroll = min(max(scroll, 0), maxScroll)
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        guard frame.width > 0, frame.height > 0 else { return }
        exportWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Export CSV"))
        let fs = CGFloat(DrawTheme.TypeSize.body)
        // `SQSearchField`: the magnifier at 9, the text from 28 (measured in the AppKit render).
        search.textInset = 28
        search.draw(&c, in: fieldRect, theme: t, focused: search.isEditing)
        c.draw(icon: .search, at: CGPoint(x: fieldRect.minX + 9, y: fieldRect.midY - 6), size: 12, t.label3)
        if search.text.isEmpty, !search.isEditing {
            c.draw(SQL10n.string("Filter markers"), in: fieldRect, fontSize: fs, t.label3, inset: 28)
        }
        InspectorDraw.button(&c, title: SQL10n.string("Export CSV"), in: exportRect, hovering: exportHover, pressed: exportPressed,
                             enabled: !model.entries.isEmpty, t)
        // Column header.
        let header = CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width, height: Self.headerHeight)
        c.fill(CGRect(x: header.minX, y: header.maxY - 1, width: header.width, height: 1), t.separator)
        var x = header.minX
        for (i, col) in Self.columns.enumerated() {
            let w = i == Self.columns.count - 1 ? max(header.maxX - x, 0) : col.width
            if !col.title.isEmpty {
                c.draw(SQL10n.string(col.title), in: CGRect(x: x, y: header.minY, width: w, height: header.height),
                       fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3, inset: 6)
            }
            x += w
        }
        let rows = model.rows
        guard !rows.isEmpty else {
            let title = model.entries.isEmpty ? "No markers" : "No matches"
            c.draw(SQL10n.string(title), in: CGRect(x: listRect.minX, y: listRect.midY - 18, width: listRect.width, height: 18),
                   fontSize: fs, t.label2, align: .center)
            if model.entries.isEmpty {
                c.draw(SQL10n.string("Press M to add a marker at the playhead"),
                       in: CGRect(x: listRect.minX, y: listRect.midY, width: listRect.width, height: 16),
                       fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3, align: .center)
            }
            return
        }
        c.saveGState()
        c.clip(to: listRect)
        for (i, e) in rows.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY >= listRect.minY, rr.minY <= listRect.maxY else { continue }
            let pill = rr.insetBy(dx: CGFloat(DrawTheme.Spacing.xs), dy: 1)
            if i == selectedRow { c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), t.accentFill) }
            else if i == hovered { c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            var cx = rr.minX
            for (ci, col) in Self.columns.enumerated() {
                let w = ci == Self.columns.count - 1 ? max(rr.maxX - cx, 0) : col.width
                let cell = CGRect(x: cx, y: rr.minY, width: w, height: rr.height)
                cx += w
                switch ci {
                case 0:
                    let d: CGFloat = 8
                    c.fill(roundedRect: CGRect(x: cell.midX - d / 2, y: cell.midY - d / 2, width: d, height: d), radius: d / 2,
                           e.color.drawColor)
                case 1: c.draw(model.text(for: e.time), in: cell, fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2, inset: 6)
                case 2: c.draw(e.name.isEmpty ? e.scopeLabel : e.name, in: cell, fontSize: fs, t.label, inset: 6)
                case 3: c.draw(model.durationText(of: e), in: cell, fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2, inset: 6)
                default: c.draw(e.comment, in: cell, fontSize: fs, t.label2, inset: 6)
                }
            }
        }
        c.restoreGState()
    }

    // MARK: Events

    /// True when the panel took the event (pointer moves go on).
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .mouseMoved(let x, let y):
            let p = pt(x, y)
            hovered = frame.contains(p) ? row(at: p) : nil
            exportHover = exportRect.contains(p)
            search.hovering = fieldRect.contains(p)
            return false
        case .mouseDown(let x, let y, let m):
            let p = pt(x, y)
            guard frame.contains(p) else {
                if search.isEditing { _ = search.commit() }
                return false
            }
            if fieldRect.contains(p) { if !search.isEditing { search.mouseDown() }; return true }
            if search.isEditing { _ = search.commit() }
            // A right click never presses the button (NSButton ignores the secondary button): it would open the
            // save panel under the context menu.
            if exportRect.contains(p), !model.entries.isEmpty, !m.contains(.secondary) { exportPressed = true; return true }
            if let i = row(at: p) {
                selectedRow = i
                session.seek(to: model.rows[i].time)       // the Mac `onGo`
            }
            return true
        case .mouseDragged:
            return exportPressed
        case .mouseUp(let x, let y):
            guard exportPressed else { return false }
            exportPressed = false
            if exportRect.contains(pt(x, y)) { exportCSV() }
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard listRect.contains(pt(x, y)) else { return false }
            scroll = min(max(scroll - CGFloat(dy) / k, 0), maxScroll)
            return true
        case .keyDown(let key, let m):
            guard search.isEditing else { return false }
            if key == .escape {
                search.cancel()
                search.text = ""
            } else {
                _ = search.key(key, modifiers: m)
            }
            model.query = search.editor?.string ?? search.text
            selectedRow = model.currentRow(at: session.playhead)
            scroll = min(scroll, maxScroll)
            return true
        }
    }

    /// The filter text (the field's live text while typing).
    public var query: String { model.query }
}

extension MarkerColor {
    /// `Theme.Palette.marker` as a draw color (the timeline's marker colors).
    var drawColor: DrawColor { TimelineMarkerColors.color(self) }
}
