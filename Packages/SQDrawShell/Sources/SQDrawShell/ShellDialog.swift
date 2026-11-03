import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// `SQDialog` translated onto the canvas: title, message and the footer of buttons on the overlay card (radius 12, .5 px edge)
/// centered over the dimmed window. Button roles, order, Return/Esc and Ctrl-D/Ctrl-S are `SQDialogModel` and the
/// `SQModal.response` rule, unchanged; the layout numbers are `SQDialogMetrics` / `Theme.Sheet` / `Theme.Modal`.
/// A form dialog sets `form` (the `SQDialog.accessoryView` + `SQDialogForm` rows): it sits between the header and the
/// footer, takes Tab, clicks and typing; Return and Esc still answer the dialog.
@MainActor
public final class ShellDialog {
    public typealias Response = SQDialogModel.Response

    // `Theme.Modal` / `Theme.Sheet` / `Theme.Dialog` (OverlayTokens.swift and ThemeTokens.swift are AppKit).
    enum M {
        static let widthS: CGFloat = 440
        /// `Theme.Modal.widthL` and `SQDialogMetrics.lBodyHeight` (heightL 640 - header 48 - footer 56 - side pad 20).
        static let widthL: CGFloat = 860
        static let heightL: CGFloat = 640
        static let lBodyHeight: CGFloat = 640 - 48 - 56 - 20
        static let radius: CGFloat = 12
        static let sidePad: CGFloat = 16
        static let headerTop: CGFloat = 20
        static let headerBottom: CGFloat = 12
        static let headerGap: CGFloat = 8
        static let titleLine: CGFloat = 13
        static let noteLine: CGFloat = 16
        static let footerGap: CGFloat = 8
        static let buttonHeight: CGFloat = 28
        static let alertFooterHeight: CGFloat = buttonHeight + sidePad
        /// The sheet look of a dialog with a form or content (`SQDialog.sheetHeader`, `SQDialogFooterBand`): a header of at
        /// least 48 with its text centered, `sidePad` under the body, a 56 high `titlebar` band with the buttons centered.
        static let bandHeaderHeight: CGFloat = 48
        static let bandFooterHeight: CGFloat = 56
        static let buttonPadding: CGFloat = 14
        static let mascotSide: CGFloat = 32   // art.html 09: Pip is 32 in the footer, smiling
        static let buttonGap: CGFloat = 8
        static let buttonRadius: CGFloat = 6
        static let titleFont: CGFloat = 13
        static let noteFont: CGFloat = 11
        static let wrapSlack: CGFloat = 5
        static let buttonFont: CGFloat = 11
        static let scrimAlpha: Float = 0.45
        static let scrimAlphaLight: Float = 0.25
        static let shadowBlur: CGFloat = 64, shadowDY: CGFloat = 24, shadowAlpha: Float = 0.55, shadowAlphaLight: Float = 0.2
        /// art.html `.db` padding: 14 above the first form row (a 22 pt field in its 26 pt row then sits 16 under the hairline).
        static let formTopPad: CGFloat = 14
        /// Header icon (art.html `.dh .hi`, 14 pt) and its gap to the title (`.dh` gap 10).
        static let headerIconSize: CGFloat = 14, headerIconGap: CGFloat = 10
        static let hairHeight: CGFloat = 1
        /// Space kept between a tall card and the window edge; the form scrolls inside the card instead (the Mac modal's
        /// scroll view around a long settings page).
        static let windowMargin: CGFloat = 24
        static let scrollBarWidth: CGFloat = 4
    }

    public var messageText = ""
    public var informativeText = ""
    public private(set) var model = SQDialogModel()
    public var canClose: (@MainActor (Response) -> Bool)?
    public var completion: (@MainActor (Response) -> Void)?
    /// Form body (`SQDialog.accessoryView`), nil for an alert.
    /// A drawn part under the form (the card import browser): it gets its own frame, its events and its drawing.
    public var content: ShellDialogContent? {
        didSet { content?.openPopup = { [weak self] items, below in self?.menu.popUp(items: items, below: below) } }
    }
    public private(set) var contentFrame: CGRect = .zero
    public var form: ShellForm? {
        didSet { form?.openPopup = { [weak self] _, items, below in self?.menu.popUp(items: items, below: below) } }
    }
    /// Card width: `Theme.Modal.widthS` for alerts; form dialogs pick theirs (`widthM` 600 for the long forms).
    public var width: CGFloat = M.widthS
    /// A fixed card height (`SQDialog.cardHeight`, the L modal's 640): the card keeps it whatever the form's length, the
    /// form scrolls inside it or leaves room under it (Preferences keeps its size across pages). nil: fits the content.
    public var cardHeight: CGFloat?
    /// The content brings its own header (the Export sheet's title row): no title block, the content starts at the card's
    /// top and ends at the footer band.
    public var headerless = false
    /// Text at the left of the footer band (`ExportDialogView`'s output summary), read at every draw.
    public var footerNote: (@MainActor () -> String)?
    /// A status line right aligned in the footer band, 8 pt left of the leftmost trailing button (Card Import's
    /// "N selected"), read at every draw.
    public var footerStatus: (@MainActor () -> String)?
    /// What Esc answers when the dialog has no Cancel button (Card Import closes with Esc only); nil = the Cancel button's.
    public var escapeResponse: Response?
    /// The New Project footer (`NewProjectSheet` band): a 44 pt preview box with the aspect as a clip-colored rectangle,
    /// a strong first line and a caption line beside it; read at every draw, replaces `footerNote`.
    public var footerSummary: (@MainActor () -> FooterSummary)?
    public struct FooterSummary: Equatable, Sendable {
        public var line1: String, line2: String
        /// Width / height of the preview rectangle.
        public var aspect: CGFloat
        public init(line1: String, line2: String, aspect: CGFloat) { self.line1 = line1; self.line2 = line2; self.aspect = aspect }
    }
    /// A close button at the right of the header (`SQButton(symbol: .close)`, tip "Close (Esc)"): answers like Esc.
    public var closeButton = false
    /// Header type of the start-screen sheets (`NewProjectSheet`: title 15 semibold, note 12); nil = the dialog's 13 / 12.
    public var headingFontSize: CGFloat?
    public private(set) var closeFrame: CGRect = .zero
    /// Fixed button widths by index (`NewProjectSheet`: Create 104, Cancel 76); others fit their title.
    public var buttonWidths: [Int: CGFloat] = [:]
    /// A key hint drawn after a button's title (`"Create  ⏎"`), kept out of the localized title.
    public var buttonHints: [Int: String] = [:]
    private var closeHovered = false
    private var closePressed = false
    /// Whether button `i` takes clicks and Return (`SQButton.isEnabled`); nil: all enabled.
    public var buttonEnabled: (@MainActor (Int) -> Bool)?
    /// An alert that the Mac shows as a sheet (band footer, 56 pt header: the Reconnect Media sheet) without a form or content.
    public var sheetStyle = false
    /// Pip at the left of the footer band (the Mac `SQDialog.footerRow(left: [SQMascotPlace...makeView()])`): the host draws
    /// him over `mascotFrame` (26 pt, `sidePad` from the left, centered in the band); zero when off.
    public var footerMascot = false
    public private(set) var mascotFrame: CGRect = .zero
    /// Sheet look (header band, footer band): every dialog with a form or a drawn content; alerts keep the plain card.
    public var isSheet: Bool { form != nil || content != nil || sheetStyle }
    /// Popup lists of the form's popup rows.
    public let menu = MenuController()

    public private(set) var card: CGRect = .zero
    public private(set) var buttonFrames: [Int: CGRect] = [:]
    /// Buttons drawn as ghost (no fill at rest, art.html `.btn.ghost`), by index.
    /// A second, gray header word after the title (the Settings page name).
    public var headerSubtitle: String?
    /// A state icon before the title (art.html `.dh .hi`: amber triangle on warnings, red on errors).
    public enum Tone: Sendable { case warning, error }
    public var headerIcon: Tone?
    public var ghostButtons: Set<Int> = []
    private var autoFocused = false
    private var titleLines: [String] = []
    /// Height of the header band above its hairline (0 = no title).
    private var headerBand: CGFloat = 0
    /// Form sheets with a note: 48 pt title band, the note in the body below it (art.html `.dlg`).
    private var noteInBody = false
    private(set) var noteLines: [String] = []
    public private(set) var hovered: Int?
    public private(set) var pressed: Int?
    /// Keyboard focus (Tab moves it): starts on Cancel in destructive dialogs (`initialFocusIndex`).
    public private(set) var focused: Int?
    public private(set) var finished = false
    /// The visible part of the form (window points) and how far it is scrolled; the whole form when it fits.
    public private(set) var formViewport: CGRect = .zero
    public private(set) var formScroll: CGFloat = 0
    private var formHeight: CGFloat = 0
    private var lastWindow: CGRect = .zero
    private var lastMeasure: TextMeasure?
    private var textTop: CGFloat = 0

    /// art.html `.frm` label columns by dialog title (each dialog has its own: 56 ... 104).
    static let labelColumns: [String: CGFloat] = [
        "Rename Workspace": 56, "Save as New Workspace": 56, "Marker": 64, "Clip Marker": 64, "Go to Timecode": 64,
        "New Color Matte": 64, "Tone Settings": 72, "Track Volume and Pan": 64, "Sequence Volume": 64, "Speed": 72,
        "Change Format": 96, "Duplicate as Format": 96, "Create Angles Clip": 80, "Create Captions": 96, "Punch In Cuts": 64,
        "Remove Silences": 96, "Anonymize": 64, "Check Cuts": 80, "New Sequence": 96, "Sequence Settings": 104,
    ]

    public init(_ message: String = "", informative: String = "") { messageText = message; informativeText = informative }

    /// The title's line height: `M.titleLine`, or 20 for a 15 pt heading (`NewProjectSheet` title frame).
    var titleIndent: CGFloat { headerIcon == nil ? 0 : M.headerIconSize + M.headerIconGap }
    var titleLine: CGFloat { headingFontSize.map { ($0 + 5).rounded() } ?? M.titleLine }

    @discardableResult
    public func addButton(_ title: String, role: SQDialogModel.Role = .normal, leading: Bool = false) -> SQDialogModel.Button {
        let b = SQDialogModel.Button(title: title, role: role, leading: leading)
        model.buttons.append(b)
        return b
    }

    // MARK: Layout (`SQDialog.layout` + `cardContent` + `footerRow`, alert form: no band)

    public func layout(in window: CGRect, measure m: TextMeasure) {
        if model.buttons.isEmpty { addButton("OK", role: .default) }
        if !autoFocused { autoFocused = true; if form?.focusFirstTextField() == true { focused = nil } }
        if focused == nil, form?.focused == nil { focused = model.initialFocusIndex }
        let width = self.width, content = width - 2 * M.sidePad
        let titleSize = headingFontSize ?? M.titleFont
        titleLines = messageText.isEmpty ? [] : m.lines(SQL10n.string(messageText), width: content - (closeButton ? M.buttonHeight : 0) - titleIndent,
                                                        size: titleSize)
        // shortcut: the atlas has no kerning, so its advances run ~1% wider than the Mac's NSTextField; the wrap gets that slack
        // (a 69-character note that fits the 400 pt column on the Mac must not break before its last word). Upgrade: kerned measure.
        noteLines = informativeText.isEmpty ? [] : m.lines(SQL10n.string(informativeText), width: content, size: M.noteFont)
        let sheet = isSheet
        form?.fixedLabelColumn = Self.labelColumns[messageText]
        var text = M.headerTop + CGFloat(titleLines.count) * titleLine
        if !titleLines.isEmpty, !noteLines.isEmpty { text += M.headerGap }
        text += CGFloat(noteLines.count) * M.noteLine + M.headerBottom
        // The start-sheet header (`NewProjectSheet`): title at 10, note at 31 in the 48 head, the form `sidePad` below it.
        if headingFontSize != nil, sheet { text = M.bandHeaderHeight + M.sidePad }
        if headerless { titleLines = []; noteLines = []; text = 0 }
        // An alert has the sheet bands too (art.html `.dlg`): a 48 header with the title, the note in the body, a 56 footer.
        let alert = !sheet && !headerless
        if alert {
            let body = noteLines.isEmpty ? 0 : M.sidePad + CGFloat(noteLines.count) * M.noteLine + M.sidePad
            text = (titleLines.isEmpty ? 0 : M.bandHeaderHeight) + body
        }
        noteInBody = sheet && !headerless && headingFontSize == nil && !titleLines.isEmpty && !noteLines.isEmpty
        if noteInBody { text = M.bandHeaderHeight + M.sidePad + CGFloat(noteLines.count) * M.noteLine + M.headerBottom }
        var h = sheet && !headerless ? max(text, M.bandHeaderHeight) : text
        textTop = headingFontSize != nil || alert || noteInBody ? 0 : ((h - text) / 2).rounded()
        headerBand = alert ? (titleLines.isEmpty ? 0 : M.bandHeaderHeight) : (headerless || titleLines.isEmpty ? 0 : (headingFontSize != nil || noteInBody ? M.bandHeaderHeight : h))
        // A form right under a plain 48 header (no note, no start-sheet heading) keeps `.db`'s 14 above its first row.
        if let form, form.sidebar == nil, headingFontSize == nil, !noteInBody, !headerless, !titleLines.isEmpty {
            h += M.formTopPad
        }
        let formTop = h
        lastWindow = window; lastMeasure = m
        formHeight = 0
        if let form {
            form.measure = m
            formHeight = form.height(width: width)
            h += formHeight + (sheet ? 0 : M.headerBottom)
        }
        let contentTop = h
        var contentHeight = self.content?.height(width: width) ?? 0
        let footer = sheet ? (headerless ? 0 : M.sidePad) + M.bandFooterHeight : M.bandFooterHeight
        if let fixed = cardHeight, self.content != nil, form == nil {
            // `SQDialog.cardHeight` with a drawn body: header and footer keep their height, the body takes the rest.
            let room = window.height > 0 ? min(fixed, max(window.height - 2 * M.windowMargin, 0)) : fixed
            contentHeight = max(room - h - footer, 120)
        }
        if self.content != nil { h += contentHeight }
        h += footer
        // A form taller than the window scrolls inside a card that keeps the window margin.
        let room = max(window.height - 2 * M.windowMargin, 0)
        var visible = formHeight
        if let fixed = cardHeight, form != nil {
            let target = room > 0 ? min(fixed, room) : fixed
            visible = max(formHeight + (target - h), min(formHeight, 80))
            h += visible - formHeight
        } else if form != nil, h > room, room > 0 {
            visible = max(formHeight - (h - room), min(formHeight, 80))
            h -= formHeight - visible
        }
        formScroll = min(max(formScroll, 0), max(formHeight - visible, 0))
        card = CGRect(x: (window.midX - width / 2).rounded(), y: (window.midY - h / 2).rounded(.down), width: width, height: h)   // the Mac sheet origin floors an odd half point
        // `NewProjectSheet`: the close button 12 from the right edge, centered in the 48 header.
        closeFrame = closeButton && !headerless
            ? CGRect(x: card.maxX - 12 - M.buttonHeight, y: card.minY + ((M.bandHeaderHeight - M.buttonHeight) / 2).rounded(),
                     width: M.buttonHeight, height: M.buttonHeight)
            : .zero
        // A first row drawn above the form top (`extraGapBefore[0] < 0`, the Mac accessory field's frame) is not clipped while unscrolled.
        let bleed = formScroll == 0 ? max(0, -(form?.extraGapBefore[0] ?? 0)) : 0
        formViewport = CGRect(x: card.minX, y: card.minY + formTop - bleed, width: width, height: visible + bleed)
        form?.sidebarShift = formScroll
        form?.viewportHeight = visible
        form?.layout(origin: CGPoint(x: card.minX, y: card.minY + formTop - formScroll), width: width)
        contentFrame = CGRect(x: card.minX, y: card.minY + contentTop - (formHeight - visible), width: width, height: contentHeight)
        self.content?.layout(contentFrame, measure: m)
        menu.bounds = window
        menu.measure = m

        // Footer: leading buttons at the left edge, the rest right aligned, 8 apart; centered in the band of a sheet, at the
        // top of the alert footer otherwise.
        let y = card.maxY - M.bandFooterHeight + ((M.bandFooterHeight - M.buttonHeight) / 2).rounded()
        var left = card.minX + M.sidePad
        mascotFrame = .zero
        if footerMascot, sheet {
            mascotFrame = CGRect(x: left, y: y + ((M.buttonHeight - M.mascotSide) / 2).rounded(), width: M.mascotSide, height: M.mascotSide)
        }
        let order = model.displayOrder
        let p = model.primaryIndex
        let leading = order.filter { model.buttons[$0].isLeading && $0 != p }
        let trailing = order.filter { !leading.contains($0) }
        buttonFrames = [:]
        for i in leading {
            let w = buttonWidth(i, m)
            // art.html footer-left slot: a ghost button's label starts at the 17 pt inset (the box reaches into the padding).
            let ghostShift = ghostButtons.contains(i) ? M.buttonPadding - 1 : 0
            buttonFrames[i] = CGRect(x: left - ghostShift, y: y, width: w, height: M.buttonHeight)
            left += w + M.buttonGap - ghostShift
        }
        var right = card.maxX - M.sidePad
        for i in trailing.reversed() {
            let w = buttonWidth(i, m)
            right -= w
            buttonFrames[i] = CGRect(x: right, y: y, width: w, height: M.buttonHeight)
            right -= M.buttonGap
        }
    }

    /// True when the form is taller than its viewport.
    public var formScrolls: Bool { formHeight > formViewport.height + 0.5 }

    /// Scrolls the form by `dy` points (positive = further down) and lays it out again.
    public func scrollForm(by dy: CGFloat) {
        guard formScrolls, let m = lastMeasure else { return }
        formScroll += dy
        layout(in: lastWindow, measure: m)
    }

    /// Back to the top (a new Preferences page).
    public func resetFormScroll() {
        guard formScroll != 0, let m = lastMeasure else { return }
        formScroll = 0
        layout(in: lastWindow, measure: m)
    }

    /// Brings the focused row into the viewport (Tab through a long form).
    private func revealFocusedRow() {
        guard formScrolls, let form, let f = form.focused, form.rowFrames.indices.contains(f) else { return }
        let r = form.rowFrames[f]
        if r.minY < formViewport.minY { scrollForm(by: r.minY - formViewport.minY) }
        else if r.maxY > formViewport.maxY { scrollForm(by: r.maxY - formViewport.maxY) }
    }

    private func buttonWidth(_ i: Int, _ m: TextMeasure) -> CGFloat {
        if let w = buttonWidths[i] { return w }
        return ceil(m.width(buttonTitle(i), size: M.buttonFont, face: m.medium)) + 2 * M.buttonPadding   // the Mac SQButton has no minimum width (`OK` is 46 pt)
    }

    func buttonTitle(_ i: Int) -> String {
        let title = SQL10n.string(model.buttons[i].title)
        return buttonHints[i].map { title + "  " + $0 } ?? title
    }

    // MARK: Responses

    /// `SQModal.response` with the shared-toolkit keys: Enter = the focused button else the main action, Esc and Ctrl-. =
    /// Cancel, Ctrl-D = Don't Save, Ctrl-S = Save.
    public func response(for key: InputKey, _ mods: InputModifiers) -> Response? {
        if mods.contains(.option) { return nil }
        if mods.contains(.command) {
            guard case .character(let c) = key else { return nil }
            switch c.lowercased() {
            case ".": return model.response(forReturn: false)
            case "d": return model.dontSaveIndex.map { Response($0) }
            case "s": return model.saveIndex.map { Response($0) }
            default: return nil
            }
        }
        switch key {
        case .escape: return escapeResponse ?? model.response(forReturn: false)
        case .enter: return focused.map { Response($0) } ?? model.response(forReturn: true)
        case .space: return focused.map { Response($0) }
        default: return nil
        }
    }

    public func isEnabled(_ i: Int) -> Bool { buttonEnabled?(i) ?? true }

    public func press(_ r: Response) {
        guard !finished, isEnabled(r.rawValue) else { return }
        if let canClose, !canClose(r) { return }
        finished = true
        let c = completion
        completion = nil
        c?(r)
    }

    /// Modal: the dialog takes every event while it shows.
    public func handle(_ e: InputEvent, scale: Float) {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        func hit(_ p: CGPoint) -> Int? { buttonFrames.first { $0.value.contains(p) }?.key }
        if menu.isOpen { _ = menu.handle(e, scale: scale); return }
        if closeFrame.width > 0 {
            switch e {
            case .mouseDown(let x, let y, _) where closeFrame.contains(pt(x, y)): closePressed = true; return
            case .mouseUp(let x, let y) where closePressed:
                closePressed = false
                if closeFrame.contains(pt(x, y)), let r = model.response(forReturn: false) { press(r) }
                return
            case .mouseMoved(let x, let y), .mouseDragged(let x, let y):
                closeHovered = closeFrame.contains(pt(x, y))
                if closeHovered { HostHover.current.offerTip(SQL10n.string("Close (Esc)")) }
            default: break
            }
        }
        if let content {
            switch e {
            case .mouseDown(let x, let y, _) where contentFrame.contains(pt(x, y)): _ = content.handle(e, scale: scale); return
            case .mouseDown: break
            default: if content.handle(e, scale: scale) { return }
            }
        }
        if let form, form.pickerOpen {
            switch e {
            case .keyDown(let k, let m): form.pickerKey(k, m)
            case .mouseDown(let x, let y, _): form.pickerMouseDown(pt(x, y))
            case .mouseDragged(let x, let y): form.pickerMouseDragged(pt(x, y))
            case .mouseUp: form.pickerMouseUp()
            default: break
            }
            return
        }
        if let form {
            switch e {
            case .keyDown(let k, let m):
                if k == InputKey.tab, form.focused == nil, !m.contains(.shift) { focused = nil }
                if form.key(k, m) { if form.focused != nil || form.sidebarFocused { focused = nil; revealFocusedRow() }; return }
                if k == InputKey.tab { if focused == nil { focused = model.primaryIndex }; return }
                if k == .enter || k == .escape { if k == .enter { form.commitEditing() } }
            case .mouseDown(let x, let y, _):
                let p = pt(x, y)
                if hit(p) == nil {
                    if formViewport.contains(p), form.mouseDown(p) { focused = nil }
                    return
                }
                form.commitEditing()
            case .mouseDragged(let x, let y): form.mouseDragged(pt(x, y))
            case .mouseUp: form.mouseUp()
            case .mouseMoved(let x, let y):
                let p = pt(x, y)
                form.mouseMoved(formViewport.contains(p) ? p : CGPoint(x: -1, y: -1))
            case .scroll(_, _, _, let dy, _):
                scrollForm(by: -CGFloat(dy / scale))
                return
            }
        }
        switch e {
        case .keyDown(let k, let m):
            if case .character(let c) = k, c == "\t" { return }
            if k == .left || k == .right {
                let order = model.displayOrder
                let at = focused.flatMap { order.firstIndex(of: $0) } ?? (k == .left ? order.count : -1)
                let next = at + (k == .right ? 1 : -1)
                if order.indices.contains(next) { focused = order[next] }
                return
            }
            if let r = response(for: k, m) { press(r) }
        case .mouseMoved(let x, let y): hovered = hit(pt(x, y))
        case .mouseDown(let x, let y, _): pressed = hit(pt(x, y))
        case .mouseDragged(let x, let y): hovered = hit(pt(x, y))
        case .mouseUp(let x, let y):
            if let p = pressed, hit(pt(x, y)) == p { press(Response(p)) }
            pressed = nil
        case .scroll: break
        }
    }

    // MARK: Drawing (`SQDialogCardView`, `SQButton`)

    public func draw(_ c: inout Canvas, theme t: DrawTheme, window: CGRect) {
        c.fill(window, DrawColor(0, 0, 0, t.palette.isDark ? M.scrimAlpha : M.scrimAlphaLight))
        c.shadow(roundedRect: card, radius: M.radius, blur: M.shadowBlur, dy: M.shadowDY,
                 DrawColor(0, 0, 0, t.palette.isDark ? M.shadowAlpha : M.shadowAlphaLight), opaqueAbove: true)
        // `SQDialogStyle.styleCard`: `panel` fill; a sheet's footer band is the card's bottom in `panel` with a hairline above.
        c.fill(roundedRect: card, radius: M.radius, t.panel)
        if headerBand > 0 { c.fill(CGRect(x: card.minX, y: card.minY + headerBand - M.hairHeight, width: card.width, height: M.hairHeight), t.hair) }
        if !headerless {
            let band = CGRect(x: card.minX, y: card.maxY - M.bandFooterHeight, width: card.width, height: M.bandFooterHeight)
            c.saveGState()
            c.clip(to: band)
            c.fill(roundedRect: card, radius: M.radius, t.panel)
            c.restoreGState()
            c.fill(CGRect(x: band.minX, y: band.minY, width: band.width, height: M.hairHeight), t.hair)
            if let status = footerStatus?() {
                let trailing = model.displayOrder.filter { !(model.buttons[$0].isLeading && $0 != model.primaryIndex) }
                let left = trailing.compactMap { buttonFrames[$0]?.minX }.min() ?? band.maxX - M.sidePad
                c.draw(status, in: CGRect(x: band.minX + M.sidePad, y: band.minY, width: max(left - 8 - band.minX - M.sidePad, 0),
                                          height: band.height), fontSize: M.noteFont, t.label3, align: .right)
            }
            if let s = footerSummary?() {
                drawFooterSummary(&c, s, band: band, t)
            } else if let note = footerNote?(), !note.isEmpty {
                let right = buttonFrames.values.map(\.minX).min() ?? band.maxX
                c.draw(note, in: CGRect(x: band.minX + M.sidePad, y: band.minY, width: max(right - band.minX - 2 * M.sidePad, 0),
                                        height: band.height), fontSize: M.noteFont, t.label2)
            }
        }
        c.stroke(roundedRect: card.insetBy(dx: 0.25, dy: 0.25), radius: M.radius, width: 0.5, MenuListView.overlayEdge(t))
        let startHeader = headingFontSize != nil && isSheet
        let alert = !isSheet && !headerless
        var y = card.minY + (startHeader ? 10 : (alert || noteInBody ? ((M.bandHeaderHeight - titleLine) / 2).rounded() + 1 : textTop + M.headerTop))
        // The start sheet's header labels are NSTextFields: 2 pt of cell padding before the text.
        let x0 = card.minX + M.sidePad + (startHeader ? 2 : 0)
        let x = x0 + titleIndent, w = card.width - 2 * M.sidePad - titleIndent
        if let tone = headerIcon, !titleLines.isEmpty {
            let iy = y - 1 + ((titleLine - M.headerIconSize) / 2).rounded()
            if tone == .error {
                // art.html 01: a circle with an exclamation mark (ring, bar, dot), drawn from primitives.
                let r = CGRect(x: x0, y: iy, width: M.headerIconSize, height: M.headerIconSize)
                c.stroke(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), radius: r.width / 2, width: 1.5, t.errText)
                let bar = CGRect(x: r.midX - 0.75, y: r.minY + 3.5, width: 1.5, height: 4.5)
                let dot = CGRect(x: r.midX - 0.85, y: r.minY + 9, width: 1.7, height: 1.7)
                c.fill(roundedRect: bar, radius: bar.width / 2, t.errText)
                c.fill(roundedRect: dot, radius: dot.width / 2, t.errText)
            } else {
                c.draw(icon: .warning, at: CGPoint(x: x0, y: iy), size: M.headerIconSize, t.warning)
            }
        }
        // `Theme.Sheet.alertTitleFont`: 13 semibold.
        let titleSize = headingFontSize ?? M.titleFont
        for l in titleLines {
            c.draw(l, in: CGRect(x: x, y: y - 1, width: w, height: titleLine), fontSize: titleSize, t.label,
                   face: c.semibold)
            y += titleLine
        }
        // Settings: the page name after the title, `t3` (art.html `.dh` subtitle).
        if let sub = headerSubtitle, !titleLines.isEmpty {
            let tw = c.size(of: titleLines[0], fontSize: titleSize, face: c.semibold).width
            c.draw(SQL10n.string(sub), in: CGRect(x: x + tw + 10, y: y - titleLine * CGFloat(titleLines.count) - 1, width: max(w - tw - 10, 0), height: titleLine),
                   fontSize: M.noteFont, t.label3)
        }
        if alert || noteInBody { y = card.minY + headerBand + M.sidePad + 1 }
        else if !titleLines.isEmpty, !noteLines.isEmpty { y += startHeader ? 1 : M.headerGap }
        // art.html 00/01/02/09: the body of an alert sits at the card's left padding, under the icon's edge, not under the title.
        let noteX = alert || noteInBody ? x0 : x, noteW = card.width - 2 * M.sidePad - (alert || noteInBody ? 0 : titleIndent)
        for l in noteLines {
            c.draw(l, in: CGRect(x: noteX, y: startHeader ? y : y - 1, width: noteW + M.wrapSlack, height: M.noteLine), fontSize: M.noteFont,
                   startHeader ? t.label3 : t.label2)
            y += M.noteLine
        }
        if let form {
            c.saveGState()
            c.clip(to: formViewport)
            form.overlayBounds = window
            form.draw(&c, theme: t)
            c.restoreGState()
            if formScrolls {
                // The overlay scroller of the Mac scroll view: a thin knob at the right edge of the viewport.
                let track = formViewport.insetBy(dx: 0, dy: 2)
                let knobH = max(track.height * formViewport.height / formHeight, 24)
                let travel = max(formHeight - formViewport.height, 1)
                let y = track.minY + (track.height - knobH) * formScroll / travel
                c.fill(roundedRect: CGRect(x: track.maxX - M.scrollBarWidth - 4, y: y, width: M.scrollBarWidth, height: knobH),
                       radius: M.scrollBarWidth / 2, t.label3)
            }
        }

        if let content {
            c.saveGState()
            c.clip(to: contentFrame)
            content.draw(&c, theme: t)
            c.restoreGState()
        }
        defer { form?.drawOverlay(&c, theme: t) }
        for (i, r) in buttonFrames {
            let b = model.buttons[i]
            let main = i == model.primaryIndex && b.role != .destructive
            let on = isEnabled(i)
            let down = pressed == i && on, over = hovered == i && on
            // art.html `.btn`: secondary = raised + 0.5 hair2 ring, primary = accent fill, ghost = clear (hover `hover`), danger = secondary
            // with err text, disabled = t4 text on `hover`, disabled primary = accent .30.
            if main {
                var fill = on ? t.accentFill : t.accentFill.alpha(0.30)
                if down { fill = fill.lifted(-0.1) } else if over { fill = fill.lifted(0.1) }
                c.fill(roundedRect: r, radius: M.buttonRadius, fill)
            } else if ghostButtons.contains(i) {
                if down { c.fill(roundedRect: r, radius: M.buttonRadius, t.current) } else if over { c.fill(roundedRect: r, radius: M.buttonRadius, t.hover) }
            } else if !on {
                c.fill(roundedRect: r, radius: M.buttonRadius, t.hover)
            } else {
                c.fill(roundedRect: r, radius: M.buttonRadius, down ? t.pressed : (over ? t.raisedHover : t.raised))
                c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: M.buttonRadius, width: 0.5, t.hair2)
            }
            // art.html `.btn.focus`: a 2 px gap, then a 2 px accent ring.
            if focused == i { c.stroke(roundedRect: r.insetBy(dx: -3, dy: -3), radius: M.buttonRadius + 3, width: 2, t.accent) }
            var text: DrawColor = main ? .white : (b.role == .destructive ? t.errText : (ghostButtons.contains(i) ? (over || down ? t.label : t.label2) : t.label))
            if !on { text = main ? DrawColor.white.alpha(0.45) : t.label4 }
            c.draw(buttonTitle(i), in: r.offsetBy(dx: 0, dy: 1), fontSize: M.buttonFont, text, align: .center, face: c.medium)
        }
        if closeFrame.width > 0 {
            if closePressed || closeHovered {
                c.fill(roundedRect: closeFrame, radius: M.buttonRadius, closePressed ? t.fillPressed : t.fillHover)
            }
            c.draw(icon: .close, at: CGPoint(x: closeFrame.midX - 7, y: closeFrame.midY - 7), size: 14, t.label2)
        }
        menu.draw(&c, theme: t)
    }

    /// `NewProjectSheet` footer: preview 44 at 20, text 14 after it (12 semibold label / 11 label3), up to the buttons.
    private func drawFooterSummary(_ c: inout Canvas, _ s: FooterSummary, band: CGRect, _ t: DrawTheme) {
        let box = CGRect(x: band.minX + M.sidePad, y: band.minY + ((band.height - 44) / 2).rounded(), width: 44, height: 44)
        c.fill(roundedRect: box, radius: CGFloat(DrawTheme.Radius.overlay), t.content)
        let side: CGFloat = 28, a = max(s.aspect, 0.05)
        let w = a >= 1 ? side : side * a, h = a >= 1 ? side / a : side
        let r = CGRect(x: box.minX + ((box.width - w) / 2).rounded(), y: box.minY + ((box.height - h) / 2).rounded(), width: w,
                       height: max(h, 2))
        c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.clip(.videoDefault).alpha(0.85))
        let x = box.maxX + 14   // measured against the Mac footer: the text starts 14 after the box
        let right = (buttonFrames.values.map(\.minX).min() ?? band.maxX) - 16
        let tw = max(right - x, 0)
        c.draw(s.line1, in: CGRect(x: x, y: band.midY - 16, width: tw, height: 16), fontSize: 12, t.label, face: c.semibold)
        c.draw(s.line2, in: CGRect(x: x, y: band.midY + 1, width: tw, height: 14), fontSize: 11, t.label3)
    }
}

/// The drawn part of a dialog under its form (`ShellDialog.content`). `handle` gets every event while the dialog shows
/// (presses only inside its frame); true = taken, the dialog's own keys and buttons do not see it.
@MainActor public protocol ShellDialogContent: AnyObject {
    var openPopup: ((_ items: [SQMenuItem], _ below: CGRect) -> Void)? { get set }
    func height(width: CGFloat) -> CGFloat
    func layout(_ frame: CGRect, measure: TextMeasure)
    func draw(_ c: inout Canvas, theme: DrawTheme)
    func handle(_ e: InputEvent, scale: Float) -> Bool
}
