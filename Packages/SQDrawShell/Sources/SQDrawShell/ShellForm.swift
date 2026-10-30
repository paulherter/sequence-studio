import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// The body of a form dialog: `SQDialogForm` and the `SQDialog.formRow` / `checkRow` / `popupRow` / `sliderRow` / `radioRow`
/// builders translated onto the canvas. Rows stack edge to edge with `Theme.Sheet.formRowGap`; a label column of 104 pt
/// (right of the 20 pt card edge, 16 pt gap) and the controls filling the rest, as on the Mac. The controls are the shared
/// toolkit ones (`TextFieldControl`, `InspectorDraw.popup` / `checkbox` / `slider`), so dialogs look like the panels.
/// Values live in `values` under each row's `id`; the caller reads them when the dialog answers.
/// A form with a `Sidebar` (Preferences: the Mac `SettingsWindow` page list) draws the page list in a left column with
/// a rule after it and the rows to its right; a click on a page answers `onChange(sidebar.id, .index(page))`.
/// The sidebar is the first Tab stop (Up/Down pick the page, as the Mac list) and stays put while a long page scrolls
/// (`sidebarShift`, set by the dialog).
@MainActor
public final class ShellForm {
    public enum Row: Equatable {
        /// A note line (`SQDialog.formText`), wrapped to the card.
        case text(String)
        /// "Label [field]" with a free text field (names, numbers with `unit`).
        case field(id: String, label: String, value: String, unit: String = "")
        /// "Label [popup]".
        case popup(id: String, label: String, options: [String], selected: Int)
        /// "Label [color well]" (`SQColorWell` in `SQDialog.formRow`): a swatch that opens the SQ color picker under it.
        /// The value answers through `color(id)`.
        case color(id: String, label: String, value: SQColorValue)
        /// A check box row (`SQDialog.checkRow`).
        case check(id: String, title: String, on: Bool)
        /// "Label [slider] [field]" (`SQDialog.sliderRow`), value in `range`.
        case slider(id: String, label: String, value: Double, range: ClosedRange<Double>, unit: String = "")
        /// "Label [slider] [number field] unit" (the Mac `NumericSlider` in `SQDialog.formRow`): the slider spans the field's
        /// `range`, the plain field (72, 12 after the slider, no capsule until edited) shows the value in accent from its
        /// leading edge, and the unit sits after it in a column of at least 24, so every such row keeps one field edge.
        /// Values answer under the field's id.
        case sliderNumber(label: String, NumberField)
        /// A radio group, one row per option (`SQDialog.radioRow` without the trailing field).
        case radio(id: String, options: [String], selected: Int)
        /// "Label  detail text  [Button] [Button]" (the Mac `SQFormRow.row(..., extra: [buttons])`: a folder path with
        /// Choose… / Use Default, a list line with Restore Factory). A click answers `onChange(id, .index(button))`;
        /// `enabled` holds one flag per button (missing = enabled).
        case buttons(id: String, label: String, detail: String, titles: [String], enabled: [Bool] = [])
        /// "Label [number field] unit" (`SQDialog.formRow` with `SQDialog.makeNumberField`): a scrub field, the value in
        /// accent; with a unit 72 wide and the unit after it, without one it fills the row.
        case number(label: String, NumberField)
        /// A radio group whose options each carry a number field (`SQDialog.radioRow`: radio in a 190 column, the field
        /// after it), one form row per option. `fields` holds one field per option.
        case radioNumbers(id: String, options: [String], selected: Int, fields: [NumberField])
        /// A group heading (`SequenceSettingsSheet.groupCaption`): body size in `label3`, 8 pt above, at the card edge.
        case caption(String)
        /// "Frame Size [w] × [h] [swap]": two 72 pt number fields and the swap button (`SequenceSettingsSheet`); the swap
        /// trades the values and answers `onChange` for both fields.
        case size(label: String, width: NumberField, height: NumberField)
        /// "Label [segmented]" (`SQSegmented`, `segmentWidth` per segment).
        case segmented(id: String, label: String, options: [String], selected: Int, segmentWidth: CGFloat)
        /// Free space (pt).
        case gap(CGFloat)
        /// "Label" over an empty control line (`SQFormRow.row("J / L Offset", [], extra: [grid])`): the row's grid, status
        /// or help sits under it.
        case label(id: String, label: String)
        /// A note and a bar chart in the control column (`CutCheckSheetView`: summary in 11 pt `label2`, 8, the chart title
        /// in 11 pt medium, 8, a 110 pt chart).
        case chart(note: String, title: String, bars: [Bar])
        /// A multi-line text box over the whole form width, `height` pt high (`ProjectNotesDialog`): Return breaks the line,
        /// Esc and Tab leave it to the dialog.
        /// shortcut: lines do not wrap softly (a long line is clipped at the box edge); upgrade with a wrapping editor.
        case textBox(id: String, value: String, height: CGFloat)
        /// "Label [list box]" (`EffectDefaultsSettingsView`): a 440 pt `fill2` box with one 28 pt line per entry (title, a
        /// button right) or, with no entry, `empty` in `label3`. A button answers `onChange(id, .index(line))`.
        case listBox(id: String, label: String, lines: [String], button: String, empty: String)
    }

    /// One column of a `.chart` row (`ShotBucket`).
    public struct Bar: Equatable, Sendable {
        public var label: String
        public var count: Int
        public init(label: String, count: Int) { self.label = label; self.count = count }
    }

    /// One line of a number grid under a row (`SQFormRow.unitGrid`): title (11 pt `label3`) | 72 pt field | unit (`label3`).
    public struct GridCell: Equatable, Sendable {
        public var title: String
        public var field: NumberField
        public var unit: String
        public init(title: String, field: NumberField, unit: String = "") { self.title = title; self.field = field; self.unit = unit }
    }

    /// A status line under a row (the Mac Edit API row: an 8 pt dot, the text, an optional button). A click on the button
    /// answers `onChange("<row id>.status", .index(0))`.
    public struct Status: Equatable, Sendable {
        public enum Tone: Equatable, Sendable { case idle, ok, warning }
        public var text: String
        public var tone: Tone
        public var button: String?
        public var buttonIcon: SQIcon?
        public init(text: String, tone: Tone, button: String? = nil, buttonIcon: SQIcon? = nil) {
            self.text = text; self.tone = tone; self.button = button; self.buttonIcon = buttonIcon
        }
    }

    /// One `SQDialog.makeNumberField` (a `ScrubField`): drag, type, arrows, double-click resets to `defaultValue`. Its value
    /// lives in `values[id]` as `.number`.
    public struct NumberField: Equatable, Sendable {
        public var id: String
        public var value: Double
        public var range: ClosedRange<Double>
        public var step: Double
        public var decimals: Int
        public var unit: String
        public var defaultValue: Double?
        public init(id: String, value: Double, range: ClosedRange<Double>, step: Double = 1, decimals: Int = 0, unit: String = "",
                    defaultValue: Double? = nil) {
            self.id = id; self.value = value; self.range = range; self.step = step; self.decimals = decimals; self.unit = unit
            self.defaultValue = defaultValue
        }
    }

    /// The link toggle beside two number rows (the Speed sheet's speed/duration link): the rows end `sidePad + 24` earlier,
    /// the icon sits at the right edge between them; a click answers `onChange(id, .bool)`.
    public struct Link: Equatable, Sendable {
        public var id: String
        public var fields: [String]
        public init(id: String, fields: [String]) { self.id = id; self.fields = fields }
    }

    /// The page list of a sidebar form: icon and title per page, the selected one under `id`.
    public struct Sidebar {
        public var id: String
        public var items: [(title: String, icon: SQIcon)]
        public init(id: String, items: [(title: String, icon: SQIcon)]) { self.id = id; self.items = items }
    }

    public enum Value: Equatable, Sendable {
        case text(String), index(Int), bool(Bool), number(Double)
    }

    enum M {
        static let sidePad: CGFloat = 20
        /// A settings page starts 8 pt lower than its sidebar.
        static let pageTop: CGFloat = 8
        static let rowGap: CGFloat = 12
        /// Mac alignment-rect insets (NSTextField 2 pt each side, NSPopUpButton 5 pt on the left) of an unlabeled dialog row.
        static let fieldBleed: CGFloat = 2
        static let popupBleed: CGFloat = 5
        static let rowHeight: CGFloat = 28
        static let checkRowHeight: CGFloat = 24
        static let labelWidth: CGFloat = 104
        /// The label column grows to its longest label up to this (the Mac form's labels never truncate).
        static let labelMax: CGFloat = 160
        /// Settings pages (`SQFormRow`): `Theme.Modal.labelColumnL`, help lines at most `SQFormRow.helpMaxWidth`, 4 below.
        #if canImport(AppKit)
        static let settingsLabelWidth = Theme.Modal.labelColumnL
        #else
        static let settingsLabelWidth: CGFloat = 132   // `Theme.Modal.labelColumnL` (SQUIKit Theme is Mac-only)
        #endif
        static let helpMaxWidth: CGFloat = 440
        static let helpGap: CGFloat = 4
        static let captionFont: CGFloat = 10
        /// `Theme.Typography.body` (11) for labels and help on settings pages; its wrapped line height.
        static let settingsFont: CGFloat = 11
        static let settingsHelpLine: CGFloat = 14
        static let labelGap: CGFloat = 16
        static let controlGap: CGFloat = 8
        static let unitFieldWidth: CGFloat = 72
        static let sliderFieldWidth: CGFloat = 72
        /// `NumericSlider.unitColumn`: the narrowest unit column after a slider's field.
        static let unitColumn: CGFloat = 24
        static let noteLine: CGFloat = 16
        static let strongLine: CGFloat = 14
        static let font: CGFloat = 12
        static let buttonPadding: CGFloat = 14
        static let minButton: CGFloat = 64
        /// The sidebar column (`SettingsPage.sidebarWidth`, 200 in the Mac L modal).
        static let sidebarWidth: CGFloat = 200
        /// `Theme.Row.list + Theme.Spacing.xs`, `Theme.Spacing.xxs` apart, inset `Theme.Spacing.sm`.
        static let sidebarRow: CGFloat = 28
        static let sidebarGap: CGFloat = 2
        static let sidebarInset: CGFloat = 8
        /// `SQDialog.radioRow`: the radio and its title take 190 pt before the field.
        static let radioColumn: CGFloat = 206   // 190 label column + `labelGap` 16
        static let linkWidth: CGFloat = 24
        static let sizeField: CGFloat = 72
        static let timesWidth: CGFloat = 7
        static let captionTop: CGFloat = 8
        static let captionLine: CGFloat = 14
        /// Extra space under a Settings page caption: measured 10 pt more than the plain stack gap in the Mac render (`SQFormRow.caption`).
        static let captionAfter: CGFloat = 10
        /// `SQFormRow.unitGrid` spacing; the `ScrubField` after a check title (`SettingsWindow` Live Ducking amount).
        static let gridGap: CGFloat = 8
        static let statusDot: CGFloat = 8
        /// `CutCheckSheetView`: block spacing, chart title line, chart height; `ShotHistogramView` metrics.
        static let chartGap: CGFloat = 8
        static let chartTitleLine: CGFloat = 14
        static let chartHeight: CGFloat = 110
        static let chartBarMax: CGFloat = 64
        static let chartLine: CGFloat = 12
        static let chartInner: CGFloat = 3
        /// `ProjectNotesDialog`: 6 pt text inset, body size lines.
        static let boxInset: CGFloat = 6
        static let boxLine: CGFloat = 14
    }

    public private(set) var rows: [Row]
    public private(set) var values: [String: Value] = [:]
    private var colors: [String: SQColorValue] = [:]
    /// The open color picker popover of a `.color` row (dialog points), drawn above the dialog by `drawOverlay`.
    private var picker: ColorPickerControl?
    private var pickerRow = 0
    private var pickerFrame: CGRect = .zero
    private var pickerDragging = false
    /// The area the picker may use (the window); the dialog sets it before drawing.
    public var overlayBounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    public var pickerOpen: Bool { picker != nil }
    /// Every row's frame and its control's frame (window points, set by `layout`).
    public private(set) var rowFrames: [CGRect] = []
    public private(set) var controlFrames: [CGRect] = []
    private var noteLines: [Int: [String]] = [:]
    var fields: [Int: TextFieldControl] = [:]
    /// The number fields by field id, their boxes after layout, the one under the pointer press.
    var scrubs: [String: ScrubFieldControl] = [:]
    public internal(set) var scrubFrames: [String: CGRect] = [:]
    var pressedScrub: String?
    var clicks = ClickCounter()
    /// Rows and number fields (by id) drawn dimmed that take no input (the Mac's `isEnabled = false`). A radio option is
    /// disabled with its field's id.
    public var disabled: Set<String> = []
    public var link: Link?
    /// Fixed control widths by row id (the Mac's 120 pt rate popups); other controls fill the row.
    public var controlWidths: [String: CGFloat] = [:]
    /// Side padding of the rows (20; the Mac `NewProjectSheet` uses 24).
    public var sidePad: CGFloat = M.sidePad
    /// Extra space before a row by row index (the Mac `NewProjectSheet` adds 4 pt after Template and Outside files).
    public var extraGapBefore: [Int: CGFloat] = [:]
    /// Text field heights by row id, centered in the 28 pt row (the Mac `Theme.Row.control` 22 pt name field).
    public var labeledFieldBleed = true
    /// The dialog text field's font: `SQTextField` is `Typography.body` (11); New Project's own fields are 12.
    public var dialogFieldFontSize = CGFloat(DrawTheme.TypeSize.body)
    /// A labeled popup's frame bleeds 5 pt left of the control column, as on a settings page (`SQDialog.formRow` popups).
    public var labeledPopupBleed = false
    /// Inset of the label column and the hints from their frames (an `NSTextField` label keeps 2 pt of cell padding).
    public var labelInset: CGFloat = 0
    public var fieldHeights: [String: CGFloat] = [:]
    /// A gray hint after a row's control by row id (`NewProjectSheet.hintAfter`: the template summary, "9:16 · px").
    public var hints: [String: String] = [:]
    /// `.size` rows (by their width field id) laid out as the Mac `NewProjectSheet`: W, the swap button, H, no "×"; the
    /// field width comes from `controlWidths[widthID]`.
    public var swapBetween: Set<String> = []
    /// `.size` rows (by their width field id) without the swap button, filling the control column as the Mac
    /// `ChangeFormatDialog`: W at the left, H ending at the right edge (`controlWidths[widthID]` each), "×" centered between.
    public var plainSize: Set<String> = []
    /// A `.listBox` line with more than its name (by row id, per line): an icon before the name, a gray detail after it and an
    /// optional warning word (the Mac Library Folders list: folder icon, name, `~` path, "unavailable").
    public struct ListLine: Equatable, Sendable {
        public var icon: SQIcon?
        public var detail: String
        public var warning: String?
        public init(icon: SQIcon? = nil, detail: String = "", warning: String? = nil) {
            self.icon = icon; self.detail = detail; self.warning = warning
        }
    }
    public var listLines: [String: [ListLine]] = [:]
    /// The Mac `SQMenuPopup` extras of a popup row: a key column per option (`SQMenuItem.shortcut`: "1080 × 1920", "Film"),
    /// group headers and separators before options, and a key drawn in the closed box left of the chevron ("9:16").
    public struct PopupStyle: Equatable, Sendable {
        public var keys: [String]
        public var headers: [Int: String]
        public var separatorBefore: Set<Int>
        public var boxKey: String
        /// A color dot (0xRRGGBB) per option: 8 pt before the title in the list and in the closed box (the Mac marker Color
        /// popup: dot 10 in, title 22 in).
        public var dots: [UInt32]
        /// Box height when taller than the 22 pt capsule (`NewProjectSheet` popups are 28); nil = the capsule.
        public var height: CGFloat?
        /// Title size when not the 11 pt body (the `NewProjectSheet` popups use its 12 pt label font).
        public var fontSize: CGFloat?
        public init(keys: [String] = [], headers: [Int: String] = [:], separatorBefore: Set<Int> = [], boxKey: String = "",
                    dots: [UInt32] = [], height: CGFloat? = nil, fontSize: CGFloat? = nil) {
            self.keys = keys; self.headers = headers; self.separatorBefore = separatorBefore; self.boxKey = boxKey; self.dots = dots; self.height = height; self.fontSize = fontSize
        }
    }
    public var popupStyles: [String: PopupStyle] = [:]
    /// Number grids under rows by row id (`setGrid`).
    public private(set) var grids: [String: [GridCell]] = [:]
    /// Number fields after a check row's title by check id (`setCheckField`), dimmed while the check is off.
    public private(set) var checkFields: [String: (field: NumberField, width: CGFloat)] = [:]
    /// Number fields whose value is drawn in `label` instead of accent (`ScrubField.valueTint = Theme.Colors.label`).
    public var labelTinted: Set<String> = []
    /// Status lines under rows by row id (`Status`); the host replaces them and lays out again.
    public var statuses: [String: Status] = [:]
    /// Frames of the extras under rows (grid titles, the status button), the box scroll, the open box editor.
    private var gridTitleFrames: [String: CGRect] = [:]
    private var statusFrames: [Int: CGRect] = [:]
    private var statusButtonFrames: [Int: CGRect] = [:]
    private var helpTops: [Int: CGFloat] = [:]
    private var chartParts: [Int: (title: CGFloat, chart: CGRect)] = [:]
    private var boxEditor: TextEditState?
    private var boxScroll: CGFloat = 0
    /// The grid or check field a click picked (its row is `focused`): keys go to it.
    private var focusedScrub: String?
    /// `.buttons` rows (by id) whose detail sits on a `fill` chip with an icon (`NewProjectSheet.PathChip`: folder icon,
    /// path in label2, truncated in the middle) and whose buttons have a fixed width (the Mac 92 pt Choose…).
    public struct Chip: Equatable, Sendable {
        public var icon: SQIcon
        public var buttonWidth: CGFloat
        public init(icon: SQIcon, buttonWidth: CGFloat) { self.icon = icon; self.buttonWidth = buttonWidth }
    }
    public var chips: [String: Chip] = [:]
    /// Help lines under a row's control by row id (`SQFormRow.row(help:)`: body size, `label3`, at most 440 wide, 4 below the
    /// control). Settings pages only.
    public var helps: [String: String] = [:]
    /// The row label of a check row by id (`SQFormRow.row("Recovery", checkItem(...))`): the label in the label column, the
    /// box in the control column.
    public var checkLabels: [String: String] = [:]
    /// Placeholder text of field rows by id (`placeholderString`: label3 in the empty field).
    public var placeholders: [String: String] = [:] {
        didSet { for (i, r) in rows.enumerated() { if case .field(let id, _, _, _) = r { fields[i]?.placeholder = placeholders[id] ?? "" } } }
    }
    /// Popup rows (by id) that sit at the end of the field row before them, `controlGap` apart, as wide as their longest
    /// option (the Mac `NSStackView([field, popup])` of the Find dialog). A field with an empty label starts at the card's
    /// inner edge (no label column).
    public var inlinePopups: Set<String> = []
    private var helpLines: [Int: [String]] = [:]
    public internal(set) var linkFrame: CGRect = .zero
    /// Text rows drawn in the warning color (`AudioGainDialog.setNote(warning:)`).
    var warningNotes: Set<Int> = []
    /// Text rows in `bodyStrong` (`label`, 14 pt lines): Remove Silences' preview line.
    var strongNotes: Set<Int> = []
    var plainStrongNotes: Set<Int> = []
    public private(set) var focused: Int?
    private var hovered: Int?
    private var hoveredPoint: CGPoint?
    private var dragging: Int?
    /// A single-line field pressed for text selection: the row, and the press point while the editor opened with that press
    /// (the first drag step then moves the anchor to it).
    private var selecting: (row: Int, start: CGPoint?)?
    public var measure = TextMeasure(atlas: nil, scale: 1)
    /// The label column of the last layout (`labelColumn`).
    public private(set) var labelWidth = M.labelWidth
    public let sidebar: Sidebar?
    /// The sidebar's page frames and the rule after the column (window points, set by `layout`).
    public private(set) var sidebarFrames: [CGRect] = []
    private var sidebarRule: CGRect = .zero
    public var sidebarRuleFrame: CGRect { sidebarRule }
    /// How far the dialog scrolled the form and how tall its viewport is: the sidebar column stays at the viewport top.
    public var sidebarShift: CGFloat = 0
    public var viewportHeight: CGFloat = 0
    /// The page list has the keyboard (first Tab stop): Up/Down pick the page.
    public internal(set) var sidebarFocused = false
    private var sidebarHovered: Int?

    /// The widest row label, at least `M.labelWidth`, at most `M.labelMax`. A settings form (with a sidebar) has the Mac
    /// `SQFormRow` column: `Theme.Modal.labelColumnL`.
    /// Text size: 12 in dialogs, the Mac settings `body` 11 on a settings form.
    var font: CGFloat { sidebar != nil ? M.settingsFont : M.font }
    private var helpLine: CGFloat { sidebar != nil ? M.settingsHelpLine : M.noteLine }

    /// Segment widths: `sw` each, or (`sw` 0, the Mac `SQSegmented` default) each title at 11 pt plus 20.
    static func segmentWidths(_ options: [String], _ sw: CGFloat, _ m: TextMeasure) -> [CGFloat] {
        options.map { sw > 0 ? sw : ceil(m.width(SQL10n.string($0), size: CGFloat(DrawTheme.TypeSize.body))) + 20 }
    }

    func labelColumn() -> CGFloat {
        if sidebar != nil { return M.settingsLabelWidth }
        var w = M.labelWidth
        for r in rows {
            let label: String
            switch r {
            case .field(_, let l, _, _), .popup(_, let l, _, _), .slider(_, let l, _, _, _), .buttons(_, let l, _, _, _),
                 .number(let l, _), .size(let l, _, _), .segmented(_, let l, _, _, _), .listBox(_, let l, _, _, _): label = l
            default: continue
            }
            w = max(w, ceil(measure.width(SQL10n.string(label), size: font)))
        }
        return min(w, M.labelMax)
    }
    /// Opens a popup's options below its control (the dialog's menu controller); the chosen index comes back through `choose`.
    var openPopup: ((_ row: Int, _ items: [SQMenuItem], _ below: CGRect) -> Void)?
    /// A value changed (dialogs that update other rows, e.g. a preset popup).
    public var onChange: (@MainActor (String, Value) -> Void)?

    public init(_ rows: [Row], sidebar: Sidebar? = nil, selected: Int = 0) {
        self.rows = rows
        self.sidebar = sidebar
        if let sidebar { values[sidebar.id] = .index(selected) }
        for (i, r) in rows.enumerated() {
            switch r {
            case .field(let id, _, let v, _):
                values[id] = .text(v)
                var f = TextFieldControl(text: v); f.alignment = .left; f.dialogStyle = sidebar == nil; fields[i] = f
            case .popup(let id, _, _, let s): values[id] = .index(s)
            case .color(let id, _, let v): colors[id] = v
            case .check(let id, _, let on): values[id] = .bool(on)
            case .slider(let id, _, let v, _, _):
                values[id] = .number(v)
                var f = TextFieldControl(text: Self.format(v)); f.alignment = .right; fields[i] = f
            case .radio(let id, _, let s), .segmented(let id, _, _, let s, _): values[id] = .index(s)
            case .number(_, let f): addScrub(f)
            case .sliderNumber(_, let f): addScrub(f); scrubs[f.id]?.isPlain = true; scrubs[f.id]?.leadingText = true
            case .size(_, let w, let h): addScrub(w); addScrub(h)
            case .radioNumbers(let id, _, let s, let fs):
                values[id] = .index(s)
                for f in fs { addScrub(f) }
            case .textBox(let id, let v, _): values[id] = .text(v)
            case .text, .gap, .buttons, .caption, .label, .chart, .listBox: break
            }
        }
    }

    /// Puts a number grid under row `rowID` (`SQFormRow.row(extra: [unitGrid])`); the fields answer `onChange` by their ids.
    public func setGrid(_ rowID: String, _ cells: [GridCell]) {
        grids[rowID] = cells
        for c in cells { addScrub(c.field) }
    }

    /// Puts number field `f` (`width` pt) after check `checkID`'s title, 8 apart (`SettingsWindow.checkItem` with a trailing
    /// field); it takes no input while the check is off.
    public func setCheckField(_ checkID: String, _ f: NumberField, width: CGFloat) {
        checkFields[checkID] = (f, width)
        addScrub(f)
    }

    /// Replaces the note and bars of the `.chart` row `i` (a rerun); lay out again afterwards.
    public func setChart(_ i: Int, note: String, bars: [Bar]) {
        guard rows.indices.contains(i), case .chart(_, let title, _) = rows[i] else { return }
        rows[i] = .chart(note: note, title: title, bars: bars)
    }

    /// Opens the editor of text box `id` with the caret at the end (the Mac box is first responder when its dialog opens).
    public func beginEditing(_ id: String) {
        guard let i = rows.indices.first(where: { Self.id(of: rows[$0]) == id }) else { return }
        focus(i)
    }

    /// The number field ids under or after row `i` (its grid, its check field).
    private func extraScrubIDs(_ i: Int) -> [String] {
        guard let id = Self.id(of: rows[i]) else { return [] }
        return (grids[id] ?? []).map(\.field.id) + (checkFields[id].map { [$0.field.id] } ?? [])
    }

    /// A number field that takes no input: listed in `disabled`, or after a check that is off.
    func scrubOff(_ id: String) -> Bool {
        if disabled.contains(id) { return true }
        if let owner = checkFields.first(where: { $0.value.field.id == id })?.key { return bool(owner) != true }
        return false
    }

    /// The color of a `.color` row.
    public func color(_ id: String) -> SQColorValue? { colors[id] }
    public func text(_ id: String) -> String? { if case .text(let s)? = values[id] { s } else { nil } }
    public func index(_ id: String) -> Int? { if case .index(let i)? = values[id] { i } else { nil } }
    public func bool(_ id: String) -> Bool? { if case .bool(let b)? = values[id] { b } else { nil } }
    public func number(_ id: String) -> Double? {
        switch values[id] {
        case .number(let d)?: d
        case .text(let s)?: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public func set(_ id: String, _ v: Value) {
        values[id] = v
        for (i, r) in rows.enumerated() where Self.id(of: r) == id {
            if case .text(let s) = v { fields[i]?.text = s }
            if case .number(let d) = v { fields[i]?.text = Self.format(d) }
        }
        if case .number(let d) = v, scrubs[id] != nil, scrubs[id]?.isEditing != true { scrubs[id]?.value = d }
    }

    /// Replaces the text left of a `.buttons` row's buttons (a chosen folder's path).
    public func setDetail(_ id: String, _ detail: String) {
        for (i, r) in rows.enumerated() {
            if case .buttons(id, let label, _, let titles, let enabled) = r {
                rows[i] = .buttons(id: id, label: label, detail: detail, titles: titles, enabled: enabled)
            }
        }
    }

    /// Replaces the note of text row `i` (a live summary line); other rows stay as they are. Lay out again afterwards.
    public func setNote(_ i: Int, _ s: String, warning: Bool = false, strong: Bool = false, plain: Bool = false) {
        guard rows.indices.contains(i), case .text = rows[i] else { return }
        rows[i] = .text(s)
        if warning { warningNotes.insert(i) } else { warningNotes.remove(i) }
        if strong { strongNotes.insert(i) } else { strongNotes.remove(i) }
        if plain { plainStrongNotes.insert(i) } else { plainStrongNotes.remove(i) }
    }

    static func id(of r: Row) -> String? {
        switch r {
        case .field(let id, _, _, _), .popup(let id, _, _, _), .check(let id, _, _), .slider(let id, _, _, _, _), .radio(let id, _, _),
             .buttons(let id, _, _, _, _), .radioNumbers(let id, _, _, _), .segmented(let id, _, _, _, _), .label(let id, _),
             .textBox(let id, _, _), .color(let id, _, _), .listBox(let id, _, _, _, _): id
        case .number(_, let f), .size(_, let f, _), .sliderNumber(_, let f): f.id
        case .text, .gap, .caption, .chart: nil
        }
    }

    static func format(_ d: Double) -> String {
        d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d)
    }

    // MARK: Layout

    /// Height of the body for a card `width` wide.
    public func height(width: CGFloat) -> CGFloat {
        layout(origin: .zero, width: width)
    }

    @discardableResult
    public func layout(origin o: CGPoint, width w: CGFloat) -> CGFloat {
        guard let sidebar else { return layoutRows(origin: o, width: w) }
        let side = M.sidebarWidth
        sidebarFrames = sidebar.items.indices.map {
            CGRect(x: o.x + M.sidebarInset, y: o.y + sidebarShift + CGFloat($0) * (M.sidebarRow + M.sidebarGap),
                   width: side - 2 * M.sidebarInset, height: M.sidebarRow)
        }
        // The Mac page starts `pageTop` below the sidebar's first row (`SQFormRow.page` top inset 20 against the sidebar's 12).
        let h = max(layoutRows(origin: CGPoint(x: o.x + side + 1, y: o.y + M.pageTop), width: w - side - 1) + M.pageTop,
                    (sidebarFrames.last?.maxY ?? o.y) - o.y - sidebarShift)
        sidebarRule = sidebarShift > 0 && viewportHeight > 0
            ? CGRect(x: o.x + side, y: o.y + sidebarShift, width: 1, height: viewportHeight)
            : CGRect(x: o.x + side, y: o.y, width: 1, height: h)
        return h
    }

    private func layoutRows(origin: CGPoint, width: CGFloat) -> CGFloat {
        rowFrames = []; controlFrames = []; scrubFrames = [:]; linkFrame = .zero; helpLines = [:]
        gridTitleFrames = [:]; statusFrames = [:]; statusButtonFrames = [:]; helpTops = [:]; chartParts = [:]
        var y = origin.y
        let x0 = origin.x + sidePad, inner = width - 2 * sidePad
        labelWidth = labelColumn()
        let cx = x0 + labelWidth + M.labelGap, cw = origin.x + width - sidePad - cx
        for (i, r) in rows.enumerated() {
            if let iw = inlineWidth(i) {
                // On the field row before it: the field gives up the popup's width and the gap.
                let prev = controlFrames[i - 1]
                // The popup ends at the card's inner edge; the field keeps its own bleed on the left only.
                let right = min(prev.maxX, x0 + inner)
                controlFrames[i - 1].size.width = max(right - iw - M.controlGap - prev.minX, 0)
                rowFrames.append(rowFrames[i - 1])
                controlFrames.append(CGRect(x: right - iw, y: prev.minY, width: iw, height: prev.height))
                continue
            }
            if i > 0 { y += M.rowGap + (extraGapBefore[i] ?? 0) } else { y += extraGapBefore[0] ?? 0 }
            var h = M.rowHeight
            var control = CGRect(x: cx, y: y, width: cw, height: h)
            switch r {
            case .text(let s):
                let lines = measure.lines(SQL10n.string(s), width: inner, size: font)
                noteLines[i] = lines
                h = CGFloat(lines.count) * (strongNotes.contains(i) ? M.strongLine : M.noteLine)
                control = CGRect(x: x0, y: y, width: inner, height: h)
            case .field(let id, let label, _, let unit):
                // The Mac NSTextField's frame is `fieldBleed` wider than its alignment rect on each side, so the naming field
                // of an `SQDialog` accessory is drawn 18 pt from the card edge, not 20.
                if label.isEmpty { control = CGRect(x: x0 - M.fieldBleed, y: y, width: inner + 2 * M.fieldBleed, height: h) }
                if let w = controlWidths[id], !(label.isEmpty && w >= inner) {
                    if label.isEmpty { control.origin.x = x0 }   // a narrower accessory field starts at the edge (no bleed)
                    control.size.width = min(w, label.isEmpty ? inner + 2 * M.fieldBleed : cw)
                }
                else if !unit.isEmpty { control.size.width = M.unitFieldWidth }
                // The same frame bleed on a labeled row of a dialog (Color Matte's Name): wider than the control column.
                if !label.isEmpty, unit.isEmpty, sidebar == nil, labeledFieldBleed { control.origin.x -= M.fieldBleed; control.size.width += 2 * M.fieldBleed }
                // The text keeps its place inside the alignment rect: 6 pt from it, so 8 from a bleeding frame.
                if let fh = fieldHeights[id], fh < h { control.origin.y += ((h - fh) / 2).rounded(); control.size.height = fh }
                fields[i]?.textInset = sidebar == nil && (label.isEmpty || !labeledFieldBleed || control.minX < cx) ? 6 + M.fieldBleed : 6   // an accessory field: 8 in
            case .check(let id, _, _):
                h = M.checkRowHeight
                // A label (even an empty one) puts the box in the control column; an empty one is the 24 pt row under a labeled
                // one (the Mac Punch In Cuts zoom levels), a real one the 28 pt `formRow`.
                let labeled = !(checkLabels[id] ?? "").isEmpty
                control = checkLabels[id] != nil ? CGRect(x: cx, y: y + (labeled ? (M.rowHeight - h) / 2 : 0), width: cw, height: h)
                    : CGRect(x: x0, y: y, width: inner, height: h)
                if labeled { h = M.rowHeight }
            case .radio(_, let options, _):
                h = CGFloat(options.count) * M.checkRowHeight
                control = CGRect(x: x0, y: y, width: inner, height: h)
            case .gap(let g):
                h = g; control = .zero
            case .number(_, let f):
                if !f.unit.isEmpty { control.size.width = M.unitFieldWidth }
                else if link?.fields.contains(f.id) == true { control.size.width -= sidePad + M.linkWidth }
                scrubFrames[f.id] = control
            case .sliderNumber(_, let f):
                scrubFrames[f.id] = sliderNumberParts(control, unit: f.unit).field
            case .radioNumbers(_, let options, _, let fs):
                h = CGFloat(options.count) * M.rowHeight + CGFloat(max(options.count - 1, 0)) * M.rowGap
                control = CGRect(x: x0, y: y, width: inner, height: h)
                for (n, f) in fs.enumerated() where n < options.count {
                    scrubFrames[f.id] = CGRect(x: x0 + M.radioColumn, y: y + CGFloat(n) * (M.rowHeight + M.rowGap),
                                               width: f.unit.isEmpty ? inner - M.radioColumn : M.unitFieldWidth, height: M.rowHeight)
                }
            case .caption:
                h = M.captionTop + M.captionLine + (sidebar != nil ? M.captionAfter : 0)
                // `SQFormRow.caption`: at the control column on a settings page.
                control = sidebar != nil ? CGRect(x: cx, y: y + M.captionTop, width: cw, height: M.captionLine)
                    : CGRect(x: x0, y: y + M.captionTop, width: inner, height: M.captionLine)
            case .size(_, let w, let hf) where swapBetween.contains(w.id):
                let fw = controlWidths[w.id] ?? M.sizeField
                control.size.width = 2 * fw + 2 * M.controlGap + M.rowHeight
                scrubFrames[w.id] = CGRect(x: cx, y: y, width: fw, height: h)
                scrubFrames[hf.id] = CGRect(x: cx + fw + 2 * M.controlGap + M.rowHeight, y: y, width: fw, height: h)
            case .size(_, let w, let hf) where plainSize.contains(w.id):
                let fw = controlWidths[w.id] ?? M.sizeField
                control.size.width = max(cw, 2 * fw + M.timesWidth + 2 * M.controlGap)
                scrubFrames[w.id] = CGRect(x: cx, y: y, width: fw, height: h)
                scrubFrames[hf.id] = CGRect(x: cx + control.size.width - fw, y: y, width: fw, height: h)
            case .size(_, let w, let hf):
                control.size.width = 2 * M.sizeField + M.timesWidth + 3 * M.controlGap + M.linkWidth
                scrubFrames[w.id] = CGRect(x: cx, y: y, width: M.sizeField, height: h)
                scrubFrames[hf.id] = CGRect(x: cx + M.sizeField + 2 * M.controlGap + M.timesWidth, y: y, width: M.sizeField, height: h)
            case .segmented(_, _, let options, _, let sw):
                control.size.width = Self.segmentWidths(options, sw, measure).reduce(0, +) + 2
            case .popup(let id, let label, _, _):
                // Unlabeled, like an unlabeled field: from the card's left edge (an `SQDialog` accessory popup).
                // The Mac `SQDialog.popupRow` has no row padding: the row is the 22 pt popup, not a 28 pt row around it.
                if label.isEmpty { h = popupStyles[id]?.height ?? CGFloat(InspectorTokens.capsule); control = CGRect(x: x0 - M.popupBleed, y: y, width: inner + M.popupBleed, height: h) }
                if let w = controlWidths[id], !(label.isEmpty && w >= inner) {
                    if label.isEmpty { control.origin.x = x0 }
                    control.size.width = min(w, label.isEmpty ? inner + M.popupBleed : cw)
                }
                // A settings page's `NSPopUpButton` frame bleeds 5 pt left of the control column (help text and fields start at it).
                if sidebar != nil || labeledPopupBleed, !label.isEmpty { control.origin.x -= M.popupBleed; control.size.width += M.popupBleed }
            case .color:
                break
            case .label:
                control = CGRect(x: cx, y: y, width: 0, height: h)
            case .chart(let note, _, _):
                let size = CGFloat(DrawTheme.TypeSize.body)
                let lines = note.isEmpty ? [] : measure.lines(SQL10n.string(note), width: cw, size: size)
                noteLines[i] = lines
                let titleY = y + CGFloat(lines.count) * M.noteLine + (lines.isEmpty ? 0 : M.chartGap)
                let chart = CGRect(x: cx, y: titleY + M.chartTitleLine + M.chartGap, width: cw, height: M.chartHeight)
                chartParts[i] = (titleY, chart)
                h = chart.maxY - y
                control = CGRect(x: cx, y: y, width: cw, height: h)
            case .textBox(_, _, let bh):
                h = bh
                control = CGRect(x: x0, y: y, width: inner, height: bh)
            case .listBox(_, _, let lines, _, let empty):
                // Empty: the wrapped hint, 28 pt line height at least, 12 inside the box.
                let hint = measure.lines(SQL10n.string(empty), width: M.helpMaxWidth - 24, size: font)
                h = lines.isEmpty ? max(M.rowHeight, CGFloat(hint.count) * M.noteLine + 12) : CGFloat(lines.count) * M.rowHeight
                control = CGRect(x: cx, y: y, width: min(M.helpMaxWidth, cw), height: h)
                noteLines[i] = hint
            case .slider, .buttons: break
            }
            if case .check(let id, let title, _) = r, let cf = checkFields[id] {
                // `checkItem`: box 14, 6, the title, 8, the field on the row's 28 pt line.
                let tw = ceil(measure.width(SQL10n.string(title), size: font))
                scrubFrames[cf.field.id] = CGRect(x: control.minX + 14 + 6 + tw + M.gridGap, y: y, width: cf.width, height: M.rowHeight)
            }
            if let id = Self.id(of: r), let cells = grids[id], !cells.isEmpty {
                let titleW = cells.map { ceil(measure.width(SQL10n.string($0.title), size: font)) }.max() ?? 0
                var gy = y + h + M.helpGap
                for cell in cells {
                    gridTitleFrames[cell.field.id] = CGRect(x: cx, y: gy, width: titleW, height: M.rowHeight)
                    scrubFrames[cell.field.id] = CGRect(x: cx + titleW + M.gridGap, y: gy, width: M.unitFieldWidth, height: M.rowHeight)
                    gy += M.rowHeight + M.gridGap
                }
                h = gy - M.gridGap - y
            }
            if let id = Self.id(of: r), let st = statuses[id] {
                // The Mac status stack is as tall as its tallest view: 14 for dot + text, 28 once a button joins them.
                let line = CGRect(x: cx, y: y + h + M.helpGap, width: cw, height: st.button != nil ? M.rowHeight : M.captionLine)
                statusFrames[i] = line
                if let b = st.button {
                    let tw = ceil(measure.width(SQL10n.string(st.text), size: font))
                    let bw = ceil(measure.width(SQL10n.string(b), size: font)) + 2 * InspectorDraw.buttonPadding + (st.buttonIcon != nil ? 18 : 0)
                    statusButtonFrames[i] = CGRect(x: cx + M.statusDot + M.gridGap + tw + M.gridGap, y: line.minY, width: bw, height: M.rowHeight)
                }
                h = line.maxY - y
            }
            if let id = Self.id(of: r), let help = helps[id], !help.isEmpty {
                let lines = measure.lines(SQL10n.string(help), width: min(cw, M.helpMaxWidth), size: font)
                helpLines[i] = lines
                helpTops[i] = y + max(h, control.maxY - y) + M.helpGap
                h = helpTops[i]! - y + CGFloat(lines.count) * helpLine
            }
            rowFrames.append(CGRect(x: origin.x, y: y, width: width, height: h))
            controlFrames.append(control)
            y += h
        }
        if let link {
            let boxes = link.fields.compactMap { scrubFrames[$0] }
            if let top = boxes.map(\.midY).min(), let bottom = boxes.map(\.midY).max() {
                linkFrame = CGRect(x: origin.x + width - sidePad - M.linkWidth, y: ((top + bottom) / 2 - M.rowHeight / 2).rounded(),
                                   width: M.linkWidth, height: M.rowHeight)
            }
        }
        return y - origin.y
    }

    /// The width of popup row `i` when it sits on the field row before it (`inlinePopups`): `controlWidths` or the Mac
    /// `SQPopup.intrinsicContentSize` (title inset 10, widest option in body size, chevron gap 8 + 7 + inset 7).
    func inlineWidth(_ i: Int) -> CGFloat? {
        guard i > 0, i - 1 < controlFrames.count, case .popup(let id, _, let options, _) = rows[i], inlinePopups.contains(id),
              case .field = rows[i - 1] else { return nil }
        if let w = controlWidths[id] { return w }
        let widest = options.map { measure.width(SQL10n.string($0), size: CGFloat(DrawTheme.TypeSize.body)) }.max() ?? 0
        return ceil(10 + widest + 8 + 7 + 7)
    }

    /// `NumericSlider.layout` with `unitOutside`: the unit column (24 at least) at the right, `controlGap`, the 72 field,
    /// 12, the slider in the rest.
    private func sliderNumberParts(_ c: CGRect, unit: String) -> (track: CGRect, field: CGRect) {
        let uw = max(M.unitColumn, ceil(measure.width(SQL10n.string(unit), size: font)))
        let field = CGRect(x: c.maxX - uw - M.controlGap - M.sliderFieldWidth, y: c.minY, width: M.sliderFieldWidth, height: c.height)
        return (CGRect(x: c.minX, y: c.minY, width: max(field.minX - 12 - c.minX, 0), height: c.height), field)
    }

    private func sliderParts(_ i: Int) -> (track: CGRect, field: CGRect) {
        let c = controlFrames[i]
        let field = CGRect(x: c.maxX - M.sliderFieldWidth, y: c.minY, width: M.sliderFieldWidth, height: c.height)
        return (CGRect(x: c.minX, y: c.minY, width: field.minX - 12 - c.minX, height: c.height), field)
    }

    /// The buttons of a `.buttons` row, right aligned in its control frame (`TextFieldControl.button` widths, 64 at least).
    func buttonFrames(_ i: Int) -> [CGRect] {
        guard controlFrames.indices.contains(i), case .buttons(let id, _, _, let titles, _) = rows[i] else { return [] }
        let c = controlFrames[i]
        var right = c.maxX, out: [CGRect] = []
        for t in titles.reversed() {
            let w = chips[id]?.buttonWidth ?? max(ceil(measure.width(SQL10n.string(t), size: font)) + 2 * M.buttonPadding, M.minButton)
            right -= w
            out.insert(CGRect(x: right, y: c.minY, width: w, height: c.height), at: 0)
            right -= M.controlGap
        }
        return out
    }

    /// The Restore button of each line of a `.listBox` row: 12 inside the box, 28 pt lines.
    func listButtonFrames(_ i: Int) -> [CGRect] {
        guard controlFrames.indices.contains(i), case .listBox(_, _, let lines, let title, _) = rows[i] else { return [] }
        let c = controlFrames[i]
        let w = max(ceil(measure.width(SQL10n.string(title), size: font)) + 2 * M.buttonPadding, M.minButton)
        return lines.indices.map { CGRect(x: c.maxX - 12 - w, y: c.minY + CGFloat($0) * M.rowHeight, width: w, height: M.rowHeight) }
    }

    /// One list line with an icon, the name, the gray detail (cut at the end) and the warning word, 12 inside the box,
    /// `Theme.Spacing.sm` between the parts (the Mac `listLine`).
    private func drawListLine(_ c: inout Canvas, _ name: String, _ x: ListLine, box: CGRect, button r: CGRect, _ t: DrawTheme) {
        let gap = CGFloat(DrawTheme.Spacing.sm)
        var cursor = box.minX + 12
        let limit = r.minX - gap
        if let icon = x.icon {
            c.draw(icon: icon, at: CGPoint(x: cursor, y: (r.midY - 6.5).rounded()), size: 13, t.label3)
            cursor += 13 + gap
        }
        let nameW = ceil(measure.width(name, size: font))
        c.draw(name, in: CGRect(x: cursor, y: r.minY, width: min(nameW, max(limit - cursor, 0)), height: r.height), fontSize: font, t.label)
        cursor += nameW + gap
        var end = limit
        if let w = x.warning {
            let ww = ceil(measure.width(SQL10n.string(w), size: font))
            end -= ww + gap
            if end > cursor { c.draw(SQL10n.string(w), in: CGRect(x: end + gap, y: r.minY, width: ww, height: r.height), fontSize: font, t.warning) }
        }
        // shortcut: the path is cut at its end, the Mac cuts it in the middle; upgrade when a long path matters.
        if end > cursor, !x.detail.isEmpty {
            c.draw(x.detail, in: CGRect(x: cursor, y: r.minY, width: end - cursor, height: r.height), fontSize: font, t.label3)
        }
    }

    private func buttonEnabled(_ i: Int, _ n: Int) -> Bool {
        guard case .buttons(_, _, _, _, let enabled) = rows[i] else { return false }
        return enabled.indices.contains(n) ? enabled[n] : true
    }

    private func press(_ i: Int, _ n: Int) {
        guard let id = Self.id(of: rows[i]), buttonEnabled(i, n) else { return }
        onChange?(id, .index(n))
    }

    /// The text area of a `.textBox` row (6 pt in, scrolled so the caret line shows).
    private func boxText(_ i: Int) -> CGRect {
        controlFrames[i].insetBy(dx: M.boxInset, dy: M.boxInset).offsetBy(dx: 0, dy: -boxScroll)
    }

    private func fieldBox(_ i: Int) -> CGRect {
        if case .slider = rows[i] { return sliderParts(i).field }
        return controlFrames[i]
    }

    // MARK: Focus (Tab order: fields, popups, checks, sliders, radios)

    private var focusable: [Int] {
        rows.indices.filter {
            if case .text = rows[$0] { return false }
            if case .gap = rows[$0] { return false }
            if case .caption = rows[$0] { return false }
            if case .label = rows[$0] { return false }
            if case .chart = rows[$0] { return false }
            return Self.id(of: rows[$0]).map { !disabled.contains($0) } ?? true
        }
    }

    /// Tab / Shift-Tab: commits an open field and moves on. False at the ends (the dialog's buttons take it).
    @discardableResult
    public func moveFocus(forward: Bool) -> Bool {
        commitEditing()
        if sidebar != nil {
            // The page list is the stop before the first row.
            if sidebarFocused {
                sidebarFocused = false
                if !forward { return false }
            } else if focused == nil, forward { sidebarFocused = true; return true }
            else if !forward, let f = focused, focusable.first == f { focused = nil; sidebarFocused = true; return true }
        }
        let order = focusable
        guard !order.isEmpty else { return false }
        let at = focused.flatMap { order.firstIndex(of: $0) }
        let next = at.map { $0 + (forward ? 1 : -1) } ?? (forward ? 0 : order.count - 1)
        guard order.indices.contains(next) else { focused = nil; return false }
        focus(order[next])
        return true
    }

    private func focus(_ i: Int) {
        sidebarFocused = false
        focused = i
        focusedScrub = nil
        if fields[i] != nil { fields[i]?.mouseDown() }
        if case .textBox(let id, _, _) = rows[i], boxEditor == nil { boxEditor = TextEditState(text(id) ?? "", selectAll: false) }
    }

    public var isEditing: Bool {
        fields.values.contains { $0.isEditing } || scrubs.values.contains { $0.isEditing } || boxEditor != nil
    }

    /// Drops the focus ring and the open editors (the shot harness shows dialogs unfocused, as the offscreen Mac window is).
    public func blur() { commitEditing(); focused = nil; focusedScrub = nil; sidebarFocused = false }

    public func commitEditing() {
        for i in fields.keys where fields[i]?.isEditing == true {
            if let s = fields[i]?.commit() { fieldCommitted(i, s) }
        }
        for id in scrubs.keys where scrubs[id]?.isEditing == true { scrubEvents(id) { $0.commitEditing() } }
        boxEditor = nil
    }

    private func fieldCommitted(_ i: Int, _ s: String) {
        guard let id = Self.id(of: rows[i]) else { return }
        if case .slider(_, _, _, let range, _) = rows[i] {
            let d = Double(s.trimmingCharacters(in: .whitespaces)).map { min(max($0, range.lowerBound), range.upperBound) }
            let v = d ?? number(id) ?? range.lowerBound
            set(id, .number(v)); onChange?(id, .number(v))
        } else {
            values[id] = .text(s); onChange?(id, .text(s))
        }
    }

    /// Picks sidebar page `n` (a click on it).
    public func selectPage(_ n: Int) {
        guard let sidebar, sidebar.items.indices.contains(n) else { return }
        commitEditing()
        values[sidebar.id] = .index(n)
        onChange?(sidebar.id, .index(n))
    }

    /// A popup row's option was chosen.
    public func choose(row i: Int, option: Int) {
        guard let id = Self.id(of: rows[i]) else { return }
        values[id] = .index(option)
        onChange?(id, .index(option))
    }

    private func toggle(_ i: Int) {
        guard case .check(let id, _, _) = rows[i] else { return }
        let v = Value.bool(!(bool(id) ?? false))
        values[id] = v; onChange?(id, v)
    }

    // MARK: Events (window points)

    private var canvas: Canvas { Canvas(width: 0, height: 0, atlas: measure.atlas, scale: measure.scale) }

    /// A key while the form has focus. True when the form used it (Enter and Esc go to the dialog unless a field is open).
    public func key(_ k: InputKey, _ m: InputModifiers) -> Bool {
        if k == InputKey.tab { return moveFocus(forward: !m.contains(.shift)) }
        if sidebarFocused, let sidebar {
            guard k == .up || k == .down else { return false }
            let now = index(sidebar.id) ?? 0
            let n = min(max(now + (k == .down ? 1 : -1), 0), sidebar.items.count - 1)
            if n != now { selectPage(n) }
            return true
        }
        guard let f = focused else { return false }
        if case .textBox(let id, _, _) = rows[f] {
            if k == .escape { return false }
            if boxEditor == nil { boxEditor = TextEditState(text(id) ?? "", selectAll: false) }
            if boxEditor?.handleLines(k, modifiers: m) == .edited, let s = boxEditor?.string {
                values[id] = .text(s); onChange?(id, .text(s))
            }
            return true
        }
        if let used = scrubKey(row: f, k, m) { return used }
        if fields[f]?.isEditing == true {
            if k == .enter { commitEditing(); return false }      // Return also presses the default button (Mac field)
            if k == .escape { fields[f]?.cancel(); return true }
            if let s = fields[f]?.key(k, modifiers: m) { fieldCommitted(f, s) }
            return true
        }
        switch rows[f] {
        case .check where k == .space: toggle(f); return true
        case .popup(_, _, let options, _) where k == .space || k == .down || k == .up:
            if k == .space { open(f) } else { step(f, k == .down ? 1 : -1, count: options.count) }
            return true
        case .radio(_, let options, _) where k == .down || k == .up || k == .left || k == .right:
            step(f, (k == .down || k == .right) ? 1 : -1, count: options.count); return true
        case .radioNumbers(_, let options, _, _) where k == .down || k == .up:
            stepRadio(f, k == .down ? 1 : -1, count: options.count); return true
        case .segmented(_, _, let options, _, _) where k == .left || k == .right:
            step(f, k == .right ? 1 : -1, count: options.count); return true
        case .buttons(_, _, _, let titles, _) where k == .space || k == .enter:
            if let n = titles.indices.first(where: { buttonEnabled(f, $0) }) { press(f, n) }
            return true
        case .slider(let id, _, _, let range, _) where k == .left || k == .right:
            let stepSize = (range.upperBound - range.lowerBound) / (m.contains(.shift) ? 10 : 100)
            let v = min(max((number(id) ?? 0) + (k == .right ? stepSize : -stepSize), range.lowerBound), range.upperBound)
            set(id, .number(v)); onChange?(id, .number(v)); return true
        default: return false
        }
    }

    private func step(_ i: Int, _ d: Int, count: Int) {
        guard let id = Self.id(of: rows[i]), count > 0 else { return }
        choose(row: i, option: max(0, min(count - 1, (index(id) ?? 0) + d)))
    }

    // MARK: Color picker popover

    private func openPicker(_ i: Int, _ id: String) {
        let p = ColorPickerControl(value: colors[id] ?? SQColorValue(h: 0, s: 0, b: 0), showsEyedropper: false)
        picker = p; pickerRow = i; pickerDragging = false
        pickerFrame = p.frame(anchor: controlFrames[i], in: overlayBounds)
    }

    private func closePicker() { picker = nil; pickerDragging = false }

    private func pickerChanged(_ p: ColorPickerControl) {
        picker = p
        guard rows.indices.contains(pickerRow), case .color(let id, _, _) = rows[pickerRow] else { return }
        colors[id] = p.value
        onChange?(id, .text(p.value.hex))
    }

    private func pickerLocal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - pickerFrame.minX, y: p.y - pickerFrame.minY) }

    /// Routes a pointer press while the picker is open: inside it drives the picker, outside closes it (taken).
    public func pickerMouseDown(_ p: CGPoint) {
        guard var pk = picker else { return }
        let q = pickerLocal(p)
        guard CGRect(origin: .zero, size: pickerFrame.size).contains(q) else { closePicker(); return }
        pickerDragging = true
        if pk.mouseDown(at: q) == .changed { pickerChanged(pk) } else { picker = pk }
    }

    public func pickerMouseDragged(_ p: CGPoint) {
        guard var pk = picker, pickerDragging else { return }
        if pk.mouseDragged(to: pickerLocal(p)) == .changed { pickerChanged(pk) } else { picker = pk }
    }

    public func pickerMouseUp() {
        guard var pk = picker else { return }
        pk.mouseUp(); picker = pk; pickerDragging = false
    }

    /// A key while the picker is open: the hex field and Esc (closes). Always taken.
    public func pickerKey(_ k: InputKey, _ m: InputModifiers) {
        guard var pk = picker else { return }
        let r = pk.key(k, modifiers: m)
        if r.outcome == .changed { pickerChanged(pk) } else { picker = pk }
        if !r.taken, k == .escape || k == .enter { closePicker() }
    }

    /// The popover above everything else (call outside the form's clip).
    public func drawOverlay(_ c: inout Canvas, theme t: DrawTheme) {
        guard let pk = picker else { return }
        c.saveGState()
        c.translateBy(x: pickerFrame.minX, y: pickerFrame.minY)
        pk.draw(&c, theme: t)
        c.restoreGState()
    }

    private func open(_ i: Int) {
        guard case .popup(let id, _, let options, _) = rows[i] else { return }
        let style = popupStyles[id]
        var items: [SQMenuItem] = []
        for (n, title) in options.enumerated() {
            if style?.separatorBefore.contains(n) == true { items.append(.separator) }
            if let h = style?.headers[n] { items.append(.header(h)) }
            let key = style.map { $0.keys.indices.contains(n) ? $0.keys[n] : "" } ?? ""
            let dot: SQMenuIcon = style.map { $0.dots.indices.contains(n) ? .swatch($0.dots[n]) : .none } ?? .none
            items.append(SQMenuItem(title: title, icon: dot, shortcut: key, isChecked: n == (self.index(id) ?? -1)) { [weak self] in
                self?.choose(row: i, option: n)
            })
        }
        openPopup?(i, items, controlFrames[i])
    }

    func row(at p: CGPoint) -> Int? {
        rowFrames.indices.first { i in
            if controlFrames[i].contains(p) { return true }
            if case .check = rows[i] { return rowFrames[i].contains(p) }
            if extraScrubIDs(i).contains(where: { scrubFrames[$0]?.contains(p) == true }) { return true }
            if statusButtonFrames[i]?.contains(p) == true { return true }
            return false
        }
    }

    /// True when the press landed on a control.
    public func mouseDown(_ p: CGPoint, modifiers: InputModifiers = []) -> Bool {
        if let n = sidebarFrames.firstIndex(where: { $0.contains(p) }) { focused = nil; sidebarFocused = false; selectPage(n); return true }
        if let link, linkFrame.contains(p) {
            commitEditing()
            if !link.fields.contains(where: disabled.contains) {
                let v = Value.bool(!(bool(link.id) ?? false)); values[link.id] = v; onChange?(link.id, v)
            }
            return true
        }
        sidebarFocused = false
        guard let i = row(at: p) else { commitEditing(); focused = nil; return false }
        if let id = Self.id(of: rows[i]), disabled.contains(id) { commitEditing(); return true }
        if let id = scrubFrames.first(where: { $0.value.contains(p) })?.key {
            if scrubOff(id) { commitEditing(); return true }
            for other in scrubs.keys where other != id && scrubs[other]?.isEditing == true { scrubEvents(other) { $0.commitEditing() } }
            if focused != i { commitEditingTextFields(); boxEditor = nil }
            focused = i
            focusedScrub = extraScrubIDs(i).contains(id) ? id : nil
            scrubDown(id, p)
            return true
        }
        if let b = statusButtonFrames[i], b.contains(p), let id = Self.id(of: rows[i]) {
            commitEditing(); onChange?(id + ".status", .index(0)); return true
        }
        if focused != i { commitEditing() }
        focused = i
        focusedScrub = nil
        switch rows[i] {
        case .field, .slider:
            if case .slider = rows[i], !sliderParts(i).field.contains(p) {
                dragging = i; drag(p); return true
            }
            let wasEditing = fields[i]?.isEditing == true
            let box = fieldBox(i).insetBy(dx: 6, dy: 0)
            if wasEditing, let e = fields[i]?.editor {
                let right = fields[i]?.alignment == .right
                let caret = InspectorDraw.caretIndex(canvas, e, x: p.x, in: box, fontSize: font, alignRight: right)
                fields[i]?.mouseDown(caret: caret, clickCount: clicks.press(x: Float(p.x), y: Float(p.y), now: ProcessInfo.processInfo.systemUptime))
                selecting = (i, nil)
            } else {
                fields[i]?.mouseDown()
                if fields[i]?.isEditing == true { selecting = (i, p) }
            }
        case .popup: open(i)
        case .color(let id, _, _): openPicker(i, id)
        case .check: toggle(i)
        case .radio(let id, let options, _):
            let n = Int((p.y - controlFrames[i].minY) / M.checkRowHeight)
            if options.indices.contains(n) { values[id] = .index(n); onChange?(id, .index(n)) }
        case .buttons:
            if let n = buttonFrames(i).firstIndex(where: { $0.contains(p) }) { press(i, n) }
        case .listBox(let id, _, _, _, _):
            if let n = listButtonFrames(i).firstIndex(where: { $0.contains(p) }) { onChange?(id, .index(n)) }
        case .radioNumbers(let id, let options, _, let fs):
            let n = Int((p.y - controlFrames[i].minY) / (M.rowHeight + M.rowGap))
            if options.indices.contains(n), !(fs.indices.contains(n) && disabled.contains(fs[n].id)) {
                values[id] = .index(n); onChange?(id, .index(n))
            }
        case .size(_, let w, let h):
            if !plainSize.contains(w.id), swapFrame(i).contains(p) { swapSize(w.id, h.id) }
        case .segmented(_, _, let options, _, let sw):
            var x = controlFrames[i].minX + 1
            for (n, w) in Self.segmentWidths(options, sw, measure).enumerated() {
                if p.x < x + w { choose(row: i, option: n); break }
                x += w
            }
        case .textBox(let id, _, _):
            if boxEditor == nil { boxEditor = TextEditState(text(id) ?? "", selectAll: false) }
            if let e = boxEditor {
                let inner = boxText(i)
                boxEditor?.place(InspectorDraw.caretIndex(canvas, e, at: p, in: inner, lineHeight: M.boxLine, fontSize: CGFloat(DrawTheme.TypeSize.body)),
                                 extend: modifiers.contains(.shift))
            }
        case .sliderNumber:
            commitEditingTextFields()
            dragging = i; drag(p)
        case .text, .gap, .number, .caption, .label, .chart: break
        }
        return true
    }

    /// The swap button of a `.size` row.
    func swapFrame(_ i: Int) -> CGRect {
        let c = controlFrames[i]
        if case .size(_, let w, _) = rows[i], swapBetween.contains(w.id) {
            return CGRect(x: c.minX + (controlWidths[w.id] ?? M.sizeField) + M.controlGap, y: c.minY, width: M.rowHeight, height: c.height)
        }
        return CGRect(x: c.maxX - M.linkWidth, y: c.minY, width: M.linkWidth, height: c.height)
    }

    private func swapSize(_ a: String, _ b: String) {
        commitEditing()
        let va = number(a) ?? 0, vb = number(b) ?? 0
        set(a, .number(vb)); set(b, .number(va))
        onChange?(a, .number(vb)); onChange?(b, .number(va))
    }

    /// The editor of a field row while it is open (tests).
    func textEditor(forRow i: Int) -> TextEditState? { fields[i]?.editor }

    private func fieldCaret(_ i: Int, at x: CGFloat) -> Int? {
        guard let e = fields[i]?.editor else { return nil }
        return InspectorDraw.caretIndex(canvas, e, x: x, in: fieldBox(i).insetBy(dx: 6, dy: 0), fontSize: font,
                                        alignRight: fields[i]?.alignment == .right)
    }

    public func mouseDragged(_ p: CGPoint) {
        if let s = selecting, let caret = fieldCaret(s.row, at: p.x) {
            let start = s.start.flatMap { fieldCaret(s.row, at: $0.x) }
            fields[s.row]?.mouseDragged(caret: caret, from: start)
            selecting = (s.row, nil)
        }
        if dragging != nil { drag(p) }
        if let id = pressedScrub { scrubEvents(id) { $0.mouseDragged(x: Float(p.x), modifiers: []) } }
    }
    public func mouseUp() {
        dragging = nil
        selecting = nil
        if let id = pressedScrub { pressedScrub = nil; scrubEvents(id) { $0.mouseUp() } }
    }
    public func mouseMoved(_ p: CGPoint) {
        hovered = row(at: p); hoveredPoint = p
        for id in scrubs.keys { scrubs[id]?.hovering = scrubFrames[id]?.contains(p) == true }
        sidebarHovered = sidebarFrames.firstIndex { $0.contains(p) }
    }

    private func drag(_ p: CGPoint) {
        if let i = dragging, case .sliderNumber(_, let f) = rows[i] {
            let t = InspectorDraw.sliderFraction(x: p.x, in: sliderNumberParts(controlFrames[i], unit: f.unit).track)
            let v = ScrubMath.clamp(f.range.lowerBound + (f.range.upperBound - f.range.lowerBound) * t, to: f.range)
            let stepped = f.step > 0 ? ScrubMath.clamp((v / f.step).rounded() * f.step, to: f.range) : v
            set(f.id, .number(stepped)); onChange?(f.id, .number(stepped))
            return
        }
        guard let i = dragging, case .slider(let id, _, _, let range, _) = rows[i] else { return }
        let f = InspectorDraw.sliderFraction(x: p.x, in: sliderParts(i).track)
        let v = range.lowerBound + (range.upperBound - range.lowerBound) * f
        set(id, .number(v)); onChange?(id, .number(v))
    }

    // MARK: Number fields (`ScrubFieldControl`, the Mac `ScrubField`)

    private func addScrub(_ f: NumberField) {
        var sc = ScrubFieldControl(value: ScrubMath.clamp(f.value, to: f.range))
        sc.range = f.range; sc.step = f.step; sc.decimals = f.decimals; sc.defaultValue = f.defaultValue
        scrubs[f.id] = sc
        values[f.id] = .number(sc.value)
    }

    /// Shows and reads field `id` through `format` / `parse` (a timecode for a frame count).
    public func setFormat(_ id: String, format: @escaping @Sendable (Double) -> String, parse: @escaping @Sendable (String) -> Double?) {
        scrubs[id]?.valueFormatter = format
        scrubs[id]?.valueParser = parse
    }

    /// Runs `body` on field `id` and answers every value it reports.
    func scrubEvents(_ id: String, _ body: (inout ScrubFieldControl) -> [ScrubFieldControl.Event]) {
        guard var sc = scrubs[id] else { return }
        let events = body(&sc)
        scrubs[id] = sc
        for e in events {
            switch e {
            case .live(let v), .change(let v), .end(let v), .cancel(let v):
                values[id] = .number(v); onChange?(id, .number(v))
            case .begin: break
            }
        }
    }

    private func scrubDown(_ id: String, _ p: CGPoint) {
        let n = clicks.press(x: Float(p.x), y: Float(p.y), now: ProcessInfo.processInfo.systemUptime)
        pressedScrub = id
        scrubEvents(id) { $0.mouseDown(x: Float(p.x), clickCount: n) }
    }

    private func commitEditingTextFields() {
        for i in fields.keys where fields[i]?.isEditing == true {
            if let s = fields[i]?.commit() { fieldCommitted(i, s) }
        }
    }

    /// The field a focused row types into: a number row's, or a number radio group's selected option.
    private func scrubID(row i: Int) -> String? {
        if let s = focusedScrub, extraScrubIDs(i).contains(s) { return s }
        return switch rows[i] {
        case .number(_, let f), .size(_, let f, _), .sliderNumber(_, let f): f.id
        case .radioNumbers(let id, _, _, let fs): index(id).flatMap { fs.indices.contains($0) ? fs[$0].id : nil }
        default: nil
        }
    }

    /// Keys for a focused number field: typing while it is open (Return commits and still presses the default button),
    /// arrows step it. Nil when the row has no field.
    private func scrubKey(row i: Int, _ k: InputKey, _ m: InputModifiers) -> Bool? {
        guard let id = scrubID(row: i), scrubs[id] != nil, !scrubOff(id) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if scrubs[id]?.isEditing == true {
            if k == .enter { commitEditing(); return false }
            scrubEvents(id) { $0.key(k, modifiers: m, now: now) }
            return true
        }
        let arrowsStep: Bool = {
            if case .number = rows[i] { return true }
            if case .sliderNumber = rows[i] { return true }
            return focusedScrub == id
        }()
        if arrowsStep, k == .left || k == .right || k == .up || k == .down {
            scrubEvents(id) { $0.key(k, modifiers: m, now: now) }; return true
        }
        if case .radioNumbers = rows[i], k == .left || k == .right {
            scrubEvents(id) { $0.key(k, modifiers: m, now: now) }; return true
        }
        return nil
    }

    /// Up/Down in a number radio group: the next option that is not disabled.
    private func stepRadio(_ i: Int, _ d: Int, count: Int) {
        guard case .radioNumbers(let id, _, _, let fs) = rows[i] else { return }
        var n = (index(id) ?? 0) + d
        while (0..<count).contains(n), fs.indices.contains(n), disabled.contains(fs[n].id) { n += d }
        guard (0..<count).contains(n) else { return }
        values[id] = .index(n); onChange?(id, .index(n))
    }

    static func dim(_ c: DrawColor) -> DrawColor { c.alpha(c.a * InspectorTokens.disabledAlpha) }

    private func drawScrub(_ c: inout Canvas, _ f: NumberField, focused: Bool, _ t: DrawTheme) {
        guard var sc = scrubs[f.id], let box = scrubFrames[f.id] else { return }
        let off = scrubOff(f.id)
        sc.isEnabled = !off
        sc.valueTint = labelTinted.contains(f.id) ? t.label : t.accent
        sc.draw(&c, in: box, theme: t, focused: focused && !off)
        if !f.unit.isEmpty {
            c.draw(SQL10n.string(f.unit), in: CGRect(x: box.maxX + M.controlGap, y: box.minY, width: 300, height: box.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), off ? Self.dim(t.label3) : t.label3)   // `SQUnitLabel`
        }
    }

    /// `SQRadio`: a 14 pt dot, accent with a white center when on.
    private func drawRadio(_ c: inout Canvas, on: Bool, enabled: Bool, at o: CGPoint, _ t: DrawTheme) {
        let dot = CGRect(x: o.x, y: o.y, width: 14, height: 14)
        // Off: fill + 0.5 edge. On: fill + 1.5 accent ring + 6 pt accent dot.
        c.fill(ellipseIn: dot, enabled ? t.fill : Self.dim(t.fill))
        if on {
            let a = enabled ? t.accent : Self.dim(t.accent)
            c.stroke(ellipseIn: dot.insetBy(dx: 0.75, dy: 0.75), width: 1.5, a)
            c.fill(ellipseIn: dot.insetBy(dx: 4, dy: 4), a)
        } else {
            let e = t.inkFill(0.10)
            c.stroke(ellipseIn: dot.insetBy(dx: 0.25, dy: 0.25), width: 0.5, enabled ? e : Self.dim(e))
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        if let sidebar { drawSidebar(&c, sidebar, theme: t) }
        // `SQDialog.labelText` and `SQFormRow.row`: form labels are right aligned against the controls.
        let labelAlign: DrawList.TextAlign = .right
        for (i, r) in rows.enumerated() where rowFrames.indices.contains(i) {
            let row = rowFrames[i], box = controlFrames[i]
            let labelRect = CGRect(x: row.minX + sidePad, y: row.minY, width: labelWidth - labelInset, height: M.rowHeight)
            let hover = hovered == i
            switch r {
            case .text:
                var y = box.minY
                let strong = strongNotes.contains(i)
                let color = warningNotes.contains(i) ? t.yellow : strong ? t.label : t.label2
                let line = strong ? M.strongLine : M.noteLine
                for l in noteLines[i] ?? [] {
                    // A strong note is medium weight, unless it is the plain `SQDialog.formText(note: false)` (regular, label color).
                    if strong && !plainStrongNotes.contains(i) { c.draw(l, in: CGRect(x: box.minX, y: y, width: box.width, height: line), fontSize: font, color, face: c.medium) }
                    else { c.draw(l, in: CGRect(x: box.minX, y: y, width: box.width, height: line), fontSize: font, color) }
                    y += line
                }
            case .field(_, let label, _, let unit):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                fields[i]?.fontSize = sidebar == nil ? dialogFieldFontSize : M.font
                fields[i]?.draw(&c, in: box, theme: t, focused: focused == i)
                if !unit.isEmpty {
                    c.draw(unit, in: CGRect(x: box.maxX + M.controlGap, y: box.minY, width: 60, height: box.height), fontSize: font, t.label3)
                }
            case .color(let id, let label, _):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                // `SQColorWell` in a form row: a capsule filling the control column, 20 high, the color under a hairline.
                let well = CGRect(x: box.minX, y: box.midY - 10, width: box.width, height: 20)
                let v = colors[id] ?? SQColorValue(h: 0, s: 0, b: 0)
                if v.a < 1 { c.fill(roundedRect: well, radius: 10, t.fill) }
                c.fill(roundedRect: well, radius: 10, ColorPickerControl.draw(v))
                c.stroke(roundedRect: well.insetBy(dx: 0.25, dy: 0.25), radius: 10, width: 0.5, t.inkFill(hover || picker != nil ? 0.30 : 0.14))
                if focused == i { InspectorDraw.focusLine(&c, box.insetBy(dx: 0, dy: 3), radius: 6, t) }
            case .popup(let id, let label, let options, _):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                let sel = index(id) ?? 0
                let title = options.indices.contains(sel) ? options[sel] : ""
                if let dots = popupStyles[id]?.dots, dots.indices.contains(sel) {
                    InspectorDraw.popup(&c, title: "", in: box, hovering: hover, open: false, enabled: true, t)
                    c.fill(ellipseIn: CGRect(x: box.minX + 10, y: (box.midY - M.statusDot / 2).rounded(), width: M.statusDot,
                                             height: M.statusDot), DrawColor(hex: dots[sel]))
                    c.draw(title, in: CGRect(x: box.minX + 22, y: box.minY, width: max(box.width - 22 - 18, 0), height: box.height),
                           fontSize: CGFloat(DrawTheme.TypeSize.body), t.label)
                } else {
                    InspectorDraw.popup(&c, title: title, in: box, hovering: hover, open: false, enabled: true,
                                        maxHeight: popupStyles[id]?.height ?? CGFloat(InspectorTokens.capsule),
                                        fontSize: popupStyles[id]?.fontSize, t)
                }
                if let key = popupStyles[id]?.boxKey, !key.isEmpty {
                    // `NewProjectSheet.KeyLabel`: 56 wide, right aligned, 28 left of the box's right edge, 11 pt label3.
                    c.draw(key, in: CGRect(x: box.maxX - 28 - 56, y: box.minY, width: 56, height: box.height), fontSize: 11, t.label3,
                           align: .right)
                }
                if focused == i { InspectorDraw.focusLine(&c, box.insetBy(dx: 0, dy: 3), radius: 6, t) }
            case .check(let id, let title, _):
                let on = !disabled.contains(id)
                if let label = checkLabels[id] {
                    c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                }
                let b = CGRect(x: box.minX, y: box.midY - 7, width: 14, height: 14)
                InspectorDraw.checkbox(&c, bool(id) == true ? .on : .off, box: b, hovering: hover && on, pressed: false, enabled: on,
                                       focused: focused == i, t)
                // `SQCheckbox` is body (11 pt) in every dialog form; the Settings sidebar keeps its own size.
                c.draw(SQL10n.string(title), in: CGRect(x: b.maxX + 6, y: box.minY, width: box.width - 20, height: box.height),
                       fontSize: sidebar == nil ? CGFloat(DrawTheme.TypeSize.body) : font, on ? t.label : Self.dim(t.label))
                if let cf = checkFields[id] { drawScrub(&c, cf.field, focused: focused == i && focusedScrub == cf.field.id, t) }
            case .number(let label, let f):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, disabled.contains(f.id) ? Self.dim(t.label2) : t.label2,
                       align: labelAlign)
                drawScrub(&c, f, focused: focused == i, t)
            case .radioNumbers(let id, let options, _, let fs):
                for (n, o) in options.enumerated() {
                    let ry = box.minY + CGFloat(n) * (M.rowHeight + M.rowGap)
                    let off = fs.indices.contains(n) && disabled.contains(fs[n].id)
                    drawRadio(&c, on: index(id) == n, enabled: !off, at: CGPoint(x: box.minX, y: ry + M.rowHeight / 2 - 7), t)
                    c.draw(SQL10n.string(o), in: CGRect(x: box.minX + 20, y: ry, width: M.radioColumn - 24, height: M.rowHeight),
                           fontSize: CGFloat(DrawTheme.TypeSize.body), off ? Self.dim(t.label) : t.label)
                    if fs.indices.contains(n) { drawScrub(&c, fs[n], focused: false, t) }
                }
                if focused == i, let n = index(id), fs.indices.contains(n), scrubs[fs[n].id]?.isEditing != true {
                    let ry = box.minY + CGFloat(n) * (M.rowHeight + M.rowGap)
                    InspectorDraw.focusLine(&c, CGRect(x: box.minX - 3, y: ry + 4, width: M.radioColumn - 8, height: M.rowHeight - 8),
                                            radius: 4, t)
                }
            case .sliderNumber(let label, let f):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                let span = f.range.upperBound - f.range.lowerBound
                InspectorDraw.slider(&c, fraction: span > 0 ? ((number(f.id) ?? 0) - f.range.lowerBound) / span : 0,
                                     in: sliderNumberParts(box, unit: f.unit).track, enabled: !scrubOff(f.id), t)
                drawScrub(&c, f, focused: focused == i, t)
            case .slider(let id, let label, _, let range, _):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                let parts = sliderParts(i)
                let span = range.upperBound - range.lowerBound
                InspectorDraw.slider(&c, fraction: span > 0 ? ((number(id) ?? 0) - range.lowerBound) / span : 0, in: parts.track,
                                     enabled: true, t)
                if fields[i]?.isEditing != true { fields[i]?.text = Self.format(number(id) ?? 0) }
                fields[i]?.fontSize = M.font
                fields[i]?.draw(&c, in: parts.field, theme: t, focused: focused == i)
            case .radio(let id, let options, _):
                for (n, o) in options.enumerated() {
                    let ry = box.minY + CGFloat(n) * M.checkRowHeight
                    drawRadio(&c, on: index(id) == n, enabled: true, at: CGPoint(x: box.minX, y: ry + M.checkRowHeight / 2 - 7), t)
                    c.draw(SQL10n.string(o), in: CGRect(x: box.minX + 20, y: ry, width: box.width - 20, height: M.checkRowHeight),
                           fontSize: CGFloat(DrawTheme.TypeSize.body), t.label)   // `SQRadio` title: Typography.body
                }
                if focused == i { InspectorDraw.focusLine(&c, box, radius: 4, t) }
            case .buttons(let id, let label, let detail, let titles, _):
                if !label.isEmpty { c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign) }
                let frames = buttonFrames(i)
                let textRight = (frames.first?.minX ?? box.maxX) - M.controlGap
                if let chip = chips[id] {
                    let r = CGRect(x: box.minX, y: box.minY, width: max(0, textRight - box.minX), height: box.height)
                    c.fill(roundedRect: r, radius: 8, t.fill)
                    c.draw(icon: chip.icon, at: CGPoint(x: r.minX + 12, y: (r.midY - 8).rounded()), size: 16, t.label2)
                    let tx = r.minX + 12 + 16 + 8 + labelInset, tw = max(r.maxX - 12 - tx, 0)
                    c.draw(measure.truncatedMiddle(detail, width: tw, size: font), in: CGRect(x: tx, y: r.minY, width: tw, height: r.height),
                           fontSize: font, t.label2)
                } else {
                    c.draw(detail, in: CGRect(x: box.minX, y: box.minY, width: max(0, textRight - box.minX), height: box.height),
                           fontSize: font, t.label)
                }
                for (n, r) in frames.enumerated() {
                    InspectorDraw.button(&c, title: SQL10n.string(titles[n]), in: r, hovering: hover && hoveredPoint.map(r.contains) == true,
                                            pressed: false, enabled: buttonEnabled(i, n),
                                         height: chips[id] != nil ? M.rowHeight : CGFloat(InspectorTokens.capsule), t)   // the Mac's Choose... is 28 pt
                }
                if focused == i, let first = frames.first { InspectorDraw.focusLine(&c, first, radius: 6, t) }
            case .listBox(_, let label, let lines, let button, let empty):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                c.fill(roundedRect: box, radius: CGFloat(DrawTheme.Radius.control), t.inkFill(0.06))
                if lines.isEmpty {
                    var y = box.minY + 6
                    for l in noteLines[i] ?? [] {
                        c.draw(l, in: CGRect(x: box.minX + 12, y: y, width: box.width - 24, height: M.noteLine), fontSize: font, t.label3)
                        y += M.noteLine
                    }
                }
                for (n, r) in listButtonFrames(i).enumerated() {
                    if case .listBox(let id, _, _, _, _) = rows[i], let extra = listLines[id], extra.indices.contains(n) {
                        drawListLine(&c, lines[n], extra[n], box: box, button: r, t)
                    } else {
                        c.draw(lines[n], in: CGRect(x: box.minX + 12, y: r.minY, width: max(r.minX - box.minX - 20, 0), height: r.height), fontSize: font, t.label)
                    }
                    InspectorDraw.button(&c, title: SQL10n.string(button), in: r.insetBy(dx: 0, dy: 0), hovering: hover && hoveredPoint.map(r.contains) == true,
                                         pressed: false, enabled: true, t)
                }
            case .caption(let s):
                if sidebar != nil {
                    c.draw(SQL10n.string(s), in: box, fontSize: M.captionFont, t.label3, face: c.atlas?.mediumFace ?? 0)
                } else {
                    c.draw(SQL10n.string(s), in: box, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3)
                }
            case .size(let label, let w, let h):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                drawScrub(&c, w, focused: focused == i, t)
                drawScrub(&c, h, focused: false, t)
                if plainSize.contains(w.id) {
                    let a = scrubFrames[w.id] ?? box, b = scrubFrames[h.id] ?? box
                    c.draw("\u{00D7}", in: CGRect(x: a.maxX, y: box.minY, width: b.minX - a.maxX, height: box.height),
                           fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, align: .center)
                } else {
                    if !swapBetween.contains(w.id) { c.draw("\u{00D7}", in: CGRect(x: box.minX + M.sizeField + M.controlGap, y: box.minY, width: M.timesWidth + 2,
                                                   height: box.height), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3) }
                    let sw = swapFrame(i)
                    if hover, hoveredPoint.map(sw.contains) == true {
                        c.fill(roundedRect: sw.insetBy(dx: 0, dy: 2), radius: CGFloat(DrawTheme.Radius.control), t.fillHover)
                    }
                    c.draw(icon: .swap, at: CGPoint(x: sw.midX - 7, y: (sw.midY - 7).rounded()), size: 14, t.label2)
                }
            case .segmented(let id, let label, let options, _, let sw):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
                let track = CGRect(x: box.minX, y: box.midY - 11, width: box.width, height: 22)
                c.fill(roundedRect: track, radius: 6, t.inkFill(0.06))
                let widths = Self.segmentWidths(options, sw, measure)
                for (n, o) in options.enumerated() {
                    let seg = CGRect(x: track.minX + 1 + widths[..<n].reduce(0, +), y: track.minY + 1, width: widths[n], height: track.height - 2)
                    if n == index(id) { c.fill(roundedRect: seg, radius: 4, t.fillPressed) }
                    else if hover, hoveredPoint.map(seg.contains) == true { c.fill(roundedRect: seg, radius: 4, t.fill) }
                    c.draw(SQL10n.string(o), in: seg, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label, align: .center)
                }
                if focused == i { InspectorDraw.focusLine(&c, track, radius: 6, t) }
            case .label(_, let label):
                c.draw(SQL10n.string(label), in: labelRect, fontSize: font, t.label2, align: labelAlign)
            case .chart(_, let title, let bars):
                drawChart(&c, i, title: title, bars: bars, t)
            case .textBox(let id, _, _):
                drawTextBox(&c, i, id: id, t)
            case .gap: break
            }
            if let id = Self.id(of: r), let cells = grids[id] {
                for cell in cells {
                    if let tr = gridTitleFrames[cell.field.id] {
                        c.draw(SQL10n.string(cell.title), in: tr, fontSize: font, scrubOff(cell.field.id) ? Self.dim(t.label3) : t.label3)
                    }
                    drawScrub(&c, cell.field, focused: focused == i && focusedScrub == cell.field.id, t)
                    if !cell.unit.isEmpty, let fb = scrubFrames[cell.field.id] {
                        c.draw(SQL10n.string(cell.unit), in: CGRect(x: fb.maxX + M.gridGap, y: fb.minY, width: 60, height: fb.height),
                               fontSize: font, t.label3)
                    }
                }
            }
            if let id = Self.id(of: r), let st = statuses[id], let line = statusFrames[i] { drawStatus(&c, i, st, line, t) }
            if let lines = helpLines[i] {
                var y = helpTops[i] ?? box.maxY + M.helpGap
                let x = sidebar != nil ? row.minX + sidePad + labelWidth + M.labelGap : box.minX
                for l in lines {
                    c.draw(l, in: CGRect(x: x, y: y, width: M.helpMaxWidth, height: helpLine), fontSize: font, t.label3); y += helpLine
                }
            }
            if let id = Self.id(of: r), let hint = hints[id], !hint.isEmpty {
                let x = box.maxX + M.controlGap + labelInset
                c.draw(SQL10n.string(hint), in: CGRect(x: x, y: box.minY, width: max(row.maxX - sidePad - x, 0), height: M.rowHeight),
                       fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3)
            }
        }
        if let link, linkFrame.width > 0 {
            let on = bool(link.id) == true, off = link.fields.contains(where: disabled.contains)
            let tint = on ? t.accent : t.label2
            c.draw(icon: on ? .link : .unlink, at: CGPoint(x: linkFrame.midX - 6, y: (linkFrame.midY - 6).rounded()), size: 12,
                   off ? Self.dim(tint) : tint)
        }
    }

    /// The Mac Edit API status line: dot (idle `label3`, ok green, warning), text (`label3` idle, else `label2`), button.
    private func drawStatus(_ c: inout Canvas, _ i: Int, _ st: Status, _ line: CGRect, _ t: DrawTheme) {
        let dot: DrawColor = switch st.tone {
        case .idle: t.label3
        case .ok: t.green
        case .warning: MenuListView.color(palette: t.palette.warning)
        }
        c.fill(roundedRect: CGRect(x: line.minX, y: (line.midY - M.statusDot / 2).rounded(), width: M.statusDot, height: M.statusDot),
               radius: CGFloat(DrawTheme.Radius.small), dot)
        let tx = line.minX + M.statusDot + M.gridGap
        let right = statusButtonFrames[i]?.minX ?? line.maxX
        c.draw(SQL10n.string(st.text), in: CGRect(x: tx, y: line.minY, width: max(right - tx, 0), height: line.height), fontSize: font,
               st.tone == .idle ? t.label3 : t.label2)
        guard let b = statusButtonFrames[i], let title = st.button else { return }
        let hover = hovered == i && hoveredPoint.map(b.contains) == true
        InspectorDraw.button(&c, title: "", in: b, hovering: hover, pressed: false, enabled: true, t)
        var x = b.minX + InspectorDraw.buttonPadding
        if let icon = st.buttonIcon {
            c.draw(icon: icon, at: CGPoint(x: x, y: (b.midY - 6).rounded()), size: 12, t.label); x += 18
        }
        c.draw(SQL10n.string(title), in: CGRect(x: x, y: b.minY, width: max(b.maxX - x, 0), height: b.height), fontSize: font, t.label)
    }

    /// `CutCheckSheetView` + `ShotHistogramView`: the note, the chart title, a column per bar (count over a bar with 3 pt top
    /// corners in `accentFill`, label under it).
    private func drawChart(_ c: inout Canvas, _ i: Int, title: String, bars: [Bar], _ t: DrawTheme) {
        guard let parts = chartParts[i] else { return }
        let box = controlFrames[i], size = CGFloat(DrawTheme.TypeSize.body)
        var y = box.minY
        for l in noteLines[i] ?? [] {
            c.draw(l, in: CGRect(x: box.minX, y: y, width: box.width, height: M.noteLine), fontSize: size, t.label2); y += M.noteLine
        }
        c.draw(SQL10n.string(title), in: CGRect(x: box.minX, y: parts.title, width: box.width, height: M.chartTitleLine), fontSize: size,
               t.label2, face: c.medium)
        guard !bars.isEmpty else { return }
        let chart = parts.chart, cap = CGFloat(DrawTheme.TypeSize.caption)
        let top = max(bars.map(\.count).max() ?? 1, 1)
        let colW = (chart.width - M.gridGap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        let baseline = chart.maxY - M.chartLine - M.chartInner
        for (n, b) in bars.enumerated() {
            let x = chart.minX + CGFloat(n) * (colW + M.gridGap)
            let h = b.count == 0 ? 0 : max(3, (M.chartBarMax * CGFloat(b.count) / CGFloat(top)).rounded())
            let bar = CGRect(x: x, y: baseline - h, width: colW, height: h)
            if h > 0 {
                c.fill(roundedRect: bar, radius: 3, t.accentFill)
                c.fill(CGRect(x: bar.minX, y: bar.maxY - min(3, h / 2), width: bar.width, height: min(3, h / 2)), t.accentFill)
            }
            c.draw("\(b.count)", in: CGRect(x: x, y: bar.minY - M.chartInner - M.chartLine, width: colW, height: M.chartLine),
                   fontSize: cap, t.label2, align: .center)
            c.draw(b.label, in: CGRect(x: x, y: baseline + M.chartInner, width: colW, height: M.chartLine), fontSize: cap, t.label3,
                   align: .center)
        }
    }

    /// `ProjectNotesDialog.NotesBox`: field fill, radius 8, a 1 pt `fieldEdge` (`accentRing` while it edits), body text 6 in.
    private func drawTextBox(_ c: inout Canvas, _ i: Int, id: String, _ t: DrawTheme) {
        let box = controlFrames[i], size = CGFloat(DrawTheme.TypeSize.body)
        let radius = CGFloat(8)
        c.fill(roundedRect: box, radius: radius, t.field)
        c.stroke(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5, width: 1,
                 boxEditor != nil && focused == i ? t.accent.alpha(0.45) : t.inkFill(0.10))
        let visible = box.insetBy(dx: M.boxInset, dy: M.boxInset)
        if let e = boxEditor, focused == i {
            let line = CGFloat(e.position(of: e.caret).line)
            if (line + 1) * M.boxLine - boxScroll > visible.height { boxScroll = (line + 1) * M.boxLine - visible.height }
            if line * M.boxLine < boxScroll { boxScroll = line * M.boxLine }
            c.saveGState(); c.clip(to: visible)
            InspectorDraw.editLines(&c, e, in: CGRect(x: visible.minX, y: visible.minY - boxScroll, width: visible.width,
                                                      height: visible.height + boxScroll), lineHeight: M.boxLine, fontSize: size,
                                    color: t.label, t)
            c.restoreGState()
            return
        }
        c.saveGState(); c.clip(to: visible)
        var y = visible.minY - boxScroll
        for l in (text(id) ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            c.draw(String(l), in: CGRect(x: visible.minX, y: y, width: visible.width, height: M.boxLine), fontSize: size, t.label)
            y += M.boxLine
        }
        c.restoreGState()
    }

    /// The Mac `SettingsSidebarRow`: icon 14 and title, the selected page on `fill`, the rule after the column.
    private func drawSidebar(_ c: inout Canvas, _ sidebar: Sidebar, theme t: DrawTheme) {
        let sel = index(sidebar.id) ?? 0
        for (n, r) in sidebarFrames.enumerated() where sidebar.items.indices.contains(n) {
            let on = n == sel
            if on || sidebarHovered == n {
                c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), on ? t.fill : t.fillHover)
            }
            if on, sidebarFocused { InspectorDraw.focusLine(&c, r, radius: CGFloat(DrawTheme.Radius.control), t) }
            let item = sidebar.items[n]
            c.draw(icon: item.icon, at: CGPoint(x: r.minX + 12, y: (r.midY - 7).rounded()), size: 14, on ? t.label : t.label3)
            c.draw(SQL10n.string(item.title), in: CGRect(x: r.minX + 12 + 14 + 8, y: r.minY, width: max(r.width - 42, 0), height: r.height),
                   fontSize: font, on ? t.label : t.label2)
        }
        c.fill(sidebarRule, t.separator)
    }
}
