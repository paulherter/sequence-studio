import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQExport
import SQUIKit

/// The Mac Export sheet (`ExportDialogView`, 860 x 640) drawn on the canvas over the same `ExportDialogModel`: header with
/// title, sequence, preset popup and the add button; left column with the preview box, the output list and the warnings;
/// right column with the folding settings sections (`ExportSheetRows`). The dialog around it draws the footer band
/// (summary, Other Formats, Cancel, Export).
/// The preview box shows the `ShellExportPreview` picture (click or Space plays, the arrows step, the bar scrubs).
@MainActor
public final class ShellExportSheet: ShellDialogContent {
    enum M {
        static let headerH: CGFloat = 56, leftW: CGFloat = 320, padX: CGFloat = 16, boxH: CGFloat = 204, fieldH: CGFloat = 22
        static let listRowH: CGFloat = 24, listInset: CGFloat = 4
        static let rowH: CGFloat = 24, labelX: CGFloat = 25, controlX: CGFloat = 128, trailing: CGFloat = 12, gap: CGFloat = 8
        static let firstHeaderH: CGFloat = 24, headerH2: CGFloat = 25, sectionGap: CGFloat = 4
        static let body: CGFloat = 11, caption: CGFloat = 10, title: CGFloat = 13
        static let checkBox: CGFloat = 14
        static let buttonPad: CGFloat = 11
    }

    public let model: ExportDialogModel
    let codecs: [VideoCodec]
    let fileOutputs: Bool
    public var openPopup: ((_ items: [SQMenuItem], _ below: CGRect) -> Void)?
    /// Folder "Change…" (`ShellFilePicker.chooseFolder`); nil leaves the button disabled.
    public var chooseFolder: (@MainActor () async -> URL?)?
    public var copyText: (@MainActor (String) -> Void)?

    public private(set) var sections: [ExportSection] = []
    /// Open state per section key, kept for the session (`InspectorSection`'s remembered state).
    static var openState: [String: Bool] = [:]
    private var customSize = false
    private var nameField = TextFieldControl()
    private var nameFocused = false
    /// The number field being typed into (path into `sections`).
    private var editingScrub: Path?

    struct Path: Hashable { var s: Int, r: Int, i: Int }
    enum Target: Equatable {
        case add, preset, play, picture, scrub, outputCheck(UUID), output(UUID), variants, section(String), item(Path), segment(Path, Int)
    }

    private(set) var frame: CGRect = .zero
    private var measure: TextMeasure?
    public private(set) var scroll: CGFloat = 0
    private var columnHeight: CGFloat = 0
    private(set) var targets: [(Target, CGRect)] = []
    private(set) var rowFrames: [(title: String, dimmed: Bool, frame: CGRect)] = []
    private(set) var headerFrames: [(title: String, open: Bool, first: Bool, frame: CGRect)] = []
    private var itemFrames: [Path: CGRect] = [:]
    private var listFrame: CGRect = .zero
    private var listContentH: CGFloat = 0
    private var listScroll: CGFloat = 0
    private var bottomBlocks: (warning: CGRect, chips: [(String, Bool, CGRect)], hint: CGRect, variants: CGRect) = (.zero, [], .zero, .zero)
    private var hover: Target?
    private var pressed: Target?
    private var scrubbing: Path?
    private var clicks = ClickCounter()
    private var scrubbingPreview = false
    /// The picture (`ExportDialogView.preview`); the host sets its `frameImage`.
    public let preview = ShellExportPreview()

    public init(model: ExportDialogModel, codecs: [VideoCodec], fileOutputs: Bool) {
        self.model = model; self.codecs = codecs; self.fileOutputs = fileOutputs
        nameField.text = model.fileName
        nameField.alignment = .left
        nameField.fontSize = M.body
        rebuild()
    }

    /// The presets the encoder writes, in the model's order; "Custom" follows while the settings match none.
    var presets: [ExportPreset] {
        let offered = Set(ShellExport.presets(codecs: codecs, fileOutputs: fileOutputs).map(\.id))
        return model.presets.filter { offered.contains($0.id) }
    }

    var builder: ExportSheetRows {
        var b = ExportSheetRows(model: model, codecs: codecs, customSize: customSize) { [weak self] rebuild in
            if rebuild { self?.rebuild() }
        }
        b.setCustomSize = { [weak self] on in self?.customSize = on }
        b.fileName = nameField
        if chooseFolder != nil { b.chooseFolder = { [weak self] in self?.pickFolder() } }
        b.copyText = copyText
        b.exportStems = { [weak self] in self?.runStems() }
        b.checkAudio = { [weak self] in self?.runAudioCheck() }
        return b
    }

    /// New rows from the model (the Mac `reload()`).
    public func rebuild() {
        sections = builder.sections()
        preview.configure(sequenceID: model.selectedID, settings: model.settings, provider: model.previewSource)
        if let m = measure, frame.width > 0 { layoutAll(m) }
    }

    func isOpen(_ s: ExportSection) -> Bool { Self.openState[s.key] ?? s.defaultOpen }

    private func pickFolder() {
        guard let choose = chooseFolder else { return }
        Task { @MainActor [weak self] in
            guard let url = await choose(), let self else { return }
            self.model.outputDirectory = url
            self.rebuild()
        }
    }

    /// Polls like the Mac `audioCheckTapped`: the result arrives later.
    private func runAudioCheck() {
        model.runAudioCheck()
        rebuild()
        Task { @MainActor [weak self] in
            while let self, self.model.isCheckingAudio { try? await Task.sleep(nanoseconds: 200_000_000) }
            self?.rebuild()
        }
    }

    private func runStems() {
        guard let dir = model.outputDirectory else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let run = Task { await self.model.exportStems(to: dir) }
            self.rebuild()
            await run.value
            self.rebuild()
        }
    }

    // MARK: Layout

    public func height(width: CGFloat) -> CGFloat { ShellDialog.M.heightL - ShellDialog.M.bandFooterHeight }

    public func layout(_ f: CGRect, measure m: TextMeasure) {
        frame = f; measure = m
        layoutAll(m)
    }

    var columnFrame: CGRect {
        CGRect(x: frame.minX + M.leftW + 1, y: frame.minY + M.headerH + 1, width: frame.width - M.leftW - 1,
               height: frame.height - M.headerH - 1)
    }

    var previewFrame: CGRect { CGRect(x: frame.minX + M.padX, y: frame.minY + M.headerH + 1 + 14, width: M.leftW - 2 * M.padX, height: M.boxH) }
    /// `ExportScrubBar`: from the play button to the timecode column (78), `Theme.Spacing.sm` apart.
    var scrubFrame: CGRect {
        let barX = frame.minX + M.padX + 24 + 8
        return CGRect(x: barX, y: previewFrame.maxY + 10, width: frame.minX + M.leftW - M.padX - 78 - 8 - barX, height: M.fieldH)
    }
    static let scrubInset: CGFloat = 8
    func scrubFraction(_ x: CGFloat) -> Double {
        let r = scrubFrame
        return min(max(Double((x - r.minX - Self.scrubInset) / max(r.width - 2 * Self.scrubInset, 1)), 0), 1)
    }
    var addFrame: CGRect { CGRect(x: frame.maxX - M.padX - 24, y: frame.minY + ((M.headerH - M.fieldH) / 2).rounded(), width: 24, height: M.fieldH) }
    var presetFrame: CGRect { CGRect(x: addFrame.minX - 12 - 230, y: addFrame.minY, width: 230, height: M.fieldH) }

    private func layoutAll(_ m: TextMeasure) {
        targets = [(.add, addFrame), (.preset, presetFrame)]
        let bar = previewFrame.maxY + 10
        targets.append((.play, CGRect(x: frame.minX + M.padX, y: bar, width: 24, height: M.fieldH)))
        targets.append((.scrub, scrubFrame))
        targets.append((.picture, previewFrame))
        layoutList(m, barY: bar)
        layoutColumn(m)
    }

    private func layoutList(_ m: TextMeasure, barY: CGFloat) {
        let w = M.leftW - 2 * M.padX, x = frame.minX + M.padX
        let lineH = m.lineHeight(M.body)
        let rows = model.outputRows
        listContentH = M.listInset * 2 + CGFloat(rows.count) * M.listRowH
        let top = barY + M.fieldH + 10 + 22 + 10
        let summaryY = frame.maxY - 14
        let warning = model.validationMessages.first ?? ""
        let warnH: CGFloat = warning.isEmpty ? 0 : lineH * 2
        let warnRect = CGRect(x: x, y: summaryY - 6 - warnH, width: w, height: warnH)
        var bottom = warning.isEmpty ? summaryY : warnRect.minY
        var chips: [(String, Bool, CGRect)] = []
        var cx: CGFloat = 0, cy: CGFloat = 0
        let chipH = CGFloat(DrawTheme.Metrics.capsule)
        for issue in model.deliveryIssues {
            let text = SQL10n.localized(issue.text)
            let cw = ceil(m.width(text, size: M.caption)) + 24
            if cx > 0, cx + cw > w { cx = 0; cy += chipH + 4 }
            chips.append((text, issue.severity == .warning, CGRect(x: cx, y: cy, width: cw, height: chipH)))
            cx += cw + 4
        }
        let chipsH: CGFloat = chips.isEmpty ? 0 : cy + chipH
        let chipsTop = bottom - 6 - chipsH
        chips = chips.map { ($0.0, $0.1, $0.2.offsetBy(dx: x, dy: chipsTop)) }
        if chipsH > 0 { bottom = chipsTop }
        let hint = model.exportNotes
        // The Mac label truncates its tail (`styled`), so its cell is one line high.
        let hintH = hint.isEmpty ? 0 : lineH
        let hintRect = CGRect(x: x, y: bottom - 6 - hintH, width: w, height: hintH)
        if !hint.isEmpty { bottom = hintRect.minY }
        var variants = CGRect.zero
        if model.hasVariants {
            variants = CGRect(x: x, y: bottom - 6 - 18, width: w, height: 18)
            bottom = variants.minY
            targets.append((.variants, variants))
        }
        bottomBlocks = (warnRect, chips, hintRect, variants)
        let h = min(listContentH, max(bottom - 10 - top, M.listRowH + 2 * M.listInset))
        listFrame = CGRect(x: x, y: top, width: w, height: h)
        listScroll = min(max(listScroll, 0), max(listContentH - h, 0))
        for (i, r) in rows.enumerated() {
            let y = top + M.listInset + CGFloat(i) * M.listRowH - listScroll
            let row = CGRect(x: x, y: y, width: w, height: M.listRowH).intersection(listFrame)
            guard !row.isNull, row.height > 0 else { continue }
            targets.append((.outputCheck(r.id), CGRect(x: x + 4, y: row.minY, width: 26, height: row.height)))
            targets.append((.output(r.id), row))
        }
    }

    /// The settings column: section headers and rows from the top, scrolled by `scroll`.
    private func layoutColumn(_ m: TextMeasure) {
        let col = columnFrame
        rowFrames = []; headerFrames = []; itemFrames = [:]
        var y: CGFloat = 0
        for (si, s) in sections.enumerated() {
            let first = si == 0
            if !first { y += M.sectionGap }
            let hh = first ? M.firstHeaderH : M.headerH2
            let header = CGRect(x: col.minX, y: col.minY + y - scroll, width: col.width, height: hh)
            let open = isOpen(s)
            headerFrames.append((s.title, open, first, header))
            targets.append((.section(s.key), header))
            y += hh
            guard open else { continue }
            for (ri, r) in s.rows.enumerated() {
                let rect = CGRect(x: col.minX, y: col.minY + y - scroll, width: col.width, height: M.rowH)
                rowFrames.append((r.title, r.dimmed, rect))
                layoutItems(r.items, in: rect, m) { ii, f in
                    let p = Path(s: si, r: ri, i: ii)
                    itemFrames[p] = f
                    if case .segmented(let labels, _, _, let sw) = r.items[ii].kind {
                        for k in labels.indices {
                            targets.append((.segment(p, k), CGRect(x: f.minX + 1 + CGFloat(k) * sw, y: f.minY, width: sw, height: f.height)))
                        }
                    } else {
                        targets.append((.item(p), f))
                    }
                }
                y += M.rowH
            }
        }
        columnHeight = y + 8
        let maxScroll = max(columnHeight - col.height, 0)
        if scroll > maxScroll { scroll = maxScroll; layoutColumn(m) }
    }

    /// `ExportSettingRow.layout`: fixed and fitted items keep their width, fill items share what is left (at least 20).
    private func layoutItems(_ items: [ExportItem], in row: CGRect, _ m: TextMeasure, _ place: (Int, CGRect) -> Void) {
        let x0 = row.minX + M.controlX, right = row.maxX - M.trailing
        let widths: [CGFloat?] = items.map { item in
            switch item.width {
            case .fill: nil
            case .fixed(let w): w
            case .fit: fitWidth(item.kind, m)
            }
        }
        let fixed = widths.compactMap { $0 }.reduce(0, +)
        let fills = widths.filter { $0 == nil }.count
        let gaps = CGFloat(max(items.count - 1, 0)) * M.gap
        let share = fills > 0 ? max((right - x0 - fixed - gaps) / CGFloat(fills), 20) : 0
        var x = x0
        for (i, item) in items.enumerated() {
            let w = (widths[i] ?? share).rounded()
            let h: CGFloat
            switch item.kind {
            case .check: h = 16
            case .text, .unit: h = row.height
            default: h = M.fieldH
            }
            place(i, CGRect(x: x, y: row.minY + ((row.height - h) / 2).rounded(), width: w, height: h))
            x += w + M.gap
        }
    }

    func fitWidth(_ k: ExportItem.Kind, _ m: TextMeasure) -> CGFloat {
        switch k {
        case .check(let title, _): title.isEmpty ? 16 : M.checkBox + 6 + ceil(m.width(title, size: M.body))
        case .unit(let s): ceil(m.width(s, size: M.body))
        case .text(let s, _, let caption): ceil(m.width(s, size: caption ? M.caption : M.body))
        case .segmented(let labels, _, _, let w): CGFloat(labels.count) * w + 2
        case .button(let s): ceil(m.width(s, size: M.body)) + 2 * M.buttonPad
        case .popup: 120
        case .scrub: ExportSheetRows.numberFieldWidth
        case .field, .path: 160
        }
    }

    // MARK: Input

    func target(at p: CGPoint) -> Target? {
        let inColumn = columnFrame.contains(p), inList = listFrame.contains(p)
        // Later entries (rows) sit over earlier ones (the list's check area is listed before its row).
        return targets.first { t, r in
            guard r.contains(p) else { return false }
            switch t {
            case .item, .segment, .section: return inColumn
            case .output, .outputCheck: return inList
            default: return true
            }
        }?.0
    }

    func item(_ p: Path) -> ExportItem? {
        guard sections.indices.contains(p.s), sections[p.s].rows.indices.contains(p.r),
              sections[p.s].rows[p.r].items.indices.contains(p.i) else { return nil }
        return sections[p.s].rows[p.r].items[p.i]
    }

    private func setScrub(_ p: Path, _ f: ScrubFieldControl) {
        guard item(p) != nil else { return }
        sections[p.s].rows[p.r].items[p.i].kind = .scrub(f)
    }

    private func scrubControl(_ p: Path) -> ScrubFieldControl? {
        if let it = item(p), case .scrub(let f) = it.kind { return f }
        return nil
    }

    /// Hands a number field's events to its row action; a committed value (typed, stepped, drag end) rebuilds the rows.
    private func deliver(_ events: [ScrubFieldControl.Event], _ p: Path) {
        guard let action = item(p)?.action else { return }
        var final: Double?
        for e in events {
            switch e {
            case .begin: break
            case .live(let v): action(.number(v, final: false))
            case .change(let v), .end(let v), .cancel(let v): final = v
            }
        }
        if let v = final { action(.number(v, final: true)) }
    }

    private func endNameEditing() {
        guard nameFocused else { return }
        nameFocused = false
        if let s = nameField.commit() { commitName(s) }
    }

    private func commitName(_ s: String) {
        model.fileName = s
        nameField.text = model.fileName
        rebuild()
    }

    private func endScrubEditing() {
        guard let p = editingScrub else { return }
        editingScrub = nil
        guard var f = scrubControl(p) else { return }
        let events = f.commitEditing()
        setScrub(p, f)
        deliver(events, p)
    }

    /// Commits a typed name or number (the Export button reads them, as the Mac `exportTapped`).
    public func commitEditing() {
        endNameEditing()
        endScrubEditing()
    }

    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            let t = target(at: p)
            if case .item(let path)? = t, case .field? = item(path)?.kind {
                endScrubEditing()
                // shortcut: a press in the open field keeps the caret where it is; upgrade with `caretIndex` (needs the canvas).
                if !nameFocused { nameFocused = true; nameField.mouseDown() }
                return true
            }
            if case .item(let path)? = t, editingScrub == path, var f = scrubControl(path) {
                let n = clicks.press(x: x, y: y, now: ProcessInfo.processInfo.systemUptime)
                let ev = f.mouseDown(x: x, clickCount: n)
                setScrub(path, f); deliver(ev, path)
                return true
            }
            commitEditing()
            press(t, at: p, x: x, y: y)
            return true
        case .mouseDragged(let x, _):
            if scrubbingPreview { preview.scrub(to: scrubFraction(CGFloat(x / scale))); return true }
            if let s = scrubbing, var f = scrubControl(s) {
                let ev = f.mouseDragged(x: x, modifiers: [], scale: scale)
                setScrub(s, f); deliver(ev, s)
                return true
            }
            return pressed != nil
        case .mouseUp(let x, let y):
            if scrubbingPreview { scrubbingPreview = false; return true }
            if let s = scrubbing {
                scrubbing = nil
                if var f = scrubControl(s) {
                    let ev = f.mouseUp()
                    setScrub(s, f)
                    if f.isEditing { editingScrub = s }
                    deliver(ev, s)
                }
                return true
            }
            guard let was = pressed else { return false }
            pressed = nil
            if target(at: pt(x, y)) == was { release(was) }
            return true
        case .mouseMoved(let x, let y):
            hover = target(at: pt(x, y))
            return false
        case .scroll(let x, let y, _, let dy, _):
            let p = pt(x, y)
            if listFrame.contains(p) {
                listScroll -= CGFloat(dy / scale)
                if let m = measure { layoutAll(m) }
            } else if columnFrame.contains(p) {
                scroll = min(max(scroll - CGFloat(dy / scale), 0), max(columnHeight - columnFrame.height, 0))
                if let m = measure { layoutAll(m) }
            }
            return true
        case .keyDown(let k, let mods):
            if nameFocused {
                if k == .escape { nameField.cancel(); nameFocused = false; return true }
                if k == .enter { endNameEditing(); return true }
                if let s = nameField.key(k, modifiers: mods) { nameFocused = false; commitName(s) }
                return true
            }
            if let p = editingScrub, var f = scrubControl(p) {
                let ev = f.key(k, modifiers: mods, now: ProcessInfo.processInfo.systemUptime)
                setScrub(p, f)
                if !f.isEditing { editingScrub = nil }
                deliver(ev, p)
                return true
            }
            // `ExportDialogView.keyDown`: Space plays, the arrows step a frame.
            if k == .space { preview.togglePlay(); return true }
            if k == .left || k == .right { preview.step(k == .left ? -1 : 1); return true }
            return false
        }
    }

    private func press(_ t: Target?, at p: CGPoint, x: Float, y: Float) {
        guard let t else { return }
        switch t {
        case .item(let path):
            guard let it = item(path), it.enabled else { return }
            switch it.kind {
            case .scrub(var f):
                let n = clicks.press(x: x, y: y, now: ProcessInfo.processInfo.systemUptime)
                let ev = f.mouseDown(x: x, clickCount: n)
                setScrub(path, f)
                scrubbing = path
                deliver(ev, path)
            case .popup(let titles, let selected, let disabled):
                guard let r = itemFrames[path] else { return }
                let action = it.action
                let items = titles.enumerated().map { i, title in
                    SQMenuItem(title: title, isEnabled: !disabled.contains(i), isChecked: i == selected) { action?(.index(i)) }
                }
                openPopup?(items, r)
            default: pressed = t
            }
        case .segment(let path, let k):
            guard let it = item(path), it.enabled, case .segmented(_, let sel, let disabled, _) = it.kind,
                  !disabled.contains(k), k != sel else { return }
            it.action?(.index(k))
        case .scrub:
            guard preview.frameCount > 0 else { return }
            scrubbingPreview = true
            preview.scrub(to: scrubFraction(p.x))
        case .preset:
            let list = presets
            let custom = !list.contains { $0.id == model.presetID }
            var items = list.map { pr in
                SQMenuItem(title: SQL10n.localized(pr.name), isChecked: pr.id == model.presetID) { [weak self] in
                    self?.model.presetID = pr.id
                    self?.customSize = false
                    self?.rebuild()
                }
            }
            if custom { items.append(SQMenuItem(title: SQL10n.string("Custom"), isChecked: true, action: {})) }
            openPopup?(items, presetFrame)
        default: pressed = t
        }
    }

    private func release(_ t: Target) {
        switch t {
        case .add: model.addFormat(); rebuild()
        case .play, .picture: preview.togglePlay()
        case .outputCheck(let id):
            let on = model.outputRows.first { $0.id == id }?.isChecked ?? false
            model.setOutputChecked(id, !on); rebuild()
        case .output(let id): model.selectOutput(id); customSize = false; rebuild()
        case .variants: model.exportAllFormats.toggle(); rebuild()
        case .section(let key):
            if let s = sections.first(where: { $0.key == key }) { Self.openState[key] = !isOpen(s) }
            if let m = measure { layoutAll(m) }
        case .item(let path):
            guard let it = item(path), it.enabled else { return }
            switch it.kind {
            case .check(_, let on): it.action?(.bool(!on))
            case .button: it.action?(.press)
            default: break
            }
        default: break
        }
    }

    // MARK: Drawing

    func color(_ tone: ExportItem.Tone, _ t: DrawTheme) -> DrawColor {
        switch tone {
        case .label: t.label
        case .label2: t.label2
        case .label3: t.label3
        case .warning: MenuListView.color(palette: t.palette.warning)
        case .green: t.green
        case .red: t.red
        }
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let f = frame
        let lineH = measure?.lineHeight(M.body) ?? 14
        // Header: "Export", the sequence, the preset popup and the add button.
        c.draw(SQL10n.string("Export"), in: CGRect(x: f.minX + M.padX, y: f.minY, width: 48, height: M.headerH), fontSize: M.title,
               t.label, face: c.medium)
        let seq = model.sequences.first { $0.id == model.selectedID }?.name ?? ""
        c.draw(seq, in: CGRect(x: f.minX + M.padX + 48 + 12, y: f.minY, width: 260, height: M.headerH), fontSize: M.body, t.label3)
        c.draw(SQL10n.string("Preset"), in: CGRect(x: presetFrame.minX - 8 - 44, y: f.minY, width: 44, height: M.headerH),
               fontSize: M.body, t.label2, align: .right)
        let custom = !presets.contains { $0.id == model.presetID }
        let presetTitle = custom ? SQL10n.string("Custom") : SQL10n.localized(presets.first { $0.id == model.presetID }?.name ?? "")
        InspectorDraw.popup(&c, title: presetTitle, in: presetFrame, hovering: hover == .preset, open: false, enabled: true, t)
        // `SQButton(symbol:)`: a bare icon, a body only under the pointer.
        if hover == .add || pressed == .add {
            InspectorDraw.button(&c, title: "", in: addFrame, hovering: true, pressed: pressed == .add, enabled: true, t)
        }
        c.draw(icon: .plus, at: CGPoint(x: addFrame.midX - 6, y: addFrame.midY - 6), size: 12, t.label)
        c.fill(CGRect(x: f.minX, y: f.minY + M.headerH, width: f.width, height: 1), t.separator)
        c.fill(CGRect(x: f.minX + M.leftW, y: f.minY + M.headerH + 1, width: 1, height: f.height - M.headerH - 1), t.separator)

        drawLeft(&c, t, lineH: lineH)
        drawColumn(&c, t)
    }

    private func drawLeft(_ c: inout Canvas, _ t: DrawTheme, lineH: CGFloat) {
        let f = frame
        let box = previewFrame
        c.fill(roundedRect: box, radius: CGFloat(DrawTheme.Radius.control), t.viewer)
        // `ExportPictureView` inside the box at the output's aspect: the picture, or the note (2 lines, body, label3).
        let v = model.settings.video
        let pic = ExportPreviewMath.pictureRect(box: box, width: v.width, height: v.height)
        if preview.image != nil {
            c.draw(imageSlot: ShellExportPreview.slot, in: pic)
        } else {
            c.fill(roundedRect: pic, radius: CGFloat(DrawTheme.Radius.control), t.viewer)
            if let note = preview.note {
                let lines = measure.map { $0.lines(note, width: pic.width - 24, size: M.body) }?.prefix(2) ?? [note]
                var y = pic.midY - lineH * CGFloat(lines.count) / 2
                for l in lines {
                    c.draw(l, in: CGRect(x: pic.minX + 12, y: y, width: pic.width - 24, height: lineH), fontSize: M.body, t.label3, align: .center)
                    y += lineH
                }
            }
        }
        let bar = box.maxY + 10
        let play = CGRect(x: f.minX + M.padX, y: bar, width: 24, height: M.fieldH)
        let canPlay = preview.frameCount > 0
        // `SQButton` 24 x fieldH with the play / pause symbol (11 pt).
        if canPlay, hover == .play { c.fill(roundedRect: play, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
        c.draw(icon: preview.isPlaying ? .pause : .play, at: CGPoint(x: play.midX - 5.5, y: play.midY - 5.5), size: 11,
               canPlay ? t.label2 : t.label2.alpha(0.4))
        // `ExportScrubBar`: 4 pt track, accent progress, a 10 pt label-colored knob while enabled.
        let sf = scrubFrame
        let track = CGRect(x: sf.minX + Self.scrubInset, y: sf.midY - 2, width: sf.width - 2 * Self.scrubInset, height: 4)
        c.fill(roundedRect: track, radius: CGFloat(DrawTheme.Radius.small), t.fill)
        if canPlay {
            let kx = track.minX + track.width * CGFloat(preview.fraction)
            c.fill(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(kx - track.minX, 0), height: 4),
                   radius: CGFloat(DrawTheme.Radius.small), t.accentFill)
            c.fill(ellipseIn: CGRect(x: kx - 5, y: sf.midY - 5, width: 10, height: 10), t.label)
            c.draw(preview.timecode, in: CGRect(x: f.minX + M.leftW - M.padX - 78, y: bar + ((M.fieldH - lineH) / 2).rounded(),
                                                width: 78, height: lineH), fontSize: M.body, t.label2, align: .right)
        }
        c.draw(SQL10n.string("Export"), in: CGRect(x: f.minX + M.padX, y: bar + M.fieldH + 10, width: 200, height: 22),
               fontSize: M.caption, t.label3, face: c.semibold)

        // The output list: field body, .5 edge, one row per output (check, name, size).
        let lf = listFrame
        c.fill(roundedRect: lf, radius: CGFloat(DrawTheme.Radius.small), t.field)
        c.stroke(roundedRect: lf.insetBy(dx: 0.25, dy: 0.25), radius: CGFloat(DrawTheme.Radius.small), width: 0.5, t.fieldEdge)
        c.saveGState()
        c.clip(to: lf)
        for (i, r) in model.outputRows.enumerated() {
            let y = lf.minY + M.listInset + CGFloat(i) * M.listRowH - listScroll
            let row = CGRect(x: lf.minX, y: y, width: lf.width, height: M.listRowH)
            // The Mac list shows the selected output by the settings column only; hover gets a soft body.
            if hover == .output(r.id) {
                c.fill(roundedRect: row.insetBy(dx: 4, dy: 1), radius: 4, t.fillHover.alpha(0.5))
            }
            let cb = CGRect(x: row.minX + 12, y: row.midY - M.checkBox / 2, width: M.checkBox, height: M.checkBox)
            InspectorDraw.checkbox(&c, r.isChecked ? .on : .off, box: cb, hovering: hover == .outputCheck(r.id),
                                   pressed: pressed == .outputCheck(r.id), enabled: true, t)
            let sizeW: CGFloat = 78
            c.draw(r.title, in: CGRect(x: row.minX + 34, y: row.minY, width: row.width - 34 - 12 - sizeW - 4, height: row.height),
                   fontSize: M.body, t.label)
            c.draw(r.sizeText, in: CGRect(x: row.maxX - 12 - sizeW, y: row.minY, width: sizeW, height: row.height),
                   fontSize: M.body, t.label2, align: .right)
        }
        c.restoreGState()

        let warn = MenuListView.color(palette: t.palette.warning)
        let b = bottomBlocks
        if let w = model.validationMessages.first, let m = measure {
            // One line, cut with an ellipsis, in the lower half of its two-line box (the Mac label's truncating tail).
            c.draw(Self.truncated(SQL10n.localized(w), width: b.warning.width, m), in: CGRect(x: b.warning.minX, y: b.warning.maxY - lineH, width: b.warning.width, height: lineH), fontSize: M.body, warn)
        }
        for (text, isWarning, r) in b.chips {
            c.fill(roundedRect: r, radius: r.height / 2, isWarning ? warn.alpha(0.14) : t.fill)
            c.draw(text, in: r, fontSize: M.caption, isWarning ? warn : t.label2, align: .center)
        }
        let hint = model.exportNotes
        if !hint.isEmpty, let m = measure {
            c.draw(Self.truncated(hint, width: b.hint.width, m), in: b.hint, fontSize: M.body, warn)
        }
        if model.hasVariants {
            let r = b.variants
            let cb = CGRect(x: r.minX, y: r.midY - M.checkBox / 2, width: M.checkBox, height: M.checkBox)
            InspectorDraw.checkbox(&c, model.exportAllFormats ? .on : .off, box: cb, hovering: hover == .variants,
                                   pressed: pressed == .variants, enabled: true, t)
            c.draw(SQL10n.string("Also export every format variant"), in: CGRect(x: cb.maxX + 6, y: r.minY, width: r.width - 20, height: r.height),
                   fontSize: M.body, t.label)
        }
    }

    /// `lineBreakMode = .byTruncatingTail`: one line, cut with an ellipsis.
    static func truncated(_ s: String, width: CGFloat, _ m: TextMeasure) -> String {
        guard m.width(s, size: M.body) > width else { return s }
        var line = s
        while line.count > 1, m.width(line + "\u{2026}", size: M.body) > width { line.removeLast() }
        return line.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private func drawColumn(_ c: inout Canvas, _ t: DrawTheme) {
        let col = columnFrame
        c.saveGState()
        c.clip(to: col)
        for h in headerFrames {
            var r = h.frame
            if !h.first {
                c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1), t.separator)
                r = CGRect(x: r.minX, y: r.minY + 1, width: r.width, height: r.height - 1)
            }
            InspectorDraw.chevron(&c, in: CGRect(x: r.minX + 6, y: r.minY, width: 18, height: r.height),
                                  direction: h.open ? .down : .right, t.label3, size: 5)
            c.draw(SQL10n.string(h.title), in: CGRect(x: r.minX + 30, y: r.minY, width: r.width - 42, height: r.height),
                   fontSize: M.body, t.label, face: c.medium)
        }
        for r in rowFrames where !r.title.isEmpty {
            c.draw(SQL10n.string(r.title), in: CGRect(x: r.frame.minX + M.labelX + 2, y: r.frame.minY, width: M.controlX - M.labelX - M.gap - 2,
                                                     height: r.frame.height), fontSize: M.body, r.dimmed ? t.label3 : t.label2)
        }
        for (p, r) in itemFrames { if let it = item(p) { drawItem(&c, it, p, r, t) } }
        c.restoreGState()
        if columnHeight > col.height + 0.5 {
            let track = col.insetBy(dx: 0, dy: 2)
            let knobH = max(track.height * col.height / columnHeight, 24)
            let y = track.minY + (track.height - knobH) * scroll / max(columnHeight - col.height, 1)
            c.fill(roundedRect: CGRect(x: track.maxX - 8, y: y, width: 4, height: knobH), radius: 2, t.label3)
        }
    }

    private func drawItem(_ c: inout Canvas, _ it: ExportItem, _ p: Path, _ r: CGRect, _ t: DrawTheme) {
        let hovering = hover == .item(p), down = pressed == .item(p)
        let a: Float = it.enabled ? 1 : InspectorTokens.disabledAlpha
        switch it.kind {
        case .popup(let titles, let selected, _):
            InspectorDraw.popup(&c, title: titles.indices.contains(selected) ? titles[selected] : "", in: r, hovering: hovering,
                                open: false, enabled: it.enabled, t)
        case .check(let title, let on):
            let cb = CGRect(x: r.minX, y: r.midY - M.checkBox / 2, width: M.checkBox, height: M.checkBox)
            InspectorDraw.checkbox(&c, on ? .on : .off, box: cb, hovering: hovering, pressed: down, enabled: it.enabled, t)
            if !title.isEmpty {
                c.draw(title, in: CGRect(x: cb.maxX + 6, y: r.minY - 4, width: r.width - M.checkBox - 6, height: r.height + 8),
                       fontSize: M.body, t.label.alpha(a))
            }
        case .scrub(var f):
            // `ScrubField`: the value in the accent color.
            if f.valueTint == nil { f.valueTint = t.accent }
            f.draw(&c, in: r, theme: t, focused: editingScrub == p)
        case .unit(let s):
            c.draw(s, in: r, fontSize: M.body, t.label2.alpha(a))
        case .text(let s, let tone, let caption):
            c.draw(s, in: r, fontSize: caption ? M.caption : M.body, color(tone, t).alpha(a))
        case .segmented(let labels, let selected, let disabled, let sw):
            let track = CGRect(x: r.minX, y: r.minY, width: CGFloat(labels.count) * sw + 2, height: r.height)
            c.fill(roundedRect: track, radius: 6, t.inkFill(0.06))
            for (k, l) in labels.enumerated() {
                let seg = CGRect(x: track.minX + 1 + CGFloat(k) * sw, y: track.minY + 1, width: sw, height: track.height - 2)
                if k == selected { c.fill(roundedRect: seg, radius: 4, t.fillPressed) }
                else if hover == .segment(p, k), !disabled.contains(k) { c.fill(roundedRect: seg, radius: 4, t.fill) }
                let on = it.enabled && !disabled.contains(k)
                c.draw(l, in: seg, fontSize: M.body, on ? t.label : t.label3, align: .center)
            }
        case .button(let s):
            InspectorDraw.button(&c, title: s, in: r, hovering: hovering, pressed: down, enabled: it.enabled, t)
        case .field(_, let suffix):
            nameField.draw(&c, in: r, theme: t, focused: nameFocused)
            if !suffix.isEmpty, !nameFocused, let m = measure {
                let text = TextFieldControl.textRect(in: r)
                let x = min(text.minX + ceil(m.width(nameField.text, size: M.body)) + 1, text.maxX - ceil(m.width(suffix, size: M.body)))
                c.draw(suffix, in: CGRect(x: x, y: text.minY, width: text.maxX - x, height: text.height), fontSize: M.body, t.label3)
            }
        case .path(let s):
            var f = TextFieldControl(text: s)
            f.alignment = .left; f.fontSize = M.body
            f.draw(&c, in: r, theme: t, focused: false)
        }
    }
}
