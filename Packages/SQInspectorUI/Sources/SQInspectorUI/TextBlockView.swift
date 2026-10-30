import AppKit
import Observation
import SQText

/// Where a text block sits. The block is identical in all three; the context only decides the extras around it.
public enum TextBlockContext: Sendable {
    /// Controls, text clip selected: Text (with the text box when `showsTextBox`) and Appearance. The host places
    /// `arrangeRows` under Transform and `animationSection` after it (the Controls skeleton).
    case clip
    /// Captions > Look: no text box, no clip animation or clip position (the caption tab has its own).
    case captions
    /// Graphics, text layer selected: text box and Animation (In, Out, animators); no Looks gallery, no position.
    case graphics
}

/// The one text block (text concept B, Bild 5): Text (text box, Font, Size, Spacing, Format), Appearance (the Look with
/// its edited state, then Fill, Outline, Background, Shadow, Second Line; each with a checkbox, color well, main value
/// and an Open chevron that reveals detail rows), and Animation. Appearance is the only place for the style values.
/// Same view in Controls, Captions > Look and Graphics; plain controls bound to `TextInspectorModel`, every edit one
/// undo step. Every row sits on `ControlsGrid`.
@MainActor
public final class TextBlockView: NSView {
    public let model: TextInspectorModel
    public let context: TextBlockContext
    /// The clip's text, so look names can be previewed with it when it is short. Set by the host.
    public var clipText: () -> String = { "" }
    /// The block grew or shrank (a detail opened or closed): the host lays out again.
    public var onHeightChange: (() -> Void)?

    // MARK: Text box (Controls and Graphics; the host owns the text itself)

    /// Shows the multi-line text box at the top of the Text section.
    public var showsTextBox: Bool { didSet { textBox.isHidden = !showsTextBox } }
    /// The box content; setting it fires no callback and is ignored while the user types in the box.
    public var text: String {
        get { textBox.string }
        set { textBox.setString(newValue) }
    }
    /// Focuses the text box with the caret at the end; false when the box is hidden or the block is not in a window.
    @discardableResult
    public func focusTextBox() -> Bool {
        guard showsTextBox, window != nil else { return false }
        textBox.focus()
        return true
    }
    /// A typing gesture starts (first change after focus), a change was typed, the gesture ended (focus left).
    public var onTextBegin: (() -> Void)? { didSet { textBox.onBegin = onTextBegin } }
    public var onTextChange: ((String) -> Void)? { didSet { textBox.onChange = onTextChange } }
    public var onTextEnd: (() -> Void)? { didSet { textBox.onEnd = onTextEnd } }

    // MARK: Look (the saved text looks by default; Captions swap in the caption looks)

    /// One entry of the Look popup.
    public struct LookSource {
        public var titles: [String]
        public var ids: [String]
        public var selected: String?
        public var pick: (String) -> Void
        /// The "+" button (save current as look); nil hides it.
        public var add: (() -> Void)?
        public init(titles: [String], ids: [String], selected: String?, pick: @escaping (String) -> Void, add: (() -> Void)?) {
            self.titles = titles; self.ids = ids; self.selected = selected; self.pick = pick; self.add = add
        }
    }
    /// nil = the model's text looks (`TextInspectorModel.styles`).
    public var lookSource: (() -> LookSource)? { didSet { refreshLook() } }
    /// The Look popup and "+" (tests and the Captions tab read them).
    let lookMenu = TextPanelMenuButton()
    private let lookAdd = IconButton(symbol: .plus, label: "Save Current as Look", handler: {})

    /// The Look the text carries and whether its values were changed since (the Appearance header shows both).
    public struct LookStatus: Equatable {
        public var name: String
        public var edited: Bool
        /// False for a built-in Look: only Save as New is offered.
        public var canUpdate: Bool
        public init(name: String, edited: Bool, canUpdate: Bool) { self.name = name; self.edited = edited; self.canUpdate = canUpdate }
    }
    /// nil = the model's text looks (`TextInspectorModel.styles`); Controls passes the session's Look state.
    public var lookStatus: (() -> LookStatus?)? { didSet { refreshLook() } }
    /// Update (write the current values back into the Look) and Save as New; nil = the model's text looks.
    public var onUpdateLook: (() -> Void)?
    public var onSaveLookAsNew: (() -> Void)?
    /// Context menu of the Look popup when `lookSource` feeds it.
    public var lookContext: (() -> [SQMenuItem])?
    /// Asks for a Look's name (Save as New Look, Rename): the same prompt in every host. Tests replace it.
    public var askLookName: (_ title: String, _ initial: String) -> String? = { TextBlockView.promptLookName($0, $1) }
    /// Tells the user that something did not happen (a Custom animation that could not be saved). Hosts route it to
    /// their status line; on its own the block shows an SQ dialog.
    public var onNotice: (String) -> Void = { TextBlockView.noticeDialog($0) }
    /// "Clean White · edited" in the Look actions row (visible while the Look is edited).
    let lookStateLabel = InspectorSectionHeader.makeSummaryLabel()
    let lookUpdate = SQButton(title: "Update", target: nil, action: nil)
    let lookSaveNew = SQButton(title: "Save as New", target: nil, action: nil)
    private(set) var lookActionsRow: TextBlockRow?

    // MARK: Parts the Controls skeleton places itself (`.clip`)

    /// Arrange: where the text box sits and the six align-to-frame buttons. Controls shows them as the last rows of
    /// Transform.
    let arrangeRows = NSStackView()
    /// Animation (In, Out, the animators and the animated looks). In Controls it follows Transform.
    var animationSection: InspectorSection { animation }

    // MARK: Controls

    private let fontControl: any TextFontControl
    private let weightMenu = TextPanelMenuButton()
    private let sizeField = NumericSlider(value: 48, range: 1...400, defaultValue: 48, step: 1, decimals: 1, unit: "px")
    // Text metrics: icon-led fields, the tooltip names the value.
    /// Letter spacing: its icon stands in the label column, the number sits on `valueX` like every other number.
    private let trackingField = ScrubField()
    /// Line spacing: icon and number right after the letter spacing number (one grid gap between the bounds).
    private let leadingBox = IconScrubField(icon: .moveVertical, tip: "Line Spacing (px)")
    private var leadingField: ScrubField { leadingBox.field }
    /// Bold, italic, all caps, underline, strikethrough, overline: one row of toggles.
    private let styleGroup = TextPanelIconGroup([
        .init(symbol: .textBold, title: nil, tip: "Bold"), .init(symbol: .textItalic, title: nil, tip: "Italic"),
        .init(symbol: .textCaseUpper, title: nil, tip: "All Caps"), .init(symbol: .textUnderline, title: nil, tip: "Underline"),
        .init(symbol: .textStrikethrough, title: nil, tip: "Strikethrough"), .init(symbol: .textOverline, title: nil, tip: "Overline")],
        mode: .toggle)
    private let alignGroup = TextPanelIconGroup([
        .init(symbol: .textAlignLeft, title: nil, tip: "Align Text Left"),
        .init(symbol: .textAlignCenter, title: nil, tip: "Center Text"),
        .init(symbol: .textAlignRight, title: nil, tip: "Align Text Right")], mode: .selectOne)
    private let verticalGroup = TextPanelIconGroup([
        .init(symbol: .textTop, title: nil, tip: "Align Text to Top"),
        .init(symbol: .textMiddle, title: nil, tip: "Center Text Vertically"),
        .init(symbol: .textBottom, title: nil, tip: "Align Text to Bottom")], mode: .selectOne)
    /// Neither picked is automatic; pressing the picked one again returns to automatic.
    private let directionGroup = TextPanelIconGroup([
        .init(symbol: .textLTR, title: nil, tip: "Left to Right"),
        .init(symbol: .textRTL, title: nil, tip: "Right to Left")], mode: .selectOne)
    private var loupe: SQLoupe?
    private let shadowSize = NumericSlider(value: 0, range: 0...100, defaultValue: 0, step: 0.5, decimals: 1, unit: "px")

    private let fill = AppearanceRow(key: "fill", title: "Fill", hasCheck: true)
    private let fillOpacity = NumericSlider(value: 100, range: 0...100, defaultValue: 100, step: 1, decimals: 1, unit: "%")
    private let outline = AppearanceRow(key: "outline", title: "Outline", hasCheck: true)
    private let strokeWidth = NumericSlider(value: 0, range: 0...100, defaultValue: 0, step: 0.5, decimals: 1, unit: "px")
    private let strokePosition = SQSegmented(labels: ["Out", "Mid"], segmentWidth: 0)
    private let fillMode = SQSegmented(labels: ["Color", "Footage", "Invert"], segmentWidth: 0)
    private let background = AppearanceRow(key: "background", title: "Background", hasCheck: true)
    private let boxOpacity = NumericSlider(value: 100, range: 0...100, defaultValue: 100, step: 1, decimals: 1, unit: "%")
    private let padX = NumericSlider(value: 0, range: 0...400, defaultValue: 0, step: 1, decimals: 1, unit: "px")
    private let padY = NumericSlider(value: 0, range: 0...400, defaultValue: 0, step: 1, decimals: 1, unit: "px")
    private let radius = NumericSlider(value: 0, range: 0...200, defaultValue: 0, step: 1, decimals: 1, unit: "px")
    private let shadowRow = AppearanceRow(key: "shadow", title: "Shadow", hasCheck: true)
    private let shadowOpacity = NumericSlider(value: 60, range: 0...100, defaultValue: 60, step: 1, decimals: 1, unit: "%")
    private let shadowAngle = NumericSlider(value: 135, range: -360...360, defaultValue: 135, step: 1, decimals: 1, unit: "°")
    private let shadowDistance = NumericSlider(value: 0, range: 0...400, defaultValue: 0, step: 0.5, decimals: 1, unit: "px")
    private let shadowBlur = NumericSlider(value: 0, range: 0...200, defaultValue: 0, step: 0.5, decimals: 1, unit: "px")
    private let gradientRow = AppearanceRow(key: "gradient", title: "Gradient", hasCheck: true)
    private let gradientEndWell = SQColorWell()
    private let gradientAngle = NumericSlider(value: 90, range: 0...360, defaultValue: 90, step: 1, decimals: 1, unit: "°")
    private let autoFitRow = AppearanceRow(key: "autofit", title: "Shrink to Box", hasCheck: true)
    private let listRow = AppearanceRow(key: "list", title: "List", hasCheck: true)
    private let listKindMenu = TextPanelMenuButton()
    private let second = AppearanceRow(key: "second", title: "Second Line", hasCheck: true)
    private let secondSummary = NSTextField(labelWithString: "")
    private let secondFontControl: any TextFontControl
    private let secondWeightMenu = TextPanelMenuButton()
    private let secondSize = NumericSlider(value: 48, range: 1...400, defaultValue: 48, step: 1, decimals: 1, unit: "px")
    private let secondWell = SQColorWell()
    private let secondItalic = TextPanelIconGroup([.init(symbol: nil, title: "I", tip: "Italic", traits: .italic)], mode: .toggle)

    // Animation (clip)
    private let animation = InspectorSection(title: "Animation", key: "textblock.animation", defaultOpen: false)
    private let animationSummary = InspectorSectionHeader.makeSummaryLabel()
    /// Font and size in the Text header.
    private let textSummary = InspectorSectionHeader.makeSummaryLabel()
    // Animated looks (clip): the gallery's entrance, loop and exit looks as style + animation in one click. Last row of
    // Animation.
    private let lookGallery = CaptionStyleLookGalleryView(groups: [.entrance, .motion, .exit])
    private let inMenu = TextPanelMenuButton(), outMenu = TextPanelMenuButton()
    /// Intro / Outro zone lengths (ms): the first N and last M seconds of the clip; they keep their length when it is trimmed.
    private let inLength = ScrubField(), outLength = ScrubField()
    // The font's variation axes (Text section)
    private let axisRows = NSStackView()
    private var axisFontName: String?
    private var axisFields: [(axis: FontResolver.Axis, field: ScrubField)] = []
    private let alignFrameGroup: TextPanelIconGroup
    private static let alignSymbols: [(FrameAlignment, SQIcon, String)] = [
        (.left, .alignLeft, "Align Left"), (.centerHorizontally, .alignCenterH, "Align Center Horizontally"),
        (.right, .alignRight, "Align Right"), (.top, .alignTop, "Align Top"),
        (.centerVertically, .alignCenterV, "Align Center Vertically"), (.bottom, .alignBottom, "Align Bottom"),
    ]

    /// W8.3: one menu per field that can follow a kit token ("Literal" releases it). Each sits in the detail rows of its
    /// layer (Font under Format); a row only shows when the project's kit has tokens for the field.
    private let tokenMenus: [(TextInspectorModel.TokenField, String, TextPanelMenuButton)] = [
        (.font, "Font", TextPanelMenuButton()), (.color, "Color", TextPanelMenuButton()),
        (.strokeColor, "Color", TextPanelMenuButton()), (.backgroundColor, "Color", TextPanelMenuButton()),
    ]
    private var tokenRows: [TextInspectorModel.TokenField: TextBlockRow] = [:]

    /// Controls of one text animator side (in or out).
    @MainActor private final class AnimatorControls {
        let side: TextInspectorModel.AnimatorSide
        let effect = TextPanelMenuButton(), unit = TextPanelMenuButton(), direction = TextPanelMenuButton()
        let easing = TextPanelMenuButton(), order = TextPanelMenuButton()
        let stagger = ScrubField(), duration = ScrubField(), distance = ScrubField(), blur = ScrubField()
        let loops = ScrubField()
        init(side: TextInspectorModel.AnimatorSide) { self.side = side }
        var menus: [TextPanelMenuButton] { [effect, unit, direction, easing, order] }
    }
    // One list for the Mac and the shared-toolkit block (TextAnimatorChoices).
    private static let effects = TextAnimatorChoices.effects, units = TextAnimatorChoices.units
    private static let directions = TextAnimatorChoices.directions, easings = TextAnimatorChoices.easings
    private static let orders = TextAnimatorChoices.orders
    private let animIn = AnimatorControls(side: .in), animOut = AnimatorControls(side: .out)
    private static let weights: [(String, FontWeight)] = [
        ("Thin", .thin), ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]

    private let textBox = TextBoxView()
    private var lastFillAlpha = 1.0
    private var colorSessionOpen = false
    private var colorSessionEnd: Task<Void, Never>?
    private var rootStack = NSStackView()

    isolated deinit {
        colorSessionEnd?.cancel()
        if wellSessionOpen { model.endEditing() }
        if colorSessionOpen { model.endEditing() }       // the timer will never run: close the undo step now
    }

    /// The font field. One line to swap in the typeable capsule (`SQFontField`): return it here, it conforms to
    /// `TextFontControl` (families in, one picked family out).
    static func makeFontControl() -> any TextFontControl { SQFontFieldControl() }

    public init(model: TextInspectorModel, context: TextBlockContext) {
        self.model = model
        self.context = context
        showsTextBox = context == .graphics
        fontControl = Self.makeFontControl()
        secondFontControl = Self.makeFontControl()
        alignFrameGroup = TextPanelIconGroup(Self.alignSymbols.map { .init(symbol: $0.1, title: nil, tip: $0.2) }, mode: .momentary)
        super.init(frame: NSRect(x: 0, y: 0, width: 332, height: 560))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
        track()
    }

    /// Existing call sites: `forCaptions` is the Captions > Look block.
    public convenience init(model: TextInspectorModel, forCaptions: Bool = false) {
        self.init(model: model, context: forCaptions ? .captions : .clip)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Control setup

    private func scrub(_ f: ScrubField, range: ClosedRange<Double>, step: Double = 1, decimals: Int = 0, unit: String = "",
                       width: CGFloat? = nil, reset: Double? = nil, _ apply: @escaping (Double) -> Void) {
        f.range = range; f.step = step; f.decimals = decimals; f.unit = unit
        f.defaultValue = reset
        f.onBegin = { [weak self] in self?.model.beginEditing() }
        f.onChange = { v in apply(v) }
        f.onEnd = { [weak self] v in apply(v); self?.model.endEditing() }
        if let width { f.widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    /// Preview on Up/Down inside one open undo session; Return/click applies in it, Esc restores, the session closes when the field ends.
    private func wireFont(_ c: any TextFontControl, set: @escaping (String) -> Void) {
        var open = false
        c.onPreview = { [weak self] name in
            if !open { open = true; self?.model.beginEditing() }
            set(name)
        }
        c.onPick = { name in set(name) }
        c.onEnd = { [weak self] in
            if open { open = false; self?.model.endEditing() }
        }
    }

    private func slider(_ n: NumericSlider, _ apply: @escaping (Double) -> Void) {
        n.fieldLeading = true
        n.fieldWidth = ControlsGrid.valueWidth
        n.gap = ControlsGrid.gap
        n.onBegin = { [weak self] in self?.model.beginEditing() }
        n.onChange = { v in apply(v) }
        n.onEnd = { [weak self] v in apply(v); self?.model.endEditing() }
    }

    private func menu(_ m: TextPanelMenuButton, width: CGFloat? = nil) {
        if let width { m.widthAnchor.constraint(equalToConstant: width).isActive = true }
        else { Self.flex(m) }
    }

    static func flex(_ v: NSView) {
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = Theme.Typography.body; t.textColor = Theme.Colors.label3
        return t
    }

    /// One grid row (`ControlsGrid`): every row of the block has the same columns and the same height.
    private func row(_ label: String?, _ controls: [NSView]) -> TextBlockRow {
        TextBlockRow(label: label, controls: controls)
    }

    private func detailRow(_ label: String, _ controls: [NSView]) -> TextBlockRow { row(label, controls) }

    private func spacer() -> NSView { let v = NSView(); Self.flex(v); return v }

    private func well(_ w: SQColorWell, _ tip: String, action: Selector) {
        w.target = self; w.action = action; w.sqToolTip = tip
        w.showsAlpha = true
        w.onOpen = { [weak self] in self?.openWellSession() }
        w.onClose = { [weak self] in self?.closeWellSession() }
        w.widthAnchor.constraint(equalToConstant: AppearanceRow.swatchWidth).isActive = true
        w.heightAnchor.constraint(equalToConstant: Theme.Row.swatch.height).isActive = true
    }

    // MARK: Build

    private func build() {
        // Look
        lookMenu.placeholder = "Custom"
        lookMenu.sqToolTip = "Look"
        lookMenu.onSelect = { [weak self] i in
            guard let self else { return }
            guard let id = lookMenu.ids[safe: i] ?? nil else { return }
            if let src = lookSource?() { src.pick(id) } else { model.applyStyle(id) }
        }
        lookAdd.handler = { [weak self] in self?.saveLookAsNew() }
        lookMenu.contextItems = { [weak self] in self?.lookContextItems() ?? [] }
        menu(lookMenu)
        lookAdd.widthAnchor.constraint(equalToConstant: ControlsGrid.resetWidth).isActive = true
        lookStateLabel.setAccessibilityLabel("Look state")
        lookUpdate.target = self; lookUpdate.action = #selector(updateLookPressed)
        lookUpdate.sqToolTip = Tooltip.text("Update the Look", shortcut: nil)
        lookSaveNew.target = self; lookSaveNew.action = #selector(saveLookAsNewPressed)
        lookSaveNew.sqToolTip = Tooltip.text("Save as New Look", shortcut: nil)

        // Font + format
        wireFont(fontControl, set: { [weak self] in self?.model.setFontFamily($0) })
        Self.flex(fontControl)
        weightMenu.setItems(Self.weights.map(\.0), selected: 2)
        weightMenu.onSelect = { [weak self] i in if Self.weights.indices.contains(i) { self?.model.setWeight(Self.weights[i].1) } }
        weightMenu.sqToolTip = "Weight"
        menu(weightMenu, width: 78)
        slider(sizeField) { [weak self] in self?.model.setSize($0) }
        sizeField.sqToolTip = "Size"
        styleGroup.onPress = { [weak self] i in
            guard let self else { return }
            let on = styleGroup.selected.contains(i)
            switch i {
            case 0: model.setWeight(on ? max(model.style.weight, .bold) : .regular)
            case 1: model.setItalic(on)
            case 2: model.setAllCaps(on)
            case 3: model.setUnderline(on)
            case 4: model.setStrikethrough(on)
            default: model.setOverline(on)
            }
        }
        alignGroup.onPress = { [weak self] i in
            let a: [TextAlignment] = [.left, .center, .right]
            if a.indices.contains(i) { self?.model.setAlignment(a[i]) }
        }
        verticalGroup.onPress = { [weak self] i in
            let a: [TextVerticalAlignment] = [.top, .middle, .bottom]
            if a.indices.contains(i) { self?.model.setVerticalAlignment(a[i]) }
        }
        directionGroup.onPress = { [weak self] i in
            guard let self else { return }
            let picked: TextDirection = i == 0 ? .leftToRight : .rightToLeft
            let again = !model.isMixed("direction") && model.style.direction == picked
            model.setDirection(again ? nil : picked)
            if again { directionGroup.selected = [] }
        }
        scrub(trackingField, range: -100...500, step: 0.5, decimals: 1, unit: "", reset: 0) { [weak self] in self?.model.setTracking($0) }
        scrub(leadingField, range: -200...500, step: 1, decimals: 1, unit: "", reset: 0) { [weak self] in self?.model.setLineSpacing($0) }

        // Fill
        well(fill.well, "Fill Color", action: #selector(fillWellChanged))
        fill.check.target = self; fill.check.action = #selector(fillChecked)
        scrub(fill.value, range: 0...100, step: 1, decimals: 1, unit: "%", reset: 100) { [weak self] in self?.setFillOpacity($0) }
        slider(fillOpacity) { [weak self] in self?.setFillOpacity($0) }
        fill.detail.append(detailRow("Opacity", [fillOpacity]))
        fillMode.target = self; fillMode.action = #selector(fillModeChanged)
        fillMode.sqToolTip = "Fill Mode"
        fill.detail.append(detailRow("Mode", [fillMode, spacer()]))

        // Outline
        well(outline.well, "Outline Color", action: #selector(outlineWellChanged))
        outline.check.target = self; outline.check.action = #selector(outlineChecked)
        scrub(outline.value, range: 0...100, step: 0.5, decimals: 1, unit: "px", reset: 0) { [weak self] in self?.model.setStrokeWidth($0) }
        slider(strokeWidth) { [weak self] in self?.model.setStrokeWidth($0) }
        strokePosition.target = self; strokePosition.action = #selector(strokePositionChanged)
        strokePosition.sqToolTip = "Outline Position"
        outline.detail.append(TextBlockRow(label: nil, icon: .minimize, tip: "Outline Width", controls: [strokeWidth]))
        outline.detail.append(detailRow("Position", [strokePosition, spacer()]))
        fill.addEyedropper(tip: "Pick Fill Color") { [weak self] in
            self?.pickColor(alpha: { $0.color.alpha }) { $0.setColor($1) }
        }
        outline.addEyedropper(tip: "Pick Outline Color") { [weak self] in
            self?.pickColor(alpha: { $0.stroke?.color.alpha ?? 1 }) { $0.setStrokeColor($1) }
        }
        background.addEyedropper(tip: "Pick Background Color") { [weak self] in
            self?.pickColor(alpha: { $0.background?.color.alpha ?? 1 }) { $0.setBackgroundColor($1) }
        }
        shadowRow.addEyedropper(tip: "Pick Shadow Color") { [weak self] in
            self?.pickColor(alpha: { $0.shadow?.color.alpha ?? 1 }) { $0.setShadowColor($1) }
        }

        // Background
        well(background.well, "Background Color", action: #selector(backgroundWellChanged))
        background.check.target = self; background.check.action = #selector(backgroundChecked)
        scrub(background.value, range: 0...100, step: 1, decimals: 1, unit: "%", reset: 100) { [weak self] in self?.model.setBackgroundOpacity($0 / 100) }
        slider(boxOpacity) { [weak self] in self?.model.setBackgroundOpacity($0 / 100) }
        slider(padX) { [weak self] _ in self?.padChanged() }
        slider(padY) { [weak self] _ in self?.padChanged() }
        slider(radius) { [weak self] in self?.model.setBackgroundRadius($0) }
        background.detail.append(detailRow("Opacity", [boxOpacity]))
        background.detail.append(detailRow("Padding X", [padX]))
        background.detail.append(detailRow("Padding Y", [padY]))
        background.detail.append(detailRow("Radius", [radius]))

        // Shadow
        well(shadowRow.well, "Shadow Color", action: #selector(shadowWellChanged))
        shadowRow.check.target = self; shadowRow.check.action = #selector(shadowChecked)
        scrub(shadowRow.value, range: 0...100, step: 1, decimals: 1, unit: "%", reset: 60) { [weak self] in self?.model.setShadowOpacity($0 / 100) }
        slider(shadowOpacity) { [weak self] in self?.model.setShadowOpacity($0 / 100) }
        slider(shadowAngle) { [weak self] _ in self?.shadowAngleChanged() }
        slider(shadowDistance) { [weak self] _ in self?.shadowAngleChanged() }
        slider(shadowBlur) { [weak self] in self?.model.setShadowBlur($0) }
        slider(shadowSize) { [weak self] in self?.model.setShadowSpread($0) }
        for (icon, tip, control) in [(SQIcon.droplet, "Shadow Opacity", shadowOpacity), (.shadowAngle, "Shadow Angle", shadowAngle),
                                     (.move, "Shadow Distance", shadowDistance), (.maximize, "Shadow Size", shadowSize),
                                     (.circleDotted, "Shadow Blur", shadowBlur)] {
            control.sqToolTip = tip
            shadowRow.detail.append(TextBlockRow(label: nil, icon: icon, tip: tip, controls: [control]))
        }

        // Gradient fill: the row's swatch is the start color
        well(gradientRow.well, "Gradient Start Color", action: #selector(gradientStartChanged))
        well(gradientEndWell, "Gradient End Color", action: #selector(gradientEndChanged))
        gradientRow.check.target = self; gradientRow.check.action = #selector(gradientChecked)
        gradientRow.value.isHidden = true
        slider(gradientAngle) { [weak self] in self?.model.setGradientAngle($0) }
        gradientRow.detail.append(detailRow("End Color", [gradientEndWell, spacer()]))
        gradientRow.detail.append(detailRow("Angle", [gradientAngle]))

        // Shrink to box and list: plain switches
        autoFitRow.makeSwitchOnly()
        autoFitRow.check.target = self; autoFitRow.check.action = #selector(autoFitChecked)
        autoFitRow.check.sqToolTip = SQL10n.string("Shrink to Box")
        listRow.well.isHidden = true
        listRow.check.target = self; listRow.check.action = #selector(listChecked)
        listRow.value.isHidden = true
        listKindMenu.setItems(["Bullets", "Numbers"], selected: 0)
        listKindMenu.onSelect = { [weak self] i in self?.model.setList(i == 1 ? .numbered : .bullet) }
        menu(listKindMenu, width: 96)
        listRow.detail.append(detailRow("Style", [listKindMenu, spacer()]))

        // Second line (the value slot is the summary)
        second.check.target = self; second.check.action = #selector(secondChecked)
        second.well.isHidden = true
        second.value.isHidden = true; second.value.unit = "px"; second.value.defaultValue = 0
        secondSummary.font = Theme.Typography.body; secondSummary.textColor = Theme.Colors.label3
        secondSummary.lineBreakMode = .byTruncatingTail
        second.setSummary(secondSummary)
        wireFont(secondFontControl, set: { [weak self] in self?.model.setSecondLineFont($0) })
        Self.flex(secondFontControl)
        secondWeightMenu.setItems(Self.weights.map(\.0), selected: 2)
        secondWeightMenu.onSelect = { [weak self] i in if Self.weights.indices.contains(i) { self?.model.setSecondLineWeight(Self.weights[i].1) } }
        menu(secondWeightMenu, width: 78)
        slider(secondSize) { [weak self] in self?.model.setSecondLineSize($0) }
        well(secondWell, "Second Line Color", action: #selector(secondWellChanged))
        secondItalic.onPress = { [weak self] _ in
            guard let self else { return }
            model.setSecondLineItalic(secondItalic.selected.contains(0))
        }
        second.detail.append(detailRow("Font", [secondFontControl, secondWeightMenu]))
        second.detail.append(detailRow("Size", [secondSize]))
        second.detail.append(detailRow("Color", [secondWell, secondItalic, spacer()]))

        // Kit tokens (W8.3)
        for (field, name, m) in tokenMenus {
            m.sqToolTip = SQL10n.format("Follow %@ Token", SQL10n.string(name))
            m.onSelect = { [weak self] i in self?.model.bindToken(field, to: i > 0 ? m.titles[safe: i] : nil) }
            menu(m)
            let r = detailRow(SQL10n.format("%@ Token", SQL10n.string(name)), [m])
            tokenRows[field] = r
            switch field {
            case .color: fill.detail.append(r)
            case .strokeColor: outline.detail.append(r)
            case .backgroundColor: background.detail.append(r)
            case .font: break
            }
        }

        // Animation
        inMenu.onSelect = { [weak self] i in if let id = self?.inMenu.ids[safe: i] ?? nil { self?.pickAnimation(id, side: .intro) } }
        outMenu.onSelect = { [weak self] i in if let id = self?.outMenu.ids[safe: i] ?? nil { self?.pickAnimation(id, side: .outro) } }
        menu(inMenu); menu(outMenu)
        for (f, side, tip) in [(inLength, AnimationSide.intro, "Intro Length"), (outLength, .outro, "Outro Length")] {
            scrub(f, range: Double(TextInspectorModel.minimumZoneMilliseconds)...Double(TextInspectorModel.maxAnimatorMilliseconds),
                  step: 10, unit: "ms", width: 76) { [weak self] v in
                self?.model.setZoneLength(milliseconds: TextInspectorModel.milliseconds(from: v), side: side)
            }
            f.sqToolTip = tip
        }
        animation.addRow(row("Intro", [inMenu, inLength]))
        animation.addRow(row("Outro", [outMenu, outLength]))
        for v in animatorRows(animIn, title: "In") + animatorRows(animOut, title: "Out") { animation.addRow(v) }
        animation.header.addAccessory(animationSummary)

        // Arrange
        alignFrameGroup.onPress = { [weak self] i in
            if Self.alignSymbols.indices.contains(i) { self?.model.alignToFrame(Self.alignSymbols[i].0) }
        }
        arrangeRows.orientation = .vertical; arrangeRows.alignment = .leading; arrangeRows.spacing = 0
        for r in [row("Arrange", [alignFrameGroup, spacer()])] {
            arrangeRows.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: arrangeRows.widthAnchor).isActive = true
        }

        assemble()
    }

    /// The sections in the skeleton's order: Text, Appearance, then (Graphics) Animation. In Controls the host places
    /// `arrangeRows` and `animationSection` itself, under and after Transform.
    private func assemble() {
        let text = InspectorSection(title: "Text", key: "textblock.text", defaultOpen: true)
        textBox.isHidden = !showsTextBox
        textBox.onBegin = onTextBegin; textBox.onChange = onTextChange; textBox.onEnd = onTextEnd
        text.addRow(textBox)
        text.addRow(row("Font", [fontControl, weightMenu]))
        text.addRow(row("Size", [sizeField]))
        // Icon rows (Premiere's text panel): they start in the label column, the tooltip names every control.
        text.addRow(TextBlockRow(label: nil, fullWidth: true, controls: [styleGroup, spacer()]))
        text.addRow(TextBlockRow(label: nil, fullWidth: true, controls: [alignGroup, spacer()]))
        text.addRow(TextBlockRow(label: nil, fullWidth: true, controls: [IconGroupPair(verticalGroup, directionGroup), spacer()]))
        // Letter and line spacing: the first icon is the row's label, its number starts on valueX; the second pair
        // (icon + number) follows one gap later.
        trackingField.isPlain = true
        trackingField.sqToolTip = "Letter Spacing (px)"
        trackingField.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth).isActive = true
        leadingBox.widthAnchor.constraint(equalToConstant: IconScrubField.iconWidth + ControlsGrid.valueWidth).isActive = true
        text.addRow(TextBlockRow(label: nil, icon: .moveHorizontal, tip: "Letter Spacing (px)", controls: [trackingField, leadingBox, spacer()]))
        axisRows.orientation = .vertical; axisRows.alignment = .leading; axisRows.spacing = 0
        axisRows.isHidden = true
        text.addRow(axisRows)
        let fontToken = tokenRows[.font]!
        text.addRow(fontToken)

        // The style values follow in the same section (no Appearance header): the Look first (Update / Save as New while
        // it is edited), then fill, outline, background and shadow. The only place for them.
        let appearance = text
        appearance.addRow(row("Look", [lookMenu, lookAdd]))
        let actions = row(nil, [lookUpdate, lookSaveNew, lookStateLabel, spacer()])
        actions.isHidden = true
        lookActionsRow = actions
        appearance.addRow(actions)
        for r in [fill, gradientRow, outline, background, shadowRow, second, autoFitRow, listRow] { appearance.addRow(r) }

        text.header.addAccessory(textSummary)
        // Graphics: Text sits below Arrange / Transform and needs its rule; Controls and Captions start with it.
        text.header.showsTopLine = context == .graphics
        var sections: [InspectorSection] = [text]
        if context == .clip {
            lookGallery.onPick = { [weak self] look in self?.model.applyLook(look) }
            animation.addRow(lookGallery)
            animation.onLayoutChange = { [weak self] in self?.onHeightChange?() }
        } else if context == .graphics {
            sections += [animation]
        }
        rootStack = NSStackView(views: sections)
        rootStack.orientation = .vertical; rootStack.alignment = .leading; rootStack.spacing = ControlsMetrics.sectionGap
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for s in sections {
            s.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
            s.onLayoutChange = { [weak self] in self?.onHeightChange?() }
        }
        for r in [fill, gradientRow, outline, background, shadowRow, second, autoFitRow, listRow] { r.onLayoutChange = { [weak self] in self?.onHeightChange?() } }
        if context != .clip { bottomAnchor.constraint(equalTo: rootStack.bottomAnchor).isActive = true }
    }

    private func animatorRows(_ c: AnimatorControls, title: String) -> [NSView] {
        func fillMenu(_ m: TextPanelMenuButton, _ titles: [String]) { m.setItems(titles, selected: 0) }
        fillMenu(c.effect, Self.effects.map(\.0)); fillMenu(c.unit, Self.units.map(\.0)); fillMenu(c.direction, Self.directions.map(\.0))
        fillMenu(c.easing, Self.easings.map(\.0)); fillMenu(c.order, Self.orders.map(\.0))
        let side = c.side
        c.effect.onSelect = { [weak self] i in if Self.effects.indices.contains(i) { self?.model.setAnimatorEffect(Self.effects[i].1, side: side) } }
        c.unit.onSelect = { [weak self] i in if Self.units.indices.contains(i) { self?.model.setAnimatorUnit(Self.units[i].1, side: side) } }
        c.direction.onSelect = { [weak self] i in if Self.directions.indices.contains(i) { self?.model.setAnimatorDirection(Self.directions[i].1, side: side) } }
        c.easing.onSelect = { [weak self] i in if Self.easings.indices.contains(i) { self?.model.setAnimatorEasing(Self.easings[i].1, side: side) } }
        c.order.onSelect = { [weak self] i in if Self.orders.indices.contains(i) { self?.model.setAnimatorOrder(Self.orders[i].1, side: side) } }
        for m in c.menus { menu(m) }
        c.effect.sqToolTip = SQL10n.format("%@ Animation", SQL10n.string(title))
        c.direction.sqToolTip = "Slide Direction"
        c.order.sqToolTip = "Start Order"
        let max = Double(TextInspectorModel.maxAnimatorMilliseconds)
        scrub(c.stagger, range: 0...max, step: 5, unit: "ms", reset: 80) { [weak self] v in
            self?.model.setAnimatorStagger(milliseconds: TextInspectorModel.milliseconds(from: v), side: side)
        }
        scrub(c.duration, range: 0...max, step: 5, unit: "ms", reset: Double(Self.defaultAnimatorDurationMilliseconds)) { [weak self] v in
            self?.model.setAnimatorDuration(milliseconds: TextInspectorModel.milliseconds(from: v), side: side)
        }
        scrub(c.distance, range: 0...TextInspectorModel.maxAnimatorPixels, step: 1, unit: "px", reset: TextInspectorModel.defaultAnimatorDistance) { [weak self] v in
            self?.model.setAnimatorDistance(v, side: side)
        }
        scrub(c.blur, range: 0...TextInspectorModel.maxAnimatorPixels, step: 1, unit: "px", reset: TextInspectorModel.defaultAnimatorBlur) { [weak self] v in
            self?.model.setAnimatorBlurRadius(v, side: side)
        }
        scrub(c.loops, range: 1...50, step: 1, unit: "x", reset: 1) { [weak self] v in
            self?.model.setAnimatorLoops(Int(v.rounded()), side: side)
        }
        c.loops.sqToolTip = "Loop Count"
        c.distance.sqToolTip = "Slide Distance"
        c.blur.sqToolTip = "Start Blur"
        c.stagger.sqToolTip = "Stagger"
        c.duration.sqToolTip = "Unit Length"
        for f in [c.stagger, c.duration, c.distance, c.blur, c.loops] {
            f.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth).isActive = true
        }
        let rows = [
            row(SQL10n.format("%@ by", SQL10n.string(title)), [c.effect, c.unit]),
            row(nil, [c.easing, c.direction]),
            row("Order", [c.order]),
            row("Stagger", [c.stagger]),
            row("Length", [c.duration]),
            row("Distance", [c.distance]),
            row("Blur", [c.blur]),
            row("Loops", [c.loops]),
        ]
        // Equal halves: only once both controls sit in their row (a constraint needs a common ancestor).
        for pair in [(c.effect, c.unit), (c.easing, c.direction)] { pair.0.widthAnchor.constraint(equalTo: pair.1.widthAnchor).isActive = true }
        return rows
    }

    // MARK: Model -> view

    private func track() {
        withObservationTracking {
            _ = model.style; _ = model.animations; _ = model.library; _ = model.styles; _ = model.fontFamilies; _ = model.kit
            _ = model.mixedPaths; _ = model.savedAnimations
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh(); self?.track() }
        }
    }

    private func nsColor(_ c: RGBAColor) -> NSColor { Theme.ColorBridge.ns(c) }

    private func rgba(_ c: NSColor, alpha: Double? = nil) -> RGBAColor {
        Theme.ColorBridge.rgba(c, alpha: alpha)
    }

    /// Re-reads the Look popup (the Captions tab calls it after its own state changed).
    func refreshLook() {
        if let src = lookSource?() {
            lookMenu.setItems(src.titles, ids: src.ids, selected: src.selected.flatMap { src.ids.firstIndex(of: $0) } ?? -1)
            lookAdd.isHidden = src.add == nil
        } else {
            let e = model.styles.entries
            lookMenu.setItems(e.map(\.name), ids: e.map(\.id), selected: model.selectedStyleID.flatMap { id in e.firstIndex { $0.id == id } } ?? -1)
            lookAdd.isHidden = false
        }
        refreshLookState()
    }

    /// The Look the text carries, from the host (`lookStatus`) or the model's text looks.
    var currentLookStatus: LookStatus? {
        if let lookStatus { return lookStatus() }
        guard lookSource == nil, let id = model.appliedStyleID, let e = model.styles.entry(id) else { return nil }
        return LookStatus(name: e.name, edited: model.isStyleModified, canUpdate: !e.isBuiltIn)
    }

    /// Look state: "Clean White" or "Clean White · edited"; the Update / Save as New row shows while edited.
    private func refreshLookState() {
        let s = currentLookStatus
        let text = s.map { $0.edited ? "\($0.name) \u{00B7} edited" : $0.name } ?? ""
        if lookStateLabel.stringValue != text {
            lookStateLabel.stringValue = text
            lookStateLabel.textColor = s?.edited == true ? Theme.Colors.accent : Theme.Colors.label3
        }
        lookUpdate.isEnabled = s?.canUpdate ?? false
        let hide = !(s?.edited ?? false)
        if let row = lookActionsRow, row.isHidden != hide {
            row.isHidden = hide
            onHeightChange?()
        }
    }

    @objc private func updateLookPressed() {
        if let onUpdateLook { onUpdateLook() } else if let id = model.appliedStyleID { model.updateStyleFromCurrent(id) }
        refreshLook()
    }

    @objc private func saveLookAsNewPressed() { saveLookAsNew() }

    /// Save as New Look, from the + button, the Save as New button and the Look menu: the host saves (it asks for the
    /// name with `askLookName`), or the block does for its own text looks.
    func saveLookAsNew() {
        if let onSaveLookAsNew {
            onSaveLookAsNew()
        } else if let src = lookSource?() {
            src.add?()
        } else {
            let base = model.appliedStyleID.flatMap { model.styles.entry($0)?.name }
            guard let name = askLookName("Save as New Look", base.map { "\($0) 2" } ?? "My Look") else { return }
            _ = model.saveCurrentAsStyle(named: name)
        }
        refreshLook()
    }

    private func refresh() {
        let s = model.style
        refreshLook()
        fontControl.families = model.fontFamilies
        fontControl.selectedFamily = model.isMixed("fontName") ? nil : s.fontName      // multi-select, differing fonts: empty
        weightMenu.setItems(Self.weights.map(\.0), selected: model.isMixed("weight") ? -1 : Self.weights.firstIndex { $0.1 == s.weight } ?? -1)
        sizeField.value = s.size
        trackingField.value = s.tracking; leadingField.value = s.lineSpacing
        refreshMixed()
        refreshDirectionAndAxes()
        // Multi-select: a differing switch is drawn off with a dash, a differing choice has nothing picked.
        let fm = Set([model.isMixed("weight") ? 0 : nil, model.isMixed("italic") ? 1 : nil, model.isMixed("allCaps") ? 2 : nil,
                      model.isMixed("underline") ? 3 : nil, model.isMixed("strikethrough") ? 4 : nil,
                      model.isMixed("overline") ? 5 : nil].compactMap { $0 })
        styleGroup.selected = Set([s.weight >= .bold ? 0 : nil, s.italic ? 1 : nil, s.allCaps ? 2 : nil, s.underline ? 3 : nil,
                                   s.strikethrough ? 4 : nil, s.overline ? 5 : nil].compactMap { $0 }).subtracting(fm)
        styleGroup.mixed = fm
        alignGroup.selected = model.isMixed("alignment") ? [] : [[TextAlignment.left, .center, .right].firstIndex(of: s.alignment) ?? 1]
        verticalGroup.selected = model.isMixed("verticalAlignment") ? []
            : [[TextVerticalAlignment.top, .middle, .bottom].firstIndex(of: s.verticalAlignment) ?? 0]

        // Fill: "off" is a fully transparent fill.
        if s.color.alpha > 0 { lastFillAlpha = s.color.alpha }
        fill.set(on: s.color.alpha > 0, color: nsColor(s.color), value: (s.color.alpha * 100).rounded())
        fillOpacity.value = (s.color.alpha * 100).rounded()
        fillMode.selectedSegment = model.isMixed("footageFill") ? -1 : s.footageFill == .stencil ? 1 : s.footageFill == .inverted ? 2 : 0

        outline.set(on: s.stroke != nil, color: s.stroke.map { nsColor($0.color) }, value: s.stroke?.width)
        strokeWidth.isEnabled = s.stroke != nil; strokePosition.isEnabled = s.stroke != nil
        if let v = s.stroke {
            strokeWidth.value = v.width
            strokePosition.selectedSegment = v.position == .outside ? 0 : 1
        }

        background.set(on: s.background != nil, color: s.background.map { nsColor($0.color) }, value: s.background.map { ($0.color.alpha * 100).rounded() })
        for n in [boxOpacity, padX, padY, radius] { n.isEnabled = s.background != nil }
        if let v = s.background {
            boxOpacity.value = (v.color.alpha * 100).rounded()
            padX.value = v.padding.horizontal; padY.value = v.padding.vertical; radius.value = v.cornerRadius
        }

        shadowRow.set(on: s.shadow != nil, color: s.shadow.map { nsColor($0.color) }, value: s.shadow.map { ($0.color.alpha * 100).rounded() })
        // Multi-select: a layer on in some clips and off in others, a color that differs.
        for (row, group, color) in [(fill, nil, "color"), (outline, "stroke", "stroke.color"),
                                    (background, "background", "background.color"), (shadowRow, "shadow", "shadow.color")] as [(AppearanceRow, String?, String)] {
            row.setMixed(on: group.map(model.isMixedPresence) ?? false, color: model.isMixedColor(color))
        }
        for n in [shadowOpacity, shadowAngle, shadowDistance, shadowBlur, shadowSize] { n.isEnabled = s.shadow != nil }
        if let v = s.shadow {
            shadowOpacity.value = (v.color.alpha * 100).rounded()
            shadowAngle.value = v.angle.rounded(); shadowDistance.value = v.distance; shadowBlur.value = v.blur
            shadowSize.value = v.spread
        }

        gradientRow.set(on: s.gradient != nil, color: s.gradient.map { nsColor($0.start) }, value: nil)
        if let g = s.gradient {
            if !gradientEndWell.isActive { gradientEndWell.color = nsColor(g.end) }
            gradientAngle.value = g.angle
        }
        gradientEndWell.isEnabled = s.gradient != nil; gradientAngle.isEnabled = s.gradient != nil
        if model.isMixedPresence("gradient") { gradientRow.check.state = .mixed }
        autoFitRow.set(on: s.autoFit == true, color: nil, value: nil)
        if model.isMixedPresence("autoFit") { autoFitRow.check.state = .mixed }
        listRow.set(on: s.list != nil, color: nil, value: nil)
        if model.isMixedPresence("list") { listRow.check.state = .mixed }
        listKindMenu.setItems(["Bullets", "Numbers"], selected: s.list == .numbered ? 1 : 0)
        listKindMenu.isEnabled = s.list != nil

        second.check.state = s.secondLine != nil ? .on : .off
        second.setDimmed(s.secondLine == nil)
        for c in [secondFontControl as NSView, secondWeightMenu, secondSize, secondWell, secondItalic] {
            (c as? NSControl)?.isEnabled = s.secondLine != nil
            (c as? NumericSlider)?.isEnabled = s.secondLine != nil
            c.alphaValue = s.secondLine != nil ? 1 : 0.4
        }
        secondFontControl.families = model.fontFamilies
        secondFontControl.selectedFamily = s.secondLine?.fontName
        if let l = s.secondLine {
            secondWeightMenu.setItems(Self.weights.map(\.0), selected: Self.weights.firstIndex { $0.1 == l.weight } ?? -1)
            secondSize.value = l.size
            if !secondWell.isActive { secondWell.color = nsColor(l.color) }
            secondItalic.selected = l.italic ? [0] : []
            secondSummary.stringValue = "\(l.fontName) · \(Self.weights.first { $0.1 == l.weight }?.0 ?? "") · \(String(format: "%.1f", l.size)) px"
        } else {
            let base = "\(s.fontName) · Regular · \(String(format: "%.1f", s.size * 2 / 3)) px"
            secondSummary.stringValue = base
        }
        // Multi-select: second line on in some clips only, or its look differs.
        if model.isMixedPresence("secondLine") { second.check.state = .mixed }
        if model.isMixed("secondLine.fontName") { secondFontControl.selectedFamily = nil }
        if model.isMixed("secondLine.weight") { secondWeightMenu.setItems(Self.weights.map(\.0), selected: -1) }
        let secondColorMixed = model.isMixedColor("secondLine.color")
        if secondWell.isMixed != secondColorMixed { secondWell.isMixed = secondColorMixed }
        let italicMixed: Set<Int> = model.isMixed("secondLine.italic") ? [0] : []
        if !italicMixed.isEmpty { secondItalic.selected = [] }
        secondItalic.mixed = italicMixed
        if model.isMixed("stroke.position") { strokePosition.selectedSegment = -1 }

        for (field, _, m) in tokenMenus {
            let names = model.tokenNames(for: field)
            m.setItems(["Literal"] + names, selected: model.boundToken(field).flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
            let usable = !names.isEmpty && field.isAvailable(in: s)
            m.isEnabled = usable
            tokenRows[field]?.isHidden = names.isEmpty
        }

        fillAnimationMenu(inMenu, side: .intro); fillAnimationMenu(outMenu, side: .outro)
        refreshAnimator(animIn); refreshAnimator(animOut)
        for (f, side) in [(inLength, AnimationSide.intro), (outLength, .outro)] {
            let ms = model.zoneMilliseconds(side)
            f.isEnabled = ms != nil; f.alphaValue = ms != nil ? 1 : 0.4
            if let ms {
                f.range = Double(TextInspectorModel.minimumZoneMilliseconds)...Double(max(ms, model.maximumZoneMilliseconds(side)))
                f.value = Double(ms)
            }
        }
        animationSummary.stringValue = animationSummaryText()
        textSummary.stringValue = model.isMixed("fontName") ? "" : "\(model.style.fontName) \u{00B7} \(Int(model.style.size.rounded()))"
        lookGallery.currentID = model.currentLookID
    }

    /// Multi-select: number fields whose value differs between the selected text clips are empty (no number).
    private func refreshMixed() {
        let fields: [(ScrubField, String)] = [
            (sizeField.field, "size"), (trackingField, "tracking"), (leadingField, "lineSpacing"),
            (fillOpacity.field, "color.alpha"), (strokeWidth.field, "stroke.width"),
            (boxOpacity.field, "background.color.alpha"), (padX.field, "background.padding.horizontal"),
            (padY.field, "background.padding.vertical"), (radius.field, "background.cornerRadius"),
            (shadowOpacity.field, "shadow.color.alpha"), (shadowBlur.field, "shadow.blur"), (shadowSize.field, "shadow.spread"),
            (shadowAngle.field, "shadow.offsetX"), (shadowDistance.field, "shadow.offsetX"), (secondSize.field, "secondLine.size"),
        ]
        for (f, path) in fields {
            var mixed = model.isMixed(path)
            if path == "shadow.offsetX" { mixed = mixed || model.isMixed("shadow.offsetY") }     // angle / distance come from both
            if f.isMixed != mixed { f.isMixed = mixed }
        }
    }

    /// Off, the presets (neutral ones first), the saved animations, Custom; a Custom side can also be saved.
    private func fillAnimationMenu(_ menu: TextPanelMenuButton, side: AnimationSide) {
        let custom = model.isCustom(side)
        let ids = (side == .intro ? model.inAnimationIDs : model.outAnimationIDs) + [AnimationChoices.customID]
            + (custom && model.canSaveAnimations ? [AnimationChoices.saveID] : [])
        let shown = custom ? AnimationChoices.customID : (side == .intro ? model.selectedInID : model.selectedOutID)
        // No entry is checked for a saved animation the Library no longer has: the button says "Saved".
        menu.placeholder = model.animationTitle(side)
        menu.setItems(ids.map { AnimationChoices.title(for: $0, side: side, store: model.keystones) }, ids: ids,
                      selected: shown.flatMap { ids.firstIndex(of: $0) } ?? -1)
    }

    /// A popup choice: a preset, Custom (its rows open in Controls), or saving the Custom side under a name. A saved
    /// side plays the saved animation (the popup shows its name); a save that did not happen is said, never dropped.
    private var savingAnimation = false

    func pickAnimation(_ id: String, side: AnimationSide) {
        guard id == AnimationChoices.saveID else { model.setAnimation(id, side: side); return }
        // A second Save pick while the name prompt or the store is busy starts nothing: the first one finishes first.
        if !savingAnimation {
            savingAnimation = true
            Task { await saveAnimation(side); savingAnimation = false }
        }
        refresh()       // the popup shows the side again, not the Save entry
    }

    /// Asks for a name and saves the side's Custom animation. The Library stores asynchronously: the popup keeps showing
    /// Custom until it did, then shows the new name; a save that did not happen is said.
    func saveAnimation(_ side: AnimationSide) async {
        guard let name = askLookName(SQL10n.format("Save %@ Animation", SQL10n.string(side.title)), SQL10n.format("My %@", SQL10n.string(side.title))) else { return }
        if !(await model.saveCustomAnimation(side, named: name)) {
            onNotice(SQL10n.format("The %@ animation could not be saved: it has no keyframes, or the Library is not available.", SQL10n.string(side.title)))
        }
        refresh()
    }

    /// A short message in the SQ design (the host may route it to its status line instead). Tests replace it.
    static func noticeDialog(_ message: String) {
        let alert = SQDialog()
        alert.messageText = message
        alert.addButton("OK")
        _ = alert.runModal()
    }

    /// "In: By Word · Up": the in animation's unit and direction (or effect), as the board shows next to the closed header.
    private func animationSummaryText() -> String {
        guard let a = model.animator(.in) else {
            return "In: " + model.animationTitle(.intro)
        }
        let unit = Self.units.first { $0.1 == a.unit }?.0 ?? ""
        let tail = a.effect == .slide ? Self.directions.first { $0.1 == a.direction }?.0 : Self.effects.first { $0.1 == a.effect }?.0
        return "In: " + [unit, tail].compactMap { $0 }.joined(separator: " · ")
    }

    /// A new animator's unit length (TextInspectorModel creates it with 0.3 s); the field's reset target.
    static let defaultAnimatorDurationMilliseconds = TextAnimatorChoices.defaultDurationMilliseconds

    static func title(for id: String) -> String { AnimationPresetName.title(for: id) }

    private func refreshAnimator(_ c: AnimatorControls) {
        func enable(_ views: [NSControl], _ on: Bool) { for v in views { v.isEnabled = on; v.alphaValue = on ? 1 : 0.4 } }
        let a = model.animator(c.side)
        c.effect.select(title: Self.effects.first { $0.1 == a?.effect }?.0 ?? "None")
        enable([c.unit, c.easing, c.order, c.stagger], a != nil)
        enable([c.duration], a != nil && a?.effect != .typewriter)   // typewriter: each unit appears at once
        enable([c.direction, c.distance], a?.effect == .slide || a?.effect == .wave)
        enable([c.loops], a?.effect.isLoop == true)
        enable([c.blur], a?.effect == .blur)
        guard let a else { return }
        c.unit.select(title: Self.units.first { $0.1 == a.unit }?.0)
        c.direction.select(title: Self.directions.first { $0.1 == a.direction }?.0)
        c.easing.select(title: Self.easings.first { $0.1 == a.easing }?.0)
        c.order.select(title: Self.orders.first { $0.1 == a.order }?.0)
        c.stagger.defaultValue = Double(model.animatorMilliseconds(TextInspectorModel.defaultStagger(a.unit)))
        c.duration.defaultValue = Double(Self.defaultAnimatorDurationMilliseconds)
        c.stagger.value = Double(model.animatorMilliseconds(a.stagger))
        c.duration.value = Double(model.animatorMilliseconds(a.duration))
        c.distance.value = a.distance
        c.blur.value = a.blurRadius
        c.loops.value = Double(a.loops)
    }

    // MARK: View -> model

    @objc private func fillWellChanged() { colorEdit { self.model.setColor(self.rgba(self.fill.well.color)) } }

    @objc private func fillChecked() { model.setFillAlpha(fill.check.state == .on ? max(lastFillAlpha, 0.01) : 0) }
    private func setFillOpacity(_ v: Double) { model.setFillAlpha(v / 100) }
    @objc private func outlineChecked() { model.setStrokeEnabled(outline.check.state == .on) }
    @objc private func outlineWellChanged() {
        colorEdit { self.model.setStrokeColor(self.rgba(self.outline.well.color)) }
    }
    @objc private func fillModeChanged() {
        model.setFootageFill([nil, .stencil, .inverted][max(0, min(2, fillMode.selectedSegment))])
    }
    @objc private func strokePositionChanged() { model.setStrokePosition(strokePosition.selectedSegment == 1 ? .centre : .outside) }
    @objc private func backgroundChecked() { model.setBackgroundEnabled(background.check.state == .on) }
    @objc private func backgroundWellChanged() {
        colorEdit { self.model.setBackgroundColor(self.rgba(self.background.well.color)) }
    }
    @objc private func shadowChecked() { model.setShadowEnabled(shadowRow.check.state == .on) }
    @objc private func shadowWellChanged() {
        colorEdit { self.model.setShadowColor(self.rgba(self.shadowRow.well.color)) }
    }
    @objc private func gradientChecked() { model.setGradientEnabled(gradientRow.check.state == .on) }
    @objc private func gradientStartChanged() { colorEdit { self.model.setGradientStart(self.rgba(self.gradientRow.well.color)) } }
    @objc private func gradientEndChanged() { colorEdit { self.model.setGradientEnd(self.rgba(self.gradientEndWell.color)) } }
    @objc private func autoFitChecked() { model.setAutoFit(autoFitRow.check.state == .on) }
    @objc private func listChecked() { model.setList(listRow.check.state == .on ? .bullet : nil) }
    @objc private func secondChecked() { model.setSecondLineEnabled(second.check.state == .on) }
    @objc private func secondWellChanged() {
        colorEdit { self.model.setSecondLineColor(self.rgba(self.secondWell.color)) }
    }
    /// The screen color picker of an Appearance row: one undo step, the layer keeps its own opacity.
    private func pickColor(alpha: @escaping (TextStyle) -> Double, apply: @escaping (TextInspectorModel, RGBAColor) -> Void) {
        guard loupe == nil else { return }
        loupe = SQLoupe.begin(onPick: { [weak self] picked in
            guard let self else { return }
            loupe = nil
            model.beginEditing()
            apply(model, rgba(picked.nsColor, alpha: alpha(model.style)))
            model.endEditing()
        }, onCancel: { [weak self] in self?.loupe = nil })
    }

    /// Direction picker and one slider per variation axis of the current font. The rows are rebuilt only when the font
    /// changes; a static font has none and the block is hidden.
    private func refreshDirectionAndAxes() {
        let s = model.style
        directionGroup.selected = model.isMixed("direction") ? []
            : Set([TextDirection?.some(.leftToRight), .some(.rightToLeft)].firstIndex(of: s.direction).map { [$0] } ?? [])
        if axisFontName != s.fontName {
            axisFontName = s.fontName
            rebuildAxisRows(model.fontAxes)
        }
        let mixed = model.isMixed("fontAxes")
        for (axis, field) in axisFields {
            if field.isMixed != mixed { field.isMixed = mixed }
            let v = model.axisValue(axis)
            if field.value != v { field.value = v }
        }
    }

    private func rebuildAxisRows(_ axes: [FontResolver.Axis]) {
        for v in axisRows.arrangedSubviews { axisRows.removeArrangedSubview(v); v.removeFromSuperview() }
        axisFields = []
        for axis in axes {
            let f = ScrubField()
            let span = axis.maximum - axis.minimum
            let step = span > 200 ? 1 : span > 20 ? 0.5 : 0.1
            scrub(f, range: axis.minimum...axis.maximum, step: step, decimals: step < 1 ? 1 : 0, reset: axis.defaultValue) {
                [weak self] in self?.model.setFontAxis(axis, $0)
            }
            f.isPlain = true
            f.sqToolTip = "\(axis.name) (\(axis.tag))"
            f.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth).isActive = true
            let r = row(axis.name, [f, spacer()])
            axisRows.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: axisRows.widthAnchor).isActive = true
            axisFields.append((axis, f))
        }
        let hide = axes.isEmpty
        if axisRows.isHidden != hide { axisRows.isHidden = hide }
        onHeightChange?()
    }

    private func padChanged() { model.setBackgroundPadding(horizontal: padX.value, vertical: padY.value) }
    private func shadowAngleChanged() { model.setShadowAngle(shadowAngle.value, distance: shadowDistance.value) }

    private var wellSessionOpen = false
    private func openWellSession() {
        guard !wellSessionOpen else { return }
        wellSessionOpen = true
        model.beginEditing()
    }
    private func closeWellSession() {
        guard wellSessionOpen else { return }
        wellSessionOpen = false
        model.endEditing()
    }

    /// The color panel streams changes while it is dragged; hold one undo step open until idle.
    private func colorEdit(_ apply: () -> Void) {
        if wellSessionOpen { apply(); return }      // a picker session holds the undo step: closing the picker ends it
        if !colorSessionOpen { colorSessionOpen = true; model.beginEditing() }
        apply()
        colorSessionEnd?.cancel()
        colorSessionEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.colorSessionOpen = false
            self.model.endEditing()
        }
    }
}

/// Existing name of the text properties view (Controls, Captions Look): it is the shared text block.
public typealias TextInspectorView = TextBlockView

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension TextBlockView {
    // MARK: Look context menu (menus.txt "Text panel: look tile")

    /// The Look menu of every host (Controls, Captions > Look, Graphics): Update, Save as New Look, Rename, Delete.
    /// `editable` is the name of the Look the text carries when the user may change it; a built-in Look, or none,
    /// only offers Save as New Look.
    static func lookMenuItems(editable name: String?, update: @escaping @MainActor () -> Void = {}, saveNew: @escaping @MainActor () -> Void,
                              rename: @escaping @MainActor () -> Void = {}, delete: @escaping @MainActor () -> Void = {}) -> [SQMenuItem] {
        TextAnimatorChoices.lookMenuItems(editable: name, update: update, saveNew: saveNew, rename: rename, delete: delete)
    }

    func lookContextItems() -> [SQMenuItem] {
        if let lookContext { return lookContext() }
        let saveNew: @MainActor () -> Void = { [weak self] in self?.saveLookAsNew() }
        // A host that lists its own Looks without a menu of its own: saving is what it offers.
        guard lookSource == nil, let id = model.appliedStyleID, let e = model.styles.entry(id), !e.isBuiltIn else {
            return Self.lookMenuItems(editable: nil, saveNew: saveNew)
        }
        return Self.lookMenuItems(
            editable: e.name,
            update: { [weak self] in self?.model.updateStyleFromCurrent(id); self?.refreshLook() },
            saveNew: saveNew,
            rename: { [weak self] in
                guard let self, let name = askLookName("Rename Look", e.name) else { return }
                model.renameStyle(id, to: name)
                refreshLook()
            },
            delete: { [weak self] in self?.model.deleteStyle(id); self?.refreshLook() })
    }

    /// The name prompt in the SQ design. Nil when canceled or left empty.
    static func promptLookName(_ title: String, _ initial: String) -> String? {
        let alert = SQDialog()
        alert.messageText = title
        alert.addButton("OK"); alert.addButton("Cancel")
        let field = SQDialog.makeField(width: 220)
        field.stringValue = initial
        alert.accessoryView = field
        alert.initialFirstResponder = field
        guard alert.runModal() == .first else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
