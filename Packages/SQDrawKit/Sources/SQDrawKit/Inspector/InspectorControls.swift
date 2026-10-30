import Foundation
import SQCore
import SQUIKit

/// Control tokens of the portable inspector (`Theme.Metrics` / `Theme.State` / `Theme.Radius` of the Mac controls).
/// shortcut: literals of the Mac tokens at UI scale 1 (Theme is AppKit); ControlsGridTokenTests and the SQInspectorUI
/// token test keep them in step. Upgrade when SQUIKit's tokens move into a portable file.
public enum InspectorTokens {
    public static let capsule: Float = 22
    public static let checkbox: CGFloat = 14
    public static let checkboxRadius: CGFloat = 4
    public static let controlRadius: CGFloat = 6
    public static let innerRadius: CGFloat = 4
    public static let focusLineWidth: CGFloat = 1.5
    public static let disabledAlpha: Float = 0.4
    public static let sliderTrack: CGFloat = 2
    public static let sliderKnob: CGFloat = 10
    /// Keyframe ring (KeyframeToggleView): 14 pt slot, 10 pt diamond, 1.2 pt dot.
    public static let ringSlot: CGFloat = 14
    public static let ringDiamond: CGFloat = 10
    public static let ringDot: CGFloat = 1.2
    /// Controls animation switch (`ControlsMetrics.toggleSide`) and key-navigation chevrons (`IconButton.symbolSize`).
    public static let switchSide: CGFloat = 7
    public static let navIcon: CGFloat = 10
    /// Corner radius of a control body (6 pt, never more than half the height).
    public static func radius(_ r: CGRect) -> CGFloat { min(controlRadius, r.height / 2) }
}

extension DrawTheme {
    /// `Theme.Colors.field`: the number field / popup body.
    public var field: DrawColor { palette.isDark ? DrawColor.black.alpha(0.28) : DrawColor.black.alpha(0.05) }
    /// `Theme.Colors.fieldEdgeHover`.
    public var fieldEdgeHover: DrawColor { inkFill(0.18) }
    /// `Theme.Colors.accentTint`: an editing field, a selected row.
    public var accentTint: DrawColor { accent.alpha(palette.isDark ? 0.22 : 0.16) }
    public var focusLine: DrawColor { accent }
    /// `Theme.Colors.selection` / `Theme.Selection.fill`: a selected row (ink at .14 dark / .08 light).
    public var selection: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? 0.14 : 0.08)) }
    /// `Theme.Colors.graphPane`: an opened curve row and its pane.
    public var graphPane: DrawColor { DrawColor.white.alpha(0.03) }
    /// `Theme.Colors.fieldEdge`: a plot's grid and baseline.
    public var fieldEdge: DrawColor { inkFill(0.10) }
    /// `Theme.Colors.red` / `green`, `Theme.Palette.channelBlue`: the curve channels.
    public var red: DrawColor { Self.color(palette.red) }
    public var warning: DrawColor { Self.color(palette.warning) }
    public var green: DrawColor { DrawColor(hex: 0x30D158) }
    public var channelBlue: DrawColor { DrawColor(hex: 0x4D8CFF) }
    /// `Theme.Palette.channelDots`: master, red, green, blue.
    public var channelDots: [DrawColor] { [DrawColor.white.alpha(0.9), red, green, channelBlue] }
    /// `Theme.Colors.keyframe`: a key glyph in the lanes; `keyframeTracked` a Magic mask's tracked frame (label3).
    public var keyframe: DrawColor { Self.color(palette.keyframe) }
    public var keyframeTracked: DrawColor { label3 }
    /// `Theme.Colors.graphGrid` / `graphHandleLine`: the speed graph's baseline and dashed guides, a handle's stem.
    public var graphGrid: DrawColor { DrawColor.white.alpha(0.06) }
    public var graphHandleLine: DrawColor { DrawColor.white.alpha(0.60) }
    /// `Theme.Palette.graphCurve`: the third and later rows of one speed graph.
    public var graphCurve: [DrawColor] {
        [0xFF8FC0, 0xFF5A4E, 0x3FD0E0, 0x5FE3B8, 0xC58AF9, 0x5FD068, 0xFF9F0A, 0xFFD60A, 0x64B5FF, 0x9FD98A, 0xE0C080, 0xB0B0B0]
            .map { DrawColor(hex: $0) }
    }
    /// `Theme.OnPicture.shadow`: the dark edge around a handle.
    public var handleShadow: DrawColor { DrawColor.black.alpha(0.5) }
}

/// Drawing of the inspector controls, translated from the Mac views (ring, navigation, checkbox, popup, slider, well).
public enum InspectorDraw {
    /// Keyboard focus (sq.css `.foc`): inner 1.5 pt accent line.
    public static func focusLine(_ c: inout Canvas, _ r: CGRect, radius: CGFloat, _ t: DrawTheme) {
        let w = InspectorTokens.focusLineWidth
        c.stroke(roundedRect: r.insetBy(dx: w, dy: w), radius: max(radius - w, 0), width: w, t.focusLine)
    }

    /// A diamond `size` pt corner to corner (KeyframeToggleView.diamondPath).
    public static func diamond(_ center: CGPoint, size: CGFloat) -> [CGPoint] {
        let h = size / 2
        return [CGPoint(x: center.x, y: center.y - h), CGPoint(x: center.x + h, y: center.y),
                CGPoint(x: center.x, y: center.y + h), CGPoint(x: center.x - h, y: center.y)]
    }

    /// The animate ring of a keyframable row (KeyframeToggleView.drawRing).
    public static func ring(_ c: inout Canvas, _ state: ScrubKeyframeState, hovering: Bool, center p: CGPoint, _ t: DrawTheme) {
        let d = diamond(p, size: InspectorTokens.ringDiamond)
        let r = InspectorTokens.ringDot
        let dot = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        switch state {
        case .none:
            let tint = hovering ? t.label2 : t.label3
            c.stroke(polygon: d, width: 1.2, tint); c.fill(ellipseIn: dot, tint)
        case .between:
            c.stroke(polygon: d, width: 1.2, t.accent); c.fill(ellipseIn: dot, t.accent)
        case .onKey:
            c.fill(polygon: d, t.accent); c.stroke(polygon: d, width: 1.2, t.accent); c.fill(ellipseIn: dot, .white)
        }
    }

    /// The animation switch of a Controls row (AnimateDiamondView `.an`): a 7 pt square turned 45 degrees; a hollow 1.2 pt
    /// outline while the parameter is static, filled accent while it has keys.
    public static func animateSwitch(_ c: inout Canvas, animated: Bool, hovering: Bool, center p: CGPoint, _ t: DrawTheme) {
        let side = InspectorTokens.switchSide
        let h = side * 2.0.squareRoot() / 2
        if animated {
            c.fill(polygon: diamond(p, size: 2 * h), t.accent)
        } else {
            let inner = (side - 1.2) * 2.0.squareRoot()
            c.stroke(polygon: diamond(p, size: inner), width: 1.2, hovering ? t.label2 : t.label3)
        }
    }

    /// Prev / key / next in three equal slots (KeyframeNavigationView), `rect` = the navigation frame. Like the Mac
    /// IconButtons: Lucide chevrons (10 pt), the key diamond (`KeyframeToggleView.diamondImage`: 9 pt, 1.1 pt line, a
    /// 1.1 pt dot, cut out of the fill on a key; `behind` = the row color showing through), disabled ones dimmed.
    public static func navigation(_ c: inout Canvas, _ s: KeyframeControlState, in rect: CGRect, enabled: Bool, behind: DrawColor? = nil,
                                  _ t: DrawTheme) {
        guard s.showsNavigation else { return }
        let w = rect.width / 3
        func dim(_ col: DrawColor, _ on: Bool) -> DrawColor { on && enabled ? col : col.alpha(col.a * InspectorTokens.disabledAlpha) }
        let prev = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        let next = CGRect(x: rect.minX + 2 * w, y: rect.minY, width: w, height: rect.height)
        let side = InspectorTokens.navIcon
        for (r, icon, on) in [(prev, SQIcon.chevronLeft, s.canGoPrevious), (next, .chevronRight, s.canGoNext)] {
            c.draw(icon: icon, at: CGPoint(x: (r.midX - side / 2).rounded(), y: (r.midY - side / 2).rounded()), size: side, dim(t.label2, on))
        }
        let mid = CGPoint(x: rect.minX + 1.5 * w, y: rect.midY)
        let d = diamond(mid, size: 9)
        let kt = dim(s.keyIsOn ? t.accent : t.label3, s.canToggleKey)
        let dotR: CGFloat = 1.1
        let dot = CGRect(x: mid.x - dotR, y: mid.y - dotR, width: 2 * dotR, height: 2 * dotR)
        if s.keyIsOn {
            c.fill(polygon: d, kt); c.stroke(polygon: d, width: 1.1, kt)
            c.fill(ellipseIn: dot, behind ?? t.panel)
        } else {
            c.stroke(polygon: d, width: 1.1, kt); c.fill(ellipseIn: dot, kt)
        }
    }

    public enum Direction: Sendable { case left, right, down, up }

    /// A chevron (Lucide chevron-*): two 1.5 pt strokes in a 10 pt box centered in `rect`.
    public static func chevron(_ c: inout Canvas, in rect: CGRect, direction: Direction, _ color: DrawColor, size: CGFloat = 8) {
        let m = CGPoint(x: rect.midX, y: rect.midY), h = size / 2, q = size / 4
        let pts: [CGPoint]
        switch direction {
        case .left: pts = [CGPoint(x: m.x + q, y: m.y - h), CGPoint(x: m.x - q, y: m.y), CGPoint(x: m.x + q, y: m.y + h)]
        case .right: pts = [CGPoint(x: m.x - q, y: m.y - h), CGPoint(x: m.x + q, y: m.y), CGPoint(x: m.x - q, y: m.y + h)]
        case .down: pts = [CGPoint(x: m.x - h, y: m.y - q), CGPoint(x: m.x, y: m.y + q), CGPoint(x: m.x + h, y: m.y - q)]
        case .up: pts = [CGPoint(x: m.x - h, y: m.y + q), CGPoint(x: m.x, y: m.y - q), CGPoint(x: m.x + h, y: m.y + q)]
        }
        c.strokePolyline(pts, width: 1.5, color)
    }

    /// The SQ checkbox (SQCheckbox.draw): 14 pt box, 4 pt corners; on = accent fill and a white check, mixed = a dash.
    public enum CheckState: Sendable { case off, on, mixed }
    public static func checkbox(_ c: inout Canvas, _ s: CheckState, box: CGRect, hovering: Bool, pressed: Bool, enabled: Bool,
                                focused: Bool = false, _ t: DrawTheme) {
        let a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        let fill: DrawColor
        if s == .on { fill = pressed ? t.accentFill.lifted(0.35) : (hovering && enabled ? t.accentFill.lifted(0.2) : t.accentFill) }
        else { fill = pressed ? t.fillPressed : (hovering && enabled ? t.fillHover : t.fill) }
        let r = InspectorTokens.checkboxRadius
        c.fill(roundedRect: box, radius: r, fill.alpha(fill.a * a))
        switch s {
        case .on:
            let w = box.width, h = box.height
            c.strokePolyline([CGPoint(x: box.minX + w * 0.24, y: box.minY + h * 0.52), CGPoint(x: box.minX + w * 0.43, y: box.minY + h * 0.72),
                              CGPoint(x: box.minX + w * 0.78, y: box.minY + h * 0.30)], width: 1.5, DrawColor.white.alpha(a))
        case .off, .mixed:
            c.stroke(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), radius: r, width: 0.5, t.trackHeaderLine.alpha(t.trackHeaderLine.a * a))
            if s == .mixed {
                c.fill(CGRect(x: box.minX + box.width * 0.27, y: box.midY - 0.75, width: box.width * 0.46, height: 1.5), t.label.alpha(a))
            }
        }
        if focused { focusLine(&c, box, radius: r, t) }
    }

    /// The SQ popup button (SQPopup): field body, title left, chevron-down right; `plain` = no body at rest (grid rows).
    public static func popup(_ c: inout Canvas, title: String, in rect: CGRect, hovering: Bool, open: Bool, enabled: Bool,
                             plain: Bool = false, maxHeight: CGFloat = CGFloat(InspectorTokens.capsule), fontSize: CGFloat? = nil,
                             _ t: DrawTheme) {
        let h = min(maxHeight, rect.height)
        let box = CGRect(x: rect.minX, y: rect.minY + ((rect.height - h) / 2).rounded(), width: rect.width, height: h)
        let r = InspectorTokens.radius(box)
        let a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        if !plain || hovering || open {
            let base = open ? t.fillPressed : (hovering && enabled ? t.fillHover : t.fill)
            c.fill(roundedRect: box, radius: r, base.alpha(base.a * a))
        }
        let size = fontSize ?? CGFloat(DrawTheme.TypeSize.body)
        let chevronW: CGFloat = 16
        c.draw(title, in: CGRect(x: box.minX + 10, y: box.minY, width: max(box.width - 10 - chevronW, 0), height: box.height),
               fontSize: size, t.label.alpha(t.label.a * a))
        popupChevron(&c, in: CGRect(x: box.maxX - 7 - 7, y: box.minY, width: 7, height: box.height), t, alpha: a)
    }

    /// `SQPopup.drawChevron`: a 1.2 pt round stroke in a 7 pt box, `#999` on a dark palette (the chevron is 4.6 wide, 2.3 tall).
    public static func popupChevron(_ c: inout Canvas, in r: CGRect, _ t: DrawTheme, alpha a: Float = 1) {
        let base = t.palette.isDark ? DrawColor(hex: 0x999999) : t.label3
        let m = r.midY
        c.strokePolyline([CGPoint(x: r.minX + 1.2, y: m - 1.1), CGPoint(x: r.minX + 3.5, y: m + 1.2), CGPoint(x: r.minX + 5.8, y: m - 1.1)],
                         width: 1.2, base.alpha(base.a * a))
    }

    /// The SQ slider (NumericSlider): 2 pt track, accent fill up to the knob, 10 pt knob with a soft shadow.
    public static func slider(_ c: inout Canvas, fraction: Double, in rect: CGRect, enabled: Bool, _ t: DrawTheme) {
        let k = InspectorTokens.sliderKnob, tr = InspectorTokens.sliderTrack
        let x0 = rect.minX + k / 2, x1 = rect.maxX - k / 2
        let f = CGFloat(max(0, min(1, fraction)))
        let kx = x0 + (x1 - x0) * f
        let a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        // `SQSlider.draw`: the track spans the whole frame (the knob travels inside it), the accent part runs to the knob center.
        let track = CGRect(x: rect.minX, y: rect.midY - tr / 2, width: rect.width, height: tr)
        c.fill(roundedRect: track, radius: tr / 2, t.fill.alpha(t.fill.a * a))
        c.fill(roundedRect: CGRect(x: rect.minX, y: track.minY, width: kx - rect.minX, height: tr), radius: tr / 2, t.accent.alpha(a))
        let knob = CGRect(x: kx - k / 2, y: rect.midY - k / 2, width: k, height: k)
        c.shadow(roundedRect: knob, radius: k / 2, blur: 1.5, dy: 0.5, DrawColor.black.alpha(0.6 * a))
        c.fill(ellipseIn: knob, DrawColor(hex: 0xF2F2F2, alpha: a))
    }

    /// Fraction of a slider for a pointer at `x` (inverse of `slider`).
    public static func sliderFraction(x: CGFloat, in rect: CGRect) -> Double {
        let k = InspectorTokens.sliderKnob
        let x0 = rect.minX + k / 2, x1 = rect.maxX - k / 2
        guard x1 > x0 else { return 0 }
        return Double(max(0, min(1, (x - x0) / (x1 - x0))))
    }

    /// A color swatch (SQColorWell): the color in a rounded box with a hairline edge.
    public static func colorWell(_ c: inout Canvas, _ color: DrawColor, in rect: CGRect, hovering: Bool, _ t: DrawTheme) {
        let h = min(CGFloat(InspectorTokens.capsule) - 4, rect.height)
        let box = CGRect(x: rect.minX, y: rect.minY + ((rect.height - h) / 2).rounded(), width: rect.width, height: h)
        c.fill(roundedRect: box, radius: InspectorTokens.innerRadius, color)
        c.stroke(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), radius: InspectorTokens.innerRadius, width: 0.5,
                 hovering ? t.fieldEdgeHover : t.trackHeaderLine)
    }

    /// The text of an open editor: selection tint, text, caret (1 pt accent bar).
    public static func editText(_ c: inout Canvas, _ e: TextEditState, in r: CGRect, fontSize size: CGFloat, color: DrawColor,
                                alignRight: Bool, _ t: DrawTheme) {
        let s = e.string
        let w = c.size(of: s, fontSize: size).width
        let x0 = alignRight ? max(r.minX, r.maxX - w) : r.minX
        func xAt(_ i: Int) -> CGFloat { x0 + c.size(of: String(e.text.prefix(i)), fontSize: size).width }
        let lineH = c.size(of: "0", fontSize: size).height
        let y = r.midY - lineH / 2
        if e.hasSelection {
            let sel = e.selection
            c.fill(CGRect(x: xAt(sel.lowerBound), y: y, width: xAt(sel.upperBound) - xAt(sel.lowerBound), height: lineH), t.accent.alpha(0.45))
        }
        c.saveGState(); c.clip(to: r)
        c.draw(s, at: CGPoint(x: x0, y: y), fontSize: size, color)
        c.restoreGState()
        let caret = CGRect(x: xAt(e.hasSelection ? e.selection.lowerBound : e.caret), y: y, width: 1, height: lineH)
        if !e.hasSelection { c.fill(caret, t.accent) }
        HostRequests.current.caret = c.px(caret)
    }

    /// Caret index for a click at `x` in an editor drawn by `editText`.
    public static func caretIndex(_ c: Canvas, _ e: TextEditState, x: CGFloat, in r: CGRect, fontSize size: CGFloat, alignRight: Bool) -> Int {
        let w = lineWidth(c, e.string, size)
        let x0 = alignRight ? max(r.minX, r.maxX - w) : r.minX
        var best = 0, bestD = CGFloat.greatestFiniteMagnitude
        for i in 0...e.text.count {
            let d = abs(x0 + lineWidth(c, String(e.text.prefix(i)), size) - x)
            if d < bestD { best = i; bestD = d }
        }
        return best
    }

    /// Width of `s`; without a glyph atlas (headless tests) an average advance of 0.55 em per character, like
    /// `TextMeasure`, so caret placement stays ordered.
    private static func lineWidth(_ c: Canvas, _ s: String, _ size: CGFloat) -> CGFloat {
        c.atlas == nil ? CGFloat(s.count) * size * 0.55 : c.size(of: s, fontSize: size).width
    }

    /// The open editor of a multi-line box (the text clip's text box): line `i` sits `i * lineHeight` below `r.minY`;
    /// the selection is tinted per line, the caret is a 1 pt accent bar on its line. Clipped to `r`.
    public static func editLines(_ c: inout Canvas, _ e: TextEditState, in r: CGRect, lineHeight: CGFloat, fontSize size: CGFloat,
                                 color: DrawColor, _ t: DrawTheme) {
        let starts = e.lineStarts
        let glyphH = c.size(of: "0", fontSize: size).height
        let sel = e.selection
        c.saveGState(); c.clip(to: r)
        for (l, start) in starts.enumerated() {
            let end = l + 1 < starts.count ? starts[l + 1] - 1 : e.text.count
            let line = Array(e.text[start..<end])
            let y = r.minY + CGFloat(l) * lineHeight + ((lineHeight - glyphH) / 2).rounded()
            func xAt(_ i: Int) -> CGFloat { r.minX + lineWidth(c, String(line.prefix(i - start)), size) }
            if e.hasSelection, sel.lowerBound <= end, sel.upperBound >= start {
                let a = max(sel.lowerBound, start), b = min(sel.upperBound, end)
                // A selected line break shows as a small tail after the line.
                let tail: CGFloat = sel.upperBound > end && l + 1 < starts.count ? 4 : 0
                c.fill(CGRect(x: xAt(a), y: y, width: xAt(b) - xAt(a) + tail, height: glyphH), t.accent.alpha(0.45))
            }
            c.draw(String(line), at: CGPoint(x: r.minX, y: y), fontSize: size, color)
            let at = e.hasSelection ? sel.lowerBound : e.caret
            if at >= start, at <= end {
                let caret = CGRect(x: xAt(at), y: y, width: 1, height: glyphH)
                if !e.hasSelection { c.fill(caret, t.accent) }
                HostRequests.current.caret = c.px(caret)
            }
        }
        c.restoreGState()
    }

    /// Caret index for a click at `p` in an editor drawn by `editLines`: the line under `p.y` (clamped), then the
    /// nearest character edge to `p.x` on it.
    public static func caretIndex(_ c: Canvas, _ e: TextEditState, at p: CGPoint, in r: CGRect, lineHeight: CGFloat,
                                  fontSize size: CGFloat) -> Int {
        let starts = e.lineStarts
        let l = max(0, min(starts.count - 1, Int(((p.y - r.minY) / max(lineHeight, 1)).rounded(.down))))
        let start = starts[l], end = l + 1 < starts.count ? starts[l + 1] - 1 : e.text.count
        let line = Array(e.text[start..<end])
        var best = start, bestD = CGFloat.greatestFiniteMagnitude
        for i in 0...line.count {
            let d = abs(r.minX + lineWidth(c, String(line.prefix(i)), size) - p.x)
            if d < bestD { best = start + i; bestD = d }
        }
        return best
    }
}
