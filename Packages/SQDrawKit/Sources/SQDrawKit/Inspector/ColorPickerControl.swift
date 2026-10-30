import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQUIKit

/// The SQ color picker (SQUIKit `SQColorPickerView`) on the canvas, for every host (inspector color wells, monitor,
/// shell): the saturation/brightness square, the hue bar, the alpha bar (optional), the row with the color pill, the hex
/// capsule and the eyedropper, and the recent colors. Coordinates are the picker's own points (origin top left, the
/// popover chrome included); the host places it with `frame(anchor:in:)`, translates and routes events.
/// Recents: the host loads them (`SQColorRecents.load`) into `recents` and stores `value` with `SQColorRecents.remember`
/// when `commitRecent()` says so.
public struct ColorPickerControl: Sendable {
    public static let width: CGFloat = 232, pad: CGFloat = 12, gap: CGFloat = 10
    public static let barHeight: CGFloat = 10, barKnob: CGFloat = 14, fieldHeight: CGFloat = 140, fieldRadius: CGFloat = 6
    public static let fieldKnob: CGFloat = 10, rowHeight: CGFloat = 22, dot: CGFloat = 16, dotGap: CGFloat = 6
    public static let pill = CGSize(width: 38, height: 20), iconWidth: CGFloat = 24, captionHeight: CGFloat = 13

    public var value: SQColorValue
    public let showsAlpha: Bool
    /// The eyedropper button (hidden when the host cannot sample the screen).
    public var showsEyedropper: Bool
    /// Recent colors as `SQColorRecents` keys, newest first; the section is hidden while empty.
    public var recents: [String]
    public var hoverEyedropper = false
    public private(set) var hex: TextEditState?
    private var dragging: Part?
    private var changed = false

    public enum Part: Sendable, Equatable { case field, hue, alpha, hex, eyedropper, recent(Int) }
    /// What a press or key did: nothing, a new `value`, or the eyedropper button (the host samples and calls `pick`).
    public enum Outcome: Sendable, Equatable { case none, changed, eyedropper }

    public init(value: SQColorValue, showsAlpha: Bool = false, showsEyedropper: Bool = true, recents: [String] = []) {
        self.value = value; self.showsAlpha = showsAlpha; self.showsEyedropper = showsEyedropper; self.recents = recents
    }

    // MARK: Layout

    private var inner: CGFloat { Self.width - 2 * Self.pad }
    public var fieldFrame: CGRect { CGRect(x: Self.pad, y: Self.pad, width: inner, height: Self.fieldHeight) }
    public var hueFrame: CGRect {
        CGRect(x: Self.pad, y: fieldFrame.maxY + Self.gap, width: inner, height: Self.barHeight)
    }
    public var alphaFrame: CGRect? {
        showsAlpha ? CGRect(x: Self.pad, y: hueFrame.maxY + Self.gap, width: inner, height: Self.barHeight) : nil
    }
    private var rowY: CGFloat { (alphaFrame ?? hueFrame).maxY + Self.gap }
    public var pillFrame: CGRect {
        CGRect(x: Self.pad, y: rowY + (Self.rowHeight - Self.pill.height) / 2, width: Self.pill.width, height: Self.pill.height)
    }
    public var eyedropperFrame: CGRect? {
        showsEyedropper ? CGRect(x: Self.pad + inner - Self.iconWidth, y: rowY, width: Self.iconWidth, height: Self.rowHeight) : nil
    }
    public var hexFrame: CGRect {
        let x = pillFrame.maxX + 8
        let end = eyedropperFrame.map { $0.minX - 8 } ?? Self.pad + inner
        return CGRect(x: x, y: rowY, width: end - x, height: Self.rowHeight)
    }
    private var recentColors: [SQColorValue] { recents.compactMap { SQColorValue.parse(hex: $0) } }
    private var captionY: CGFloat { rowY + Self.rowHeight + Self.gap }
    public func recentFrame(_ i: Int) -> CGRect {
        CGRect(x: Self.pad + CGFloat(i) * (Self.dot + Self.dotGap), y: captionY + Self.captionHeight + Self.gap,
               width: Self.dot, height: Self.dot)
    }
    public var size: CGSize {
        let bottom = recentColors.isEmpty ? rowY + Self.rowHeight : recentFrame(0).maxY
        return CGSize(width: Self.width, height: bottom + Self.pad)
    }

    /// The popover frame for `anchor` (host points): below the anchor, above when it does not fit, kept inside
    /// `visible` (SQPopoverLogic: gap 4, margin 6, centered on the anchor).
    public func frame(anchor: CGRect, in visible: CGRect) -> CGRect {
        let s = size, gap: CGFloat = 4, margin: CGFloat = 6
        let area = visible.insetBy(dx: margin, dy: margin)
        var y = anchor.maxY + gap
        if y + s.height > area.maxY, anchor.minY - gap - s.height >= area.minY { y = anchor.minY - gap - s.height }
        let x = min(max(anchor.midX - s.width / 2, area.minX), max(area.minX, area.maxX - s.width))
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    public func part(at p: CGPoint) -> Part? {
        let k = (Self.barKnob - Self.barHeight) / 2
        if fieldFrame.contains(p) { return .field }
        if hueFrame.insetBy(dx: 0, dy: -k).contains(p) { return .hue }
        if let a = alphaFrame, a.insetBy(dx: 0, dy: -k).contains(p) { return .alpha }
        if hexFrame.contains(p) { return .hex }
        if let e = eyedropperFrame, e.contains(p) { return .eyedropper }
        for i in recentColors.indices where recentFrame(i).contains(p) { return .recent(i) }
        return nil
    }

    // MARK: Input

    public mutating func mouseDown(at p: CGPoint) -> Outcome {
        let hit = part(at: p)
        if hit != .hex { endHexEdit() }
        switch hit {
        case .field, .hue, .alpha:
            dragging = hit
            return track(p)
        case .hex:
            if hex == nil { hex = TextEditState(value.hex) }
            return .none
        case .eyedropper: return .eyedropper
        case .recent(let i):
            var n = recentColors[i]
            if !showsAlpha { n.a = 1 }
            return apply(n)
        case nil: return .none
        }
    }

    public mutating func mouseDragged(to p: CGPoint) -> Outcome { dragging == nil ? .none : track(p) }

    public mutating func mouseUp() { dragging = nil }

    public mutating func mouseMoved(to p: CGPoint) { hoverEyedropper = part(at: p) == .eyedropper }

    /// A key: the hex capsule while it edits (every valid text applies at once), else arrows nudge the last dragged
    /// part (0.01, 0.1 with Shift). Esc in the capsule ends the edit; the host closes the popover on Esc otherwise.
    public mutating func key(_ k: InputKey, modifiers: InputModifiers) -> (taken: Bool, outcome: Outcome) {
        if var e = hex {
            let out = e.handle(k, modifiers: modifiers)
            hex = e
            switch out {
            case .commit, .cancel: endHexEdit(); return (true, .none)
            case .edited:
                if let v = SQColorValue.parse(hex: e.string, keepingAlpha: value.a) { return (true, apply(v)) }
                return (true, .none)
            case .moved: return (true, .none)
            case .ignored: return (false, .none)
            }
        }
        let step = modifiers.contains(.shift) ? 0.1 : 0.01
        var v = value
        switch k {
        case .left: v.h = max(0, v.h - step)
        case .right: v.h = min(0.9999, v.h + step)
        case .up: v.b = min(1, v.b + step)
        case .down: v.b = max(0, v.b - step)
        default: return (false, .none)
        }
        return (true, apply(v))
    }

    /// The eyedropper picked `c` (the current alpha stays).
    public mutating func pick(_ c: SQColorValue) -> Outcome {
        var v = c
        v.a = value.a
        return apply(v)
    }

    /// The color gesture ended (popover closed, hex edit done): true when `value` changed since the last call, then
    /// it leads the recents and the host stores it.
    public mutating func commitRecent() -> Bool {
        guard changed else { return false }
        changed = false
        recents = SQColorRecents.adding(SQColorRecents.key(for: value), to: recents)
        return true
    }

    private mutating func endHexEdit() { hex = nil }

    private mutating func apply(_ v: SQColorValue) -> Outcome {
        guard v != value else { return .none }
        value = v
        changed = true
        return .changed
    }

    private mutating func track(_ p: CGPoint) -> Outcome {
        var v = value
        switch dragging {
        case .field:
            let r = fieldFrame
            v.s = Double(min(max((p.x - r.minX) / r.width, 0), 1))
            v.b = Double(1 - min(max((p.y - r.minY) / r.height, 0), 1))
        case .hue, .alpha:
            let r = hueFrame, k = Self.barKnob / 2
            let t = Double(min(max((p.x - r.minX - k) / (r.width - 2 * k), 0), 1))
            if dragging == .hue { v.h = min(t, 0.9999) } else { v.a = t }
        default: return .none
        }
        return apply(v)
    }

    // MARK: Drawing

    /// Draws the popover (chrome and content) with its top left at the current origin.
    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let bounds = CGRect(origin: .zero, size: size), radius = SQMenuLayout.cornerRadius
        c.shadow(roundedRect: bounds, radius: radius, blur: 10, dy: 4, DrawColor(0, 0, 0, 0.25))
        let bg = bounds.insetBy(dx: 0.25, dy: 0.25)
        c.fill(roundedRect: bg, radius: radius, t.overlay)
        c.stroke(roundedRect: bg, radius: radius, width: 0.5, t.inkFill(0.14))
        drawField(&c)
        drawBar(&c, hueFrame, alpha: false)
        if let a = alphaFrame { drawBar(&c, a, alpha: true) }
        drawPill(&c, t)
        drawHex(&c, t)
        if let e = eyedropperFrame {
            if hoverEyedropper { c.fill(roundedRect: e, radius: InspectorTokens.radius(e), t.fillHover) }
            let s: CGFloat = 14
            c.draw(icon: .eyedropper, at: CGPoint(x: e.midX - s / 2, y: e.midY - s / 2), size: s, t.label2)
        }
        let colors = recentColors
        guard !colors.isEmpty else { return }
        c.draw("Recent", at: CGPoint(x: Self.pad, y: captionY), fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3)
        for (i, v) in colors.enumerated() {
            let r = recentFrame(i)
            if v.a < 1 { Self.checker(&c, in: r, cell: 4, round: true) }
            c.fill(ellipseIn: r, Self.draw(v))
            c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: r.height / 2, width: 0.5, t.inkFill(0.14))
        }
    }

    public static func draw(_ v: SQColorValue) -> DrawColor {
        let c = v.rgb
        return DrawColor(Float(c.r), Float(c.g), Float(c.b), Float(v.a))
    }
    private static let checkerDark = DrawColor(0.30, 0.30, 0.30), checkerLight = DrawColor(0.45, 0.45, 0.45)

    /// The transparency checkerboard (`Theme.Palette.checker`), cells kept inside the capsule when `round`.
    static func checker(_ c: inout Canvas, in r: CGRect, cell: CGFloat, round: Bool) {
        c.fill(roundedRect: r, radius: round ? r.height / 2 : 0, checkerDark)
        c.saveGState(); c.clip(to: r)
        let rad = r.height / 2
        for y in 0..<Int((r.height / cell).rounded(.up)) {
            for x in 0..<Int((r.width / cell).rounded(.up)) where (x + y) % 2 == 1 {
                let q = CGRect(x: r.minX + CGFloat(x) * cell, y: r.minY + CGFloat(y) * cell, width: cell, height: cell)
                if round, !Self.inside(q, r, radius: rad) { continue }
                c.fill(q, checkerLight)
            }
        }
        c.restoreGState()
    }

    /// The cell's center lies inside the rounded rect `r`.
    private static func inside(_ q: CGRect, _ r: CGRect, radius: CGFloat) -> Bool {
        let cx = min(max(q.midX, r.minX + radius), r.maxX - radius), cy = min(max(q.midY, r.minY + radius), r.maxY - radius)
        let dx = q.midX - cx, dy = q.midY - cy
        return dx * dx + dy * dy <= radius * radius
    }

    /// Hue fill, white to clear left to right, clear to black top to bottom: per point exactly HSB(h, s, b).
    /// shortcut: 3 pt cells with the corners cut by the cell center, upgrade to a gradient quad kind (one quad) if the
    /// steps show.
    private func drawField(_ c: inout Canvas) {
        let r = fieldFrame, cell: CGFloat = 3
        let cols = Int((r.width / cell).rounded(.up)), rows = Int((r.height / cell).rounded(.up))
        for y in 0..<rows {
            for x in 0..<cols {
                let q = CGRect(x: r.minX + CGFloat(x) * cell, y: r.minY + CGFloat(y) * cell,
                               width: min(cell, r.maxX - r.minX - CGFloat(x) * cell),
                               height: min(cell, r.maxY - r.minY - CGFloat(y) * cell))
                guard Self.inside(q, r, radius: Self.fieldRadius) else { continue }
                let s = Double((q.midX - r.minX) / r.width), b = 1 - Double((q.midY - r.minY) / r.height)
                c.fill(q, Self.draw(SQColorValue(h: value.h, s: s, b: b)))
            }
        }
        let kr = CGRect(x: r.minX + CGFloat(value.s) * r.width - Self.fieldKnob / 2,
                        y: r.minY + CGFloat(1 - value.b) * r.height - Self.fieldKnob / 2, width: Self.fieldKnob, height: Self.fieldKnob)
        c.stroke(roundedRect: kr.insetBy(dx: -1, dy: -1), radius: kr.width / 2 + 1, width: 1, DrawColor(0, 0, 0, 0.5))
        c.stroke(roundedRect: kr, radius: kr.width / 2, width: 2, .white)
    }

    /// The hue or alpha bar: a capsule gradient (alpha over the checker) and the white knob.
    /// shortcut: one quad per point column, ends as filled half circles, upgrade with a gradient quad kind.
    private func drawBar(_ c: inout Canvas, _ r: CGRect, alpha: Bool) {
        let rad = r.height / 2
        func color(_ t: Double) -> DrawColor {
            if alpha { var v = value; v.a = t; return Self.draw(v) }
            return Self.draw(SQColorValue(h: min(t, 0.9999), s: 1, b: 1))
        }
        if alpha { Self.checker(&c, in: r, cell: 4, round: true) }
        c.fill(ellipseIn: CGRect(x: r.minX, y: r.minY, width: r.height, height: r.height), color(0))
        c.fill(ellipseIn: CGRect(x: r.maxX - r.height, y: r.minY, width: r.height, height: r.height), color(1))
        let span = r.width - 2 * rad
        var x = r.minX + rad
        while x < r.maxX - rad {
            let w = min(1, r.maxX - rad - x)
            c.fill(CGRect(x: x, y: r.minY, width: w, height: r.height), color(Double((x + w / 2 - r.minX - rad) / span)))
            x += 1
        }
        let k = Self.barKnob, t = alpha ? value.a : value.h
        let kr = CGRect(x: r.minX + CGFloat(t) * (r.width - k), y: r.midY - k / 2, width: k, height: k)
        c.shadow(roundedRect: kr, radius: k / 2, blur: 3, dy: 1, DrawColor(0, 0, 0, 0.9))
        c.fill(ellipseIn: kr, .white)
    }

    private func drawPill(_ c: inout Canvas, _ t: DrawTheme) {
        let r = pillFrame
        if value.a < 1 { Self.checker(&c, in: r, cell: 5, round: true) }
        c.fill(roundedRect: r, radius: r.height / 2, Self.draw(value))
        c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: r.height / 2, width: 0.5, t.trackHeaderLine)
    }

    private func drawHex(_ c: inout Canvas, _ t: DrawTheme) {
        let r = hexFrame, rad = InspectorTokens.radius(r), size = CGFloat(DrawTheme.TypeSize.body)
        c.fill(roundedRect: r, radius: rad, t.field)
        if hex != nil { c.fill(roundedRect: r, radius: rad, t.accentTint); InspectorDraw.focusLine(&c, r, radius: rad, t) }
        c.draw("#", in: CGRect(x: r.minX + 8, y: r.minY, width: 10, height: r.height), fontSize: size, t.label3, align: .left)
        let text = CGRect(x: r.minX + 17, y: r.minY, width: r.width - 23, height: r.height)
        if let e = hex {
            InspectorDraw.editText(&c, e, in: text, fontSize: size, color: t.label, alignRight: false, t)
        } else {
            c.draw(value.hex, in: text, fontSize: size, t.label, align: .left)
        }
    }
}
