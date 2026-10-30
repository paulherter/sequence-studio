import Foundation
import SQCore
import SQUIKit

/// The SQ text field (SQTextField, sq.css `.fld`) on the canvas: a 22 pt capsule with the `field` fill, the text centered
/// or leading; a click opens the editor with everything selected, Enter or a click elsewhere commits, Esc cancels.
public struct TextFieldControl: Sendable {
    public var text: String
    public var alignment: Alignment = .center
    public enum Alignment: Sendable { case left, center, right
        public var listAlign: DrawList.TextAlign { switch self { case .left: .left; case .center: .center; case .right: .right } }
    }
    public var fontSize = CGFloat(DrawTheme.TypeSize.caption)
    public var isEnabled = true
    /// The dialog field (`SQDialog.makeField`): the whole 28 pt row, 6 pt corners, no hairline (inspector fields are 22 pt capsules).
    public var dialogStyle = false
    public var hovering = false
    /// The quiet search field (`SQSearchField`): the `fill2` body (0.06 ink) and no hairline.
    public var quiet = false
    /// Text inset from the frame's side: 6, or 8 for a dialog field whose frame bleeds 2 pt past its alignment rect.
    public var textInset: CGFloat = 6
    /// Gray text in the empty field (the Mac placeholder string).
    public var placeholder = ""
    public private(set) var editor: TextEditState?
    public var isEditing: Bool { editor != nil }

    public init(text: String = "") { self.text = text }

    /// A press: opens the editor (all selected); a press inside an open editor places the caret.
    /// `clickCount`: a double click selects the word under the caret, a triple click everything (the Mac field editor).
    public mutating func mouseDown(caret: Int? = nil, clickCount: Int = 1) {
        guard isEnabled else { return }
        if editor == nil { editor = TextEditState(text); return }
        guard let caret else { return }
        editor?.place(caret)
        if clickCount == 2 { editor?.selectWord(at: caret) } else if clickCount >= 3 { editor?.selectAll() }
    }

    /// The pointer moved with the button down inside the open editor: the selection runs from the press to `caret` (the Mac
    /// field editor). `from` is the caret index of the press when the editor opened with that same press (all selected).
    public mutating func mouseDragged(caret: Int, from start: Int? = nil) {
        guard editor != nil else { return }
        if let start { editor?.place(start) }
        editor?.place(caret, extend: true)
    }

    /// A key while editing. Returns the committed text on Enter (and on Tab, which the caller also uses to move focus).
    public mutating func key(_ k: InputKey, modifiers: InputModifiers) -> String? {
        guard var e = editor else { return nil }
        if k == InputKey.tab { return commit() }
        let out = e.handle(k, modifiers: modifiers)
        editor = e
        switch out {
        case .commit: return commit()
        case .cancel: editor = nil; return nil
        default: return nil
        }
    }

    /// Ends editing and hands out the typed text (nil when nothing was open).
    public mutating func commit() -> String? {
        guard let e = editor else { return nil }
        editor = nil
        text = e.string
        return text
    }

    public mutating func cancel() { editor = nil }

    /// The capsule `draw` puts in `bounds`.
    public static func box(in bounds: CGRect) -> CGRect {
        let h = min(CGFloat(InspectorTokens.capsule), bounds.height)
        return CGRect(x: bounds.minX, y: bounds.minY + ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }

    /// Where `draw` puts the text inside `bounds`.
    public static func textRect(in bounds: CGRect) -> CGRect { box(in: bounds).insetBy(dx: 6, dy: 0) }

    /// The caret index under `x` for a press inside the open editor drawn in `bounds` (nil while closed): pass it to
    /// `mouseDown(caret:)`.
    public func caretIndex(_ c: Canvas, x: CGFloat, in bounds: CGRect) -> Int? {
        guard let e = editor else { return nil }
        return InspectorDraw.caretIndex(c, e, x: x, in: (dialogStyle ? bounds : Self.box(in: bounds)).insetBy(dx: textInset, dy: 0), fontSize: fontSize, alignRight: alignment == .right)
    }

    public func draw(_ c: inout Canvas, in bounds: CGRect, theme t: DrawTheme, focused: Bool) {
        let box = dialogStyle ? bounds : Self.box(in: bounds)
        let dim: Float = isEnabled ? 1 : InspectorTokens.disabledAlpha
        let radius = dialogStyle ? CGFloat(DrawTheme.Radius.control) : InspectorTokens.radius(box)
        c.fill(roundedRect: box, radius: radius, quiet ? t.inkFill(0.06).alpha(t.inkFill(0.06).a * dim) : t.field.alpha(t.field.a * dim))
        if isEditing { c.fill(roundedRect: box, radius: radius, t.accentTint) }
        if hovering, isEnabled, !isEditing {
            c.stroke(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5, width: 1, t.fieldEdgeHover)
        } else if !dialogStyle, !quiet {
            c.stroke(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, t.trackHeaderLine.alpha(t.trackHeaderLine.a * dim))
        }
        if focused || isEditing { InspectorDraw.focusLine(&c, box, radius: radius, t) }
        let inner = (dialogStyle ? bounds : Self.box(in: bounds)).insetBy(dx: textInset, dy: 0)
        // `setQuietPlaceholder` / `placeholderString`: label3 while the field (or its open editor) is empty.
        if !placeholder.isEmpty, (editor?.string ?? text).isEmpty {
            c.draw(placeholder, in: inner, fontSize: fontSize, t.label3.alpha(t.label3.a * dim), align: alignment.listAlign)
        }
        if let e = editor {
            InspectorDraw.editText(&c, e, in: inner, fontSize: fontSize, color: t.label, alignRight: alignment == .right, t)
            return
        }
        c.draw(text, in: inner, fontSize: fontSize, t.label.alpha(t.label.a * dim), align: alignment.listAlign)
    }
}

extension InspectorDraw {
    /// SQButton's quiet look: `fill` body (hover `fillHover`, pressed `fillPressed`), 11 pt padding, `label` title;
    /// `accent` = the one filled blue variant.
    public static let buttonPadding: CGFloat = 11

    /// The button's natural width for `title` (SQButton.intrinsicContentSize).
    public static func buttonWidth(_ c: Canvas, title: String) -> CGFloat {
        ceil(c.size(of: title, fontSize: CGFloat(DrawTheme.TypeSize.body)).width + buttonPadding * 2)
    }

    public static func button(_ c: inout Canvas, title: String, in rect: CGRect, hovering: Bool, pressed: Bool, enabled: Bool,
                              accent: Bool = false, height: CGFloat = CGFloat(InspectorTokens.capsule), _ t: DrawTheme) {
        let h = min(height, rect.height)
        let box = CGRect(x: rect.minX, y: rect.minY + ((rect.height - h) / 2).rounded(), width: rect.width, height: h)
        let a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        let base: DrawColor
        if accent { base = pressed ? t.accentFill.lifted(0.35) : (hovering && enabled ? t.accentFill.lifted(0.2) : t.accentFill) }
        else { base = pressed ? t.fillPressed : (hovering && enabled ? t.fillHover : t.fill) }
        c.fill(roundedRect: box, radius: InspectorTokens.radius(box), base.alpha(base.a * a))
        let text = accent ? DrawColor.white : t.label
        c.draw(title, in: box.insetBy(dx: 4, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.body), text.alpha(text.a * a), align: .center)
    }

    /// The thin progress bar (TranscribeProgressBar): `fill` track, `accentFill` share, 2 pt ends.
    public static func progress(_ c: inout Canvas, fraction: Double, in rect: CGRect, _ t: DrawTheme) {
        let r = min(2, rect.height / 2)
        c.fill(roundedRect: rect, radius: r, t.fill)
        let w = rect.width * CGFloat(max(0, min(1, fraction)))
        if w > 0 { c.fill(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), radius: r, t.accentFill) }
    }
}

extension InputKey {
    /// Tab arrives as the character "\t" (no own case, so the hosts' exhaustive key switches stay valid): it moves focus
    /// to the next field, Shift+Tab to the previous one.
    public static let tab = InputKey.character("\t")
}
