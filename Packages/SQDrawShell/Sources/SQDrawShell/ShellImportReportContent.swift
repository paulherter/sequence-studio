import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQPremiereImport

/// The rows of the import report card (the Mac `ImportReportSheet` body): an inset well of 38 pt rows, each a status dot,
/// a strong name over a label3 detail line and, in checklist mode, a Show / Reconnect… button on the rows that can act.
@MainActor
public final class ShellImportReportContent: ShellDialogContent {
    enum M {
        static let sidePad: CGFloat = 20
        static let rowHeight: CGFloat = 38
        static let wellPad: CGFloat = 4
        static let wellRadius: CGFloat = 6   // Theme.Dialog.reportWellRadius
        static let minHeight: CGFloat = 46, maxHeight: CGFloat = 300
        static let dot: CGFloat = 8
        static let dotX: CGFloat = 12, textX: CGFloat = 30, trailing: CGFloat = 12
        static let buttonHeight: CGFloat = 24, buttonPadding: CGFloat = 10, buttonRadius: CGFloat = 8
        static let bodySize: CGFloat = 11, buttonSize: CGFloat = 12
    }

    public enum Tone: Sendable { case green, yellow, orange, red }

    /// One row: status color, headline, detail and (checklist mode) the item behind it with its button title.
    public struct Row: Sendable, Equatable {
        public var tone: Tone
        public var head: String
        public var detail: String
        public var item: PRImportChecklist.Item?
        public var action: String?
        public static func == (a: Row, b: Row) -> Bool {
            a.tone == b.tone && a.head == b.head && a.detail == b.detail && a.item?.id == b.item?.id && a.action == b.action
        }
    }

    /// Checklist mode: a row per checklist item, "Show" where clips can be visited, "Reconnect…" for missing files.
    public static func rows(checklist: PRImportChecklist, canReconnect: Bool) -> [Row] {
        checklist.items.map { i in
            let tone: Tone = switch i.kind {
            case .cameOver: .green
            case .approximated: .yellow
            case .leftOut: .orange
            case .missingFiles: .red
            }
            let head = i.kind == .approximated || i.kind == .leftOut ? "\(i.count)x  \(i.title)" : i.title
            let action: String? = switch i.kind {
            case .cameOver: nil
            case .missingFiles: canReconnect ? "Reconnect…" : nil
            case .approximated, .leftOut: i.locations.isEmpty ? nil : "Show"
            }
            return Row(tone: tone, head: head, detail: i.detail, item: i, action: action)
        }
    }

    /// Report mode (no checklist): worst first, dropped red, approximated orange, mapped green.
    public static func rows(report: PRImportReport) -> [Row] {
        report.entries.sorted { ($0.status, $1.count, $0.feature) > ($1.status, $0.count, $1.feature) }.map { e in
            let tone: Tone = e.status == .dropped ? .red : e.status == .approximated ? .orange : .green
            let status = e.status.label.prefix(1).uppercased() + e.status.label.dropFirst()
            return Row(tone: tone, head: "\(e.count)x  \(e.feature)", detail: e.note.isEmpty ? status : "\(status): \(e.note)")
        }
    }

    public let rows: [Row]
    /// A row's button was pressed (the host closes the dialog and acts).
    public var onAction: ((PRImportChecklist.Item) -> Void)?
    public var openPopup: ((_ items: [SQMenuItem], _ below: CGRect) -> Void)?
    private(set) var well: CGRect = .zero
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    private var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    private var measure = TextMeasure(atlas: nil, scale: 1)
    private var hovered: Int?, pressed: Int?

    public init(rows: [Row]) { self.rows = rows }

    var listHeight: CGFloat { CGFloat(rows.count) * M.rowHeight + 2 * M.wellPad }
    var wellHeight: CGFloat { min(max(listHeight, M.minHeight), M.maxHeight) }

    public func height(width: CGFloat) -> CGFloat { wellHeight }

    public func layout(_ frame: CGRect, measure m: TextMeasure) {
        measure = m
        well = CGRect(x: frame.minX + M.sidePad, y: frame.minY, width: frame.width - 2 * M.sidePad, height: frame.height)
        scroll = min(max(scroll, 0), max(listHeight - well.height, 0))
    }

    func rowFrame(_ i: Int) -> CGRect {
        CGRect(x: well.minX, y: well.minY + M.wellPad + CGFloat(i) * M.rowHeight - scroll, width: well.width, height: M.rowHeight)
    }

    func buttonFrame(_ i: Int) -> CGRect? {
        guard let title = rows[i].action else { return nil }
        let w = ceil(measure.width(SQL10n.string(title), size: M.buttonSize, face: measure.medium)) + 2 * M.buttonPadding
        let r = rowFrame(i)
        return CGRect(x: r.maxX - 12 - w, y: r.midY - M.buttonHeight / 2, width: w, height: M.buttonHeight)
    }

    func button(at p: CGPoint) -> Int? {
        guard well.contains(p) else { return nil }
        return rows.indices.first { buttonFrame($0)?.contains(p) == true }
    }

    func color(_ t: Tone, _ th: DrawTheme) -> DrawColor {
        switch t {
        case .green: DrawTheme.marker(.green)
        case .yellow: DrawTheme.marker(.yellow)
        case .orange: DrawTheme.marker(.orange)
        case .red: MenuListView.color(palette: th.palette.red)
        }
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        c.fill(roundedRect: well, radius: M.wellRadius, t.content)
        c.saveGState()
        c.clip(to: well)
        for (i, r) in rows.enumerated() {
            let f = rowFrame(i)
            guard f.maxY > well.minY, f.minY < well.maxY else { continue }
            c.fill(ellipseIn: CGRect(x: f.minX + M.dotX, y: f.midY - M.dot / 2, width: M.dot, height: M.dot), color(r.tone, t))
            let b = buttonFrame(i)
            let right = (b?.minX ?? f.maxX) - M.trailing
            let x = f.minX + M.textX, w = max(right - x, 0)
            let line = measure.lineHeight(M.bodySize) + 2
            let top = f.midY - line
            c.draw(r.head, in: CGRect(x: x, y: top, width: w, height: line), fontSize: M.bodySize, t.label, face: c.semibold)
            c.draw(SQL10n.string(r.detail), in: CGRect(x: x, y: top + line, width: w, height: line), fontSize: M.bodySize, t.label3)
            if let b, let title = r.action {
                let fill = pressed == i ? t.fillPressed : (hovered == i ? t.fillHover : t.fill)
                c.fill(roundedRect: b, radius: M.buttonRadius, fill)
                c.draw(SQL10n.string(title), in: b, fontSize: M.buttonSize, t.label, align: .center, face: c.medium)
            }
        }
        c.restoreGState()
    }

    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .mouseMoved(let x, let y): hovered = button(at: pt(x, y)); return false
        case .mouseDown(let x, let y, _): pressed = button(at: pt(x, y)); return pressed != nil
        case .mouseDragged(let x, let y): hovered = button(at: pt(x, y)); return pressed != nil
        case .mouseUp(let x, let y):
            defer { pressed = nil }
            guard let p = pressed else { return false }
            if button(at: pt(x, y)) == p, let item = rows[p].item { onAction?(item) }
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard well.contains(pt(x, y)), listHeight > well.height else { return false }
            scrollBody.wheel(dy: dy, scale: CGFloat(scale), maxOffset: listHeight - well.height, extent: well.height)
            return true
        default: return false
        }
    }
}
