import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// Effect Controls on the shared toolkit (the Windows port plan, "Panel status: Inspector"): EffectControlsView translated
/// row by row onto the SQDrawKit Canvas. The model, the row layout (`EffectControlsLayout.rows`), the grid
/// (`ControlsGrid`) and every action are the Mac ones; only drawing and event glue are new. Coordinates are points, y down,
/// (0, 0) = the panel's top-left; the host converts its pixels (`handle(_:scale:origin:)`) or calls the point methods.
/// Menus (popups, right-click) go out through `onMenu` as `SQMenuItem`s, so the host shows them with its one menu system.
@MainActor public final class EffectControlsDrawPanel {
    public let model: EffectControlsModel
    public var theme = DrawTheme()
    public var size: CGSize = .zero {
        didSet {
            // The caption list fills the column height, so a height change re-lays it out too.
            if size.width != oldValue.width || (size.height != oldValue.height && clipSections?.mode == .captions) { relayout() }
        }
    }
    public var scrollY: CGFloat = 0
    public private(set) var rows: [EffectRow] = []

    /// A popup or a context menu: the items and the anchor (panel points). The host shows them (SQDrawShell menu list).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// Turning a parameter's animation off asks first (R29): the host shows `KeyToolPrompt.removeKeyframes(title)` and
    /// calls `remove` when confirmed. Default (no host dialog): the keys go without asking.
    public var confirmRemoveKeyframes: @MainActor (_ title: String, _ remove: @escaping @MainActor () -> Void) -> Void = { _, remove in remove() }
    /// A color well was clicked: the host opens its color picker at `anchor` and reports every change, nil when it closes.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// The curve popover for `source` (speed transition, a motion effect's Custom curve) at `anchor` (panel points): the
    /// host shows `EasingPopoverDraw`.
    public var onEaseCurve: (@MainActor (_ source: any EaseCurveSource, _ anchor: CGRect) -> Void)?
    /// Seconds for the arrow / wheel burst timer (StepBurst idle).
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public init(model: EffectControlsModel) { self.model = model }

    // MARK: Row identity and hit targets

    /// The row a control belongs to.
    public enum RowRef: Hashable, Sendable {
        case property(EffectProperty), speed(SpeedControl), blend
        /// A field of a translated row (`EffectControlsDrawRows`), by widget key.
        case custom(String)
    }
    public struct FieldID: Hashable, Sendable {
        public var ref: RowRef
        public var component: EffectComponent
    }
    /// What the pointer is over.
    public enum Target: Hashable, Sendable {
        case chevron(EffectSection), eye(EffectSection), sectionReset(EffectSection), header(EffectSection)
        case ring(RowRef), previous(RowRef), key(RowRef), next(RowRef), open(RowRef), reset(RowRef)
        case label(RowRef), field(FieldID), link(EffectProperty), keyPick(EffectProperty), checkbox(RowRef), popup(RowRef), well(EffectProperty)
        /// The Edit Curve button next to a motion effect's Curve popup (FB-T3).
        case curve(EffectProperty)
        case row(RowRef)
        /// A control of a translated row, and the enable box of a disclosure row.
        case widget(String), widgetToggle(String)
        case none
    }

    public private(set) var fields: [FieldID: ScrubFieldControl] = [:]
    public private(set) var focusedField: FieldID?
    /// Text fields of translated rows (timecodes), by widget key, and the one being typed in.
    public private(set) var textFields: [String: TextFieldControl] = [:]
    public private(set) var focusedText: String?
    var surfaces: [String: DrawSurface] = [:]
    private var customSpecs: [String: FieldSpec] = [:]
    /// Text width in points at the body size (from the canvas' atlas, set while drawing).
    var measure: (@MainActor (String) -> CGFloat)?
    /// "Edit Custom Setup" of a Multiband Compressor: the host opens the setup editor for the effect.
    /// shortcut: the floating setup window (MultibandEditorPanel) is not on the canvas yet; upgrade by translating it.
    public var onMultibandEditor: (@MainActor (ClipEffect.ID) -> Void)?
    private var hoverPoint: CGPoint?
    var pressTarget: Target = .none
    private var pressPoint: CGPoint = .zero
    private var pressModifiers: InputModifiers = []
    private var reordering: (section: EffectSection, target: Int?)?
    private var clicks = ClickCounter()

    // MARK: Layout (EffectControlsView.rebuild)

    /// Rows from the model, with the Mac rebuild's arguments; call after every model change.
    public func relayout() {
        rows = EffectControlsLayout.rows(sections: model.visibleSections, collapsed: model.collapsedSections,
                                         expanded: model.graphEditor ? [] : model.expanded, blendModeRow: true, groupHeaders: false,
                                         openColorGroups: model.openColorGroups,
                                         subjectMasks: model.subjectMaskIDs, pictureMasks: model.pictureMaskIDs,
                                         colorRangeMasks: model.colorRangeMaskIDs, gradeRanges: model.gradeRangeEffects,
                                         stabilizers: model.stabilizerMethods,
                                         transformCrop: model.transformCropProperties)
        placeSection()
        syncFields()
    }

    /// The clip's content section (Audio, Shape, Color Matte, ...): set by the host; placed like the Mac skeleton.
    public var clipSections: ClipSectionsDraw? {
        didSet {
            clipSections?.onHeightChange = { [weak self] in self?.relayout() }
            // Menus and the color picker go out through the panel's own hooks, anchored in panel coordinates.
            clipSections?.onMenu = { [weak self] items, anchor in
                guard let self else { return }
                onMenu?(items, anchor.offsetBy(dx: 0, dy: sectionFrame.minY - scrollY))
            }
            clipSections?.onPickColor = { [weak self] color, anchor, change in
                guard let self else { return }
                onPickColor?(color, anchor.offsetBy(dx: 0, dy: sectionFrame.minY - scrollY), change)
            }
            clipSections?.slotOffset = { [weak self] part in
                guard let self, let f = slotFrame(part) else { return 0 }
                return f.minY - sectionFrame.minY
            }
            relayout()
        }
    }
    /// Where the section sits in content coordinates (zero height: none).
    public private(set) var sectionFrame: CGRect = .zero
    /// The your-default marker of each section header as last drawn (row coordinates): its tooltip.
    private var defaultMarkers: [EffectSection: CGRect] = [:]
    private var sectionPressed = false
    /// The text clip's Arrange part (closes Transform) and Animation section (after Transform), content coordinates.
    public private(set) var arrangeFrame: CGRect = .zero
    public private(set) var animationFrame: CGRect = .zero
    private var slotPressed: TextBlockDraw.Part?

    func slotFrame(_ part: TextBlockDraw.Part) -> CGRect? {
        switch part {
        case .text: nil
        case .arrange: arrangeFrame.height > 0 ? arrangeFrame : nil
        case .animation: animationFrame.height > 0 ? animationFrame : nil
        }
    }

    /// EffectControlsView.place: a leading section goes before the rows (they move down by its height and the gap),
    /// any other after the last row. A text clip's Arrange part goes in at the end of Transform (none while Transform
    /// is collapsed) and its Animation section right after Transform; the sections below move down.
    private func placeSection() {
        arrangeFrame = .zero; animationFrame = .zero
        guard let sec = clipSections, sec.mode != .none else { sectionFrame = .zero; return }
        sec.width = size.width
        sec.theme = theme
        sec.availableHeight = size.height
        let h = sec.height, gap = ControlsMetrics.sectionGap
        if sec.mode.leads {
            sectionFrame = CGRect(x: 0, y: 0, width: size.width, height: h)
            let offset = h > 0 && !rows.isEmpty ? h + gap : 0
            func isSection(_ r: EffectRow) -> Bool { if case .section = r.kind { true } else { false } }
            let motion = rows.firstIndex { $0.kind == .section(.motion) }
            let insert = motion.flatMap { m in rows[(m + 1)...].firstIndex(where: isSection) } ?? rows.count
            var shift: CGFloat = 0
            if motion != nil {
                let end = (insert < rows.count ? rows[insert].y - gap : rows.last.map { $0.y + $0.height } ?? 0) + offset
                let tailH = model.collapsedSections.contains(.motion) ? 0 : sec.transformTailHeight
                let animH = sec.afterTransformHeight
                arrangeFrame = CGRect(x: 0, y: end, width: size.width, height: tailH)
                animationFrame = CGRect(x: 0, y: end + tailH + gap, width: size.width, height: animH)
                shift = tailH + (animH > 0 ? gap + animH : 0)
            }
            rows = rows.enumerated().map { i, r in var r = r; r.y += offset + (i >= insert ? shift : 0); return r }
        } else {
            var y = rows.last.map { $0.y + $0.height } ?? 0
            if y > 0 { y += gap }
            sectionFrame = CGRect(x: 0, y: y, width: size.width, height: h)
        }
    }

    private func inSection(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + scrollY - sectionFrame.minY) }
    private func overSection(_ p: CGPoint) -> Bool { sectionFrame.height > 0 && sectionFrame.offsetBy(dx: 0, dy: -scrollY).contains(p) }

    public var contentHeight: CGFloat {
        max(rows.last.map { $0.y + $0.height } ?? 0, sectionFrame.maxY, arrangeFrame.maxY, animationFrame.maxY)
    }

    /// The text slot under `p` (panel points) and `p` in its coordinates.
    private func slot(at p: CGPoint) -> (TextBlockDraw.Part, CGPoint)? {
        for part in [TextBlockDraw.Part.arrange, .animation] {
            guard let f = slotFrame(part), f.offsetBy(dx: 0, dy: -scrollY).contains(p) else { continue }
            return (part, inSlot(p, part))
        }
        return nil
    }
    private func inSlot(_ p: CGPoint, _ part: TextBlockDraw.Part) -> CGPoint {
        CGPoint(x: p.x, y: p.y + scrollY - (slotFrame(part)?.minY ?? 0))
    }
    private var textSlots: TextBlockDraw? { clipSections?.mode == .text ? clipSections?.textBlock : nil }

    private var grid: ControlsGrid { ControlsGrid(width: size.width) }

    private func rowTop(_ r: EffectRow) -> CGFloat { r.y - scrollY }
    func rowTopInPanel(_ r: EffectRow) -> CGFloat { rowTop(r) }

    public func row(at p: CGPoint) -> EffectRow? {
        rows.first { p.y >= rowTop($0) && p.y < rowTop($0) + $0.height }
    }

    // MARK: Fields (PropertyRow.update, SpeedControlRow.update)

    /// The scrub fields of a row: one per component, keyed by row and component.
    func fieldIDs(_ kind: EffectRow.Kind) -> [FieldID] {
        switch kind {
        case .property(let p) where p.paramKind.map(Self.isNumber) ?? true:
            return model.valueComponents(p).map { FieldID(ref: .property(p), component: $0) }
        case .speedControl(.speed): return [FieldID(ref: .speed(.speed), component: .all)]
        case .property, .speedControl, .section, .blendMode, .group, .placeholder: return []
        default:
            guard let r = rows.first(where: { $0.kind == kind }), let ws = widgets(r) else { return [] }
            return ws.compactMap { if case .field = $0.kind { FieldID(ref: .custom($0.key), component: .all) } else { nil } }
        }
    }

    private static func isNumber(_ k: EffectParamKind) -> Bool {
        switch k {
        case .color, .checkbox, .choice: false
        default: true
        }
    }

    /// Format and value of every visible field from the model (a field being dragged or typed in keeps its own value).
    public func syncFields() {
        var live: [FieldID: ScrubFieldControl] = [:]
        var specs: [String: FieldSpec] = [:], texts: [String: TextFieldControl] = [:]
        for r in rows {
            if let ws = widgets(r) {
                for w in ws {
                    switch w.kind {
                    case .field(let spec): specs[w.key] = spec
                    case .textField(let text, _):
                        var f = textFields[w.key] ?? TextFieldControl(text: text)
                        if !f.isEditing { f.text = text }
                        f.isEnabled = w.enabled
                        texts[w.key] = f
                    default: break
                    }
                }
            }
        }
        customSpecs = specs
        textFields = texts
        if let focusedText, texts[focusedText] == nil { self.focusedText = nil }
        for r in rows {
            for id in fieldIDs(r.kind) {
                var f = fields[id] ?? ScrubFieldControl(value: 0)
                configure(&f, id)
                live[id] = f
            }
        }
        if let focusedField, live[focusedField] == nil { self.focusedField = nil }
        fields = live
    }

    private func configure(_ f: inout ScrubFieldControl, _ id: FieldID) {
        let busy = f.isDragging || f.isEditing
        switch id.ref {
        case .property(let p):
            let pic = model.displayPicture
            f.range = p.displayRange(picture: pic); f.step = p.displayStep(picture: pic)
            f.unit = p.displayUnit(picture: pic); f.decimals = p.displayDecimals(picture: pic)
            f.isPlain = true; f.leadingText = true      // board `.hv`: plain accent numbers; the capsule shows while typing
            if p == .rotation {      // turns + degrees from 360 up ("1x 30.0°"), typing "1x30" or "390" both work
                let current = f.isMixed ? 0 : f.value
                f.valueFormatter = { RotationText.format($0) }
                f.valueParser = { RotationText.parse($0, current: current) }
            }
            let v: Double
            switch id.component {
            case .x: v = p.display(model.vectorValue(p).x, component: .x, picture: pic)
            case .y: v = p.display(model.vectorValue(p).y, component: .y, picture: pic)
            case .all: v = p.display(model.scalarValue(p), picture: pic)
            }
            if !busy { f.value = v }
            f.isMixed = model.isMixed(p, component: id.component)
        case .speed:
            f.range = 1...10000; f.step = 1; f.decimals = 1; f.unit = "%"; f.defaultValue = 100
            f.isPlain = true
            if !busy { f.value = model.speedPercent }
        case .blend: break
        case .custom(let key):
            guard let spec = customSpecs[key] else { break }
            spec.configure(&f)
            if !busy { f.value = spec.value() }
        }
        if case .custom(let key) = id.ref, let r = rows.first(where: { widgets($0)?.contains { $0.key == key } == true }),
           let w = widgets(r)?.first(where: { $0.key == key }) { f.isEnabled = w.enabled }
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ id: FieldID) {
        for e in events {
            switch id.ref {
            case .property(let p):
                let set = { (v: Double) in
                    _ = self.model.setValue(p, component: id.component,
                                            to: p.native(fromDisplay: v, component: id.component, picture: self.model.displayPicture))
                }
                switch e {
                case .begin: model.beginGesture()
                case .live(let v), .change(let v): set(v)
                case .end: model.endGesture()
                case .cancel(let v): set(v); model.endGesture()      // PropertyRow has no onCancel: apply the start, then end
                }
            case .speed:
                switch e {
                case .begin: model.beginSpeedGesture()
                case .live(let v), .change(let v): model.setSpeedPercent(v)
                case .end: model.endSpeedGesture()
                case .cancel(let v): model.setSpeedPercent(v); model.endSpeedGesture()
                }
            case .blend: break
            case .custom(let key):
                guard let spec = customSpecs[key] else { break }
                switch e {
                case .begin: spec.begin()
                case .live(let v), .change(let v): spec.change(v)
                case .end: spec.end()
                case .cancel(let v): spec.change(v); spec.end()
                }
            }
        }
    }

    // MARK: Geometry shared by drawing and hit testing

    private func eyeFrame(_ h: CGFloat) -> CGRect {
        CGRect(x: grid.resetX - ControlsGrid.gap - ControlsGrid.resetWidth, y: 0, width: ControlsGrid.resetWidth, height: h)
    }
    /// ControlsKeyNavigation: four equal slots (previous, key, next, open) in the navigation column.
    func navigationSlot(_ i: Int, _ h: CGFloat) -> CGRect {
        let n = grid.navigationFrame(height: h), w = n.width / 4
        return CGRect(x: n.minX + CGFloat(i) * w, y: 0, width: w, height: h)
    }
    /// EffectParamRowBase: the control from the value column, `width` at most, before the key navigation.
    /// The control of a parameter row; a motion effect's Curve popup leaves room for its Edit Curve button.
    private func paramFrame(_ p: EffectProperty, _ kind: EffectParamKind, _ h: CGFloat) -> CGRect {
        guard motionCurveEffect(p) != nil else { return paramControlFrame(kind, h) }
        return grid.fillFrame(height: h, maxX: grid.valueMaxX - ControlsGrid.resetWidth - ControlsGrid.gap,
                              maxWidth: ControlsMetrics.Portable.popupWidth)
    }
    private func curveButtonFrame(_ p: EffectProperty, _ h: CGFloat) -> CGRect {
        guard let k = p.paramKind else { return .zero }
        return grid.controlFrame(x: paramFrame(p, k, h).maxX + ControlsGrid.gap, width: ControlsGrid.resetWidth, height: h)
    }
    /// The motion effect whose Curve parameter `p` is (EffectParamRows: the row gets the curve editor button).
    func motionCurveEffect(_ p: EffectProperty) -> ClipEffect.ID? {
        if case .fx(let id, let kind, let key) = p, key == ClipEffect.motionCurveKey, ClipEffect.motionKinds.contains(kind) { return id }
        return nil
    }
    private func paramControlFrame(_ kind: EffectParamKind, _ h: CGFloat) -> CGRect {
        let width: CGFloat
        switch kind {
        case .color: width = 44
        case .checkbox: width = 22
        default: width = ControlsMetrics.Portable.popupWidth
        }
        return grid.fillFrame(height: h, maxX: grid.valueMaxX, maxWidth: width)
    }
    private func hasLink(_ p: EffectProperty) -> Bool { p.pair?.linkable == true || p == .scale }
    /// Color Key's Key Hue: an eyedropper next to the field (EffectControlsView `pick`), where a screen sampler exists.
    private func hasKeyPick(_ p: EffectProperty) -> Bool { EffectControlsModel.isKeyHue(p) && keySampler != nil }
    /// The screen color sampler of the key eyedropper; nil = the shared `ScreenColorSampler` seam.
    public var sampleScreenColor: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)?
    private var keySampler: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? { sampleScreenColor ?? ScreenColorSampler.begin }

    /// shortcut: samples the screen (the monitor as displayed, sRGB) instead of the Mac's rendered-frame readback, so
    /// display scaling blends edge pixels; upgrade with a Program frame readback on Windows.
    private func pickKeyColor(_ p: EffectProperty) {
        keySampler? { [weak self] picked in
            guard let self, let picked else { return }
            let c = picked.rgb
            self.model.applyKeyColor(p, linear: EffectControlsModel.linear(fromSRGB: c.r, c.g, c.b))
        }
    }
    private func linkFrame(_ p: EffectProperty, _ h: CGFloat) -> CGRect {
        grid.controlFrame(x: ControlsGrid.valueColumn(model.valueComponents(p).count), width: ControlsGrid.controlHeight, height: h)
    }
    private func blendFrame(_ h: CGFloat) -> CGRect {
        grid.fillFrame(height: h, maxX: grid.valueMaxX, maxWidth: ControlsMetrics.Portable.popupWidth)
    }
    private func checkboxFrame(_ h: CGFloat) -> CGRect {
        grid.controlFrame(x: ControlsGrid.valueX, width: InspectorTokens.checkbox, height: h, controlHeight: InspectorTokens.checkbox)
    }

    /// The control under `p` (panel points).
    public func target(at p: CGPoint) -> Target {
        guard let r = row(at: p) else { return .none }
        let l = CGPoint(x: p.x, y: p.y - rowTop(r)), h = r.height, g = grid
        switch r.kind {
        case .section(let s):
            if g.headerToggleFrame(height: h).contains(l) { return .chevron(s) }
            if model.hasFXToggle(s), eyeFrame(h).contains(l) { return .eye(s) }
            if g.resetFrame(height: h).contains(l) { return .sectionReset(s) }
            return .header(s)
        case .property(let prop):
            let ref = RowRef.property(prop)
            if let t = keyControlsTarget(ref, l, h, state: model.keyframeControlState(prop), showsOpen: prop.hasGraph) { return t }
            if let k = prop.paramKind, !Self.isNumber(k) {
                if motionCurveEffect(prop) != nil, curveButtonFrame(prop, h).contains(l) { return .curve(prop) }
                if paramFrame(prop, k, h).contains(l) {
                    switch k {
                    case .color: return .well(prop)
                    case .checkbox: return .checkbox(ref)
                    default: return .popup(ref)
                    }
                }
            } else {
                for (i, id) in fieldIDs(r.kind).enumerated() where g.valueFrame(i, height: h).contains(l) { return .field(id) }
                if hasLink(prop), linkFrame(prop, h).contains(l) { return .link(prop) }
                if hasKeyPick(prop), linkFrame(prop, h).contains(l) { return .keyPick(prop) }
            }
            if g.labelFrame(height: h).contains(l) { return .label(ref) }
            return .row(ref)
        case .speedControl(let k):
            let ref = RowRef.speed(k)
            if k == .speed {
                if model.speedKeysAvailable,
                   let t = keyControlsTarget(ref, l, h, state: model.speedKeyControlState(), showsOpen: model.speedHasTransition) { return t }
                if g.valueFrame(0, height: h).contains(l) { return .field(FieldID(ref: ref, component: .all)) }
            } else if k != .timeInterpolation, checkboxFrame(h).insetBy(dx: -4, dy: -4).contains(l) {
                return .checkbox(ref)
            }
            return .row(ref)
        case .blendMode:
            return blendFrame(h).contains(l) ? .popup(.blend) : .row(.blend)
        default:
            guard let ws = widgets(r) else { return .none }
            for w in ws.reversed() {
                if let box = w.toggleFrame, box.insetBy(dx: -4, dy: -4).contains(l) { return .widgetToggle(w.key) }
                switch w.kind {
                case .navigation, .progress: continue
                case .text where w.help == nil: continue
                case .field: if w.frame.contains(l) { return .field(FieldID(ref: .custom(w.key), component: .all)) }
                default: if w.frame.contains(l) { return .widget(w.key) }
                }
            }
            return .none
        }
    }

    private func keyControlsTarget(_ ref: RowRef, _ l: CGPoint, _ h: CGFloat, state: KeyframeControlState, showsOpen: Bool) -> Target? {
        if grid.toggleFrame(height: h).contains(l) { return .ring(ref) }
        if grid.resetFrame(height: h).contains(l) { return .reset(ref) }
        guard state.showsNavigation else { return nil }
        let slots: [Target] = [.previous(ref), .key(ref), .next(ref), .open(ref)]
        for i in 0..<(showsOpen ? 4 : 3) where navigationSlot(i, h).contains(l) { return slots[i] }
        return nil
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, bounds = CGRect(origin: .zero, size: size)
        if let atlas = c.atlas {
            let fs = Float(DrawTheme.TypeSize.body)
            measure = { CGFloat(atlas.width(of: $0, pixelSize: fs)) }
        }
        let hover = hoverPoint.map { target(at: $0) } ?? Target.none
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.panel)
        for r in rows where rowTop(r) + r.height > 0 && rowTop(r) < size.height {
            c.saveGState()
            c.translateBy(x: 0, y: rowTop(r))
            drawRow(r, &c, hover: hover)
            c.restoreGState()
        }
        if let sec = clipSections, sectionFrame.height > 0 {
            c.saveGState()
            c.translateBy(x: 0, y: sectionFrame.minY - scrollY)
            sec.draw(&c)
            c.restoreGState()
        }
        if let b = textSlots {
            for part in [TextBlockDraw.Part.arrange, .animation] {
                guard let f = slotFrame(part) else { continue }
                c.saveGState()
                c.translateBy(x: 0, y: f.minY - scrollY)
                b.draw(&c, part: part)
                c.restoreGState()
            }
        }
        if let line = dropLineY() { c.fill(CGRect(x: 0, y: line - 1, width: size.width, height: 2), t.accent) }
        if showsEmptyState { drawEmptyState(&c) }
        c.restoreGState()
    }

    /// EffectControlsView.updateChrome: nothing selected and no caption track shows the empty state.
    public var showsEmptyState: Bool { model.clip == nil && clipSections?.mode != .captions }
    static let emptyTitle = "No clip selected", emptyHint = "Select a clip in the timeline to see its Controls."

    private func drawEmptyState(_ c: inout Canvas) {
        c.drawEmptyState(title: SQL10n.string(Self.emptyTitle), hint: SQL10n.string(Self.emptyHint),
                         in: CGRect(origin: .zero, size: size), theme: theme)
    }

    /// RowBackground: fill, the 1 pt row line at the bottom, a hairline at the top of a group.
    /// The fill of the row being drawn (the key diamond's center dot cuts through to it).
    private var rowFill: DrawColor?

    private func background(_ c: inout Canvas, _ h: CGFloat, fill: DrawColor, bottomLine: Bool = true, topSeparator: Bool = false) {
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: h), fill)
        rowFill = fill
        if bottomLine { c.fill(CGRect(x: 0, y: h - 1, width: size.width, height: 1), theme.trackRowLine) }
        if topSeparator { c.fill(CGRect(x: 0, y: 0, width: size.width, height: 1), theme.separator) }
    }

    func icon(_ c: inout Canvas, _ i: SQIcon, in r: CGRect, size s: CGFloat = 10, _ color: DrawColor) {
        c.draw(icon: i, at: CGPoint(x: (r.midX - s / 2).rounded(), y: (r.midY - s / 2).rounded()), size: s, color)
    }

    /// IconButton's tint: label2 (or the given one), label while hovered, dimmed while disabled.
    func buttonTint(_ base: DrawColor? = nil, hovered: Bool, enabled: Bool = true, alpha: Float = 1) -> DrawColor {
        var col = base ?? theme.label2
        if hovered && enabled && base == nil || hovered && enabled && base == theme.label3 { col = theme.label }
        let a = col.a * alpha * (enabled ? 1 : InspectorTokens.disabledAlpha)
        return col.alpha(a)
    }

    /// The name in the label column (ControlsGrid.place: wider into free room, else cut in the middle).
    private func label(_ c: inout Canvas, _ s: String, _ h: CGFloat, maxX: CGFloat? = nil, color: DrawColor? = nil) {
        let text = SQL10n.string(s), fs = CGFloat(DrawTheme.TypeSize.body)
        var f = grid.labelFrame(height: h)
        let natural = ceil(c.size(of: text, fontSize: fs).width)
        if let maxX, natural > f.width { f.size.width = min(natural, max(maxX - ControlsGrid.labelX, f.width)) }
        c.draw(Self.middleCut(text, width: f.width) { c.size(of: $0, fontSize: fs).width }, in: f, fontSize: fs,
               color ?? theme.label2)
    }

    /// `.byTruncatingMiddle`.
    static func middleCut(_ s: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(s) > width + 0.5, s.count > 2 else { return s }
        let chars = Array(s)
        var keep = chars.count - 1
        while keep > 1 {
            let head = keep / 2 + keep % 2, tail = keep / 2
            let cand = String(chars[..<head]) + "…" + String(chars[(chars.count - tail)...])
            if measure(cand) <= width { return cand }
            keep -= 1
        }
        return String(chars.first!) + "…"
    }

    private func drawRow(_ r: EffectRow, _ c: inout Canvas, hover: Target) {
        let t = theme, h = r.height
        switch r.kind {
        case .section(let s): drawSectionHeader(s, &c, h, hover: hover)
        case .group(let g):
            background(&c, h, fill: t.panel, topSeparator: r.y > 0)
            let lead = ControlsGrid.headerToggleX
            c.draw(SQL10n.string(g.title).uppercased(), in: CGRect(x: lead, y: (h - 13) / 2, width: max(size.width - 2 * lead, 0), height: 13),
                   fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3)
        case .placeholder:
            background(&c, h, fill: t.panel)
            c.draw(SQL10n.string("Not available yet"), in: grid.labelFrame(height: h, maxX: grid.tailMaxX + ControlsGrid.gap),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3)
        case .property(let p): drawProperty(p, &c, h, hover: hover)
        case .graph:
            // EasePaneView: empty on purpose, keeps the curve aligned with the lanes; continues the row above (no top line).
            background(&c, h, fill: t.panel, bottomLine: false)
            c.fill(CGRect(x: 0, y: 0, width: size.width, height: h), t.graphPane)
            c.fill(CGRect(x: 0, y: h - 1, width: size.width, height: 1), t.separator)
        case .speedControl(let k): drawSpeed(k, &c, h, hover: hover)
        case .blendMode:
            background(&c, h, fill: t.panel)
            let title = model.isBlendModeMixed ? "" : SQL10n.string(model.blendMode.title)
            InspectorDraw.popup(&c, title: title, in: blendFrame(h), hovering: hover == .popup(.blend), open: false,
                                enabled: model.isBlendGroupEnabled, t)
            label(&c, "Blend Mode", h)
        default:
            if let ws = widgets(r) { drawWidgets(r, ws, &c, hover: hover); return }
            // shortcut: a row whose Mac view is not translated yet keeps its height and shows its kind; upgrade row by row
            // (WINDOWS-PLAN "missing").
            background(&c, h, fill: t.panel)
            c.draw(Self.pendingTitle(r.kind), in: grid.labelFrame(height: h, maxX: grid.tailMaxX), fontSize: CGFloat(DrawTheme.TypeSize.caption),
                   t.label3)
        }
    }

    static func pendingTitle(_ k: EffectRow.Kind) -> String {
        let s = String(describing: k)
        return String(s.prefix { $0 != "(" })
    }

    /// SectionHeaderRow.
    private func drawSectionHeader(_ s: EffectSection, _ c: inout Canvas, _ h: CGFloat, hover: Target) {
        let t = theme, g = grid
        let rowHovered = hoverPoint.map { if case .header = target(at: $0) { true } else { [.chevron(s), .eye(s), .sectionReset(s)].contains(target(at: $0)) } } ?? false
        background(&c, h, fill: model.isSectionSelected(s) ? t.selection : t.panel)
        let collapsed = model.collapsedSections.contains(s)
        icon(&c, collapsed ? .chevronRight : .chevronDown, in: g.headerToggleFrame(height: h), size: 9, t.label3)
        let on = model.isEffectEnabled(s), mixed = model.isEffectEnabledMixed(s)
        // Eye and reset are always shown in their fixed slots (feedback 2026-10-11); dim at rest, full while the pointer is over the row.
        let a: Float = rowHovered ? 1 : 0.55
        if model.hasFXToggle(s) {
            icon(&c, mixed ? .minus : on ? .eye : .eyeOff, in: eyeFrame(h),
                 buttonTint(t.label3, hovered: hover == .eye(s), alpha: a))
        }
        let resettable = s.properties.contains { !model.isDefault($0) } || !on
        icon(&c, .reset, in: g.resetFrame(height: h), buttonTint(hovered: hover == .sectionReset(s), enabled: resettable, alpha: a))
        // Title (bodyStrong), your-default marker, summary right aligned up to the eye slot.
        let fs = CGFloat(DrawTheme.TypeSize.body), titleX = ControlsGrid.headerLabelX, bold = c.semibold
        let rightX = eyeFrame(h).minX - ControlsGrid.gap
        let user = model.hasUserDefault(s)
        let markerW: CGFloat = user ? 14 : 0
        let lh = ControlsGrid.labelHeight, ly = ((h - lh) / 2).rounded()
        var name = SQL10n.string(s.title)
        if case .mask(let id) = s, let m = model.clip?.mask(id) { name = m.name }
        let titleW = min(ceil(c.size(of: name, fontSize: fs, face: bold).width) + 4, max(rightX - titleX - markerW, 0))
        c.draw(Self.middleCut(name, width: titleW) { c.size(of: $0, fontSize: fs, face: bold).width },
               in: CGRect(x: titleX, y: ly, width: titleW, height: lh), fontSize: fs, on ? t.label : t.label3, face: bold)
        if user {
            let marker = CGRect(x: titleX + titleW + 2, y: 0, width: 10, height: h)
            defaultMarkers[s] = marker
            icon(&c, .bookmarkFilled, in: marker, size: 9, t.label3)
        } else { defaultMarkers[s] = nil }
        let sumX = titleX + titleW + markerW + ControlsGrid.gap
        if let summary = model.sectionSummary(s), rightX > sumX {
            c.draw(summary, in: CGRect(x: sumX, y: ly, width: rightX - sumX, height: lh), fontSize: CGFloat(DrawTheme.TypeSize.caption),
                   t.label3, align: .right)
        }
    }

    /// The ring, key navigation, Open and reset of a keyframable row (ParameterKeyControls).
    private func drawKeyControls(_ ref: RowRef, _ c: inout Canvas, _ h: CGFloat, state: KeyframeControlState, showsOpen: Bool,
                                 isOpen: Bool, resettable: Bool, hover: Target) {
        let t = theme
        let ring = grid.toggleFrame(height: h)
        // The Mac Controls row: a plain diamond switch (AnimateDiamondView), not the dotted ring of the Graphics rows.
        InspectorDraw.animateSwitch(&c, animated: state.showsNavigation, hovering: hover == .ring(ref),
                                    center: CGPoint(x: ring.midX, y: ring.midY), t)
        if state.showsNavigation {
            let n = navigationSlot(0, h).union(navigationSlot(2, h))
            InspectorDraw.navigation(&c, state, in: n, enabled: true, behind: rowFill, t)
            if showsOpen {
                // v9 `.kcv`: chevron right, turned down and `label` while the curve is open.
                icon(&c, isOpen ? .chevronDown : .chevronRight, in: navigationSlot(3, h), size: 9,
                     buttonTint(isOpen ? t.label : t.label3, hovered: hover == .open(ref)))
            }
        }
        icon(&c, .reset, in: grid.resetFrame(height: h), buttonTint(hovered: hover == .reset(ref), enabled: resettable))
    }

    /// PropertyRow, and EffectParamRows for color, checkbox and choice parameters.
    private func drawProperty(_ p: EffectProperty, _ c: inout Canvas, _ h: CGFloat, hover: Target) {
        let t = theme, ref = RowRef.property(p)
        let opened = model.expanded.contains(p) && p.hasGraph && !model.graphEditor
        // `.kp.sel`: a selected row. Open curve: the name row and the pane under it are one lighter element.
        let fill = model.graphProperties.contains(p) ? t.selection : (opened ? t.graphPane : t.panel)
        background(&c, h, fill: fill, bottomLine: !opened)
        drawKeyControls(ref, &c, h, state: model.keyframeControlState(p), showsOpen: p.hasGraph, isOpen: model.expanded.contains(p),
                        resettable: !model.isDefault(p), hover: hover)
        if let k = p.paramKind, !Self.isNumber(k) {
            let f = paramFrame(p, k, h)
            if motionCurveEffect(p) != nil {
                icon(&c, .curve, in: curveButtonFrame(p, h), buttonTint(hovered: hover == .curve(p)))
            }
            let mixed = model.isMixed(p)
            switch k {
            case .color:
                let v = model.colorValue(p).clamped
                let col = mixed ? t.field : DrawColor(Float(v.red), Float(v.green), Float(v.blue), 1)
                InspectorDraw.colorWell(&c, col, in: f, hovering: hover == .well(p), t)
            case .checkbox:
                let on = k.isOn(model.scalarValue(p))
                let box = CGRect(x: f.minX, y: (f.midY - InspectorTokens.checkbox / 2).rounded(), width: InspectorTokens.checkbox,
                                 height: InspectorTokens.checkbox)
                InspectorDraw.checkbox(&c, mixed ? .mixed : on ? .on : .off, box: box, hovering: hover == .checkbox(ref),
                                       pressed: pressTarget == .checkbox(ref), enabled: true, t)
            case .choice(let items):
                let i = k.choiceIndex(for: model.scalarValue(p))
                let title = mixed || !items.indices.contains(i) ? "" : SQL10n.string(items[i])
                InspectorDraw.popup(&c, title: title, in: f, hovering: hover == .popup(ref), open: false, enabled: true, t)
            default: break
            }
            label(&c, p.title, h)
            return
        }
        for (i, id) in fieldIDs(.property(p)).enumerated() {
            fields[id]?.draw(&c, in: grid.valueFrame(i, height: h), theme: t, focused: focusedField == id)
        }
        if hasLink(p) {
            let on = p == .scale ? model.uniformScale : model.isLinked(p)
            icon(&c, on ? .link : .unlink, in: linkFrame(p, h), size: 11, buttonTint(on ? t.accent : t.label3, hovered: hover == .link(p)))
        }
        if hasKeyPick(p) { icon(&c, .eyedropper, in: linkFrame(p, h), size: 11, buttonTint(t.label2, hovered: hover == .keyPick(p))) }
        label(&c, p.title, h)
    }

    /// SpeedControlRow.
    private func drawSpeed(_ k: SpeedControl, _ c: inout Canvas, _ h: CGFloat, hover: Target) {
        let t = theme, ref = RowRef.speed(k)
        background(&c, h, fill: t.panel)
        switch k {
        case .speed:
            let id = FieldID(ref: ref, component: .all)
            fields[id]?.draw(&c, in: grid.valueFrame(0, height: h), theme: t, focused: focusedField == id)
            if model.speedKeysAvailable {
                drawKeyControls(ref, &c, h, state: model.speedKeyControlState(), showsOpen: model.speedHasTransition, isOpen: false,
                                resettable: model.speedPercent != 100 || model.speedIsAnimated, hover: hover)
            } else {
                icon(&c, .reset, in: grid.resetFrame(height: h),
                     buttonTint(hovered: hover == .reset(ref), enabled: model.speedPercent != 100 || model.speedIsAnimated))
            }
            label(&c, "Speed", h)
        case .reverse, .keepPitch:
            let on = k == .reverse ? model.isReversed : model.keepsPitch
            InspectorDraw.checkbox(&c, on ? .on : .off, box: checkboxFrame(h), hovering: hover == .checkbox(ref),
                                   pressed: pressTarget == .checkbox(ref), enabled: true, t)
            label(&c, k == .reverse ? "Reverse" : "Keep Pitch", h)
        case .timeInterpolation:
            label(&c, "Keep Pitch", h)
        }
    }

    // MARK: Reorder (EffectControlsView.effectBlocks / reorderMoved / reorderEnded)

    private func effectBlocks() -> [(section: EffectSection, frame: CGRect)] {
        var out: [(EffectSection, CGRect)] = []
        for (i, row) in rows.enumerated() {
            guard case .section(let s) = row.kind, s.effectKind != nil else { continue }
            let next = rows[(i + 1)...].first { if case .section = $0.kind { true } else { false } }
            let end = next?.y ?? contentHeight
            out.append((s, CGRect(x: 0, y: row.y, width: size.width, height: end - row.y)))
        }
        return out
    }

    private func dropLineY() -> CGFloat? {
        guard let r = reordering, let target = r.target else { return nil }
        let blocks = effectBlocks()
        guard let from = blocks.firstIndex(where: { $0.section == r.section }), target != from, blocks.indices.contains(target) else { return nil }
        return (target < from ? blocks[target].frame.minY : blocks[target].frame.maxY) - scrollY
    }

    // MARK: Input (points)

    public func mouseMoved(to p: CGPoint?) {
        hoverPoint = p
        clipSections?.mouseMoved(to: p.flatMap { overSection($0) ? inSection($0) : nil })
        if let b = textSlots, let (part, q) = p.flatMap(slot(at:)) { b.mouseMoved(to: q, part: part) }
        let over = p.map { target(at: $0) } ?? Target.none
        for id in fields.keys { fields[id]?.hovering = over == .field(id) }
        if let p, case .widget(let key) = over, let (r, w) = widget(key), case .surface(let make) = w.kind {
            surface(key, make).mouseMoved(to: CGPoint(x: p.x, y: p.y - rowTop(r)), in: w.frame)
        }
    }

    /// The row and widget of a translated row's control.
    func widget(_ key: String) -> (EffectRow, Widget)? {
        for r in rows {
            if let w = widgets(r)?.first(where: { $0.key == key }) { return (r, w) }
        }
        return nil
    }

    /// The tooltip at `p` (`sqToolTip` of the Mac control under the pointer), nil for none.
    private func overDefaultMarker(_ p: CGPoint, _ s: EffectSection) -> Bool {
        guard let r = row(at: p), let m = defaultMarkers[s] else { return false }
        return m.insetBy(dx: -2, dy: 0).contains(CGPoint(x: p.x, y: p.y - rowTop(r)))
    }

    public func help(at p: CGPoint) -> String? {
        if overSection(p) { return clipSections?.help(at: inSection(p)) }
        if let b = textSlots, let (part, q) = slot(at: p) { return b.help(at: q, part: part) }
        let tg = target(at: p)
        switch tg {
        case .widget, .field:
            let key: String
            if case .widget(let k) = tg { key = k } else if case .field(let id) = tg, case .custom(let k) = id.ref { key = k } else { return nil }
            guard let (r, w) = widget(key) else { return nil }
            if case .surface(let make) = w.kind, let tip = surface(key, make).help(at: CGPoint(x: p.x, y: p.y - rowTop(r)), in: w.frame) {
                return tip
            }
            return w.help.map { SQL10n.string($0) }
        case .widgetToggle(let key):
            guard let (_, w) = widget(key), case .disclosure(let title, _, _) = w.kind else { return nil }
            return SQL10n.format("Enable %@", title)
        case .chevron(let s): return SQL10n.format(model.collapsedSections.contains(s) ? "Expand %@" : "Collapse %@", SQL10n.string(s.title))
        case .eye(let s): return SQL10n.string(model.isEffectEnabled(s) ? "Disable Effect" : "Enable Effect")
        case .sectionReset(let s): return SQL10n.format(model.hasUserDefault(s) ? "Reset %@ to Your Default" : "Reset %@", SQL10n.string(s.title))
        case .header(let s) where model.hasUserDefault(s) && overDefaultMarker(p, s): return SQL10n.string("Your Default")
        case .ring: return SQL10n.string("Toggle Animation")
        case .previous: return SQL10n.string("Go to Previous Keyframe")
        case .key: return SQL10n.string("Add or Remove Keyframe")
        case .next: return SQL10n.string("Go to Next Keyframe")
        case .open: return SQL10n.string("Show Curve")
        case .curve: return SQL10n.string("Edit Curve")
        case .reset: return SQL10n.string("Reset")
        case .link(let prop):
            if prop == .scale { return SQL10n.string("Uniform Scale") }
            return SQL10n.string(model.isLinked(prop) ? "Unlink Width and Height" : "Link Width and Height")
        case .keyPick: return SQL10n.string("Pick Key Color from Monitor")
        case .popup(.blend): return SQL10n.string("Blend Mode")
        case .label(.property(let prop)): return SQL10n.string(prop.title)
        default: return nil
        }
    }

    public func mouseDown(at p: CGPoint, clickCount: Int, modifiers: InputModifiers) {
        sectionPressed = false
        if overSection(p), !modifiers.contains(.secondary), let sec = clipSections {
            pressTarget = .none
            sectionPressed = true
            sec.mouseDown(at: inSection(p), clickCount: clickCount)
            return
        }
        slotPressed = nil
        if let b = textSlots {
            if !modifiers.contains(.secondary), let (part, q) = slot(at: p) {
                pressTarget = .none
                slotPressed = part
                b.mouseDown(at: q, part: part, clickCount: clickCount)
                return
            }
            b.resignFocus()
        }
        if modifiers.contains(.secondary) {      // right click: the row's context menu, no press
            pressTarget = .none
            if overSection(p), clipSections?.contextMenu(at: inSection(p)) == true { return }
            contextMenu(at: p)
            return
        }
        let tg = target(at: p)
        pressTarget = tg; pressPoint = p; pressModifiers = modifiers
        if let f = focusedField, tg != .field(f) {
            var field = fields[f]
            if let events = field?.resignFocus() { fields[f] = field; apply(events, f) }
            focusedField = nil
        }
        if let key = focusedText, tg != .widget(key) { commitText(key) }
        switch tg {
        case .widget(let key):
            guard let (r, w) = widget(key) else { break }
            let l = CGPoint(x: p.x, y: p.y - rowTop(r))
            switch w.kind {
            case .textField:
                focusedText = key
                textFields[key]?.mouseDown()
            case .surface(let make):
                surface(key, make).mouseDown(at: l, in: w.frame, clickCount: clickCount, modifiers: modifiers)
            case .disclosure where clickCount == 2:
                pressTarget = .none      // the first click already toggled
            default: break
            }
        case .header(let s):
            model.selectEffectHeader(s)
            if clickCount == 2 { toggleCollapsed(s); pressTarget = .none }
        case .field(let id):
            focusedField = id
            if case .property(let prop) = id.ref { model.focusedProperty = prop }
            if clickCount >= 2, case .property(let prop) = id.ref {
                // R25: double-click = the reset arrow (whole row, keys removed).
                var f = fields[id]; _ = f?.cancelGesture(); fields[id] = f
                _ = model.reset(prop)
                syncFields()
                pressTarget = .none
                return
            }
            var f = fields[id]
            if let events = f?.mouseDown(x: Float(p.x), clickCount: clickCount) { fields[id] = f; apply(events, id) }
        case .label(let ref):
            if case .property(let prop) = ref {
                model.focusedProperty = prop
                model.selectPropertyRow(prop, extend: modifiers.contains(.shift) || modifiers.contains(.command))
            }
        case .row(let ref):
            if case .property(let prop) = ref { model.focusedProperty = prop }
            model.clearRowSelection()      // a click elsewhere on the row clears; only the label selects
        default:
            if case .property(let prop) = tg.rowRef { model.focusedProperty = prop }
        }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers? = nil) {
        if sectionPressed { clipSections?.mouseDragged(to: inSection(p), modifiers: modifiers ?? []); return }
        if let part = slotPressed { textSlots?.mouseDragged(to: inSlot(p, part), part: part, modifiers: modifiers ?? []); return }
        switch pressTarget {
        case .widget(let key):
            if let (r, w) = widget(key), case .surface(let make) = w.kind {
                surface(key, make).mouseDragged(to: CGPoint(x: p.x, y: p.y - rowTop(r)), in: w.frame, modifiers: modifiers ?? pressModifiers)
            }
        case .field(let id):
            var f = fields[id]
            if let events = f?.mouseDragged(x: Float(p.x), modifiers: modifiers ?? pressModifiers) { fields[id] = f; apply(events, id) }
        case .header(let s):
            // Dragging an effect header up or down reorders the effects (the list order is the order they are applied in).
            guard s.effectKind != nil else { return }
            if reordering == nil, abs(p.y - pressPoint.y) > 4 { reordering = (s, nil) }
            guard reordering != nil else { return }
            let blocks = effectBlocks()
            guard let from = blocks.firstIndex(where: { $0.section == s }) else { return }
            reordering?.target = EffectControlsModel.dropIndex(forY: p.y + scrollY, midpoints: blocks.map { $0.frame.minY + 9 }, dragging: from)
        default: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        if sectionPressed { sectionPressed = false; clipSections?.mouseUp(at: inSection(p)); return }
        if let part = slotPressed { slotPressed = nil; textSlots?.mouseUp(at: inSlot(p, part), part: part); return }
        let pressed = pressTarget
        pressTarget = .none
        if case .field(let id) = pressed {
            var f = fields[id]
            if let events = f?.mouseUp() { fields[id] = f; apply(events, id) }
            return
        }
        if case .widget(let key) = pressed, let (r, w) = widget(key), case .surface(let make) = w.kind {
            surface(key, make).mouseUp(at: CGPoint(x: p.x, y: p.y - rowTop(r)), in: w.frame)
            syncFields()
            return
        }
        if case .header(let s) = pressed, let r = reordering {
            reordering = nil
            let blocks = effectBlocks()
            guard let t = r.target, t < blocks.count, let from = blocks.firstIndex(where: { $0.section == s }), t != from,
                  let index = model.effectIndex(blocks[t].section) else { return }
            _ = model.moveEffect(s, toIndex: index)
            return
        }
        guard pressed != .none, target(at: p) == pressed else { return }      // buttons fire on release inside
        click(pressed, at: p)
    }

    private func toggleCollapsed(_ s: EffectSection) {
        if model.collapsedSections.contains(s) { model.collapsedSections.remove(s) } else { model.collapsedSections.insert(s) }
        relayout()
    }

    private func anchor(of tg: Target, near p: CGPoint) -> CGRect {
        guard let r = row(at: p) else { return CGRect(origin: p, size: .zero) }
        let h = r.height, top = rowTop(r)
        var f: CGRect
        switch tg {
        case .popup(.blend): f = blendFrame(h)
        case .popup(.property(let prop)), .checkbox(.property(let prop)): f = prop.paramKind.map { paramFrame(prop, $0, h) } ?? .zero
        case .well(let prop): f = prop.paramKind.map { paramFrame(prop, $0, h) } ?? .zero
        case .open: f = navigationSlot(3, h)
        case .curve(let prop): f = curveButtonFrame(prop, h)
        case .widget(let key): f = widget(key)?.1.frame ?? .zero
        default: f = CGRect(x: p.x, y: p.y - top, width: 0, height: 0)
        }
        f.origin.y += top
        return f
    }

    /// A released button: the Mac handlers of each control.
    private func click(_ tg: Target, at p: CGPoint) {
        switch tg {
        case .chevron(let s): toggleCollapsed(s)
        case .eye(let s): model.toggleEffectEnabled(s)
        case .sectionReset(let s): model.resetSection(s)
        case .ring(.property(let prop)):
            stopwatch(prop)
        case .ring(.speed):
            if model.toggleSpeedAnimation() == .needsConfirmation {
                confirmRemoveKeyframes("Speed") { [weak self] in _ = self?.model.toggleSpeedAnimation(confirmRemoval: true) }
            }
        case .previous(.property(let prop)): model.goToPreviousKey(prop)
        case .next(.property(let prop)): model.goToNextKey(prop)
        case .key(.property(let prop)): _ = model.toggleKeyAtPlayhead(prop)
        case .open(.property(let prop)): model.toggleOpen(prop); relayout()
        case .open(.speed):
            // The ease editor of the speed transition at the playhead (the popover every keyframe curve uses).
            if let source = model.speedCurveSource() { onEaseCurve?(source, anchor(of: tg, near: p)) }
        case .curve(let prop):
            if let id = motionCurveEffect(prop) { onEaseCurve?(MotionCurveEaseSource(model: model, effect: id), anchor(of: tg, near: p)) }
        case .reset(.property(let prop)): model.resetAll(prop)
        case .previous(.speed): model.goToPreviousSpeedKey()
        case .next(.speed): model.goToNextSpeedKey()
        case .key(.speed): _ = model.toggleSpeedKeyAtPlayhead()
        case .reset(.speed):
            if model.speedIsAnimated { _ = model.toggleSpeedAnimation(confirmRemoval: true) }
            model.setSpeedPercent(100)
        case .link(let prop):
            if prop == .scale { model.setUniformScale(!model.uniformScale) } else { model.setLinked(prop, !model.isLinked(prop)) }
            relayout()
        case .keyPick(let prop): pickKeyColor(prop)
        case .checkbox(.speed(let k)):
            if k == .reverse { model.setReversedClip(!model.isReversed) } else { model.setKeepsPitchClip(!model.keepsPitch) }
        case .checkbox(.property(let prop)):
            let on = prop.paramKind?.isOn(model.scalarValue(prop)) ?? false
            _ = model.setValue(prop, to: model.isMixed(prop) || !on ? 1 : 0)     // from mixed: on
        case .popup(.blend):
            guard model.isBlendGroupEnabled else { return }
            onMenu?(blendMenu(), anchor(of: tg, near: p))
        case .popup(.property(let prop)):
            onMenu?(choiceMenu(prop), anchor(of: tg, near: p))
        case .well(let prop):
            model.focusedProperty = prop
            onPickColor?(model.colorValue(prop).clamped, anchor(of: tg, near: p)) { [weak self] color in
                guard let self else { return }
                if let color { self.model.setColorContinuously(prop, to: color) } else { self.model.endColorGesture() }
            }
        case .widget(let key):
            guard let (_, w) = widget(key), w.enabled else { return }
            if let menu = w.menu { onMenu?(menu(), anchor(of: tg, near: p)); return }
            if case .textField = w.kind { return }
            w.action?()
            relayout()
            return
        case .widgetToggle(let key):
            widget(key)?.1.toggle?()
            relayout()
            return
        default: break
        }
        syncFields()
    }

    /// EffectControlsView.stopwatchTapped: turning animation off asks before the keys go.
    func stopwatch(_ p: EffectProperty) {
        if model.toggleStopwatch(p) == .needsConfirmation {
            confirmRemoveKeyframes(p.title) { [weak self] in _ = self?.model.toggleStopwatch(p, confirmRemoval: true) }
        }
    }

    // MARK: Menus

    /// BlendModeRow: the sections of `BlendMode.menuSections` with a separator between them.
    func blendMenu() -> [SQMenuItem] {
        var m: [SQMenuItem] = []
        let current: BlendMode? = model.isBlendModeMixed ? nil : model.blendMode
        for (n, section) in BlendMode.menuSections.enumerated() {
            if n > 0 { m.append(.separator) }
            for mode in section {
                m.append(SQMenuItem(title: mode.title, isChecked: mode == current) { [model] in model.setBlendMode(mode) })
            }
        }
        return m
    }

    /// EffectChoiceRow: the catalog's items; an item can be off for this clip, with the reason as help.
    func choiceMenu(_ p: EffectProperty) -> [SQMenuItem] {
        guard case .choice(let items)? = p.paramKind else { return [] }
        let off = model.disabledChoices(p)
        let current = model.isMixed(p) ? nil : p.paramKind?.choiceIndex(for: model.scalarValue(p))
        return items.enumerated().map { i, title in
            SQMenuItem(title: title, isEnabled: off[i] == nil, isChecked: i == current, help: off[i]) { [model] in
                _ = model.setValue(p, to: Double(i))
            }
        }
    }

    /// Right-click at `p`: the row's menu (SectionHeaderRow / PropertyRow / EffectParamRowBase.contextItems).
    public func contextMenu(at p: CGPoint) {
        guard let r = row(at: p) else { return }
        let items: [SQMenuItem]
        switch r.kind {
        case .section(let s): items = sectionMenu(s)
        case .property(let prop): items = propertyMenu(prop, numeric: prop.paramKind.map(Self.isNumber) ?? true)
        default: return
        }
        guard !items.isEmpty else { return }
        onMenu?(items, CGRect(origin: p, size: .zero))
    }

    func sectionMenu(_ section: EffectSection) -> [SQMenuItem] {
        model.selectedSection = section
        var m: [SQMenuItem] = []
        func item(_ t: String, shortcut: String = "", enabled: Bool = true, _ run: @escaping @MainActor (EffectControlsModel) -> Void) -> SQMenuItem {
            SQMenuItem(title: t, shortcut: shortcut, isEnabled: enabled) { [model] in run(model) }
        }
        // Order (INTERACTION-AUDIT section 5): edit group, then the effect's own actions, then the destructive ones last.
        let removable = model.canRemoveEffect(section)
        if removable { m.append(item("Cut", shortcut: "\u{2318}X") { $0.cutEffect(section) }) }
        if model.canCopyEffect(section) { m.append(item("Copy", shortcut: "\u{2318}C") { if $0.copyEffect(section) { $0.markEffectCopied() } }) }
        if model.canPasteEffect { m.append(item("Paste", shortcut: "\u{2318}V") { $0.pasteEffect() }) }
        if removable { m.append(item("Duplicate Effect") { $0.duplicateEffect(section) }) }
        if !m.isEmpty { m.append(.separator) }
        if model.hasFXToggle(section) {
            let on = model.isEffectEnabled(section) && !model.isEffectEnabledMixed(section)
            m.append(item(on ? "Disable Effect" : "Enable Effect") { $0.toggleEffectEnabled(section) })
        }
        m.append(item(SQL10n.format(model.hasUserDefault(section) ? "Reset %@ to Your Default" : "Reset %@", SQL10n.string(section.title))) { $0.resetSection(section) })
        if model.canUseAsDefault(section) {
            m.append(.separator)
            m.append(item("Use as Default") { $0.useAsDefault(section) })
            if model.effectIsAnimated(section) {
                m.append(item("Use as Default Without Keyframes") { $0.useAsDefault(section, keepKeyframes: false) })
            }
            m.append(item("Reset Default to Factory", enabled: model.hasUserDefault(section)) { $0.resetDefaultToFactory(section) })
        }
        if section.effectKind != nil {
            m.append(.separator)
            m.append(item("Convert to Keyframes", enabled: model.canConvertToKeyframes(section)) { $0.convertToKeyframes(section) })
        } else if section == .motion {
            m.append(.separator)
            m.append(item(model.reopenTitle, enabled: model.canReopenAsEffect) { $0.reopenAsEffect() })
        }
        let isMask: Bool = { if case .mask = section { return true } else { return false } }()
        if removable || isMask { m.append(.separator) }
        if removable && !isMask { m.append(item("Delete", shortcut: "\u{232B}") { $0.removeEffect(section) }) }
        if isMask { m.append(item("Delete Mask") { if case .mask(let id) = section { $0.removeMask(id) } }) }
        return m
    }

    func propertyMenu(_ p: EffectProperty, numeric: Bool) -> [SQMenuItem] {
        let animated = model.isAnimated(p)
        var m: [SQMenuItem] = []
        if animated {
            if numeric {
                let st = model.keyframeControlState(p)
                m.append(SQMenuItem(title: st.keyIsOn ? "Remove Keyframe" : "Add Keyframe", isEnabled: st.canToggleKey) { [model] in _ = model.toggleKeyAtPlayhead(p) })
                m.append(SQMenuItem(title: "Go to Previous Keyframe", isEnabled: st.canGoPrevious) { [model] in model.goToPreviousKey(p) })
                m.append(SQMenuItem(title: "Go to Next Keyframe", isEnabled: st.canGoNext) { [model] in model.goToNextKey(p) })
                m.append(.separator)
            }
            m.append(SQMenuItem(title: "Reset at Playhead", isEnabled: model.playheadInClip) { [model] in model.resetAtPlayhead(p) })
        }
        m.append(SQMenuItem(title: animated ? "Reset All (Remove Keyframes)" : "Reset", isEnabled: !model.isDefault(p)) { [model] in model.resetAll(p) })
        m.append(.separator)
        m.append(model.graphEditorMenuItem())
        if numeric, model.canResetToAutomatic(p) {      // a variant is active and overrides this property
            m.append(.separator)
            m.append(SQMenuItem(title: "Reset to Automatic") { [model] in model.resetToAutomatic(p) })
        }
        return m
    }

    // MARK: Keys, wheel, timer

    /// A key for the focused field (typing, arrows, Esc). Returns whether the panel used it.
    @discardableResult
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        // Undo / Redo are the project's, not the field's: a value being typed is dropped (as Escape does) and the key goes
        // on to the app, so Cmd+Z after an inspector edit never dies in a field that was left open.
        if modifiers.contains(.command), k == .character("z") {
            if focusedField != nil || focusedText != nil { _ = key(.escape, modifiers: []) }
            return false
        }
        if focusedField == nil, focusedText == nil, clipSections?.key(k, modifiers: modifiers) == true { return true }
        if k == InputKey.tab, focusedField != nil || focusedText != nil {
            moveFocus(backward: modifiers.contains(.shift))
            return true
        }
        if let key = focusedText, var f = textFields[key] {
            let committed = f.key(k, modifiers: modifiers)
            textFields[key] = f
            if let committed { runCommit(key, committed) }
            if !f.isEditing { focusedText = nil }
            return true
        }
        guard let id = focusedField, var f = fields[id] else { return false }
        let events = f.key(k, modifiers: modifiers, now: clock())
        let used = !events.isEmpty || f.isEditing || [.up, .down, .escape, .enter].contains(k)
        fields[id] = f
        apply(events, id)
        if !f.isEditing, k == .enter || k == .escape { focusedField = nil }
        return used
    }

    /// The fields in row order (Tab order): the scrub fields of every row and the text fields of translated rows.
    enum Focusable: Equatable { case field(FieldID), text(String) }
    func focusOrder() -> [Focusable] {
        var out: [Focusable] = []
        for r in rows {
            if let ws = widgets(r) {
                for w in ws {
                    switch w.kind {
                    case .field where w.enabled: out.append(.field(FieldID(ref: .custom(w.key), component: .all)))
                    case .textField where w.enabled: out.append(.text(w.key))
                    default: break
                    }
                }
            } else {
                out += fieldIDs(r.kind).filter { fields[$0]?.isEnabled ?? false }.map { .field($0) }
            }
        }
        return out
    }

    /// Tab / Shift+Tab (ScrubField's nextKeyView chain): commit the current field and open the next one for typing.
    func moveFocus(backward: Bool) {
        let order = focusOrder()
        let current: Focusable? = focusedField.map { .field($0) } ?? focusedText.map { .text($0) }
        if let f = focusedField {
            var field = fields[f]
            if let events = field?.resignFocus() { fields[f] = field; apply(events, f) }
            focusedField = nil
        }
        if let key = focusedText { commitText(key) }
        syncFields()
        guard !order.isEmpty else { return }
        let i = current.flatMap { order.firstIndex(of: $0) } ?? (backward ? 0 : order.count - 1)
        let next = order[(i + (backward ? order.count - 1 : 1)) % order.count]
        switch next {
        case .field(let id):
            focusedField = id
            fields[id]?.beginEditing()
        case .text(let key):
            focusedText = key
            textFields[key]?.mouseDown()
        }
    }

    private func commitText(_ key: String) {
        focusedText = nil
        guard var f = textFields[key] else { return }
        let text = f.commit()
        textFields[key] = f
        if let text { runCommit(key, text) }
    }

    private func runCommit(_ key: String, _ text: String) {
        guard let (_, w) = widget(key), case .textField(_, let commit) = w.kind else { return }
        commit(text)
        syncFields()
    }

    /// Wheel at `p`: Option steps the hovered or focused field (ScrubField); otherwise the panel scrolls.
    @discardableResult
    public func scroll(at p: CGPoint, dy: CGFloat, precise: Bool, modifiers: InputModifiers) -> Bool {
        if case .field(let id) = target(at: p), var f = fields[id] {
            let r = f.scroll(delta: Double(dy), precise: precise, modifiers: modifiers, focused: focusedField == id, now: clock())
            fields[id] = f
            apply(r.events, id)
            if r.used { return true }
        }
        if case .widget(let key) = target(at: p), let (r, w) = widget(key), case .surface(let make) = w.kind,
           surface(key, make).scroll(at: CGPoint(x: p.x, y: p.y - rowTop(r)), in: w.frame, dy: precise ? dy : dy * 4) {
            return true
        }
        if overSection(p), clipSections?.scroll(at: inSection(p), dy: precise ? dy : dy * 4) == true { return true }
        let maxY = max(contentHeight - size.height, 0)
        let y = min(max(scrollY - dy, 0), maxY)
        guard y != scrollY else { return false }
        scrollY = y
        return true
    }

    /// Ends idle arrow / wheel bursts (call every frame or from a timer).
    public func tick() {
        clipSections?.tick()
        let now = clock()
        for id in Array(fields.keys) {
            guard var f = fields[id] else { continue }
            let events = f.tick(now: now)
            fields[id] = f
            apply(events, id)
        }
    }

    // MARK: Pixels

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
    /// shortcut: `InputEvent` has no click count or drag modifiers yet: clicks are counted here and a drag keeps the
    /// modifiers of its press; upgrade when the hosts send both.
    @discardableResult
    public func handle(_ e: InputEvent, scale: Float, origin: CGPoint = .zero) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale) - origin.x, y: CGFloat(y / scale) - origin.y) }
        switch e {
        case .mouseDown(let x, let y, let mods):
            let p = pt(x, y)
            mouseDown(at: p, clickCount: clicks.press(x: Float(p.x), y: Float(p.y), now: clock()), modifiers: mods)
        case .mouseDragged(let x, let y): mouseDragged(to: pt(x, y))
        case .mouseUp(let x, let y): mouseUp(at: pt(x, y))
        case .mouseMoved(let x, let y):
            mouseMoved(to: pt(x, y))
            HostHover.current.offerTip(help(at: pt(x, y)))
        case .scroll(let x, let y, _, let dy, let mods): return scroll(at: pt(x, y), dy: CGFloat(dy / scale), precise: true, modifiers: mods)
        case .keyDown(let k, let mods): return key(k, modifiers: mods)
        }
        return true
    }
}

extension EffectControlsDrawPanel.Target {
    var rowRef: EffectControlsDrawPanel.RowRef? {
        switch self {
        case .ring(let r), .previous(let r), .next(let r), .key(let r), .open(let r), .reset(let r), .label(let r),
             .checkbox(let r), .popup(let r), .row(let r): r
        case .field(let id): id.ref
        case .link(let p), .keyPick(let p), .well(let p), .curve(let p): .property(p)
        default: nil
        }
    }
}

extension EffectControlsModel {
    /// The number fields of a parameter row (PropertyRow.components): Scale shows Width and Height while its link is off,
    /// positions always show X and Y.
    public func valueComponents(_ p: EffectProperty) -> [EffectComponent] {
        if p.pair?.linkable == true && isLinked(p) { return [.all] }      // P5: Transform Scale, linked
        if p.kind == .vector || (p == .scale && !uniformScale) { return [.x, .y] }
        return [.all]
    }
}
