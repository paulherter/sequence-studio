import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQText
import SQUIKit
import SQDrawKit

/// The text clip's block of Controls on the shared toolkit: `TextBlockView` (context `.clip`) translated. Three parts,
/// each with its own coordinates (points, y down, (0, 0) = the part's top-left), placed by the host like the Mac
/// skeleton: `.text` (Text section: box, font, size, style toggles, alignment, spacing, Look and the Appearance rows with
/// their detail rows) leads Controls, `.arrange` (align to frame) closes Transform, `.animation` (Intro / Outro) follows
/// Transform. The model is the Mac `TextInspectorModel`; this draws it and turns pointer and keys into its setters.
@MainActor public final class TextBlockDraw {
    public let model: TextInspectorModel
    public var theme = DrawTheme()
    public var width: CGFloat = 320
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public enum Part: Sendable, CaseIterable { case text, arrange, animation }

    /// The clip's text shown in the box; kept while the user types in it.
    public var text = "" { didSet { if editor == nil { boxText = text } } }
    private var boxText = ""
    /// A typing gesture starts (first change after focus), a change was typed, the gesture ended (focus left).
    public var onTextBegin: (() -> Void)?
    public var onTextChange: ((String) -> Void)?
    public var onTextEnd: (() -> Void)?
    /// A part's height changed (a section or detail row opened, the box grew): the host re-lays out.
    public var onHeightChange: (() -> Void)?
    /// A popup opened: the host shows the SQ menu at `anchor` (coordinates of `part`).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect, _ part: Part) -> Void)?
    /// A swatch was clicked: the host opens its color picker; `change(nil)` = the picker closed.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect, _ part: Part,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// Something did not happen (a Custom animation that could not be saved): the host shows it in its status line.
    public var onNotice: ((String) -> Void)?
    /// Asks for a name (Save as New Look, Rename, Save Animation) and answers through `done` (nil = canceled); without
    /// it the suggested name is taken as it is.
    public var askName: (@MainActor (_ title: String, _ initial: String, _ done: @escaping @MainActor (String?) -> Void) -> Void)?
    /// The Appearance rows' eyedroppers (`TextBlockView.pickColor`): samples a screen color; nil = the host's
    /// `ScreenColorSampler`. Without either the buttons hide.
    public var sampleScreenColor: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)?
    var sampler: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? { sampleScreenColor ?? ScreenColorSampler.begin }

    // MARK: Looks (TextBlockView.LookSource / LookStatus)

    public struct LookSource {
        public var titles: [String]
        public var ids: [String]
        public var selected: String?
        public var pick: (String) -> Void
        public var add: (() -> Void)?
        public init(titles: [String], ids: [String], selected: String?, pick: @escaping (String) -> Void, add: (() -> Void)?) {
            self.titles = titles; self.ids = ids; self.selected = selected; self.pick = pick; self.add = add
        }
    }
    public struct LookStatus: Equatable {
        public var name: String
        public var edited: Bool
        public var canUpdate: Bool
        public init(name: String, edited: Bool, canUpdate: Bool) { self.name = name; self.edited = edited; self.canUpdate = canUpdate }
    }
    /// nil = the model's text looks (`TextInspectorModel.styles`).
    public var lookSource: (() -> LookSource)?
    public var lookStatus: (() -> LookStatus?)?
    public var onUpdateLook: (() -> Void)?
    public var onSaveLookAsNew: (() -> Void)?
    /// Right-click on the Look popup (the host's Look menu); nil = the model's text looks (`lookContextItems`).
    public var lookContext: (() -> [SQMenuItem])?

    /// The text box row (the Captions Look tab hides it: a caption's words are edited in the list).
    public var showsTextBox = true
    /// The animated Look gallery as the last Animation row (the clip context of `TextBlockView`).
    public var showsLookGallery = false { didSet { if oldValue != showsLookGallery { onHeightChange?() } } }
    public let lookGallery = LookGalleryDraw(groups: [.entrance, .motion, .exit])

    public init(model: TextInspectorModel) {
        self.model = model
        lookGallery.onPick = { [weak model] look in model?.applyLook(look) }
        let d = UserDefaults.standard
        textOpen = d.object(forKey: TextBlockDraw.sectionKey("textblock.text")) as? Bool ?? true
        animationOpen = d.object(forKey: TextBlockDraw.sectionKey("textblock.animation")) as? Bool ?? false
        for l in Layer.allCases where d.bool(forKey: Self.layerKey(l)) { openLayers.insert(l) }
    }

    // MARK: Controls

    enum Layer: String, CaseIterable, Hashable {
        case fill, gradient, outline, background, shadow, second, autoFit = "autofit", list
        var title: String {
            switch self {
            case .fill: "Fill"
            case .gradient: "Gradient"
            case .outline: "Outline"
            case .background: "Background"
            case .shadow: "Shadow"
            case .second: "Second Line"
            case .autoFit: "Shrink to Box"
            case .list: "List"
            }
        }
        var hasWell: Bool { self != .second && self != .autoFit && self != .list }
        var hasDetail: Bool { self != .autoFit }
    }
    static func layerKey(_ l: Layer) -> String { "sq.textBlock.open.\(l.rawValue)" }
    /// Open state of the Text and Animation sections: the Mac `InspectorSection.defaultsKey` (Mac-only module part).
    static func sectionKey(_ k: String) -> String { "sq.inspector.open.\(k)" }

    enum Field: Hashable, CaseIterable {
        case size, tracking, leading
        case fillValue, outlineValue, backgroundValue, shadowValue
        case fillOpacity, strokeWidth, boxOpacity, padX, padY, radius
        case shadowOpacity, shadowAngle, shadowDistance, shadowSize, shadowBlur, gradientAngle, secondSize
        case inLength, outLength
        /// A numeric field of a text animator side (stagger, length, distance, blur, loops).
        case animator(TextInspectorModel.AnimatorSide, TextAnimatorChoices.Control)
        /// A variation axis of the style's font, by its tag (only the font's own axes, so not in `allCases`).
        case axis(String)

        static let animatorFields: [TextAnimatorChoices.Control] = [.stagger, .length, .distance, .blur, .loops]
        static var allCases: [Field] {
            [.size, .tracking, .leading, .fillValue, .outlineValue, .backgroundValue, .shadowValue, .fillOpacity, .strokeWidth,
             .boxOpacity, .padX, .padY, .radius, .shadowOpacity, .shadowAngle, .shadowDistance, .shadowSize, .shadowBlur,
             .gradientAngle, .secondSize, .inLength, .outLength]
                + [TextInspectorModel.AnimatorSide.in, .out].flatMap { side in animatorFields.map { .animator(side, $0) } }
        }
    }

    enum Group: Hashable { case style, align, vertical, direction, frame, fillMode, strokePosition, secondItalic }

    enum Control: Hashable {
        case textHeader, animationHeader, textBox
        case font, weight, look, lookAdd, lookUpdate, lookSaveNew
        case button(Group, Int)
        case check(Layer), well(Layer), chevron(Layer)
        /// The eyedropper after a row's value (fill, outline, background, shadow).
        case eyedropper(Layer)
        case gradientEnd, secondWell, secondFont, secondWeight, listKind, intro, outro
        /// A popup of a text animator side (effect, unit, easing, direction, order).
        case animator(TextInspectorModel.AnimatorSide, TextAnimatorChoices.Control)
        case field(Field)
        /// A kit token popup ("Literal" releases the field from the token).
        case token(TextInspectorModel.TokenField)
        /// The Look gallery (the last Animation row).
        case gallery
        /// A field-leading slider (NumericSlider with `fieldLeading`): the field, then the track.
        case slider(Field)
    }

    struct Row {
        var label: String?
        var icon: SQIcon?
        var level = 0
        var y: CGFloat
        var height: CGFloat
        var controls: [(Control, CGRect)]
        var tip: String?
    }

    static let weights: [(String, FontWeight)] = [
        ("Thin", .thin), ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]
    static let alignSymbols: [(FrameAlignment, SQIcon, String)] = [
        (.left, .alignLeft, "Align Left"), (.centerHorizontally, .alignCenterH, "Align Center Horizontally"),
        (.right, .alignRight, "Align Right"), (.top, .alignTop, "Align Top"),
        (.centerVertically, .alignCenterV, "Align Center Vertically"), (.bottom, .alignBottom, "Align Bottom"),
    ]
    /// Icon (or title) and tooltip of each button of a group.
    static func buttons(_ g: Group) -> [(icon: SQIcon?, title: String?, tip: String)] {
        switch g {
        case .style: [(.textBold, nil, "Bold"), (.textItalic, nil, "Italic"), (.textCaseUpper, nil, "All Caps"),
                      (.textUnderline, nil, "Underline"), (.textStrikethrough, nil, "Strikethrough"), (.textOverline, nil, "Overline")]
        case .align: [(.textAlignLeft, nil, "Align Text Left"), (.textAlignCenter, nil, "Center Text"), (.textAlignRight, nil, "Align Text Right")]
        case .vertical: [(.textTop, nil, "Align Text to Top"), (.textMiddle, nil, "Center Text Vertically"),
                         (.textBottom, nil, "Align Text to Bottom")]
        case .direction: [(.textLTR, nil, "Left to Right"), (.textRTL, nil, "Right to Left")]
        case .frame: alignSymbols.map { ($0.1, nil, $0.2) }
        case .fillMode: [(nil, "Color", "Fill Mode"), (nil, "Footage", "Fill Mode"), (nil, "Invert", "Fill Mode")]
        case .strokePosition: [(nil, "Out", "Outline Position"), (nil, "Mid", "Outline Position")]
        case .secondItalic: [(nil, "I", "Italic")]
        }
    }
    static let iconButton: CGFloat = 28
    static let segmentWidth: CGFloat = 60
    static let weightWidth: CGFloat = 78
    static let lengthWidth: CGFloat = 76

    // MARK: Open state

    private(set) var textOpen: Bool
    private(set) var animationOpen: Bool
    private(set) var openLayers: Set<Layer> = []

    private func setOpen(_ l: Layer, _ open: Bool) {
        if open { openLayers.insert(l) } else { openLayers.remove(l) }
        UserDefaults.standard.set(open, forKey: Self.layerKey(l))
        onHeightChange?()
    }

    // MARK: Layout

    private var rh: CGFloat { ControlsGrid.rowHeight }
    private var valueEnd: CGFloat { max(width - ControlsGrid.trailing, ControlsGrid.valueX) }
    private var resetX: CGFloat { valueEnd - ControlsGrid.resetWidth }
    private func box(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat = ControlsGrid.controlHeight) -> CGRect {
        CGRect(x: x, y: ((rh - h) / 2).rounded(), width: max(w, 0), height: h)
    }
    private func group(_ g: Group, x: CGFloat, width w: CGFloat = TextBlockDraw.iconButton) -> [(Control, CGRect)] {
        Self.buttons(g).indices.map { (.button(g, $0), box(x + CGFloat($0) * w, w)) }
    }

    /// The text box: 2 to 6 lines.
    static let lineHeight: CGFloat = CGFloat(DrawTheme.TypeSize.body) + 5
    var boxHeight: CGFloat {
        let lines = boxText.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(max(lines, 2), 6)) * Self.lineHeight + 8
    }

    var lookEdited: Bool { currentLookStatus?.edited ?? false }

    func rows(_ part: Part) -> [Row] {
        var out: [Row] = []
        var y: CGFloat = 0
        func add(_ label: String?, icon: SQIcon? = nil, level: Int = 0, tip: String? = nil, _ c: [(Control, CGRect)],
                 height: CGFloat? = nil) {
            let h = height ?? rh
            out.append(Row(label: label, icon: icon, level: level, y: y, height: h, controls: c, tip: tip))
            y += h
        }
        let x0 = ControlsGrid.valueX, full = box(x0, valueEnd - x0)
        let fw = ControlsGrid.valueWidth
        let slider: (Field) -> [(Control, CGRect)] = { [(.slider($0), full)] }
        switch part {
        case .text:
            add(nil, [(.textHeader, CGRect(x: 0, y: 0, width: width, height: rh))])
            guard textOpen else { break }
            let bh = boxHeight
            if showsTextBox {
                add(nil, [(.textBox, CGRect(x: ControlsGrid.labelX, y: 4, width: max(valueEnd - ControlsGrid.labelX, 0), height: bh))],
                    height: bh + 8)
            }
            add("Font", [(.font, box(x0, valueEnd - Self.weightWidth - ControlsGrid.gap - x0)),
                         (.weight, box(valueEnd - Self.weightWidth, Self.weightWidth))])
            add("Size", slider(.size))
            add(nil, group(.style, x: ControlsGrid.labelX))
            add(nil, group(.align, x: ControlsGrid.labelX))
            add(nil, group(.vertical, x: ControlsGrid.labelX)
                + group(.direction, x: ControlsGrid.labelX + 3 * Self.iconButton + 2 * ControlsGrid.gap))
            let lead = x0 + fw + ControlsGrid.gap
            add(nil, icon: .moveHorizontal, tip: "Letter Spacing (px)",
                [(.field(.tracking), box(x0, fw)), (.field(.leading), box(lead + 14 + ControlsGrid.gap, fw))])
            // The font's variation axes (TextBlockView.rebuildAxisRows): one number per axis, none for a static font.
            for a in fontAxes { add(a.name, tip: "\(a.name) (\(a.tag))", [(.field(.axis(a.tag)), box(x0, fw))]) }
            // Kit tokens (TextBlockView.tokenMenus): a row only while the project's kit has tokens for the field.
            func tokenRow(_ f: TextInspectorModel.TokenField, level: Int) {
                guard !model.tokenNames(for: f).isEmpty else { return }
                let name = f == .font ? "Font" : "Color"
                add(SQL10n.format("%@ Token", SQL10n.string(name)), level: level, tip: SQL10n.format("Follow %@ Token", SQL10n.string(name)),
                    [(.token(f), box(x0, valueEnd - x0))])
            }
            tokenRow(.font, level: 0)
            add("Look", [(.look, box(x0, resetX - ControlsGrid.gap - x0)),
                         (.lookAdd, box(resetX, ControlsGrid.resetWidth))])
            if lookEdited {
                add(nil, [(.lookUpdate, box(x0, 64)), (.lookSaveNew, box(x0 + 64 + ControlsGrid.gap, 96))])
            }
            for l in Layer.allCases {
                var c: [(Control, CGRect)] = [(.check(l), box(ControlsGrid.toggleX, ControlsGrid.toggleWidth, 14))]
                if l.hasWell { c.append((.well(l), box(ControlsGrid.valueColumn(0), fw, 18))) }
                switch l {
                case .fill: c.append((.field(.fillValue), box(ControlsGrid.valueColumn(1), fw)))
                case .outline: c.append((.field(.outlineValue), box(ControlsGrid.valueColumn(1), fw)))
                case .background: c.append((.field(.backgroundValue), box(ControlsGrid.valueColumn(1), fw)))
                case .shadow: c.append((.field(.shadowValue), box(ControlsGrid.valueColumn(1), fw)))
                default: break
                }
                if Self.eyedropperLayers.contains(l), sampler != nil {
                    c.append((.eyedropper(l), box(ControlsGrid.valueColumn(2), ControlsGrid.resetWidth)))
                }
                if l.hasDetail { c.append((.chevron(l), box(resetX, ControlsGrid.resetWidth))) }
                add(l.title, c)
                guard l.hasDetail, openLayers.contains(l) else { continue }
                let seg = Self.segmentWidth
                switch l {
                case .fill:
                    add("Opacity", level: 1, slider(.fillOpacity))
                    add("Mode", level: 1, group(.fillMode, x: x0, width: seg))
                    tokenRow(.color, level: 1)
                case .gradient:
                    add("End Color", level: 1, [(.gradientEnd, box(x0, fw, 18))])
                    add("Angle", level: 1, slider(.gradientAngle))
                case .outline:
                    add(nil, icon: .minimize, level: 1, tip: "Outline Width", slider(.strokeWidth))
                    add("Position", level: 1, group(.strokePosition, x: x0, width: seg))
                    tokenRow(.strokeColor, level: 1)
                case .background:
                    add("Opacity", level: 1, slider(.boxOpacity))
                    add("Padding X", level: 1, slider(.padX))
                    add("Padding Y", level: 1, slider(.padY))
                    add("Radius", level: 1, slider(.radius))
                    tokenRow(.backgroundColor, level: 1)
                case .shadow:
                    add(nil, icon: .droplet, level: 1, tip: "Shadow Opacity", slider(.shadowOpacity))
                    add(nil, icon: .shadowAngle, level: 1, tip: "Shadow Angle", slider(.shadowAngle))
                    add(nil, icon: .move, level: 1, tip: "Shadow Distance", slider(.shadowDistance))
                    add(nil, icon: .maximize, level: 1, tip: "Shadow Size", slider(.shadowSize))
                    add(nil, icon: .circleDotted, level: 1, tip: "Shadow Blur", slider(.shadowBlur))
                case .second:
                    add("Font", level: 1, [(.secondFont, box(x0, valueEnd - Self.weightWidth - ControlsGrid.gap - x0)),
                                           (.secondWeight, box(valueEnd - Self.weightWidth, Self.weightWidth))])
                    add("Size", level: 1, slider(.secondSize))
                    add("Color", level: 1, [(.secondWell, box(x0, fw, 18))] + group(.secondItalic, x: x0 + fw + ControlsGrid.gap))
                case .list:
                    add("Style", level: 1, [(.listKind, box(x0, 96))])
                case .autoFit: break
                }
            }
        case .arrange:
            add("Arrange", group(.frame, x: x0))
        case .animation:
            add(nil, [(.animationHeader, CGRect(x: 0, y: 0, width: width, height: rh))])
            guard animationOpen else { break }
            let pw = valueEnd - Self.lengthWidth - ControlsGrid.gap - x0
            add("Intro", [(.intro, box(x0, pw)), (.field(.inLength), box(valueEnd - Self.lengthWidth, Self.lengthWidth))])
            add("Outro", [(.outro, box(x0, pw)), (.field(.outLength), box(valueEnd - Self.lengthWidth, Self.lengthWidth))])
            // The text animators (TextBlockView.animatorRows): two half-width popups per row, then the value fields.
            let half = ((valueEnd - x0 - ControlsGrid.gap) / 2).rounded(.down)
            for (side, title) in [(TextInspectorModel.AnimatorSide.in, "In"), (.out, "Out")] {
                add(SQL10n.format("%@ by", SQL10n.string(title)),
                    [(.animator(side, .effect), box(x0, half)), (.animator(side, .unit), box(valueEnd - half, half))])
                add(nil, [(.animator(side, .easing), box(x0, half)), (.animator(side, .direction), box(valueEnd - half, half))])
                add("Order", [(.animator(side, .order), box(x0, half))])
                for (f, label) in [(TextAnimatorChoices.Control.stagger, "Stagger"), (.length, "Length"), (.distance, "Distance"),
                                   (.blur, "Blur"), (.loops, "Loops")] {
                    add(label, [(.field(.animator(side, f)), box(x0, fw))])
                }
            }
            if showsLookGallery {
                let gh = lookGallery.height(forWidth: width)
                add(nil, [(.gallery, CGRect(x: 0, y: 0, width: width, height: gh))], height: gh)
            }
        }
        return out
    }

    public func height(_ part: Part) -> CGFloat { rows(part).last.map { $0.y + $0.height } ?? 0 }

    func frame(_ c: Control, _ part: Part) -> CGRect? {
        for r in rows(part) { if let f = r.controls.first(where: { $0.0 == c })?.1 { return f.offsetBy(dx: 0, dy: r.y) } }
        return nil
    }

    /// Slider parts: the value field first, the track after it (NumericSlider `fieldLeading`).
    func sliderParts(_ r: CGRect) -> (field: CGRect, track: CGRect) {
        let fw = min(ControlsGrid.valueWidth, r.width)
        let field = CGRect(x: r.minX, y: r.minY, width: fw, height: r.height)
        let tx = field.maxX + ControlsGrid.gap
        return (field, CGRect(x: tx, y: r.minY, width: max(r.maxX - tx, 0), height: r.height))
    }

    // MARK: Values

    struct Spec { var range: ClosedRange<Double>; var def: Double?; var step: Double; var decimals: Int; var unit: String }
    func spec(_ f: Field) -> Spec {
        if case .animator(_, let k) = f {
            let ms = Double(TextInspectorModel.maxAnimatorMilliseconds), px = TextInspectorModel.maxAnimatorPixels
            return switch k {
            case .stagger: Spec(range: 0...ms, def: Double(animatorStaggerDefault(f)), step: 5, decimals: 0, unit: "ms")
            case .length: Spec(range: 0...ms, def: Double(TextAnimatorChoices.defaultDurationMilliseconds), step: 5, decimals: 0, unit: "ms")
            case .distance: Spec(range: 0...px, def: TextInspectorModel.defaultAnimatorDistance, step: 1, decimals: 0, unit: "px")
            case .blur: Spec(range: 0...px, def: TextInspectorModel.defaultAnimatorBlur, step: 1, decimals: 0, unit: "px")
            default: Spec(range: 1...50, def: 1, step: 1, decimals: 0, unit: "x")
            }
        }
        if case .axis(let tag) = f {
            guard let a = axis(tag) else { return Spec(range: 0...1, def: nil, step: 1, decimals: 0, unit: "") }
            let span = a.maximum - a.minimum, step = span > 200 ? 1 : span > 20 ? 0.5 : 0.1
            return Spec(range: a.minimum...max(a.minimum, a.maximum), def: a.defaultValue, step: step, decimals: step < 1 ? 1 : 0, unit: "")
        }
        if f == .inLength || f == .outLength {
            let side: AnimationSide = f == .inLength ? .intro : .outro
            let lo = Double(TextInspectorModel.minimumZoneMilliseconds)
            let hi = Double(max(model.zoneMilliseconds(side) ?? 0, model.maximumZoneMilliseconds(side)))
            return Spec(range: lo...max(lo, hi), def: nil, step: 10, decimals: 0, unit: "ms")
        }
        return switch f {
        case .size, .secondSize: Spec(range: 1...400, def: 48, step: 1, decimals: 1, unit: "px")
        case .tracking: Spec(range: -100...500, def: 0, step: 0.5, decimals: 1, unit: "")
        case .leading: Spec(range: -200...500, def: 0, step: 1, decimals: 1, unit: "")
        case .fillValue, .fillOpacity, .backgroundValue, .boxOpacity: Spec(range: 0...100, def: 100, step: 1, decimals: 1, unit: "%")
        case .shadowValue, .shadowOpacity: Spec(range: 0...100, def: 60, step: 1, decimals: 1, unit: "%")
        case .outlineValue, .strokeWidth, .shadowSize: Spec(range: 0...100, def: 0, step: 0.5, decimals: 1, unit: "px")
        case .padX, .padY: Spec(range: 0...400, def: 0, step: 1, decimals: 1, unit: "px")
        case .radius: Spec(range: 0...200, def: 0, step: 1, decimals: 1, unit: "px")
        case .shadowAngle: Spec(range: -360...360, def: 135, step: 1, decimals: 1, unit: "°")
        case .shadowDistance: Spec(range: 0...400, def: 0, step: 0.5, decimals: 1, unit: "px")
        case .shadowBlur: Spec(range: 0...200, def: 0, step: 0.5, decimals: 1, unit: "px")
        case .gradientAngle: Spec(range: 0...360, def: 90, step: 1, decimals: 1, unit: "°")
        case .inLength, .outLength, .animator, .axis: Spec(range: 0...1, def: nil, step: 10, decimals: 0, unit: "ms")   // handled above
        }
    }

    /// The style font's variation axes, looked up once per font name (rows are laid out every frame).
    var fontAxes: [FontResolver.Axis] {
        let name = model.style.fontName
        if let c = axisCache, c.font == name { return c.axes }
        let axes = model.fontAxes
        axisCache = (name, axes)
        return axes
    }
    private var axisCache: (font: String, axes: [FontResolver.Axis])?
    func axis(_ tag: String) -> FontResolver.Axis? { fontAxes.first { $0.tag == tag } }

    /// The Stagger reset follows the animator's unit (TextInspectorModel.defaultStagger).
    private func animatorStaggerDefault(_ f: Field) -> Int {
        guard case .animator(let side, _) = f, let a = model.animator(side) else { return TextAnimatorChoices.defaultStaggerMilliseconds }
        return model.animatorMilliseconds(TextInspectorModel.defaultStagger(a.unit))
    }

    func value(_ f: Field) -> Double {
        let s = model.style
        switch f {
        case .size: return s.size
        case .tracking: return s.tracking
        case .leading: return s.lineSpacing
        case .fillValue, .fillOpacity: return (s.color.alpha * 100).rounded()
        case .outlineValue, .strokeWidth: return s.stroke?.width ?? 0
        case .backgroundValue, .boxOpacity: return s.background.map { ($0.color.alpha * 100).rounded() } ?? 100
        case .padX: return s.background?.padding.horizontal ?? 0
        case .padY: return s.background?.padding.vertical ?? 0
        case .radius: return s.background?.cornerRadius ?? 0
        case .shadowValue, .shadowOpacity: return s.shadow.map { ($0.color.alpha * 100).rounded() } ?? 60
        case .shadowAngle: return s.shadow?.angle.rounded() ?? 135
        case .shadowDistance: return s.shadow?.distance ?? 0
        case .shadowBlur: return s.shadow?.blur ?? 0
        case .shadowSize: return s.shadow?.spread ?? 0
        case .gradientAngle: return s.gradient?.angle ?? 90
        case .secondSize: return s.secondLine?.size ?? s.size * 2 / 3
        case .inLength: return Double(model.zoneMilliseconds(.intro) ?? 0)
        case .outLength: return Double(model.zoneMilliseconds(.outro) ?? 0)
        case .axis(let tag): return axis(tag).map(model.axisValue) ?? 0
        case .animator(let side, let k):
            guard let a = model.animator(side) else { return k == .loops ? 1 : 0 }
            return switch k {
            case .stagger: Double(model.animatorMilliseconds(a.stagger))
            case .length: Double(model.animatorMilliseconds(a.duration))
            case .distance: a.distance
            case .blur: a.blurRadius
            default: Double(a.loops)
            }
        }
    }

    func isEnabled(_ f: Field) -> Bool {
        let s = model.style
        switch f {
        case .size, .tracking, .leading, .fillValue, .fillOpacity: return true
        case .outlineValue, .strokeWidth: return s.stroke != nil
        case .backgroundValue, .boxOpacity, .padX, .padY, .radius: return s.background != nil
        case .shadowValue, .shadowOpacity, .shadowAngle, .shadowDistance, .shadowBlur, .shadowSize: return s.shadow != nil
        case .gradientAngle: return s.gradient != nil
        case .secondSize: return s.secondLine != nil
        case .inLength: return model.zoneMilliseconds(.intro) != nil
        case .outLength: return model.zoneMilliseconds(.outro) != nil
        case .animator(let side, let k): return TextAnimatorChoices.isEnabled(k, model.animator(side))
        case .axis(let tag): return axis(tag) != nil
        }
    }

    /// Multi-select: a value that differs between the selected text clips shows no number.
    func isMixed(_ f: Field) -> Bool {
        switch f {
        case .size: model.isMixed("size")
        case .tracking: model.isMixed("tracking")
        case .leading: model.isMixed("lineSpacing")
        case .fillValue, .fillOpacity: model.isMixed("color.alpha")
        case .outlineValue, .strokeWidth: model.isMixed("stroke.width")
        case .backgroundValue, .boxOpacity: model.isMixed("background.color.alpha")
        case .padX: model.isMixed("background.padding.horizontal")
        case .padY: model.isMixed("background.padding.vertical")
        case .radius: model.isMixed("background.cornerRadius")
        case .shadowValue, .shadowOpacity: model.isMixed("shadow.color.alpha")
        case .shadowAngle, .shadowDistance: model.isMixed("shadow.offsetX") || model.isMixed("shadow.offsetY")
        case .shadowBlur: model.isMixed("shadow.blur")
        case .shadowSize: model.isMixed("shadow.spread")
        case .secondSize: model.isMixed("secondLine.size")
        case .axis: model.isMixed("fontAxes")
        case .gradientAngle, .inLength, .outLength, .animator: false
        }
    }

    func set(_ f: Field, _ v: Double) {
        let s = model.style
        switch f {
        case .size: model.setSize(v)
        case .tracking: model.setTracking(v)
        case .leading: model.setLineSpacing(v)
        case .fillValue, .fillOpacity: model.setFillAlpha(v / 100)
        case .outlineValue, .strokeWidth: model.setStrokeWidth(v)
        case .backgroundValue, .boxOpacity: model.setBackgroundOpacity(v / 100)
        case .padX: model.setBackgroundPadding(horizontal: v, vertical: s.background?.padding.vertical ?? 0)
        case .padY: model.setBackgroundPadding(horizontal: s.background?.padding.horizontal ?? 0, vertical: v)
        case .radius: model.setBackgroundRadius(v)
        case .shadowValue, .shadowOpacity: model.setShadowOpacity(v / 100)
        case .shadowAngle: model.setShadowAngle(v, distance: s.shadow?.distance ?? 0)
        case .shadowDistance: model.setShadowAngle(s.shadow?.angle ?? 135, distance: v)
        case .shadowBlur: model.setShadowBlur(v)
        case .shadowSize: model.setShadowSpread(v)
        case .gradientAngle: model.setGradientAngle(v)
        case .secondSize: model.setSecondLineSize(v)
        case .inLength: model.setZoneLength(milliseconds: TextInspectorModel.milliseconds(from: v), side: .intro)
        case .outLength: model.setZoneLength(milliseconds: TextInspectorModel.milliseconds(from: v), side: .outro)
        case .axis(let tag): if let a = axis(tag) { model.setFontAxis(a, v) }
        case .animator(let side, let k):
            switch k {
            case .stagger: model.setAnimatorStagger(milliseconds: TextInspectorModel.milliseconds(from: v), side: side)
            case .length: model.setAnimatorDuration(milliseconds: TextInspectorModel.milliseconds(from: v), side: side)
            case .distance: model.setAnimatorDistance(v, side: side)
            case .blur: model.setAnimatorBlurRadius(v, side: side)
            default: model.setAnimatorLoops(Int(v.rounded()), side: side)
            }
        }
    }

    private var fields: [Field: ScrubFieldControl] = [:]
    private(set) var focused: Field?
    func field(_ f: Field) -> ScrubFieldControl {
        var fd = fields[f] ?? ScrubFieldControl(value: value(f))
        let sp = spec(f)
        fd.range = sp.range; fd.step = sp.step; fd.unit = sp.unit; fd.defaultValue = sp.def; fd.decimals = sp.decimals
        fd.isEnabled = isEnabled(f)
        fd.isMixed = isMixed(f)
        if !fd.isDragging, !fd.isEditing { fd.value = value(f) }
        return fd
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ f: Field) {
        for e in events {
            switch e {
            case .begin: model.beginEditing()
            case .live(let v), .change(let v): set(f, v)
            case .end(let v), .cancel(let v): set(f, v); model.endEditing()
            }
        }
    }

    /// Selected and mixed buttons of a group (TextBlockView.refresh).
    func buttonState(_ g: Group, _ i: Int) -> (on: Bool, mixed: Bool) {
        let s = model.style
        switch g {
        case .style:
            let paths = ["weight", "italic", "allCaps", "underline", "strikethrough", "overline"]
            let on = [s.weight >= .bold, s.italic, s.allCaps, s.underline, s.strikethrough, s.overline]
            let mixed = model.isMixed(paths[i])
            return (on[i] && !mixed, mixed)
        case .align:
            if model.isMixed("alignment") { return (false, true) }
            return (([TextAlignment.left, .center, .right].firstIndex(of: s.alignment) ?? 1) == i, false)
        case .vertical:
            if model.isMixed("verticalAlignment") { return (false, true) }
            return (([TextVerticalAlignment.top, .middle, .bottom].firstIndex(of: s.verticalAlignment) ?? 0) == i, false)
        case .direction:
            if model.isMixed("direction") { return (false, true) }
            return (s.direction == (i == 0 ? .leftToRight : .rightToLeft), false)
        case .frame: return (false, false)
        case .fillMode:
            if model.isMixed("footageFill") { return (false, true) }
            let cur = s.footageFill == .stencil ? 1 : s.footageFill == .inverted ? 2 : 0
            return (cur == i, false)
        case .strokePosition:
            if model.isMixed("stroke.position") { return (false, true) }
            return ((s.stroke?.position == .centre ? 1 : 0) == i, false)
        case .secondItalic:
            if model.isMixed("secondLine.italic") { return (false, true) }
            return (s.secondLine?.italic == true, false)
        }
    }

    func buttonEnabled(_ g: Group) -> Bool {
        switch g {
        case .strokePosition: model.style.stroke != nil
        case .secondItalic: model.style.secondLine != nil
        default: true
        }
    }

    func press(_ g: Group, _ i: Int) {
        let s = model.style
        switch g {
        case .style:
            let on = !buttonState(g, i).on
            switch i {
            case 0: model.setWeight(on ? max(s.weight, .bold) : .regular)
            case 1: model.setItalic(on)
            case 2: model.setAllCaps(on)
            case 3: model.setUnderline(on)
            case 4: model.setStrikethrough(on)
            default: model.setOverline(on)
            }
        case .align: model.setAlignment([TextAlignment.left, .center, .right][i])
        case .vertical: model.setVerticalAlignment([TextVerticalAlignment.top, .middle, .bottom][i])
        case .direction:
            // Pressing the picked one again returns to automatic.
            let picked: TextDirection = i == 0 ? .leftToRight : .rightToLeft
            let again = !model.isMixed("direction") && s.direction == picked
            model.setDirection(again ? nil : picked)
        case .frame: model.alignToFrame(Self.alignSymbols[i].0)
        case .fillMode: model.setFootageFill([nil, TextFootageFill.stencil, .inverted][i])
        case .strokePosition: model.setStrokePosition(i == 1 ? .centre : .outside)
        case .secondItalic: model.setSecondLineItalic(!(s.secondLine?.italic ?? false))
        }
    }

    // MARK: Appearance rows

    private var lastFillAlpha = 1.0

    func checkState(_ l: Layer) -> InspectorDraw.CheckState {
        let group: String? = switch l {
        case .fill: nil
        case .gradient: "gradient"
        case .outline: "stroke"
        case .background: "background"
        case .shadow: "shadow"
        case .second: "secondLine"
        case .autoFit: "autoFit"
        case .list: "list"
        }
        if let group, model.isMixedPresence(group) { return .mixed }
        return isOn(l) ? .on : .off
    }

    func isOn(_ l: Layer) -> Bool {
        let s = model.style
        switch l {
        case .fill: return s.color.alpha > 0
        case .gradient: return s.gradient != nil
        case .outline: return s.stroke != nil
        case .background: return s.background != nil
        case .shadow: return s.shadow != nil
        case .second: return s.secondLine != nil
        case .autoFit: return s.autoFit == true
        case .list: return s.list != nil
        }
    }

    func toggle(_ l: Layer) {
        let on = checkState(l) != .on
        switch l {
        case .fill:
            if model.style.color.alpha > 0 { lastFillAlpha = model.style.color.alpha }
            model.setFillAlpha(on ? max(lastFillAlpha, 0.01) : 0)
        case .gradient: model.setGradientEnabled(on)
        case .outline: model.setStrokeEnabled(on)
        case .background: model.setBackgroundEnabled(on)
        case .shadow: model.setShadowEnabled(on)
        case .second: model.setSecondLineEnabled(on)
        case .autoFit: model.setAutoFit(on)
        case .list: model.setList(on ? .bullet : nil)
        }
    }

    /// The swatch color of a row (nil = the layer is off: the well shows the field color).
    func wellColor(_ c: Control) -> RGBAColor? {
        let s = model.style
        switch c {
        case .well(.fill): return s.color
        case .well(.gradient): return s.gradient?.start
        case .well(.outline): return s.stroke?.color
        case .well(.background): return s.background?.color
        case .well(.shadow): return s.shadow?.color
        case .gradientEnd: return s.gradient?.end
        case .secondWell: return s.secondLine?.color
        default: return nil
        }
    }

    func setWell(_ c: Control, _ v: RGBAColor) {
        switch c {
        case .well(.fill): model.setColor(v)
        case .well(.gradient): model.setGradientStart(v)
        case .well(.outline): model.setStrokeColor(v)
        case .well(.background): model.setBackgroundColor(v)
        case .well(.shadow): model.setShadowColor(v)
        case .gradientEnd: model.setGradientEnd(v)
        case .secondWell: model.setSecondLineColor(v)
        default: break
        }
    }

    // MARK: Looks

    var currentLookStatus: LookStatus? {
        if let lookStatus { return lookStatus() }
        guard lookSource == nil, let id = model.appliedStyleID, let e = model.styles.entry(id) else { return nil }
        return LookStatus(name: e.name, edited: model.isStyleModified, canUpdate: !e.isBuiltIn)
    }

    var lookTitle: String {
        if let src = lookSource?() {
            return src.selected.flatMap { id in src.ids.firstIndex(of: id).map { src.titles[$0] } } ?? SQL10n.string("Custom")
        }
        return model.selectedStyleID.flatMap { model.styles.entry($0)?.name } ?? SQL10n.string("Custom")
    }

    func lookMenu() -> [SQMenuItem] {
        if let src = lookSource?() {
            return zip(src.titles, src.ids).map { title, id in
                SQMenuItem(title: title, isChecked: id == src.selected) { src.pick(id) }
            }
        }
        let sel = model.selectedStyleID
        return model.styles.entries.map { e in
            SQMenuItem(title: e.name, isChecked: e.id == sel) { [model] in model.applyStyle(e.id) }
        }
    }

    /// Asks the host for a name (`askName`); `then` runs with the typed name, not at all when it was canceled or empty.
    func name(_ title: String, _ initial: String, then: @escaping @MainActor (String) -> Void) {
        guard let askName else { then(initial); return }
        askName(title, initial) { typed in
            guard let n = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return }
            then(n)
        }
    }

    func saveLookAsNew() {
        if let onSaveLookAsNew { onSaveLookAsNew(); return }
        if let src = lookSource?() { src.add?(); return }
        let base = model.appliedStyleID.flatMap { model.styles.entry($0)?.name }
        name("Save as New Look", base.map { "\($0) 2" } ?? "My Look") { [weak self] n in
            _ = self?.model.saveCurrentAsStyle(named: n)
            self?.onHeightChange?()
        }
    }

    /// Right-click on the Look popup (TextBlockView.lookContextItems): the host's menu, else the model's text looks.
    func lookContextItems() -> [SQMenuItem] {
        if let lookContext { return lookContext() }
        let saveNew: @MainActor () -> Void = { [weak self] in self?.saveLookAsNew() }
        guard lookSource == nil, let id = model.appliedStyleID, let e = model.styles.entry(id), !e.isBuiltIn else {
            return TextAnimatorChoices.lookMenuItems(editable: nil, saveNew: saveNew)
        }
        return TextAnimatorChoices.lookMenuItems(
            editable: e.name,
            update: { [weak self] in self?.model.updateStyleFromCurrent(id); self?.onHeightChange?() },
            saveNew: saveNew,
            rename: { [weak self] in
                self?.name("Rename Look", e.name) { n in self?.model.renameStyle(id, to: n); self?.onHeightChange?() }
            },
            delete: { [weak self] in self?.model.deleteStyle(id); self?.onHeightChange?() })
    }

    /// A right click at `p`: the Look popup shows its menu (true); elsewhere nothing happens here (false).
    public func contextMenu(at p: CGPoint, part: Part) -> Bool {
        guard control(at: p, part) == .look, let f = frame(.look, part) else { return false }
        let items = lookContextItems()
        if !items.isEmpty { onMenu?(items, f, part) }
        return true
    }

    func updateLook() {
        if let onUpdateLook { onUpdateLook() } else if let id = model.appliedStyleID { model.updateStyleFromCurrent(id) }
    }

    // MARK: Menus

    func fontMenu(current: String?, set: @escaping @MainActor (String) -> Void) -> [SQMenuItem] {
        model.fontFamilies.map { f in SQMenuItem(title: f, isChecked: f == current) { set(f) } }
    }

    func weightMenu(current: FontWeight?, set: @escaping @MainActor (FontWeight) -> Void) -> [SQMenuItem] {
        Self.weights.map { w in SQMenuItem(title: w.0, isChecked: w.1 == current) { set(w.1) } }
    }

    /// Off, the presets, the saved animations, Custom; a Custom side can also be saved (fillAnimationMenu).
    func animationMenu(_ side: AnimationSide) -> [SQMenuItem] {
        let custom = model.isCustom(side)
        let ids = (side == .intro ? model.inAnimationIDs : model.outAnimationIDs) + [AnimationChoices.customID]
            + (custom && model.canSaveAnimations ? [AnimationChoices.saveID] : [])
        let shown = custom ? AnimationChoices.customID : (side == .intro ? model.selectedInID : model.selectedOutID)
        return ids.map { id in
            SQMenuItem(title: AnimationChoices.title(for: id, side: side, store: model.keystones), isChecked: id == shown) { [weak self] in
                self?.pickAnimation(id, side: side)
            }
        }
    }

    private var savingAnimation = false
    func pickAnimation(_ id: String, side: AnimationSide) {
        guard id == AnimationChoices.saveID else { model.setAnimation(id, side: side); return }
        guard !savingAnimation else { return }
        name(SQL10n.format("Save %@ Animation", SQL10n.string(side.title)), SQL10n.format("My %@", SQL10n.string(side.title))) { [weak self] n in
            guard let self, !savingAnimation else { return }
            savingAnimation = true
            Task { [weak self] in
                guard let self else { return }
                if !(await model.saveCustomAnimation(side, named: n)) {
                    onNotice?(SQL10n.format("The %@ animation could not be saved: it has no keyframes, or the Library is not available.",
                                            SQL10n.string(side.title)))
                }
                savingAnimation = false
            }
        }
    }

    func menu(for c: Control) -> [SQMenuItem]? {
        let s = model.style
        switch c {
        case .font: return fontMenu(current: model.isMixed("fontName") ? nil : s.fontName) { [model] in model.setFontFamily($0) }
        case .weight: return weightMenu(current: model.isMixed("weight") ? nil : s.weight) { [model] in model.setWeight($0) }
        case .look: return lookMenu()
        case .secondFont:
            guard s.secondLine != nil else { return nil }
            return fontMenu(current: s.secondLine?.fontName) { [model] in model.setSecondLineFont($0) }
        case .secondWeight:
            guard s.secondLine != nil else { return nil }
            return weightMenu(current: s.secondLine?.weight) { [model] in model.setSecondLineWeight($0) }
        case .listKind:
            guard s.list != nil else { return nil }
            return [("Bullets", TextListKind.bullet), ("Numbers", .numbered)].map { t, k in
                SQMenuItem(title: t, isChecked: s.list == k) { [model] in model.setList(k) }
            }
        case .intro: return animationMenu(.intro)
        case .outro: return animationMenu(.outro)
        case .animator(let side, let k): return animatorMenu(side, k)
        case .token(let f):
            guard f.isAvailable(in: s) else { return nil }
            let names = model.tokenNames(for: f), bound = model.boundToken(f)
            return [SQMenuItem(title: "Literal", isChecked: bound == nil) { [model] in model.bindToken(f, to: nil) }]
                + names.map { n in SQMenuItem(title: n, isChecked: n == bound) { [model] in model.bindToken(f, to: n) } }
        default: return nil
        }
    }

    /// One popup of a text animator side (TextBlockView.animatorRows); nil while it takes no input.
    func animatorMenu(_ side: TextInspectorModel.AnimatorSide, _ k: TextAnimatorChoices.Control) -> [SQMenuItem]? {
        let a = model.animator(side)
        guard TextAnimatorChoices.isEnabled(k, a) else { return nil }
        func items<T: Equatable>(_ list: [(String, T)], _ cur: T?, _ set: @escaping @MainActor (T) -> Void) -> [SQMenuItem] {
            list.map { title, v in SQMenuItem(title: title, isChecked: v == cur) { set(v) } }
        }
        let m = model
        return switch k {
        // `.some(nil)` = no animator, so "None" shows its check (a bare nil would mean "nothing picked").
        case .effect: items(TextAnimatorChoices.effects, TextAnimatorEffect??.some(a?.effect)) { m.setAnimatorEffect($0, side: side) }
        case .unit: items(TextAnimatorChoices.units, a?.unit) { m.setAnimatorUnit($0, side: side) }
        case .easing: items(TextAnimatorChoices.easings, a?.easing) { m.setAnimatorEasing($0, side: side) }
        case .direction: items(TextAnimatorChoices.directions, a?.direction) { m.setAnimatorDirection($0, side: side) }
        case .order: items(TextAnimatorChoices.orders, a?.order) { m.setAnimatorOrder($0, side: side) }
        default: nil
        }
    }

    func animatorTitle(_ side: TextInspectorModel.AnimatorSide, _ k: TextAnimatorChoices.Control) -> String {
        func title<T: Equatable>(_ list: [(String, T)], _ cur: T?) -> String { list.first { $0.1 == cur }?.0 ?? list.first?.0 ?? "" }
        let a = model.animator(side)
        return switch k {
        case .effect: TextAnimatorChoices.effects.first { $0.1 == a?.effect }?.0 ?? "None"
        case .unit: title(TextAnimatorChoices.units, a?.unit)
        case .easing: title(TextAnimatorChoices.easings, a?.easing)
        case .direction: title(TextAnimatorChoices.directions, a?.direction)
        case .order: title(TextAnimatorChoices.orders, a?.order)
        default: ""
        }
    }

    func popupTitle(_ c: Control) -> String {
        let s = model.style
        switch c {
        case .font: return model.isMixed("fontName") ? "" : s.fontName
        case .weight: return model.isMixed("weight") ? "" : Self.weights.first { $0.1 == s.weight }?.0 ?? ""
        case .look: return lookTitle
        case .secondFont: return model.isMixed("secondLine.fontName") ? "" : s.secondLine?.fontName ?? s.fontName
        case .secondWeight:
            return model.isMixed("secondLine.weight") ? "" : Self.weights.first { $0.1 == (s.secondLine?.weight ?? .regular) }?.0 ?? ""
        case .listKind: return s.list == .numbered ? "Numbers" : "Bullets"
        case .intro: return model.animationTitle(.intro)
        case .outro: return model.animationTitle(.outro)
        case .animator(let side, let k): return animatorTitle(side, k)
        case .token(let f): return model.boundToken(f).flatMap { model.tokenNames(for: f).contains($0) ? $0 : nil } ?? "Literal"
        default: return ""
        }
    }

    func popupEnabled(_ c: Control) -> Bool {
        switch c {
        case .secondFont, .secondWeight: model.style.secondLine != nil
        case .listKind: model.style.list != nil
        case .animator(let side, let k): TextAnimatorChoices.isEnabled(k, model.animator(side))
        case .token(let f): f.isAvailable(in: model.style)
        default: true
        }
    }

    /// One line under the Second Line title (the Mac summary in the value slot).
    var secondSummary: String {
        let s = model.style
        if let l = s.secondLine {
            return "\(l.fontName) · \(Self.weights.first { $0.1 == l.weight }?.0 ?? "") · \(String(format: "%.1f", l.size)) px"
        }
        return "\(s.fontName) · Regular · \(String(format: "%.1f", s.size * 2 / 3)) px"
    }

    var textSummary: String {
        model.isMixed("fontName") ? "" : "\(model.style.fontName) \u{00B7} \(Int(model.style.size.rounded()))"
    }

    var animationSummary: String {
        "\(SQL10n.string("Intro")): \(model.animationTitle(.intro)) \u{00B7} \(SQL10n.string("Outro")): \(model.animationTitle(.outro))"
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, part: Part) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        let h = height(part)
        c.fill(CGRect(x: 0, y: 0, width: width, height: h), t.panel)
        for r in rows(part) {
            let labelX = ControlsGrid.labelX + CGFloat(r.level) * ControlsGrid.levelIndent
            if let l = r.label {
                c.draw(SQL10n.string(l), in: CGRect(x: labelX, y: r.y, width: max(ControlsGrid.valueX - labelX - ControlsGrid.gap, 0),
                                                    height: r.height), fontSize: fs, t.label2)
            }
            if let i = r.icon {
                c.draw(icon: i, at: CGPoint(x: labelX, y: r.y + ((r.height - 12) / 2).rounded()), size: 12, t.label2)
            }
            for (k, f0) in r.controls { drawControl(&c, k, f0.offsetBy(dx: 0, dy: r.y), part: part) }
            if case .check(.second)? = r.controls.first?.0 {
                c.draw(secondSummary, in: CGRect(x: ControlsGrid.valueColumn(0), y: r.y, width: max(resetX - ControlsGrid.gap - ControlsGrid.valueColumn(0), 0),
                                                 height: r.height), fontSize: fs, t.label3)
            }
            if case .field(.tracking)? = r.controls.first?.0 {
                let x = ControlsGrid.valueX + ControlsGrid.valueWidth + ControlsGrid.gap
                c.draw(icon: .moveVertical, at: CGPoint(x: x, y: r.y + ((r.height - 12) / 2).rounded()), size: 12, t.label2)
            }
        }
    }

    private func drawHeader(_ c: inout Canvas, _ f: CGRect, title: String, open: Bool, summary: String, topLine: Bool) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        if topLine { c.fill(CGRect(x: 0, y: f.minY, width: width, height: 1), t.separator) }
        InspectorDraw.chevron(&c, in: CGRect(x: ControlsGrid.headerToggleX, y: f.minY, width: 12, height: f.height),
                              direction: open ? .down : .right, t.label3, size: 8)
        c.draw(SQL10n.string(title), in: CGRect(x: ControlsGrid.headerLabelX, y: f.minY, width: 120, height: f.height), fontSize: fs, t.label)
        c.draw(summary, in: CGRect(x: ControlsGrid.headerLabelX + 90, y: f.minY,
                                   width: max(width - ControlsGrid.trailing - ControlsGrid.headerLabelX - 90, 0), height: f.height),
               fontSize: fs, t.label3, align: .right)
        c.fill(CGRect(x: 0, y: f.maxY - 1, width: width, height: 1), t.trackRowLine)
    }

    private func drawControl(_ c: inout Canvas, _ k: Control, _ f: CGRect, part: Part) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        switch k {
        case .textHeader: drawHeader(&c, f, title: "Text", open: textOpen, summary: textSummary, topLine: false)
        case .animationHeader: drawHeader(&c, f, title: "Animation", open: animationOpen, summary: animationSummary, topLine: true)
        case .textBox: drawBox(&c, f)
        case .gallery:
            lookGallery.theme = t
            lookGallery.width = width
            lookGallery.currentID = model.currentLookID
            c.saveGState(); c.translateBy(x: f.minX, y: f.minY); lookGallery.draw(&c); c.restoreGState()
        case .font, .weight, .look, .secondFont, .secondWeight, .listKind, .intro, .outro, .animator, .token:
            InspectorDraw.popup(&c, title: SQL10n.string(popupTitle(k)), in: f, hovering: hover == k, open: false, enabled: popupEnabled(k), t)
        case .lookAdd:
            if hover == k { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), pressed == k ? t.fillPressed : t.fillHover) }
            c.draw(icon: .plus, at: CGPoint(x: (f.midX - 6).rounded(), y: (f.midY - 6).rounded()), size: 12, t.label2)
        case .lookUpdate:
            InspectorDraw.button(&c, title: SQL10n.string("Update"), in: f, hovering: hover == k, pressed: pressed == k,
                                 enabled: currentLookStatus?.canUpdate ?? false, t)
        case .lookSaveNew:
            InspectorDraw.button(&c, title: SQL10n.string("Save as New"), in: f, hovering: hover == k, pressed: pressed == k, enabled: true, t)
            let state = currentLookStatus.map { $0.edited ? "\($0.name) \u{00B7} \(SQL10n.string("edited"))" : $0.name } ?? ""
            c.draw(state, in: CGRect(x: f.maxX + ControlsGrid.gap, y: f.minY, width: max(valueEnd - f.maxX - ControlsGrid.gap, 0), height: f.height),
                   fontSize: fs, t.accent)
        case .button(let g, let i):
            let st = buttonState(g, i), on = buttonEnabled(g), b = Self.buttons(g)[i]
            if st.on || (hover == k && on) {
                c.fill(roundedRect: f.insetBy(dx: 1, dy: 0), radius: CGFloat(DrawTheme.Radius.small), st.on ? t.fillPressed : t.fillHover)
            }
            let ink = (st.on ? t.label : t.label2).alpha(on ? 1 : InspectorTokens.disabledAlpha)
            if let icon = b.icon {
                c.draw(icon: icon, at: CGPoint(x: (f.midX - 6).rounded(), y: (f.midY - 6).rounded()), size: 12, ink)
            } else if let title = b.title {
                c.draw(SQL10n.string(title), in: f, fontSize: fs, ink, align: .center)
            }
            // Multi-select: a differing switch shows a dash under its glyph.
            if st.mixed { c.fill(CGRect(x: f.midX - 4, y: f.maxY - 3, width: 8, height: 1), t.label3) }
        case .check(let l):
            InspectorDraw.checkbox(&c, checkState(l), box: CGRect(x: f.minX, y: f.minY, width: 14, height: 14),
                                   hovering: hover == k, pressed: pressed == k, enabled: true, t)
            _ = l
        case .well, .gradientEnd, .secondWell:
            if let col = wellColor(k) {
                InspectorDraw.colorWell(&c, DrawColor(Float(col.red), Float(col.green), Float(col.blue), Float(max(col.alpha, 0.15))),
                                        in: f, hovering: hover == k, t)
            } else {
                InspectorDraw.colorWell(&c, t.field, in: f, hovering: false, t)
            }
        case .eyedropper(let l):
            let on = isOn(l)
            if hover == k && on { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), pressed == k ? t.fillPressed : t.fillHover) }
            c.draw(icon: .eyedropper, at: CGPoint(x: (f.midX - 6).rounded(), y: (f.midY - 6).rounded()), size: 12,
                   t.label2.alpha(on ? 1 : InspectorTokens.disabledAlpha))
        case .chevron(let l):
            InspectorDraw.chevron(&c, in: f, direction: openLayers.contains(l) ? .down : .right, hover == k ? t.label : t.label3, size: 8)
        case .field(let fl):
            var fd = field(fl)
            fd.hovering = hover == k
            fd.draw(&c, in: f, theme: t, focused: focused == fl)
        case .slider(let fl):
            let p = sliderParts(f), sp = spec(fl)
            var fd = field(fl)
            fd.hovering = hover == k
            fd.draw(&c, in: p.field, theme: t, focused: focused == fl)
            let frac = (value(fl) - sp.range.lowerBound) / max(sp.range.upperBound - sp.range.lowerBound, 1e-9)
            InspectorDraw.slider(&c, fraction: frac, in: p.track, enabled: isEnabled(fl), t)
        }
        _ = part
    }

    /// The text box: the field capsule grown to its lines; while typing, the open editor (line by line, caret and
    /// selection on their lines).
    private func drawBox(_ c: inout Canvas, _ f: CGRect) {
        measure = (c.atlas, c.scale)
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        let r = CGFloat(InspectorTokens.controlRadius)
        c.fill(roundedRect: f, radius: r, t.field)
        if editor != nil { c.fill(roundedRect: f, radius: r, t.accentTint) }
        c.stroke(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, width: 1, hover == .textBox ? t.fieldEdgeHover : t.fieldEdge)
        let inner = f.insetBy(dx: 8, dy: 4)
        if let e = editor {
            InspectorDraw.focusLine(&c, f, radius: r, t)
            InspectorDraw.editLines(&c, e, in: inner, lineHeight: Self.lineHeight, fontSize: fs, color: t.label, t)
            return
        }
        c.saveGState()
        c.clip(to: inner)
        let lines = boxText.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            c.draw(String(line), in: CGRect(x: inner.minX, y: inner.minY + CGFloat(i) * Self.lineHeight, width: inner.width, height: Self.lineHeight),
                   fontSize: fs, t.label)
        }
        c.restoreGState()
    }

    // MARK: Pointer

    private(set) var hover: Control?
    private var pressed: Control?
    private var pressPart: Part = .text
    private var sliderDrag: Field?
    private var fieldPress: Field?
    private var counter = ClickCounter()
    private(set) var editor: TextEditState?
    /// The glyph atlas of the last draw: click-to-caret measures with it.
    private var measure: (atlas: GlyphAtlas?, scale: Float) = (nil, 1)
    /// The caret index under `p` (part coordinates) in the open box.
    private func boxCaret(_ e: TextEditState, at p: CGPoint, part: Part) -> Int? {
        guard let f = frame(.textBox, part) else { return nil }
        let c = Canvas(width: 0, height: 0, atlas: measure.atlas, scale: measure.scale)
        return InspectorDraw.caretIndex(c, e, at: p, in: f.insetBy(dx: 8, dy: 4), lineHeight: Self.lineHeight,
                                        fontSize: CGFloat(DrawTheme.TypeSize.body))
    }
    private var typed = false
    private var colorOpen = false

    func control(at p: CGPoint, _ part: Part) -> Control? {
        for r in rows(part) where p.y >= r.y && p.y < r.y + r.height {
            for (k, f) in r.controls {
                let hit = f.offsetBy(dx: 0, dy: r.y)
                let wide = k == .textBox ? hit : CGRect(x: hit.minX, y: r.y, width: hit.width, height: r.height)
                if wide.contains(p) { return k }
            }
            // The Appearance title opens and closes its detail rows like the chevron.
            if case .check(let l)? = r.controls.first?.0, l.hasDetail, p.x >= ControlsGrid.labelX, p.x < ControlsGrid.valueX {
                return .chevron(l)
            }
        }
        return nil
    }

    public func mouseMoved(to p: CGPoint?, part: Part) {
        guard sliderDrag == nil, fieldPress == nil else { return }
        hover = p.flatMap { control(at: $0, part) }
        if part == .animation { lookGallery.mouseMoved(to: hover == .gallery ? p.flatMap(galleryPoint) : nil) }
    }

    /// `p` (animation part coordinates) in the gallery's coordinates.
    private func galleryPoint(_ p: CGPoint) -> CGPoint? {
        frame(.gallery, .animation).map { CGPoint(x: p.x - $0.minX, y: p.y - $0.minY) }
    }

    /// True while the Look gallery previews a hovered look: the host keeps redrawing at display rate.
    public var isAnimating: Bool { showsLookGallery && animationOpen && lookGallery.tick() }

    public func mouseDown(at p: CGPoint, part: Part, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p, part)
        if let fl = focused, k != .field(fl), k != .slider(fl) { resignFocus() }
        if k != .textBox { endTyping() }
        guard let k else { return }
        pressed = k
        pressPart = part
        switch k {
        case .gallery: if let q = galleryPoint(p) { lookGallery.mouseDown(at: q) }
        case .textBox:
            if editor == nil { editor = TextEditState(boxText, selectAll: false); typed = false }
            // A click places the caret (shift extends the selection), a triple click selects everything.
            if var e = editor, let i = boxCaret(e, at: p, part: part) {
                if n >= 3 { e.selectAll() } else if n == 2 { e.place(i); e.selectWord(at: i) } else { e.place(i) }
                editor = e
            }
        case .field(let fl):
            guard isEnabled(fl) else { return }
            var fd = field(fl)
            apply(fd.mouseDown(x: Float(p.x), clickCount: n), fl)
            fields[fl] = fd
            fieldPress = fl
            focused = fl
        case .slider(let fl):
            guard isEnabled(fl), let f = frame(k, part) else { return }
            let parts = sliderParts(f)
            if p.x < parts.field.maxX {
                var fd = field(fl)
                apply(fd.mouseDown(x: Float(p.x), clickCount: n), fl)
                fields[fl] = fd
                fieldPress = fl
                focused = fl
            } else {
                sliderDrag = fl
                model.beginEditing()
                setFromSlider(fl, x: p.x, track: parts.track)
            }
        default:
            if let items = menu(for: k), let f = frame(k, part) {
                pressed = nil
                if !items.isEmpty { onMenu?(items, f, part) }
            }
        }
    }

    public func mouseDragged(to p: CGPoint, part: Part, modifiers: InputModifiers = []) {
        if pressed == .textBox, var e = editor, let i = boxCaret(e, at: p, part: pressPart) {
            e.place(i, extend: true)        // drag-select in the box
            editor = e
            return
        }
        if let fl = sliderDrag, let f = frame(.slider(fl), pressPart) {
            setFromSlider(fl, x: p.x, track: sliderParts(f).track)
        } else if let fl = fieldPress {
            var fd = field(fl)
            apply(fd.mouseDragged(x: Float(p.x), modifiers: modifiers), fl)
            fields[fl] = fd
        }
    }

    public func mouseUp(at p: CGPoint, part: Part) {
        defer { pressed = nil; mouseMoved(to: p, part: part) }
        if sliderDrag != nil { sliderDrag = nil; model.endEditing(); return }
        if let fl = fieldPress {
            var fd = field(fl)
            apply(fd.mouseUp(), fl)
            fields[fl] = fd
            fieldPress = nil
            return
        }
        if pressed == .gallery, part == .animation {
            lookGallery.mouseUp(at: galleryPoint(p) ?? CGPoint(x: -1, y: -1))
            return
        }
        guard let k = pressed, part == pressPart, control(at: p, part) == k else { return }
        switch k {
        case .textHeader:
            textOpen.toggle()
            UserDefaults.standard.set(textOpen, forKey: TextBlockDraw.sectionKey("textblock.text"))
            onHeightChange?()
        case .animationHeader:
            animationOpen.toggle()
            UserDefaults.standard.set(animationOpen, forKey: TextBlockDraw.sectionKey("textblock.animation"))
            onHeightChange?()
        case .button(let g, let i): if buttonEnabled(g) { press(g, i) }
        case .check(let l): toggle(l)
        case .chevron(let l): setOpen(l, !openLayers.contains(l))
        case .lookAdd: saveLookAsNew()
        case .lookUpdate: if currentLookStatus?.canUpdate == true { updateLook() }
        case .lookSaveNew: saveLookAsNew()
        case .well, .gradientEnd, .secondWell: pickColor(k, part)
        case .eyedropper(let l): if isOn(l) { sampleColor(l) }
        default: break
        }
        if case .lookUpdate = k { onHeightChange?() }
        if case .lookSaveNew = k { onHeightChange?() }
    }

    private func setFromSlider(_ fl: Field, x: CGFloat, track: CGRect) {
        let sp = spec(fl)
        let raw = sp.range.lowerBound + InspectorDraw.sliderFraction(x: x, in: track) * (sp.range.upperBound - sp.range.lowerBound)
        set(fl, (raw / sp.step).rounded() * sp.step)
    }

    /// The SQ color picker through the host: one picker session is one undo step; the layer keeps its own opacity.
    private func pickColor(_ k: Control, _ part: Part) {
        guard let pick = onPickColor, let cur = wellColor(k), let f = frame(k, part) else { return }
        if colorOpen { model.endEditing(); colorOpen = false }
        pick(EffectColor(red: cur.red, green: cur.green, blue: cur.blue, alpha: cur.alpha), f, part) { [weak self] color in
            guard let self else { return }
            guard let color else {
                if colorOpen { colorOpen = false; model.endEditing() }
                return
            }
            if !colorOpen { colorOpen = true; model.beginEditing() }
            let alpha = wellColor(k)?.alpha ?? 1
            setWell(k, RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha))
        }
    }

    static let eyedropperLayers: [Layer] = [.fill, .outline, .background, .shadow]

    /// An eyedropper: the host samples the screen; the picked color is one undo step and the layer keeps its opacity.
    func sampleColor(_ l: Layer) {
        guard let begin = sampler else { return }
        begin { [weak self] picked in
            guard let self, let picked else { return }
            let alpha = wellColor(.well(l))?.alpha ?? 1
            let rgb = picked.rgb
            let v = RGBAColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
            model.beginEditing()
            setWell(.well(l), v)
            model.endEditing()
        }
    }

    // MARK: Keys

    /// Keys for the text box or the focused value field; false when neither has them.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if var e = editor {
            // Return breaks the line (the box is multi-line); the box ends with Esc, Tab or a click elsewhere.
            if k == .escape || k == .tab { endTyping(); return true }
            if e.handleLines(k, modifiers: modifiers) != .edited { editor = e; return true }
            editor = e
            if !typed { typed = true; onTextBegin?() }
            boxText = e.string
            onTextChange?(e.string)
            onHeightChange?()
            return true
        }
        guard let fl = focused else { return false }
        var fd = field(fl)
        if k == .tab {
            apply(fd.resignFocus(), fl); fields[fl] = fd
            moveFocus(from: fl, backward: modifiers.contains(.shift))
            return true
        }
        apply(fd.key(k, modifiers: modifiers, now: clock()), fl)
        fields[fl] = fd
        return true
    }

    /// Tab order: the enabled value fields shown, top to bottom.
    private func moveFocus(from fl: Field, backward: Bool) {
        var order: [Field] = []
        for part in Part.allCases {
            for r in rows(part) {
                for (k, _) in r.controls {
                    if case .field(let x) = k, isEnabled(x) { order.append(x) }
                    if case .slider(let x) = k, isEnabled(x) { order.append(x) }
                }
            }
        }
        guard let i = order.firstIndex(of: fl), !order.isEmpty else { focused = nil; return }
        focused = order[(i + (backward ? order.count - 1 : 1)) % order.count]
    }

    private func endTyping() {
        guard editor != nil else { return }
        editor = nil
        if typed { onTextEnd?() }
        typed = false
        boxText = text
    }

    /// Puts the caret at the end of the text box (the Mac `TextBlockView.focusTextBox`); false when the box is hidden.
    @discardableResult
    public func focusTextBox() -> Bool {
        guard showsTextBox else { return false }
        if focused != nil { resignFocus() }
        if editor == nil {
            var e = TextEditState(boxText, selectAll: false)
            e.place(e.text.count)
            editor = e
            typed = false
        }
        return true
    }

    public func resignFocus() {
        endTyping()
        guard let fl = focused else { return }
        var fd = field(fl)
        apply(fd.resignFocus(), fl)
        fields[fl] = fd
        focused = nil
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each).
    public func tick() {
        for fl in Array(fields.keys) { guard var fd = fields[fl] else { continue }; apply(fd.tick(now: clock()), fl); fields[fl] = fd }
    }

    public func help(at p: CGPoint, part: Part) -> String? {
        guard let k = control(at: p, part) else {
            return rows(part).first { p.y >= $0.y && p.y < $0.y + $0.height }?.tip.map { SQL10n.string($0) }
        }
        let tip: String? = switch k {
        case .textHeader: textOpen ? "Collapse Text" : "Expand Text"
        case .animationHeader: animationOpen ? "Collapse Animation" : "Expand Animation"
        case .font: "Font"
        case .weight: "Weight"
        case .look: "Look"
        case .lookAdd: "Save Current as Look"
        case .lookUpdate: "Update the Look"
        case .lookSaveNew: "Save as New Look"
        case .button(let g, let i): Self.buttons(g)[i].tip
        case .check(let l): l.title
        case .chevron(let l): openLayers.contains(l) ? "Hide Details" : "Show Details"
        case .well(.gradient): "Gradient Start Color"
        case .well(let l): "\(l.title) Color"
        case .field(.animator(_, .loops)): "Loop Count"
        case .field(.animator(_, .distance)): "Slide Distance"
        case .field(.animator(_, .blur)): "Start Blur"
        case .field(.animator(_, .stagger)): "Stagger"
        case .field(.animator(_, .length)): "Unit Length"
        case .eyedropper(let l): "Pick \(l.title) Color"
        case .gradientEnd: "Gradient End Color"
        case .secondWell: "Second Line Color"
        case .secondFont: "Second Line Font"
        case .secondWeight: "Second Line Weight"
        case .listKind: "List Style"
        case .intro: "Intro"
        case .outro: "Outro"
        case .field(.tracking): "Letter Spacing (px)"
        case .field(.leading): "Line Spacing (px)"
        case .field(.inLength): "Intro Length"
        case .field(.outLength): "Outro Length"
        case .slider(.size): "Size"
        case .token(let f): SQL10n.format("Follow %@ Token", SQL10n.string(f == .font ? "Font" : "Color"))
        case .gallery: galleryPoint(p).flatMap(lookGallery.help(at:))
        default: rows(part).first { p.y >= $0.y && p.y < $0.y + $0.height }?.tip
        }
        return tip.map { SQL10n.string($0) }
    }
}
