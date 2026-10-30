import AppKit
import SQCore

/// Binds one `AppearanceRow` (check, color, main value) to the selected items of the Graphics editor. Used by the
/// Graphics panel (Fill, Outline, Shadow) and by Controls > Graphic (Fill, Outline): one wiring for both places.
@MainActor
enum GraphicAppearanceBinding {
    /// Wires the row's controls and returns the loader that shows the selection's state: `on` / color / `value` read nil
    /// when the items differ (dash, empty swatch, empty field). Each control is one undo step per gesture.
    static func bind(_ row: AppearanceRow, title: String, editor: GraphicsEditor?, on: @escaping () -> Bool?,
                     setOn: @escaping (Bool) -> Void, colorKind: String, colorKey: String, value: @escaping () -> Double?,
                     setValue: @escaping (Double) -> Void, unit: String, reset: Double) -> () -> Void {
        bind(row, title: title, editor: { [weak editor] in editor }, on: on, setOn: setOn, colorKind: colorKind,
             colorKey: colorKey, value: value, setValue: setValue, unit: unit, reset: reset)
    }

    /// The same with an editor that is looked up on every use (a host that gets its editor after it was built).
    static func bind(_ row: AppearanceRow, title: String, editor: @escaping () -> GraphicsEditor?, on: @escaping () -> Bool?,
                     setOn: @escaping (Bool) -> Void, colorKind: String, colorKey: String, value: @escaping () -> Double?,
                     setValue: @escaping (Double) -> Void, unit: String, reset: Double) -> () -> Void {
        let checkTarget = ActionTarget { [weak row] in
            guard let row else { return }
            editor()?.beginGesture()
            setOn(row.check.state != .off)
        }
        row.check.allowsMixedState = false
        row.check.target = checkTarget; row.check.action = #selector(ActionTarget.fire)
        keep(checkTarget, on: row.check)
        row.well.showsAlpha = true
        row.well.onOpen = { editor()?.beginGesture() }
        let wellTarget = ActionTarget { [weak row] in
            guard let row, let c = GraphicsPanelView.effectColor(row.well.color) else { return }
            editor()?.setColor(kind: colorKind, key: colorKey, c)
        }
        row.well.target = wellTarget; row.well.action = #selector(ActionTarget.fire)
        keep(wellTarget, on: row.well)
        row.value.unit = unit
        row.value.decimals = 0
        row.value.defaultValue = reset
        row.value.setAccessibilityLabel(title)
        row.value.onBegin = { editor()?.beginGesture() }
        row.value.onChange = { v in setValue(v) }
        return { [weak row] in
            guard let e = editor(), let row else { return }
            let state = on()
            let c = e.color(kind: colorKind, key: colorKey)
            let v = value()
            row.set(on: state ?? true, color: c.map(GraphicsPanelView.nsColor), value: v)
            row.setMixed(on: state == nil, color: c == nil && state != false)
            if !row.value.isEditing && !row.value.isDragging { row.value.isMixed = v == nil && state != false }
        }
    }

    /// Fill of shape items: on / off, color, opacity. The opacity is written per item, so items of different colors keep them.
    static func bindFill(_ row: AppearanceRow, editor: @escaping () -> GraphicsEditor?) -> () -> Void {
        let kind = ClipEffect.shapeEffectKind, key = ClipEffect.shapeFillColorKey
        return bind(row, title: "Fill", editor: editor,
                    on: { editor()?.shapeValue(ClipEffect.shapeFillKey).map { $0 >= 0.5 } },
                    setOn: { editor()?.setShapeValue(ClipEffect.shapeFillKey, $0 ? 1 : 0) },
                    colorKind: kind, colorKey: key,
                    value: { editor()?.colorAlpha(kind: kind, key: key).map { $0 * 100 } },
                    setValue: { editor()?.setColorAlpha(kind: kind, key: key, $0 / 100) }, unit: "%", reset: 100)
    }

    /// Outline of shape items: on / off, color, width.
    static func bindOutline(_ row: AppearanceRow, editor: @escaping () -> GraphicsEditor?) -> () -> Void {
        let width = GraphicsEditor.Property.shape(ClipEffect.shapeStrokeWidthKey)
        return bind(row, title: "Outline", editor: editor,
                    on: { editor()?.shapeValue(ClipEffect.shapeStrokeKey).map { $0 >= 0.5 } },
                    setOn: { editor()?.setShapeValue(ClipEffect.shapeStrokeKey, $0 ? 1 : 0) },
                    colorKind: ClipEffect.shapeEffectKind, colorKey: ClipEffect.shapeStrokeColorKey,
                    value: { editor()?.value(width) },
                    setValue: { editor()?.setValue(width, max($0, 0)) }, unit: "px", reset: 8)
    }

    private static func keep(_ t: ActionTarget, on v: NSView) {
        objc_setAssociatedObject(v, &ActionTarget.key, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
