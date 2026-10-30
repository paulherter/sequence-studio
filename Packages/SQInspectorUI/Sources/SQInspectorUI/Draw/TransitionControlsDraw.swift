import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// Controls while a transition is selected, on the shared toolkit: the Mac `TransitionControlsView` translated (name,
/// kind line, Type for a transition layer, Duration as timecode, Alignment, the element parameters, Stinger clip and cut
/// point, Color, Easing with Custom, Direction with Reverse, Softness, Border and its color, Motion Blur, the held-frame
/// note, Reset and Save as Preset…, the right-click default menu). Rules and session calls are the shared
/// `TransitionControlsLogic` and `TransitionControlsActions`. Coordinates: points, y down, (0, 0) = the panel's top-left.
@MainActor public final class TransitionControlsDraw {
    public var theme = DrawTheme()
    public var size = CGSize(width: 320, height: 400)
    public let actions: TransitionControlsActions
    /// Popups and the right-click menu: the shell's menu at `anchor` (panel points).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// The SQ color picker as a popover; `change` gets every pick, nil when the picker closes.
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// Easing > Custom: the curve popover on the shown transition's easing.
    public var onEaseCurve: (@MainActor (_ source: any EaseCurveSource, _ anchor: CGRect) -> Void)?
    /// "Save as Preset…": the host asks for a name and saves the selected transition to the Library.
    public var onSavePreset: (() -> Void)?
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public private(set) var shown: TransitionControlsShown?
    private(set) var rows: [TransitionControlsLogic.Row] = []
    private var fields: [TransitionControlsLogic.Row: ScrubFieldControl] = [:]
    /// Rows whose gesture already sent its first change (the Mac `Flag` of `wire`).
    private var started: Set<TransitionControlsLogic.Row> = []
    private(set) var focused: TransitionControlsLogic.Row?

    public init(actions: TransitionControlsActions) { self.actions = actions }

    // MARK: Metrics (the Mac stack: lg padding, sm spacing, 70 pt labels)

    static let pad = CGFloat(DrawTheme.Spacing.lg)
    static let gap = CGFloat(DrawTheme.Spacing.sm)
    static let labelWidth: CGFloat = 70
    static let controlHeight = ControlsGrid.controlHeight
    static let pitch = ControlsGrid.controlHeight + CGFloat(DrawTheme.Spacing.sm)
    static let popupWidth: CGFloat = 160
    static let directionWidth: CGFloat = 120
    static let durationWidth: CGFloat = 110
    static let sliderWidth: CGFloat = 190
    static let sliderFieldWidth: CGFloat = 52
    static let elementFieldWidth: CGFloat = 72
    static let wellWidth: CGFloat = 44
    static let checkSide: CGFloat = 14
    static let titleHeight: CGFloat = 18, subtitleHeight: CGFloat = 16
    static let noteWidth: CGFloat = 280

    var valueX: CGFloat { Self.pad + Self.labelWidth + Self.gap }
    var rowsTop: CGFloat { Self.pad + Self.titleHeight + Self.gap + Self.subtitleHeight + Self.gap }
    func rowY(_ i: Int) -> CGFloat { rowsTop + CGFloat(i) * Self.pitch }

    /// Shows a transition (nil = nothing); the fields keep the value being typed or dragged.
    public func show(_ s: TransitionControlsShown?) {
        if s?.transition.id != shown?.transition.id || s?.transition.kind != shown?.transition.kind {
            fields = [:]; started = []; focused = nil; pressed = nil
        }
        shown = s
        guard let s else { rows = []; return }
        rows = TransitionControlsLogic.rows(s)
        let tr = s.transition, k = tr.kind, fd = s.frameDuration
        for r in rows {
            var f: ScrubFieldControl
            let v: Double
            switch r {
            case .duration:
                f = fields[r] ?? ScrubFieldControl(value: 0)
                f.range = 1...1_000_000
                let tc = Timecode(frameDuration: fd, dropFrame: false)
                f.valueFormatter = { v in tc.format(TransitionControlsLogic.duration(frames: v, frameDuration: fd)) }
                f.valueParser = { text in
                    guard let t = tc.parse(text), t > .zero else { return nil }
                    return TransitionControlsLogic.durationFrames(t, frameDuration: fd)
                }
                v = TransitionControlsLogic.durationFrames(TransitionControlsLogic.shownDuration(s), frameDuration: fd)
            case .softness:
                f = slider(r, TransitionControlsLogic.softnessRange, def: TransitionControlsLogic.softnessPercent(TransitionKind.defaultSoftness))
                v = TransitionControlsLogic.softnessPercent(tr.effectiveSoftness)
            case .motionBlur:
                f = slider(r, TransitionControlsLogic.blurRange(k), def: TransitionControlsLogic.blurPercent(k.defaultMotionBlur))
                v = TransitionControlsLogic.blurPercent(tr.effectiveMotionBlur)
            case .border:
                f = slider(r, TransitionControlsLogic.borderRange, def: 0)
                v = ((tr.borderWidth ?? 0) * 100).rounded()
            case .stingerCut:
                f = slider(r, TransitionControlsLogic.stingerCutRange, def: 50)
                v = ((tr.stinger?.cutFraction ?? 0.5) * 100).rounded()
            case .element(let key):
                guard let spec = k.elementParams.first(where: { $0.key == key }), case .slider = spec.kind else { continue }
                f = fields[r] ?? ScrubFieldControl(value: spec.defaultValue)
                f.range = spec.range; f.step = spec.step; f.decimals = spec.decimals; f.unit = spec.unit
                f.defaultValue = spec.defaultValue
                v = tr.param(key)
            default: continue
            }
            if !f.isDragging, !f.isEditing { f.value = v }
            fields[r] = f
        }
    }

    private func slider(_ r: TransitionControlsLogic.Row, _ range: ClosedRange<Double>, def: Double) -> ScrubFieldControl {
        var f = fields[r] ?? ScrubFieldControl(value: def)
        f.range = range; f.unit = "%"; f.defaultValue = def
        return f
    }

    private func spec(_ key: String) -> EffectParamSpec? { shown?.transition.kind.elementParams.first { $0.key == key } }

    // MARK: Layout

    enum Control: Hashable {
        case row(TransitionControlsLogic.Row)
        /// The slider track of a slider row.
        case track(TransitionControlsLogic.Row)
        case reverse, reset, savePreset
    }

    private func isSlider(_ r: TransitionControlsLogic.Row) -> Bool {
        switch r { case .softness, .motionBlur, .border, .stingerCut: true; default: false }
    }

    /// The field / popup / well of a row (for a slider row: its number field).
    func frame(_ k: Control) -> CGRect {
        let ch = Self.controlHeight
        switch k {
        case .row(let r), .track(let r):
            guard let i = rows.firstIndex(of: r) else { return .zero }
            let y = rowY(i)
            func box(_ w: CGFloat) -> CGRect { CGRect(x: valueX, y: y, width: min(w, max(size.width - valueX - Self.pad, 0)), height: ch) }
            switch r {
            case .kind, .alignment, .easing: return box(Self.popupWidth)
            case .stingerClip: return box(200)
            case .direction: return box(Self.directionWidth)
            case .duration: return box(Self.durationWidth)
            case .color, .borderColor: return box(Self.wellWidth)
            case .element(let key):
                switch spec(key)?.kind {
                case .choice: return box(Self.popupWidth)
                case .checkbox: return CGRect(x: valueX, y: y + ((ch - Self.checkSide) / 2).rounded(), width: Self.checkSide, height: Self.checkSide)
                default: return box(Self.elementFieldWidth)
                }
            case .softness, .motionBlur, .border, .stingerCut:
                let whole = box(Self.sliderWidth)
                let fw = min(Self.sliderFieldWidth, whole.width)
                if case .track = k { return CGRect(x: whole.minX, y: whole.minY, width: max(whole.width - fw - Self.gap, 0), height: ch) }
                return CGRect(x: whole.maxX - fw, y: whole.minY, width: fw, height: ch)
            }
        case .reverse:
            let d = frame(.row(.direction))
            return CGRect(x: d.maxX + Self.gap, y: d.minY + ((ch - Self.checkSide) / 2).rounded(), width: Self.checkSide + 6 + reverseTitleWidth,
                          height: Self.checkSide)
        case .reset, .savePreset:
            let y = buttonsY
            let resetW = showsReset ? resetWidth : 0
            if k == .reset { return CGRect(x: Self.pad, y: y, width: resetW, height: ch) }
            return CGRect(x: Self.pad + (showsReset ? resetW + Self.gap : 0), y: y, width: saveWidth, height: ch)
        }
    }

    private var reverseTitleWidth: CGFloat = 48
    private var resetWidth: CGFloat = 52
    private var saveWidth: CGFloat = 110
    private var noteLines: Int = 0

    private var showsButtons: Bool { shown.map { !$0.isLayer } ?? false }
    private var showsReset: Bool { showsButtons && shown?.transition.kind.isStinger == false }
    private var noteY: CGFloat { rowY(rows.count) }
    private var noteHeight: CGFloat {
        noteLines == 0 ? 0 : CGFloat(noteLines) * (CGFloat(DrawTheme.TypeSize.body) + 4) + Self.gap
    }
    private var buttonsY: CGFloat { noteY + noteHeight }

    /// The content height (rows, note and buttons).
    public var contentHeight: CGFloat { buttonsY + (showsButtons ? Self.controlHeight : 0) + Self.pad }

    func control(at p: CGPoint) -> Control? {
        guard shown != nil else { return nil }
        if showsButtons {
            if showsReset, frame(.reset).contains(p) { return .reset }
            if frame(.savePreset).contains(p) { return .savePreset }
        }
        if rows.contains(.direction), frame(.reverse).contains(p) { return .reverse }
        for r in rows {
            if isSlider(r), frame(.track(r)).insetBy(dx: -4, dy: 0).contains(p) { return .track(r) }
            if frame(.row(r)).contains(p) { return .row(r) }
        }
        return nil
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        guard let s = shown else { return }
        let fs = CGFloat(DrawTheme.TypeSize.body), k = s.transition.kind
        let w = max(size.width - Self.pad * 2, 0)
        c.draw(SQL10n.string(k.name), in: CGRect(x: Self.pad, y: Self.pad, width: w, height: Self.titleHeight),
               fontSize: CGFloat(DrawTheme.TypeSize.title), t.label)
        c.draw(SQL10n.string(TransitionControlsLogic.subtitle(s)),
               in: CGRect(x: Self.pad, y: Self.pad + Self.titleHeight + Self.gap, width: w, height: Self.subtitleHeight),
               fontSize: fs, t.label3)
        for (i, r) in rows.enumerated() {
            c.draw(SQL10n.string(TransitionControlsLogic.title(r, kind: k)),
                   in: CGRect(x: Self.pad, y: rowY(i), width: Self.labelWidth, height: Self.controlHeight), fontSize: fs, t.label2, align: .right)
            drawControl(&c, r, s)
        }
        if let note = TransitionControlsLogic.note(s) {
            let nw = min(Self.noteWidth, w)
            noteLines = c.wrap(SQL10n.string(note), width: nw, fontSize: fs).count
            _ = c.drawWrapped(SQL10n.string(note), in: CGRect(x: Self.pad, y: noteY, width: nw, height: noteHeight), fontSize: fs,
                              lineHeight: fs + 4, t.label3)
        } else {
            noteLines = 0
        }
        guard showsButtons else { return }
        resetWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Reset"))
        saveWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Save as Preset…"))
        if showsReset {
            InspectorDraw.button(&c, title: SQL10n.string("Reset"), in: frame(.reset), hovering: hover == .reset,
                                    pressed: pressed == .reset, enabled: true, t)
        }
        InspectorDraw.button(&c, title: SQL10n.string("Save as Preset…"), in: frame(.savePreset), hovering: hover == .savePreset,
                                pressed: pressed == .savePreset, enabled: true, t)
    }

    private func drawControl(_ c: inout Canvas, _ r: TransitionControlsLogic.Row, _ s: TransitionControlsShown) {
        let t = theme, f = frame(.row(r)), hov = hover == .row(r), tr = s.transition
        func popup(_ title: String, enabled: Bool = true) {
            InspectorDraw.popup(&c, title: SQL10n.string(title), in: f, hovering: hov, open: false, enabled: enabled, t)
        }
        func well(_ rgb: [UInt8]) {
            let v = rgb.count == 3 ? rgb : [255, 255, 255]
            InspectorDraw.colorWell(&c, DrawColor(Float(v[0]) / 255, Float(v[1]) / 255, Float(v[2]) / 255, 1), in: f, hovering: hov, t)
        }
        switch r {
        case .kind: popup(tr.kind.name)
        case .alignment:
            let options = TransitionControlsLogic.alignmentOptions(s)
            popup(options.contains(tr.alignment) ? tr.alignment.name : "", enabled: TransitionControlsLogic.isTwoSided(s))
        case .easing:
            let i = TransitionControlsLogic.easingIndex(of: tr.effectiveEasing)
            popup(i < TransitionControlsLogic.easings.count ? TransitionControlsLogic.easings[i].displayName : TransitionControlsLogic.customEasingTitle)
        case .direction:
            popup(tr.effectiveDirection.name)
            let rb = frame(.reverse), box = CGRect(x: rb.minX, y: rb.minY, width: Self.checkSide, height: Self.checkSide)
            InspectorDraw.checkbox(&c, tr.isReversed ? .on : .off, box: box, hovering: hover == .reverse, pressed: pressed == .reverse,
                                   enabled: true, t)
            let title = SQL10n.string("Reverse")
            reverseTitleWidth = c.size(of: title, fontSize: CGFloat(DrawTheme.TypeSize.body)).width
            c.draw(title, in: CGRect(x: box.maxX + 6, y: box.minY - 4, width: reverseTitleWidth + 4, height: Self.checkSide + 8),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label)
        case .stingerClip:
            let items = TransitionControlsLogic.stingerItems(s)
            popup(items.titles[items.selected])
        case .color: well(TransitionControlsLogic.color(s))
        case .borderColor: well(TransitionControlsLogic.borderColor(s))
        case .duration:
            guard var fd = fields[r] else { return }
            fd.hovering = hov
            fd.draw(&c, in: f, theme: t, focused: focused == r)
        case .softness, .motionBlur, .border, .stingerCut:
            guard var fd = fields[r] else { return }
            let span = fd.range.upperBound - fd.range.lowerBound
            InspectorDraw.slider(&c, fraction: span > 0 ? (fd.value - fd.range.lowerBound) / span : 0, in: frame(.track(r)), enabled: true, t)
            fd.hovering = hov
            fd.draw(&c, in: f, theme: t, focused: focused == r)
        case .element(let key):
            guard let sp = spec(key) else { return }
            switch sp.kind {
            case .choice(let titles):
                let i = sp.kind.choiceIndex(for: tr.param(key))
                popup(titles.indices.contains(i) ? titles[i] : "")
            case .checkbox:
                InspectorDraw.checkbox(&c, sp.kind.isOn(tr.param(key)) ? .on : .off, box: f, hovering: hov, pressed: pressed == .row(r),
                                       enabled: true, t)
            default:
                guard var fd = fields[r] else { return }
                fd.hovering = hov
                fd.draw(&c, in: f, theme: t, focused: focused == r)
            }
        }
    }

    // MARK: Pointer and keys

    private(set) var hover: Control?
    private(set) var pressed: Control?
    private var counter = ClickCounter()

    public func mouseMoved(to p: CGPoint?) { if pressed == nil { hover = p.flatMap(control) } }

    public func mouseDown(at p: CGPoint, clickCount: Int? = nil, modifiers: InputModifiers = []) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if let f = focused, k != .row(f) { resignFocus() }
        // FB-W: right-click anywhere in the controls.
        if modifiers.contains(.secondary) {
            pressed = nil
            showContextMenu(at: p)
            return
        }
        pressed = k
        guard let k, let s = shown else { return }
        switch k {
        case .track(let r):
            focused = nil
            started.remove(r)
            setFromTrack(r, x: p.x, continues: false)
        case .row(let r):
            if var fd = fields[r], !isPopupRow(r) {
                apply(fd.mouseDown(x: Float(p.x), clickCount: n), r)
                fields[r] = fd
                focused = r
                return
            }
            pressed = isCheckRow(r) ? k : nil
            openRow(r, s)
        default: break
        }
    }

    private func isPopupRow(_ r: TransitionControlsLogic.Row) -> Bool {
        switch r {
        case .kind, .alignment, .easing, .direction, .stingerClip, .color, .borderColor: return true
        case .element(let key): if case .choice = spec(key)?.kind { return true }; return false
        default: return false
        }
    }

    private func isCheckRow(_ r: TransitionControlsLogic.Row) -> Bool {
        if case .element(let key) = r, case .checkbox = spec(key)?.kind { return true }
        return false
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        switch pressed {
        case .track(let r)?: setFromTrack(r, x: p.x, continues: true)
        case .row(let r)? where fields[r] != nil:
            guard var fd = fields[r] else { return }
            apply(fd.mouseDragged(x: Float(p.x), modifiers: modifiers), r)
            fields[r] = fd
        default: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        let k = pressed
        pressed = nil
        defer { mouseMoved(to: p) }
        switch k {
        case .track(let r)?:
            started.remove(r)
            return
        case .row(let r)? where fields[r] != nil:
            guard var fd = fields[r] else { return }
            apply(fd.mouseUp(), r)
            fields[r] = fd
            return
        default: break
        }
        guard let k, control(at: p) == k, let s = shown else { return }
        switch k {
        case .reverse: actions.setReversed(!s.transition.isReversed)
        case .reset: actions.reset()
        case .savePreset: onSavePreset?()
        case .row(.element(let key)): if let sp = spec(key) { actions.setElementParam(key, sp.kind.isOn(s.transition.param(key)) ? 0 : 1) }
        default: break
        }
    }

    /// A press or drag on a slider track: the value under the pointer, one undo step per drag.
    private func setFromTrack(_ r: TransitionControlsLogic.Row, x: CGFloat, continues: Bool) {
        guard var fd = fields[r] else { return }
        let range = fd.range
        let v = (range.lowerBound + InspectorDraw.sliderFraction(x: x, in: frame(.track(r))) * (range.upperBound - range.lowerBound)).rounded()
        guard !continues || v != fd.value else { return }
        fd.value = v
        fields[r] = fd
        report(r, v)
    }

    /// The field's begin / change / end events to the session: the first change of a gesture starts the undo step, the
    /// rest join it; a typed value reports once at the end (the Mac `wire` and the element rows' `started` flag).
    private func apply(_ events: [ScrubFieldControl.Event], _ r: TransitionControlsLogic.Row) {
        guard let s = shown else { return }
        for e in events {
            switch e {
            case .begin: started.remove(r)
            case .live(let v), .change(let v):
                if r == .duration { continue }
                report(r, v)
            case .end(let v), .cancel(let v):
                if r == .duration {
                    let t = TransitionControlsLogic.duration(frames: v, frameDuration: s.frameDuration)
                    if t != TransitionControlsLogic.shownDuration(s) { actions.setDuration(t) }
                } else if !started.contains(r) {
                    report(r, v)
                }
                started.remove(r)
            }
        }
    }

    private func report(_ r: TransitionControlsLogic.Row, _ value: Double) {
        let cont = started.contains(r)
        started.insert(r)
        switch r {
        case .softness: actions.setSoftness(value.rounded() / 100, continuesGesture: cont)
        case .motionBlur: actions.setMotionBlur(TransitionControlsLogic.shutter(percent: value.rounded()), continuesGesture: cont)
        case .border: actions.setBorderWidth(value.rounded() / 100, continuesGesture: cont)
        case .stingerCut: actions.setStingerCut(value.rounded() / 100, continuesGesture: cont)
        case .element(let key): actions.setElementParamLive(key, value, continuesGesture: cont)
        default: break
        }
    }

    /// Popups and color wells: the shell menu or the color picker anchored to the control.
    private func openRow(_ r: TransitionControlsLogic.Row, _ s: TransitionControlsShown) {
        let anchor = frame(.row(r)), tr = s.transition
        var items: [SQMenuItem] = []
        switch r {
        case .kind:
            items = TransitionKind.layerKinds.map { k in
                SQMenuItem(title: k.name, isChecked: k == tr.kind) { [weak self] in self?.actions.setKind(k) }
            }
        case .alignment:
            guard TransitionControlsLogic.isTwoSided(s) else { return }
            items = TransitionControlsLogic.alignmentOptions(s).map { a in
                SQMenuItem(title: a.name, isChecked: a == tr.alignment) { [weak self] in self?.actions.setAlignment(a) }
            }
        case .easing:
            let current = TransitionControlsLogic.easingIndex(of: tr.effectiveEasing)
            items = TransitionControlsLogic.easings.enumerated().map { i, c in
                SQMenuItem(title: c.displayName, isChecked: i == current) { [weak self] in self?.actions.setEasing(c) }
            }
            items.append(SQMenuItem(title: TransitionControlsLogic.customEasingTitle,
                                    isChecked: current == TransitionControlsLogic.customEasingIndex) { [weak self] in
                self?.editCustomCurve(anchor)
            })
        case .direction:
            items = TransitionDirection.allCases.map { d in
                SQMenuItem(title: d.name, isChecked: d == tr.effectiveDirection) { [weak self] in self?.actions.setDirection(d) }
            }
        case .stingerClip:
            let list = TransitionControlsLogic.stingerItems(s)
            items = list.titles.indices.map { i in
                SQMenuItem(title: list.titles[i], isChecked: i == list.selected) { [weak self] in self?.actions.setStingerMedia(list.ids[i]) }
            }
        case .element(let key):
            guard let sp = spec(key), case .choice(let titles) = sp.kind else { return }
            let current = sp.kind.choiceIndex(for: tr.param(key))
            items = titles.enumerated().map { i, title in
                SQMenuItem(title: title, isChecked: i == current) { [weak self] in self?.actions.setElementParam(key, Double(i)) }
            }
        case .color: pickColor(TransitionControlsLogic.color(s), anchor) { [weak self] rgb, cont in self?.actions.setColor(rgb, continuesGesture: cont) }
        case .borderColor:
            pickColor(TransitionControlsLogic.borderColor(s), anchor) { [weak self] rgb, cont in self?.actions.setBorderColor(rgb, continuesGesture: cont) }
        default: break
        }
        if !items.isEmpty { onMenu?(items, anchor) }
    }

    /// Custom: starts from the curve that is shown (a preset's handles), so Custom never jumps; then the editor opens.
    private func editCustomCurve(_ anchor: CGRect) {
        guard let easing = shown?.transition.effectiveEasing else { return }
        if easing.matchingTransitionPreset != nil, let c = EasingCurve.transitionCustom(easing.shape) { actions.setEasing(c) }
        if let source = actions.easeSource() { onEaseCurve?(source, anchor) }
    }

    /// One picker session is one undo step: the first pick starts it, the rest join it.
    private func pickColor(_ rgb: [UInt8], _ anchor: CGRect, _ send: @escaping @MainActor ([UInt8], Bool) -> Void) {
        guard let pick = onPickColor else { return }
        let v = rgb.count == 3 ? rgb : [255, 255, 255]
        var open = false
        pick(EffectColor(red: Double(v[0]) / 255, green: Double(v[1]) / 255, blue: Double(v[2]) / 255, alpha: 1), anchor) { color in
            guard let color else { open = false; return }
            func byte(_ x: Double) -> UInt8 { UInt8(min(max((x * 255).rounded(), 0), 255)) }
            send([byte(color.red), byte(color.green), byte(color.blue)], open)
            open = true
        }
    }

    private func showContextMenu(at p: CGPoint) {
        guard let s = shown, !s.isLayer else { return }
        let items = TransitionControlsLogic.contextItems(
            kind: s.transition.kind, hasUserDefault: s.hasUserDefault,
            reset: { [weak self] in self?.actions.reset() },
            useAsDefault: { [weak self] in self?.actions.useAsDefault() },
            resetDefaultToFactory: { [weak self] in self?.actions.resetDefaultToFactory() })
        if !items.isEmpty { onMenu?(items, CGRect(origin: p, size: .zero)) }
    }

    /// Keys for the focused field: typing, arrows, Return / Esc; Tab moves to the next field.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard let r = focused, var fd = fields[r] else { return false }
        if k == InputKey.tab {
            apply(fd.resignFocus(), r)
            fields[r] = fd
            let order = rows.filter { fields[$0] != nil }
            if let i = order.firstIndex(of: r), !order.isEmpty {
                let next = order[(i + (modifiers.contains(.shift) ? order.count - 1 : 1)) % order.count]
                focused = next
                if var nf = fields[next] { nf.beginEditing(); fields[next] = nf }
            }
            return true
        }
        apply(fd.key(k, modifiers: modifiers, now: clock()), r)
        fields[r] = fd
        return true
    }

    public func resignFocus() {
        guard let r = focused else { return }
        focused = nil
        if var fd = fields[r] { apply(fd.resignFocus(), r); fields[r] = fd }
    }

    /// Ends idle arrow / wheel bursts.
    public func tick() {
        for r in Array(fields.keys) {
            guard var fd = fields[r] else { continue }
            let events = fd.tick(now: clock())
            fields[r] = fd
            if !events.isEmpty { apply(events, r) }
        }
    }

    /// Hover tips (the Mac tool tips and accessibility labels).
    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .reset?: SQL10n.string(TransitionControlsLogic.resetTip(hasUserDefault: shown?.hasUserDefault ?? false))
        case .savePreset?: SQL10n.string("Save as Preset")
        case .reverse?: SQL10n.string("Reverse transition")
        case .row(.borderColor)?: SQL10n.string("Border Color")
        case .row(.color)?: SQL10n.string("Color")
        case .row(.stingerClip)?: SQL10n.string("Stinger Clip")
        case .row(.stingerCut)?, .track(.stingerCut)?: SQL10n.string("Stinger Cut Point")
        case .row(.duration)?: SQL10n.string("Transition duration")
        default: nil
        }
    }

    // MARK: Pixels

    private var clicks = ClickCounter()

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
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
        case .scroll(let x, let y, _, let dy, let mods):
            let p = pt(x, y)
            guard case .row(let r)? = control(at: p), var fd = fields[r] else { return false }
            let out = fd.scroll(delta: Double(dy / scale), precise: true, modifiers: mods, focused: focused == r, now: clock())
            fields[r] = fd
            apply(out.events, r)
            return out.used
        case .keyDown(let k, let mods): return key(k, modifiers: mods)
        }
        return true
    }
}
