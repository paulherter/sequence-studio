import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary

/// The card import board inside the import dialog (the Mac CardImportView): Videos / Photos segments with counts, the
/// sort popup and the list / grid switch on top; the files as 140 x 80 tiles with a checkbox (or list rows) on the left,
/// the last clicked file's picture, name, date and size on the right; "n selected" under it. Click selects one, Shift-click
/// a range, Ctrl-click (Command on the Mac) or the checkbox toggles one; Ctrl-A selects all files of the kind.
@MainActor public final class ShellCardBrowser: ShellDialogContent {
    public enum Layout: Sendable { case grid, list }
    enum M {
        static let pad: CGFloat = 20
        static let toolbar = CGFloat(DrawTheme.Metrics.capsule)
        static let toolbarGap: CGFloat = 12
        static let toolbarTop: CGFloat = 4, toolbarBottom: CGFloat = 10, toolbarSide: CGFloat = 16
        static let sortWidth: CGFloat = 150
        static let layoutSegment: CGFloat = 40
        static let tile = CGSize(width: 140, height: 80)
        static let tileName: CGFloat = 19
        static let tileGapX: CGFloat = 12, tileGapY: CGFloat = 14, gridPad: CGFloat = 16
        static let check: CGFloat = 12, checkInset: CGFloat = 6
        static let rowHeight: CGFloat = 24, rowThumb: CGFloat = 20, sizeColumn: CGFloat = 70
        static let previewWidth: CGFloat = 301, previewPad: CGFloat = 16, previewPicture: CGFloat = 168
        static let status: CGFloat = 20
        static let font = CGFloat(DrawTheme.TypeSize.body)
        static let mini = CGFloat(DrawTheme.TypeSize.caption)
    }

    public let items: [CardCandidate]
    public private(set) var kind: CardMediaKind
    public private(set) var sort: CardSort = .newestFirst
    public private(set) var layout: Layout = .grid
    public private(set) var selection = CardSelection()
    public private(set) var previewID: String?
    /// The file's picture (Windows: the FFmpeg thumbnail atlas, asked again every frame until it is there).
    public var poster: ((CardCandidate) -> ProjectPoster?)?
    public var openPopup: ((_ items: [SQMenuItem], _ below: CGRect) -> Void)?

    private(set) var frame: CGRect = .zero
    private(set) var kindFrames: [(CardMediaKind, CGRect)] = []
    private(set) var sortFrame: CGRect = .zero
    private(set) var toolbarFrame: CGRect = .zero
    private(set) var layoutFrames: [(Layout, CGRect)] = []
    private(set) var listFrame: CGRect = .zero
    private(set) var previewFrame: CGRect = .zero
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    private var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    private var hovered: String?
    private var measure: TextMeasure?

    public init(items: [CardCandidate]) {
        self.items = items
        kind = items.contains { $0.kind == .video } || items.isEmpty ? .video : .photo
    }

    // MARK: Model

    /// The files of the shown kind in the chosen order.
    public var visible: [CardCandidate] { sort.apply(items.filter { $0.kind == kind }) }
    public var visibleIDs: [String] { visible.map(\.id) }
    /// The ticked files in the shown order (what an import takes).
    public var selected: [CardCandidate] { visible.filter { selection.ids.contains($0.id) } }
    public var preview: CardCandidate? { previewID.flatMap { id in items.first { $0.id == id } } }
    public func count(_ k: CardMediaKind) -> Int { items.filter { $0.kind == k }.count }

    public func setKind(_ k: CardMediaKind) {
        guard k != kind else { return }
        kind = k
        scroll = 0
        selection.prune(to: visibleIDs)
        if let p = previewID, !visibleIDs.contains(p) { previewID = nil }
    }
    public func setSort(_ s: CardSort) { sort = s }
    public func setLayout(_ l: Layout) { layout = l; scroll = 0; relayout() }
    public func selectAll() { selection.selectAll(visibleIDs) }
    public func click(_ id: String, shift: Bool = false, toggle: Bool = false) {
        selection.click(id, in: visibleIDs, shift: shift, toggle: toggle)
        previewID = id
    }
    /// After a copy where some files failed: only those stay ticked, so a retry does not copy the others again.
    public func keepOnly(_ ids: Set<String>) { selection.deselect(Set(visibleIDs).subtracting(ids)) }

    public var statusText: String { SQL10n.format("%@ selected", String(selected.count)) }

    // MARK: Layout

    public func height(width: CGFloat) -> CGFloat { ShellDialog.M.lBodyHeight }

    public func layout(_ f: CGRect, measure m: TextMeasure) {
        frame = f; measure = m
        relayout()
    }

    private func relayout() {
        // Board: 4 above, 22 high controls, 10 below, 16 at the sides, 12 between; a 1 pt line closes the band.
        let controlY = frame.minY + M.toolbarTop
        let inner = frame.insetBy(dx: M.toolbarSide, dy: 0)
        var x = inner.minX
        kindFrames = CardMediaKind.allCases.map { k in
            let w = ceil(measure?.width(kindTitle(k), size: M.font) ?? 80) + 24
            defer { x += w }
            return (k, CGRect(x: x, y: controlY, width: w, height: M.toolbar))
        }
        layoutFrames = [(.list, CGRect(x: inner.maxX - 2 * M.layoutSegment, y: controlY, width: M.layoutSegment, height: M.toolbar)),
                        (.grid, CGRect(x: inner.maxX - M.layoutSegment, y: controlY, width: M.layoutSegment, height: M.toolbar))]
        // `SQPopup.intrinsicContentSize`: the widest title plus the 10 pt inset, the 8 gap, the 7 chevron and its 7 inset.
        let sortW = measure.map { m in ceil(CardSort.allCases.map { m.width($0.title, size: M.font) }.max() ?? 0) + 32 } ?? M.sortWidth
        sortFrame = CGRect(x: inner.maxX - 2 * M.layoutSegment - M.toolbarGap - sortW, y: controlY, width: sortW, height: M.toolbar)
        toolbarFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: M.toolbarTop + M.toolbar + M.toolbarBottom)
        let top = toolbarFrame.maxY + 1
        let bodyH = max(frame.maxY - top, 0)
        previewFrame = CGRect(x: frame.maxX - M.previewWidth, y: top, width: M.previewWidth, height: bodyH)
        listFrame = CGRect(x: frame.minX, y: top, width: previewFrame.minX - 1 - frame.minX, height: bodyH)
        scroll = min(max(scroll, 0), max(contentHeight - listFrame.height, 0))
    }

    func kindTitle(_ k: CardMediaKind) -> String {
        SQL10n.format(k == .video ? "Videos (%@)" : "Photos (%@)", String(count(k)))
    }

    var columns: Int { max(Int((listFrame.width - 2 * M.gridPad + M.tileGapX) / (M.tile.width + M.tileGapX)), 1) }
    var contentHeight: CGFloat {
        let n = visible.count
        switch layout {
        case .list: return CGFloat(n) * M.rowHeight
        case .grid:
            let rows = (n + columns - 1) / columns
            return rows == 0 ? 0 : 2 * M.gridPad + CGFloat(rows) * (M.tile.height + M.tileName) + CGFloat(rows - 1) * M.tileGapY
        }
    }

    /// The tile (grid) or row (list) of the `i`th visible file, scrolled.
    func cellFrame(_ i: Int) -> CGRect {
        switch layout {
        case .list:
            return CGRect(x: listFrame.minX, y: listFrame.minY + CGFloat(i) * M.rowHeight - scroll, width: listFrame.width, height: M.rowHeight)
        case .grid:
            let col = i % columns, row = i / columns
            return CGRect(x: listFrame.minX + M.gridPad + CGFloat(col) * (M.tile.width + M.tileGapX),
                          y: listFrame.minY + M.gridPad + CGFloat(row) * (M.tile.height + M.tileName + M.tileGapY) - scroll,
                          width: M.tile.width, height: M.tile.height + M.tileName)
        }
    }

    func checkFrame(_ cell: CGRect) -> CGRect {
        switch layout {
        case .list: return CGRect(x: cell.minX + 8, y: cell.midY - M.check / 2, width: M.check, height: M.check)
        case .grid: return CGRect(x: cell.minX + M.checkInset, y: cell.minY + M.checkInset, width: M.check, height: M.check)
        }
    }

    func hit(_ p: CGPoint) -> Int? {
        guard listFrame.contains(p) else { return nil }
        return visible.indices.first { cellFrame($0).contains(p) }
    }

    // MARK: Events

    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        if scrollBody.scrollerEvent(e, scale: scale, viewport: listFrame, content: contentHeight) { return true }
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .mouseDown(let x, let y, let mods):
            let p = pt(x, y)
            if let k = kindFrames.first(where: { $0.1.contains(p) })?.0 { setKind(k); return true }
            if let l = layoutFrames.first(where: { $0.1.contains(p) })?.0 { setLayout(l); return true }
            if sortFrame.contains(p) {
                openPopup?(CardSort.allCases.map { s in
                    SQMenuItem(title: s.title, isChecked: s == sort) { [weak self] in self?.setSort(s) }
                }, sortFrame)
                return true
            }
            if let i = hit(p) {
                let id = visible[i].id
                if checkFrame(cellFrame(i)).insetBy(dx: -3, dy: -3).contains(p) { click(id, toggle: true) }
                else { click(id, shift: mods.contains(.shift), toggle: mods.contains(.command)) }
            }
            return frame.contains(p)
        case .mouseMoved(let x, let y):
            hovered = hit(pt(x, y)).map { visible[$0].id }
            return false
        case .scroll(let x, let y, _, let dy, _):
            guard listFrame.contains(pt(x, y)) else { return false }
            scrollBody.wheel(dy: dy, scale: CGFloat(scale), maxOffset: max(contentHeight - listFrame.height, 0), extent: listFrame.height)
            return true
        case .keyDown(.character(let c), let mods) where mods.contains(.command) && c.lowercased() == "a":
            selectAll()
            return true
        default:
            return false
        }
    }

    // MARK: Drawing

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        c.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), t.overlay)
        c.fill(listFrame, t.content)
        c.fill(CGRect(x: frame.minX, y: toolbarFrame.maxY, width: frame.width, height: 1), t.separator)
        c.fill(CGRect(x: listFrame.maxX, y: listFrame.minY, width: 1, height: listFrame.height), t.separator)
        drawToolbar(&c, t)
        c.saveGState()
        c.clip(to: listFrame)
        let shown = visible
        for (i, item) in shown.enumerated() {
            let r = cellFrame(i)
            guard r.maxY >= listFrame.minY, r.minY <= listFrame.maxY else { continue }
            layout == .grid ? drawTile(&c, item, r, t) : drawRow(&c, item, r, t)
        }
        if shown.isEmpty {
            c.draw(SQL10n.string(kind == .video ? "No videos on this card." : "No photos on this card."), in: listFrame,
                   fontSize: M.font, t.label3, align: .center)
        }
        c.restoreGState()
        scrollBody.drawScroller(&c, viewport: listFrame, content: contentHeight, theme: t)
        drawPreview(&c, t)
    }

    /// One SQSegmented track (ink 0.06, radius 6) with its selected segment lifted (radius 4, inset 1).
    private func segmented(_ c: inout Canvas, _ frames: [CGRect], selected: Int?, _ t: DrawTheme) {
        guard let first = frames.first, let last = frames.last else { return }
        c.fill(roundedRect: first.union(last), radius: 6, t.inkFill(0.06))
        if let n = selected { c.fill(roundedRect: frames[n].insetBy(dx: 1, dy: 1), radius: 4, t.fillPressed) }
    }

    private func drawToolbar(_ c: inout Canvas, _ t: DrawTheme) {
        segmented(&c, kindFrames.map(\.1), selected: kindFrames.firstIndex { $0.0 == kind }, t)
        for (k, r) in kindFrames { c.draw(kindTitle(k), in: r, fontSize: M.font, t.label, align: .center) }
        InspectorDraw.popup(&c, title: SQL10n.string(sort.title), in: sortFrame, hovering: false, open: false, enabled: true, t)
        segmented(&c, layoutFrames.map(\.1), selected: layoutFrames.firstIndex { $0.0 == layout }, t)
        for (l, r) in layoutFrames {
            let s: CGFloat = 14
            c.draw(icon: l == .grid ? .grid : .list, at: CGPoint(x: r.midX - s / 2, y: r.midY - s / 2), size: s, t.label)
        }
    }

    private func picture(_ c: inout Canvas, _ item: CardCandidate, in r: CGRect, radius: CGFloat, _ t: DrawTheme) {
        c.fill(roundedRect: r, radius: radius, t.fill)
        if let p = poster?(item) { c.draw(imageSlot: p.slot, in: r, source: p.cropped(toFill: r)) }
        else {
            let s = min(r.height * 0.4, 24)
            c.draw(icon: item.kind == .video ? .film : .image, at: CGPoint(x: r.midX - s / 2, y: r.midY - s / 2), size: s, t.label3)
        }
    }

    private func drawTile(_ c: inout Canvas, _ item: CardCandidate, _ r: CGRect, _ t: DrawTheme) {
        let pic = CGRect(origin: r.origin, size: M.tile)
        let radius = CGFloat(DrawTheme.Radius.control)
        picture(&c, item, in: pic, radius: radius, t)
        if previewID == item.id { c.stroke(roundedRect: pic.insetBy(dx: 1, dy: 1), radius: radius, width: 2, t.yellow) }
        else if hovered == item.id { c.stroke(roundedRect: pic.insetBy(dx: 0.5, dy: 0.5), radius: radius, width: 1, t.label3) }
        InspectorDraw.checkbox(&c, selection.ids.contains(item.id) ? .on : .off, box: checkFrame(r), hovering: false, pressed: false,
                               enabled: true, t)
        c.saveGState()
        c.clip(to: CGRect(x: r.minX, y: pic.maxY, width: r.width, height: M.tileName))
        c.draw(item.name, in: CGRect(x: r.minX, y: pic.maxY + 5, width: r.width, height: M.tileName - 5), fontSize: M.font, t.label)
        c.restoreGState()
    }

    private func drawRow(_ c: inout Canvas, _ item: CardCandidate, _ r: CGRect, _ t: DrawTheme) {
        let on = selection.ids.contains(item.id)
        if on { c.fill(r, t.accentFill.alpha(0.35)) } else if previewID == item.id || hovered == item.id { c.fill(r, t.fill) }
        InspectorDraw.checkbox(&c, on ? .on : .off, box: checkFrame(r), hovering: false, pressed: false, enabled: true, t)
        let thumb = CGRect(x: r.minX + 28, y: r.midY - M.rowThumb / 2, width: M.rowThumb, height: M.rowThumb)
        picture(&c, item, in: thumb, radius: 3, t)
        let sizeR = CGRect(x: r.maxX - 8 - M.sizeColumn, y: r.minY, width: M.sizeColumn, height: r.height)
        c.draw(SQByteSize.string(item.size), in: sizeR, fontSize: M.mini, t.label3, align: .right)
        let date = Self.dateFormat.string(from: item.modified)
        let dateW = ceil(measure?.width(date, size: M.mini) ?? 110)
        let dateR = CGRect(x: sizeR.minX - 12 - dateW, y: r.minY, width: dateW, height: r.height)
        c.draw(date, in: dateR, fontSize: M.mini, t.label3)
        let nameR = CGRect(x: thumb.maxX + 8, y: r.minY, width: max(dateR.minX - 12 - thumb.maxX - 8, 0), height: r.height)
        c.saveGState()
        c.clip(to: nameR)
        c.draw(item.name, in: nameR, fontSize: M.font, t.label)
        c.restoreGState()
    }

    private func drawPreview(_ c: inout Canvas, _ t: DrawTheme) {
        let inner = previewFrame.insetBy(dx: M.previewPad, dy: 0)
        let pic = CGRect(x: inner.minX, y: previewFrame.minY + M.previewPad, width: inner.width, height: M.previewPicture)
        guard let item = preview else {
            c.fill(roundedRect: pic, radius: CGFloat(DrawTheme.Radius.control), t.fill)
            return
        }
        picture(&c, item, in: pic, radius: CGFloat(DrawTheme.Radius.control), t)
        c.saveGState()
        c.clip(to: CGRect(x: inner.minX, y: pic.maxY, width: inner.width, height: 60))
        c.draw(item.name, in: CGRect(x: inner.minX, y: pic.maxY + 8, width: inner.width, height: 16), fontSize: M.font, t.label,
               face: c.semibold)
        c.draw(Self.dateFormat.string(from: item.modified) + " · " + SQByteSize.string(item.size),
               in: CGRect(x: inner.minX, y: pic.maxY + 32, width: inner.width, height: 14), fontSize: M.mini, t.label3)
        c.restoreGState()
    }
}
