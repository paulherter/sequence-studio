import Foundation
import SQCore
import SQDrawKit
import SQUIKit

/// The viewer header of the Color page as shared-toolkit draw code (Windows; translated from `ColorViewerHeaderView`):
/// the graded clip's name and "n of m" at the left, Before | After | Split and the more-actions button at the right,
/// a hairline at the bottom. The content comes from `ColorGradeController.viewerHeaderContent`, the segment calls
/// `setCompare`, the more button opens the viewer menu (`menuItems`: Copy Grade / Paste Grade, as the Mac `showViewerMenu`).
/// The clip name draws in the atlas's Medium face (the Mac `bodyStrong`, as the timeline's clip names).
@MainActor
public final class ColorViewerHeaderDraw {
    public enum Control: Hashable, Sendable { case compare(ColorCompareMode), more }

    public let controller: ColorGradeController
    public var theme = DrawTheme()
    public var size = CGSize(width: 600, height: CGFloat(DrawTheme.Metrics.panelHeader))
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    private(set) var hover: Control?

    public init(controller: ColorGradeController) { self.controller = controller }

    static let right = CGFloat(DrawTheme.Spacing.sm)
    static let textLeft: CGFloat = 12
    /// SQSegmented (compact): a segment is its label plus 20, 1 pt between the track edge and the segments.
    static let segmentPadding: CGFloat = 20
    static let trackPadding: CGFloat = 1
    /// `Theme.Spacing.iconToLabel` between the segment and the more button; the button is `barIconWidth` wide.
    static let moreGap: CGFloat = 6
    static let moreWidth: CGFloat = 24
    /// The segment widths from the canvas the header drew last (before any draw: 7 points per letter).
    private var segmentWidths: [CGFloat] = ColorCompareMode.allCases.map { CGFloat($0.title.count) * 7 + ColorViewerHeaderDraw.segmentPadding }

    /// The controls and their frames, right to left: more, then the segments (their drawn shapes inside the track).
    func frames() -> [(Control, CGRect)] {
        let h = size.height, ch = CGFloat(DrawTheme.Metrics.capsule)
        let y = ((h - ch) / 2).rounded()
        var x = size.width - Self.right - Self.moreWidth
        var out: [(Control, CGRect)] = [(.more, CGRect(x: x, y: y, width: Self.moreWidth, height: ch))]
        x -= Self.moreGap + Self.trackPadding
        for m in ColorCompareMode.allCases.reversed() {
            let w = segmentWidths[m.rawValue]
            x -= w
            out.append((.compare(m), CGRect(x: x, y: y + Self.trackPadding, width: w, height: ch - 2 * Self.trackPadding)))
        }
        return out
    }

    /// The segment's track around the segment frames of `fr`.
    func trackRect(_ fr: [(Control, CGRect)]) -> CGRect {
        let segs = fr.compactMap { if case .compare = $0.0 { $0.1 } else { nil } }
        guard let first = segs.min(by: { $0.minX < $1.minX }), let last = segs.max(by: { $0.minX < $1.minX }) else { return .null }
        return first.union(last).insetBy(dx: -Self.trackPadding, dy: -Self.trackPadding)
    }

    /// A press or hover anywhere in a segment's column counts (the track padding and the full header height, as
    /// SQSegmented `columnRect`); the more button by its frame.
    func control(at p: CGPoint) -> Control? {
        let fr = frames(), track = trackRect(fr)
        for (k, r) in fr {
            switch k {
            case .more: if r.contains(p) { return k }
            case .compare(let m):
                let lo = m == ColorCompareMode.allCases.first ? track.minX : r.minX
                let hi = m == ColorCompareMode.allCases.last ? track.maxX : r.maxX
                if p.x >= lo, p.x < hi, p.y >= 0, p.y < size.height { return k }
            }
        }
        return nil
    }

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        let b = CGRect(origin: .zero, size: size)
        c.fill(b, t.panel)
        c.fill(CGRect(x: 0, y: b.maxY - 1, width: b.width, height: 1), t.separator)
        if c.atlas != nil {
            segmentWidths = ColorCompareMode.allCases.map { ceil(c.size(of: SQL10n.string($0.title), fontSize: fs).width) + Self.segmentPadding }
        }
        let fr = frames()
        let track = trackRect(fr)
        let segLeft = track.isNull ? b.maxX : track.minX
        let content = controller.viewerHeaderContent
        var x = Self.textLeft
        // The Mac layout: the text ends `iconToLabel` + `Spacing.sm` before the segment's track.
        let right = segLeft - Self.moreGap
        let room = max(right - CGFloat(DrawTheme.Spacing.sm) - x, 0)
        let pw = content.position.map { ceil(c.size(of: $0, fontSize: fs).width) + 4 } ?? 0
        let nw = min(ceil(c.size(of: content.name, fontSize: fs, face: c.medium).width) + 4, max(room - pw - (pw > 0 ? 12 : 0), 0))
        c.draw(content.name, at: CGPoint(x: x, y: ((b.height - fs - 4) / 2).rounded()), fontSize: fs, t.label, maxWidth: nw, face: c.medium)
        if let pos = content.position {
            x += nw + 12
            c.draw(pos, at: CGPoint(x: x, y: ((b.height - fs - 4) / 2).rounded()), fontSize: fs, t.label3, maxWidth: min(pw, max(right - x, 0)))
        }
        // The segment (SQSegmented compact): a `fill2` track, the picked mode `fillPressed` with white text, the others
        // in `label`, the hovered one `fillHover`.
        if !track.isNull { c.fill(roundedRect: track, radius: min(CGFloat(DrawTheme.Radius.control), track.height / 2), t.inkFill(0.06)) }
        for (k, r) in fr {
            switch k {
            case .compare(let m):
                let on = controller.compare == m
                let inner = min(CGFloat(DrawTheme.Radius.small), r.height / 2)
                if on { c.fill(roundedRect: r, radius: inner, t.fillPressed) }
                else if hover == k { c.fill(roundedRect: r, radius: inner, t.fillHover) }
                c.draw(SQL10n.string(m.title), in: r, fontSize: fs, on ? .white : t.label, align: .center)
            case .more:
                if hover == k { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
                c.draw(icon: .ellipsis, at: CGPoint(x: r.midX - 6, y: r.midY - 6), size: 12, t.label2)
            }
        }
    }

    public func mouseMoved(to p: CGPoint?) { hover = p.flatMap(control) }

    /// The tip under the pointer (HostHover): the graded clip's whole name (the Mac `name.sqToolTip`), the compare
    /// modes and the more-actions button.
    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .compare(.before)?: return SQL10n.string("Before: the picture without the grade")
        case .compare(.after)?: return SQL10n.string("After: the graded picture")
        case .compare(.split)?: return SQL10n.string("Split: ungraded on the left, graded on the right")
        case .more?: return SQL10n.string("More viewer actions")
        case nil:
            let name = controller.viewerHeaderContent.name
            let track = trackRect(frames())
            return p.x < (track.isNull ? size.width : track.minX) && !name.isEmpty ? name : nil
        }
    }

    public func mouseDown(at p: CGPoint) {
        guard let k = control(at: p), let r = frames().first(where: { $0.0 == k })?.1 else { return }
        switch k {
        case .compare(let m): if controller.compare != m { controller.setCompare(m) }
        case .more: onMenu?(menuItems(), r)
        }
    }

    /// The viewer menu; a refused copy or paste beeps (`controller.beep`).
    func menuItems() -> [SQMenuItem] {
        let c = controller
        return [
            SQMenuItem(title: "Copy Grade", isEnabled: c.canCopyGrade) { [weak c] in if c?.copyGrade() == false { c?.beep() } },
            SQMenuItem(title: "Paste Grade", isEnabled: c.canPasteGrade) { [weak c] in if c?.pasteGrade() == false { c?.beep() } },
        ]
    }
}

// MARK: - Strip tools
// (In this file because the package lists its Windows sources by name.)

/// The right end of the Color panels' tab strips on the shared toolkit (the Mac `PanelHeaderItems` of EditorPanels+Headers
/// with `ColorGradeTools`): a quiet detail text, then Add Step (Steps only), Copy Grade and Paste Grade as 12 pt icon
/// buttons. Color settings shows only its detail (Simple | Pro and "..." are drawn inside `ColorGradeDraw`); the
/// Timeline's strip (on the Color page, when it shares a group) shows its hint and Copy / Paste Grade.
/// Frames are in the strip's coordinates (the host passes the strip rect in window points).
@MainActor
public final class ColorStripToolsDraw {
    public enum Panel: Hashable, Sendable { case colorInspector, steps, sources, timeline }
    public enum Button: Hashable, Sendable { case addStep, copy, paste, simple, pro, more }

    public let controller: ColorGradeController
    public var theme = DrawTheme()
    /// Opens a menu (Add Step's kinds) under `anchor` (window points).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// Add Step's menu items (the Steps panel's `ColorGraphMenus.addMenuItems`); nil = no graph to add to.
    public var addMenuItems: (@MainActor () -> [SQMenuItem]?)?
    /// The Color tab's "..." menu items (`ColorGradeDraw.panelMenuItems`).
    public var moreMenuItems: (@MainActor () -> [SQMenuItem])?
    private(set) var hover: (Panel, Button)?
    private(set) var pressed: (Panel, Button)?

    public init(controller: ColorGradeController) { self.controller = controller }

    /// v9 `.btn.ic`: 24 wide, the capsule's height; 2 pt between buttons, 8 pt before the strip's right edge.
    static let buttonWidth: CGFloat = 24
    static let buttonGap: CGFloat = 2
    /// The Simple | Pro segments (SQSegmented with an icon beside the label, 14 pt icons).
    static let segmentWidth: CGFloat = 76
    static let colorRight: CGFloat = 10, colorSegmentGap: CGFloat = 5
    static func width(of b: Button) -> CGFloat { b == .simple || b == .pro ? segmentWidth : buttonWidth }
    static let right = CGFloat(DrawTheme.Spacing.sm)
    static let detailGap = CGFloat(DrawTheme.Spacing.sm)
    /// The detail never takes more than this (it is cut with an ellipsis).
    static let detailMax: CGFloat = 260
    static let fontSize = CGFloat(DrawTheme.TypeSize.body)

    public static func buttons(_ p: Panel) -> [Button] {
        switch p {
        case .colorInspector: [.simple, .pro, .more]
        case .steps: [.addStep, .copy, .paste]
        case .sources, .timeline: [.copy, .paste]
        }
    }

    /// The quiet text before the buttons (the Mac header detail).
    public func detail(_ p: Panel) -> String? {
        let s: String? = switch p {
        case .colorInspector: controller.headerDetail
        case .steps: controller.stepsDetail
        case .sources: ColorGradeController.sourcesHint
        case .timeline: controller.timelineDetail
        }
        return s.flatMap { $0.isEmpty ? nil : SQL10n.string($0) }
    }

    func isEnabled(_ b: Button) -> Bool {
        switch b {
        case .addStep: controller.model?.graph != nil
        case .simple, .pro, .more: true
        case .copy: controller.canCopyGrade
        case .paste: controller.canPasteGrade
        }
    }

    static func icon(_ b: Button) -> SQIcon {
        switch b { case .addStep: .plus; case .copy: .copy; case .paste: .paste; case .simple: .toolMask; case .pro: .slidersHorizontal; case .more: .ellipsis }
    }

    /// The Mac `ColorGradeTools` tips.
    static func tip(_ b: Button) -> String {
        switch b {
        case .addStep: "Add a Step after the selected one"
        case .copy: "Copy the grade of what is being graded"
        case .paste: "Paste the copied grade onto the selected clips"
        case .simple, .pro: "Simple: the guided controls. Pro: the Color Graph of Steps. The other grade keeps its values."
        case .more: "More actions"
        }
    }

    /// Room the dock leaves at the strip's right end (`ShellDock.stripTools`).
    public func width(_ p: Panel, measure: (String) -> CGFloat) -> CGFloat {
        let bs = Self.buttons(p)
        let buttons = bs.isEmpty ? 0 : bs.reduce(CGFloat(0)) { $0 + Self.width(of: $1) } + CGFloat(bs.count - 1) * Self.buttonGap
            - (bs.contains(.simple) ? Self.buttonGap : 0) + (p == .colorInspector ? Self.colorSegmentGap - Self.buttonGap : 0)
        let text = detail(p).map { min(ceil(measure($0)) + 2, Self.detailMax) } ?? 0
        let gap = buttons > 0 && text > 0 ? Self.detailGap : 0
        return buttons + text + gap + (p == .colorInspector ? Self.colorRight : Self.right) + (text > 0 ? Self.detailGap : 0)
    }

    /// The buttons' frames, left to right, in window points inside `strip`.
    func frames(_ p: Panel, strip: CGRect) -> [(Button, CGRect)] {
        let h = CGFloat(DrawTheme.Metrics.capsule)
        let y = (strip.minY + (strip.height - 1 - h) / 2).rounded()
        // The Color tab's strip keeps 10 pt after its "..." and 5 pt between the segments and it (the Mac strip).
        var x = strip.maxX - (p == .colorInspector ? Self.colorRight : Self.right)
        var out: [(Button, CGRect)] = []
        for b in Self.buttons(p).reversed() {
            let w = Self.width(of: b)
            x -= w
            out.insert((b, CGRect(x: x, y: y, width: w, height: h)), at: 0)
            // The two grade segments touch (one track); every other button keeps its gap.
            x -= b == .pro ? 0 : (b == .more && p == .colorInspector ? Self.colorSegmentGap : Self.buttonGap)
        }
        return out
    }

    func button(_ p: Panel, strip: CGRect, at q: CGPoint) -> Button? { frames(p, strip: strip).first { $0.1.contains(q) }?.0 }

    public func draw(_ c: inout Canvas, panel p: Panel, strip: CGRect, reserved: CGFloat) {
        let t = theme
        let fr = frames(p, strip: strip)
        let seg = fr.filter { $0.0 == .simple || $0.0 == .pro }.map(\.1)
        if let first = seg.first, let last = seg.last {
            c.fill(roundedRect: first.union(last), radius: min(CGFloat(DrawTheme.Radius.control), first.height / 2), t.inkFill(0.06))
        }
        for (b, r) in fr {
            if b == .simple || b == .pro {
                let on = (controller.model?.shownGrade == .pro) == (b == .pro)
                // The picked segment sits 1 pt inside the 22 pt track (the Mac SQSegmented).
                let pick = r.insetBy(dx: 0, dy: 1), inner = min(CGFloat(DrawTheme.Radius.small), pick.height / 2)
                if on { c.fill(roundedRect: pick, radius: inner, t.fillPressed) }
                else if hover.map({ $0 == (p, b) }) == true { c.fill(roundedRect: pick, radius: inner, t.fillHover) }
                let title = SQL10n.string(b == .pro ? "Pro" : "Simple"), tw = ceil(c.size(of: title, fontSize: Self.fontSize).width)
                let icon: CGFloat = 14, gap: CGFloat = 6
                let x = r.midX - (icon + gap + tw) / 2
                c.draw(icon: Self.icon(b), at: CGPoint(x: x, y: r.midY - icon / 2), size: icon, on ? .white : t.label2)
                c.draw(title, in: CGRect(x: x + icon + gap, y: r.minY, width: tw + 2, height: r.height), fontSize: Self.fontSize, on ? .white : t.label)
                continue
            }
            let on = isEnabled(b)
            if on, pressed.map({ $0 == (p, b) }) == true { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), t.fillPressed) }
            else if on, hover.map({ $0 == (p, b) }) == true { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: Self.icon(b), at: CGPoint(x: r.midX - 6, y: r.midY - 6), size: 12, on ? t.label2 : t.label3.alpha(0.5))
        }
        guard let text = detail(p) else { return }
        let right = (fr.first?.1.minX).map { $0 - Self.detailGap } ?? strip.maxX - Self.right
        let left = max(strip.maxX - reserved + Self.detailGap, strip.minX)
        let w = max(right - left, 0)
        guard w > 8 else { return }
        let tw = min(ceil(c.size(of: text, fontSize: Self.fontSize).width) + 2, w)
        c.draw(text, at: CGPoint(x: right - tw, y: (strip.minY + (strip.height - 1 - Self.fontSize - 4) / 2).rounded()),
               fontSize: Self.fontSize, t.label3, maxWidth: tw)
    }

    public func mouseMoved(panel p: Panel?, strip: CGRect?, to q: CGPoint) {
        guard let p, let strip, let b = button(p, strip: strip, at: q) else { hover = nil; return }
        hover = (p, b)
    }

    /// The tip under the pointer (HostHover).
    public func help(panel p: Panel, strip: CGRect, at q: CGPoint) -> String? {
        if let b = button(p, strip: strip, at: q) { return SQL10n.string(Self.tip(b)) }
        return detail(p)
    }

    /// A press in the tools: true when it hit a button (it acts on release over the same button).
    public func mouseDown(panel p: Panel, strip: CGRect, at q: CGPoint) -> Bool {
        guard let b = button(p, strip: strip, at: q) else { return false }
        pressed = (p, b)
        return true
    }

    public func mouseUp(panel p: Panel, strip: CGRect, at q: CGPoint) {
        guard let (pp, b) = pressed else { return }
        pressed = nil
        guard pp == p, button(p, strip: strip, at: q) == b, let r = frames(p, strip: strip).first(where: { $0.0 == b })?.1 else { return }
        press(b, anchor: r)
    }

    /// The button's action; a refused one beeps (`controller.beep`, the Mac `NSSound.beep`).
    func press(_ b: Button, anchor: CGRect) {
        switch b {
        case .copy: if !controller.copyGrade() { controller.beep() }
        case .paste: if !controller.pasteGrade() { controller.beep() }
        case .simple: controller.chooseGrade(pro: false)
        case .pro: controller.chooseGrade(pro: true)
        case .more: if let items = moreMenuItems?(), !items.isEmpty { onMenu?(items, anchor) }
        case .addStep:
            guard let items = addMenuItems?(), !items.isEmpty else { controller.beep(); return }
            onMenu?(items, anchor)
        }
    }
}
