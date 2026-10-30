import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// Controls > Graphic, the basics of the selected items on the shared toolkit (the Mac `GraphicItemRows`): the text box
/// of a selected text item, then Corners (rectangles), Fill (color, opacity) and Outline (color, width) of two or more
/// shape items. They read and write the same Shape values as the Graphics panel through the one `GraphicsEditor`, at the
/// playhead, so keys are kept; the wiring is the Graphics panel's (`GraphicsPanelDraw.buildAppearance`).
/// Coordinates: points, y down, (0, 0) = the rows' top-left.
@MainActor final class GraphicItemRowsDraw {
    weak var editor: GraphicsEditor?
    var theme = DrawTheme() { didSet { form.theme = theme } }
    var width: CGFloat = 320 { didSet { form.width = width } }
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime } { didSet { form.clock = clock } }
    var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                  _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?

    let form = GraphicsFormDraw()
    private(set) var structureKey = ""
    /// The selected text item's string (nil: no text item, no box).
    private(set) var boxText: String?
    private(set) var typing: TextEditState?
    private var typed = false
    private var counter = ClickCounter()
    private var measure: (atlas: GlyphAtlas?, scale: Float) = (nil, 1)
    private(set) var boxHover = false
    private var boxPressed = false
    private var formPressed = false

    /// The Mac TextBoxView: 52 pt high, 2 pt below the row top, the row one gap taller.
    static let boxHeight: CGFloat = 52
    static let lineHeight: CGFloat = CGFloat(DrawTheme.TypeSize.body) + 5
    var boxRowHeight: CGFloat { boxText == nil ? 0 : Self.boxHeight + ControlsGrid.gap }
    var boxFrame: CGRect {
        CGRect(x: ControlsGrid.labelX, y: 2, width: max(width - ControlsGrid.labelX - ControlsGrid.trailing, 0), height: Self.boxHeight)
    }
    var height: CGFloat { boxRowHeight + form.height }

    init() {
        form.onBeginGesture = { [weak self] in self?.editor?.beginGesture() }
        form.onMenu = { [weak self] items, anchor in
            guard let self else { return }
            onMenu?(items, anchor.offsetBy(dx: 0, dy: boxRowHeight))
        }
        form.onPickColor = { [weak self] color, anchor, change in
            guard let self else { return }
            onPickColor?(color, anchor.offsetBy(dx: 0, dy: boxRowHeight), change)
        }
    }

    /// The shape items the rows edit (`GraphicsPanelLogic.itemRowLayers`).
    var shownLayers: [GraphicsLayer] { editor.map { GraphicsPanelLogic.itemRowLayers($0.targetLayers) } ?? [] }

    /// Rebuilds the rows when the selection's kinds changed and loads the text item's string (not while typing).
    /// True when the height changed.
    @discardableResult
    func sync() -> Bool {
        let before = height
        let text = editor?.textTemplate?.text
        if typing == nil { boxText = text } else if text == nil { endTyping(); boxText = nil }
        let layers = shownLayers
        let key = layers.isEmpty ? "" : "\(GraphicsPanelLogic.allRectangles(layers))|\(layers.allSatisfy(GraphicsPanelLogic.isLineLike))"
        if key != structureKey { structureKey = key; rebuild(layers) }
        return height != before
    }

    private func rebuild(_ layers: [GraphicsLayer]) {
        form.reset()
        form.width = width
        guard !layers.isEmpty else { return }
        let kind = ClipEffect.shapeEffectKind
        if GraphicsPanelLogic.allRectangles(layers) {
            let p = GraphicsEditor.Property.shape(ClipEffect.shapeCornerRadiusKey)
            let def = EffectCatalog.param(kind, ClipEffect.shapeCornerRadiusKey)?.defaultValue
            form.numbers("Corners", unit: "px", keyed: { [weak self] in self?.editor?.isKeyed(p) ?? false }, decimals: 0,
                         reset: def.map { [$0] }, range: 0...Double.greatestFiniteMagnitude,
                         fields: [({ [weak self] in self?.editor?.value(p) }, { [weak self] v in self?.editor?.setValue(p, max(v, 0)) })])
        }
        if !layers.allSatisfy(GraphicsPanelLogic.isLineLike) {
            let key = ClipEffect.shapeFillColorKey
            form.appearance("Fill", key: "fill", on: { [weak self] in self?.editor?.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 } },
                            setOn: { [weak self] in self?.editor?.setShapeValue(ClipEffect.shapeFillKey, $0 ? 1 : 0) },
                            color: { [weak self] in self?.editor?.color(kind: kind, key: key) },
                            setColor: { [weak self] in self?.editor?.setColor(kind: kind, key: key, $0) },
                            value: { [weak self] in self?.editor?.colorAlpha(kind: kind, key: key).map { $0 * 100 } },
                            setValue: { [weak self] in self?.editor?.setColorAlpha(kind: kind, key: key, min(max($0, 0), 100) / 100) },
                            unit: "%", reset: 100, hasDetail: false)
        }
        let widthP = GraphicsEditor.Property.shape(ClipEffect.shapeStrokeWidthKey)
        let stroke = ClipEffect.shapeStrokeColorKey
        form.appearance("Outline", key: "outline", on: { [weak self] in self?.editor?.shapeValue(ClipEffect.shapeStrokeKey).map { $0 >= 0.5 } },
                        setOn: { [weak self] in self?.editor?.setShapeValue(ClipEffect.shapeStrokeKey, $0 ? 1 : 0) },
                        color: { [weak self] in self?.editor?.color(kind: kind, key: stroke) },
                        setColor: { [weak self] in self?.editor?.setColor(kind: kind, key: stroke, $0) },
                        value: { [weak self] in self?.editor?.value(widthP) },
                        setValue: { [weak self] in self?.editor?.setValue(widthP, max($0, 0)) },
                        unit: "px", reset: 8, hasDetail: false)
    }

    // MARK: Drawing

    func draw(_ c: inout Canvas) {
        measure = (c.atlas, c.scale)
        if boxText != nil { drawBox(&c, boxFrame) }
        c.saveGState(); c.translateBy(x: 0, y: boxRowHeight); form.draw(&c); c.restoreGState()
    }

    /// The text box as in the Text section (`TextBlockDraw.drawBox`): field capsule, the open editor while typing.
    /// shortcut: a copy of TextBlockDraw's box drawing; share one TextBoxDraw when a third text box is needed.
    private func drawBox(_ c: inout Canvas, _ f: CGRect) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        let r = CGFloat(InspectorTokens.controlRadius)
        c.fill(roundedRect: f, radius: r, t.field)
        if typing != nil { c.fill(roundedRect: f, radius: r, t.accentTint) }
        c.stroke(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, width: 1, boxHover ? t.fieldEdgeHover : t.fieldEdge)
        let inner = f.insetBy(dx: 8, dy: 4)
        c.saveGState()
        c.clip(to: inner)
        if let e = typing {
            InspectorDraw.focusLine(&c, f, radius: r, t)
            InspectorDraw.editLines(&c, e, in: inner, lineHeight: Self.lineHeight, fontSize: fs, color: t.label, t)
        } else {
            for (i, line) in (boxText ?? "").split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                c.draw(String(line), in: CGRect(x: inner.minX, y: inner.minY + CGFloat(i) * Self.lineHeight, width: inner.width,
                                                height: Self.lineHeight), fontSize: fs, t.label)
            }
        }
        c.restoreGState()
    }

    // MARK: Pointer and keys

    private func inForm(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - boxRowHeight) }
    private func overBox(_ p: CGPoint) -> Bool { boxText != nil && boxFrame.contains(p) }

    private func caret(_ e: TextEditState, at p: CGPoint) -> Int {
        let c = Canvas(width: 0, height: 0, atlas: measure.atlas, scale: measure.scale)
        return InspectorDraw.caretIndex(c, e, at: p, in: boxFrame.insetBy(dx: 8, dy: 4), lineHeight: Self.lineHeight,
                                        fontSize: CGFloat(DrawTheme.TypeSize.body))
    }

    func mouseMoved(to p: CGPoint?) {
        boxHover = p.map(overBox) ?? false
        form.mouseMoved(to: p.flatMap { $0.y >= boxRowHeight ? inForm($0) : nil })
    }

    func mouseDown(at p: CGPoint, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        if overBox(p) {
            form.resignFocus()
            boxPressed = true
            var e = typing ?? TextEditState(boxText ?? "", selectAll: false)
            if typing == nil { typed = false }
            if n >= 3 { e.selectAll() } else { e.place(caret(e, at: p)) }
            typing = e
            return
        }
        endTyping()
        guard p.y >= boxRowHeight else { return }
        formPressed = true
        form.mouseDown(at: inForm(p), clickCount: n)
    }

    func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        if boxPressed, var e = typing { e.place(caret(e, at: p), extend: true); typing = e; return }
        if formPressed { form.mouseDragged(to: inForm(p), modifiers: modifiers) }
    }

    func mouseUp(at p: CGPoint) {
        if boxPressed { boxPressed = false; return }
        if formPressed { formPressed = false; form.mouseUp(at: inForm(p)) }
    }

    /// Typing in the box (Return breaks the line; Esc, Tab or a click elsewhere end it), else the focused value field.
    func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if var e = typing {
            if k == .escape || k == .tab { endTyping(); return true }
            let outcome = e.handleLines(k, modifiers: modifiers)
            typing = e
            guard outcome == .edited else { return true }
            // One undo step per typing run (the Mac TextBoxView onBegin / onChange).
            if !typed { typed = true; editor?.beginGesture() }
            boxText = e.string
            editor?.updateText("Edit Text") { $0.text = e.string }
            return true
        }
        return form.key(k, modifiers: modifiers)
    }

    func scroll(at p: CGPoint, dy: CGFloat, precise: Bool, modifiers: InputModifiers) -> Bool {
        p.y >= boxRowHeight && form.scroll(at: inForm(p), dy: dy, precise: precise, modifiers: modifiers)
    }

    func endTyping() {
        typing = nil
        typed = false
        boxText = editor?.textTemplate?.text
    }

    func resignFocus() { endTyping(); form.resignFocus() }
    func tick() { form.tick() }
    var isTyping: Bool { typing != nil }
}
