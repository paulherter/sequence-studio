import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// Text widths in points for layout (`NSString.size(withAttributes:)` of the Mac views), from the glyph atlas at the device
/// scale. `face`: 0 regular, `medium` / `semibold` the atlas faces of those weights (0 without an atlas).
public struct TextMeasure {
    public let atlas: GlyphAtlas?
    public let scale: Float
    public init(atlas: GlyphAtlas?, scale: Float) { self.atlas = atlas; self.scale = scale }

    public var medium: Int { atlas?.mediumFace ?? 0 }
    public var semibold: Int { atlas?.semiboldFace ?? 0 }

    public func width(_ s: String, size: CGFloat, face: Int = 0) -> CGFloat {
        guard let atlas else { return CGFloat(s.count) * size * 0.55 }
        return CGFloat(atlas.width(of: s, pixelSize: Float(size) * scale, face: face) / scale)
    }
    public func lineHeight(_ size: CGFloat) -> CGFloat {
        guard let atlas else { return (size * 1.21).rounded(.up) }
        let p = Float(size) * scale
        return CGFloat(((atlas.ascent(pixelSize: p) + atlas.descent(pixelSize: p)) / scale).rounded(.up))
    }
    /// Lines of greedy word wrap at `width`.
    public func lines(_ s: String, width: CGFloat, size: CGFloat) -> [String] {
        var out: [String] = []
        for para in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in para.split(separator: " ") {
                let cand = line.isEmpty ? String(word) : line + " " + word
                if !line.isEmpty, self.width(cand, size: size) > width { out.append(line); line = String(word) } else { line = cand }
            }
            out.append(line)
        }
        return out
    }

    /// `lineBreakMode = .byTruncatingMiddle`: one line, the middle cut with an ellipsis ("~/Movies/…/Projects").
    public func truncatedMiddle(_ s: String, width: CGFloat, size: CGFloat) -> String {
        guard self.width(s, size: size) > width, s.count > 2 else { return s }
        var head = Array(s.prefix(s.count / 2)), tail = Array(s.suffix(s.count - s.count / 2))
        while head.count + tail.count > 1 {
            if tail.count >= head.count { tail.removeFirst() } else { head.removeLast() }
            if self.width(String(head) + "\u{2026}" + String(tail), size: size) <= width { break }
        }
        return String(head) + "\u{2026}" + String(tail)
    }

    /// Lets `SQMenuLayout` (help lines, caption heights) measure with this font.
    public func installInMenuLayout() {
        let m = self
        SQMenuLayout.measureLines = { t, w, s in max(1, m.lines(t, width: w, size: s).count) }
        SQMenuLayout.lineHeight = { m.lineHeight($0) }
    }
}

/// The menu font sizes (artifact `.mi` 11, `shortcutFont` 11, `captionFont` 11 semibold, help `Typography.caption` 10,
/// caption rows `Typography.body` 11).
public enum MenuFont {
    public static let title: CGFloat = 11
    public static let shortcut: CGFloat = 11
    public static let header: CGFloat = 10
    public static let help: CGFloat = 10
    public static let caption: CGFloat = 11
}

/// One level of a menu: rows, shortcut column, checkmarks, submenu chevrons. `SQMenuListView` translated: the layout code is
/// the same line for line, the drawing goes to the `Canvas` (points, y down) instead of AppKit. Dumb: the controller
/// (`MenuController`) owns the navigation state.
public struct MenuListView {
    public var items: [SQMenuItem] { didSet { needsLayout = true } }
    /// Type-to-filter text; the filter row exists only while this is non-empty.
    public var filter: String = "" { didSet { if oldValue != filter { needsLayout = true } } }
    public private(set) var filterFrame: CGRect?
    public var highlighted: Int?
    public private(set) var rowFrames: [CGRect] = []
    public private(set) var width: CGFloat = SQMenuLayout.minWidth
    public private(set) var symbolWidth: CGFloat = 0
    public private(set) var iconWidth: CGFloat = SQMenuLayout.iconColumn
    /// Tallest the list may be (the window's room); taller content scrolls.
    public var maxHeight: CGFloat? { didSet { if oldValue != maxHeight { needsLayout = true } } }
    public private(set) var scrollOffset: CGFloat = 0
    /// Top-left corner in window points (set by the controller when it places the level).
    public var origin: CGPoint = .zero
    private var needsLayout = true

    public init(items: [SQMenuItem]) { self.items = items }

    /// Full size of the rows.
    public var contentSize: CGSize { CGSize(width: width, height: (rowFrames.last?.maxY ?? SQMenuLayout.inset) + SQMenuLayout.inset) }
    /// What the list shows: the content, clamped to `maxHeight`.
    public var visibleSize: CGSize { CGSize(width: width, height: min(contentSize.height, maxHeight ?? .greatestFiniteMagnitude)) }
    public var frame: CGRect { CGRect(origin: origin, size: visibleSize) }
    public var maxScroll: CGFloat { max(contentSize.height - visibleSize.height, 0) }

    public mutating func scroll(by delta: CGFloat) { setScroll(scrollOffset + delta) }
    private mutating func setScroll(_ y: CGFloat) { scrollOffset = max(0, min(y, maxScroll)) }
    /// Scrolls the least that shows row `i` completely.
    public mutating func reveal(row i: Int) {
        guard rowFrames.indices.contains(i) else { return }
        let r = rowFrames[i]
        if r.minY - SQMenuLayout.inset < scrollOffset { setScroll(r.minY - SQMenuLayout.inset) }
        else if r.maxY + SQMenuLayout.inset > scrollOffset + visibleSize.height { setScroll(r.maxY + SQMenuLayout.inset - visibleSize.height) }
    }

    public mutating func layoutIfNeeded(_ m: TextMeasure) { if needsLayout { relayout(m) } }

    public mutating func relayout(_ m: TextMeasure) {
        needsLayout = false
        // Artifact: [check 12 + gap 8, only when a row is checked][swatch 10 + gap 8, only when a row carries one][title].
        let dots = items.contains { if case .swatch = $0.icon { true } else { false } }
        let checks = dots || items.contains { $0.isChecked }
        iconWidth = (checks ? SQMenuLayout.checkColumn + SQMenuLayout.gap : 0) + (dots ? SQMenuLayout.dotColumn : 0)
        // Artifact: the width is the widest single row (title + gap + its own shortcut), not widest title + widest shortcut.
        var maxText: CGFloat = 0, maxRow: CGFloat = 0
        let symbols = items.contains { $0.leadingSymbol != nil }
        symbolWidth = symbols ? SQMenuLayout.symbolColumn : 0
        for i in items where i.kind == .action {
            var tw = m.width(i.title, size: MenuFont.title)
            if let h = i.help, !h.isEmpty { tw = max(tw, min(SQMenuLayout.helpWidth, ceil(m.width(h, size: MenuFont.help)))) }
            let own: CGFloat = i.submenu != nil ? 12 : m.width(i.shortcut, size: MenuFont.shortcut)
            maxRow = max(maxRow, tw + (own > 0 ? SQMenuLayout.shortcutGap + own : 0))
        }
        // Header rows start at the left padding (`.mcap`), left of the title column by the icon columns.
        let headerIndent = -(iconWidth + symbolWidth)
        for i in items where i.kind == .header {
            maxText = max(maxText, m.width(i.title, size: MenuFont.header, face: m.semibold) + headerIndent)
        }
        maxText = max(maxText, maxRow)
        // Artifact: the label list (swatch rows) is a compact 160 wide submenu, not the 200 floor of the action menus.
        width = max(dots ? 160 : SQMenuLayout.minWidth, ceil(SQMenuLayout.inset * 2 + SQMenuLayout.rowPad + iconWidth + symbolWidth + maxText + SQMenuLayout.rowPad))
        if items.contains(where: { $0.kind == .caption }) {
            width = max(width, ceil(SQMenuLayout.inset * 2 + SQMenuLayout.rowPad * 2 + SQMenuLayout.captionWidth))
        }
        var y = SQMenuLayout.inset
        if filter.isEmpty {
            filterFrame = nil
        } else {
            filterFrame = CGRect(x: SQMenuLayout.inset, y: y, width: width - 2 * SQMenuLayout.inset, height: SQMenuLayout.rowHeight)
            y += SQMenuLayout.rowHeight + SQMenuLayout.separatorHeight
            width = max(width, ceil(m.width(filter, size: MenuFont.title) + 40))
            filterFrame?.size.width = width - 2 * SQMenuLayout.inset
        }
        rowFrames = []
        for h in SQMenuLayout.heights(items) {
            rowFrames.append(CGRect(x: SQMenuLayout.inset, y: y, width: width - 2 * SQMenuLayout.inset, height: h))
            y += h
        }
        setScroll(scrollOffset)
    }

    /// Row under `p` (window points).
    public func index(at p: CGPoint) -> Int? {
        let q = CGPoint(x: p.x - origin.x, y: p.y - origin.y + scrollOffset)
        guard q.x >= 0, q.x < width, p.y - origin.y >= 0, p.y - origin.y < visibleSize.height else { return nil }
        return rowFrames.firstIndex { $0.contains(q) }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let bounds = CGRect(origin: .zero, size: visibleSize)
        c.saveGState()
        c.translateBy(x: origin.x, y: origin.y)
        // The panel's shadow (`SQMenuPanel.hasShadow`).
        c.shadow(roundedRect: bounds, radius: SQMenuLayout.cornerRadius, blur: 32, dy: 12, DrawColor(0, 0, 0, t.palette.isDark ? 0.5 : 0.18), opaqueAbove: true)
        let bg = bounds.insetBy(dx: 0.25, dy: 0.25)
        c.fill(roundedRect: bg, radius: SQMenuLayout.cornerRadius, t.overlay)
        c.stroke(roundedRect: bg, radius: SQMenuLayout.cornerRadius, width: 0.5, t.menuEdge)

        c.saveGState()
        c.clip(to: bounds)
        c.translateBy(x: 0, y: -scrollOffset)

        if let f = filterFrame {
            c.draw(filter, in: CGRect(x: f.minX + 8, y: f.minY, width: f.width - 8, height: f.height), fontSize: MenuFont.title, t.label)
            c.fill(CGRect(x: f.minX + SQMenuLayout.rowPad, y: f.maxY + SQMenuLayout.separatorHeight / 2 - 0.5,
                          width: f.width - 2 * SQMenuLayout.rowPad, height: 1), t.separatorStrong)
        }

        for (i, item) in items.enumerated() where rowFrames.indices.contains(i) {
            let r = rowFrames[i]
            switch item.kind {
            case .separator:
                c.fill(CGRect(x: r.minX + SQMenuLayout.sepPad, y: r.midY - 0.5, width: r.width - 2 * SQMenuLayout.sepPad, height: 1), t.separatorStrong)
            case .header:
                // `.mcap`: semibold, left padding, 4 pt above the row bottom.
                let hx = r.minX + SQMenuLayout.rowPad
                let lh = SQMenuLayout.lineHeightPortable(MenuFont.header)
                c.draw(item.title, in: CGRect(x: hx, y: r.maxY - SQMenuLayout.headerBottom - lh, width: r.maxX - hx, height: lh),
                       fontSize: MenuFont.header, t.label3, face: c.semibold)
            case .caption:
                let box = CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY + SQMenuLayout.captionPad,
                                 width: r.width - 2 * SQMenuLayout.rowPad, height: r.height - 2 * SQMenuLayout.captionPad)
                c.drawWrapped(item.title, in: box, fontSize: MenuFont.caption, lineHeight: SQMenuLayout.lineHeightPortable(MenuFont.caption), t.label2)
            case .action:
                drawRow(&c, item, in: r, active: highlighted == i, t)
            }
        }
        c.restoreGState()
        // A tall menu scrolls: a 3 pt thumb on the right edge shows there are more rows above or below.
        if maxScroll > 0 {
            let track = bounds.height - 2 * SQMenuLayout.inset
            let h = max(track * bounds.height / contentSize.height, 20)
            let y = SQMenuLayout.inset + (track - h) * scrollOffset / maxScroll
            c.fill(roundedRect: CGRect(x: bounds.maxX - 5, y: y, width: 3, height: h), radius: CGFloat(DrawTheme.Radius.small), t.label4)
        }
        c.restoreGState()
    }

    private func drawRow(_ c: inout Canvas, _ item: SQMenuItem, in r: CGRect, active: Bool, _ t: DrawTheme) {
        if active { c.fill(roundedRect: r, radius: SQMenuLayout.rowRadius, t.rowHover) }
        let text: DrawColor = !item.isEnabled ? t.label4 : (item.isDestructive ? t.errText : t.label)
        let sub: DrawColor = !item.isEnabled ? t.label4 : t.label2

        let checkBox = CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY, width: SQMenuLayout.checkColumn, height: r.height)
        if item.isChecked { Self.drawCheck(&c, color: item.isEnabled ? t.label : t.label4, in: checkBox) }
        var tx = r.minX + SQMenuLayout.rowPad + iconWidth
        if iconWidth > SQMenuLayout.checkColumn + SQMenuLayout.gap {
            let chip = CGRect(x: checkBox.maxX + SQMenuLayout.gap, y: r.midY - SQMenuLayout.swatchSize / 2,
                              width: SQMenuLayout.swatchSize, height: SQMenuLayout.swatchSize)
            if case .swatch(let rgb) = item.icon {
                c.fill(roundedRect: chip, radius: SQMenuLayout.swatchRadius, DrawColor(hex: rgb, alpha: item.isEnabled ? 1 : 0.4))
            }
            c.stroke(roundedRect: chip.insetBy(dx: 0.25, dy: 0.25), radius: SQMenuLayout.swatchRadius, width: 0.5, t.swatchEdge)
        }
        if let sym = item.leadingSymbol {
            let tint = item.leadingTint.map { item.isEnabled ? Self.color($0) : t.label3 } ?? text
            let size: CGFloat = 12.5
            c.draw(icon: sym, at: CGPoint(x: tx + 1, y: r.minY + (min(r.height, SQMenuLayout.rowHeight) - size) / 2), size: size, tint)
            tx += symbolWidth
        }
        let hasHelp = item.help?.isEmpty == false
        let titleBox = hasHelp ? CGRect(x: tx, y: r.minY - 1, width: r.maxX - tx, height: SQMenuLayout.rowHeight) : CGRect(x: tx, y: r.minY, width: r.maxX - tx, height: r.height)
        c.draw(item.title, in: titleBox, fontSize: MenuFont.title, text)
        if let help = item.help, hasHelp {
            let box = CGRect(x: tx, y: r.minY + SQMenuLayout.rowHeight - 2, width: SQMenuLayout.helpWidth + 2,
                             height: CGFloat(SQMenuLayout.helpLines(item)) * SQMenuLayout.helpHeight)
            c.drawWrapped(help, in: box, fontSize: MenuFont.help, lineHeight: SQMenuLayout.helpHeight, sub)
        }

        if item.submenu != nil {
            let size: CGFloat = 12   // artifact svg ~12 px, t3, right edge 8 px, optically 2.5 pt low
            c.draw(icon: .chevronRight, at: CGPoint(x: r.maxX - SQMenuLayout.rowPad - size, y: r.midY - size / 2 + 1), size: size,
                   item.isEnabled ? t.label3 : t.label4)
        } else if !item.shortcut.isEmpty {
            // One shortcut style: every key, punctuation included, is a plain glyph (no key cap) in the right column.
            c.draw(item.shortcut, in: CGRect(x: r.minX, y: r.minY, width: r.width - SQMenuLayout.rowPad, height: min(r.height, SQMenuLayout.rowHeight)),
                   fontSize: MenuFont.shortcut, sub, align: .right)
        }
    }

    /// The artifact's check: a 1.5 pt stroke, about 10 pt wide, in the 12 pt box.
    static func drawCheck(_ c: inout Canvas, color: DrawColor, in box: CGRect) {
        c.strokePolyline([CGPoint(x: box.minX + 1, y: box.midY + 0.5), CGPoint(x: box.minX + 4.5, y: box.midY + 3.5),
                          CGPoint(x: box.minX + 11, y: box.midY - 3.5)], width: 1.5, color)
    }

    /// Dialog and card edge (`Theme.ink(0.14)`); the menus use `DrawTheme.menuEdge`.
    static func overlayEdge(_ t: DrawTheme) -> DrawColor {
        let i = t.palette.ink
        return DrawColor(Float(i.r) / 255, Float(i.g) / 255, Float(i.b) / 255, 0.14)
    }

    static func color(palette c: PaletteColor) -> DrawColor {
        DrawColor(Float(c.r / 255), Float(c.g / 255), Float(c.b / 255), Float(c.a))
    }

    static func color(_ tint: SQMenuTint) -> DrawColor {
        return color(palette: tint)
    }
}

extension SQMenuLayout {
    /// Line height of the caption rows on both systems (the Mac reads it from the font, off the Mac `lineHeight`).
    static func lineHeightPortable(_ size: CGFloat) -> CGFloat {
        lineHeight(size)
    }
}
