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

    /// Lets `SQMenuLayout` (help lines, caption heights) measure with this font off the Mac.
    public func installInMenuLayout() {
        #if !canImport(AppKit)
        let m = self
        SQMenuLayout.measureLines = { t, w, s in max(1, m.lines(t, width: w, size: s).count) }
        SQMenuLayout.lineHeight = { m.lineHeight($0) }
        #endif
    }
}

/// The menu font sizes (`Theme.Menu.font` 12, `shortcutFont` 11, `captionFont` 11 semibold, help `Typography.caption` 10,
/// caption rows `Typography.body` 11).
public enum MenuFont {
    public static let title: CGFloat = 12
    public static let shortcut: CGFloat = 11
    public static let header: CGFloat = 11
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
        // Board: [check 14][gap 8][color dot 8 + gap 8, only when a row carries one][title]; no other icons.
        let dots = items.contains { if case .swatch = $0.icon { true } else { false } }
        iconWidth = SQMenuLayout.checkColumn + (dots ? SQMenuLayout.dotColumn : 0)
        var maxText: CGFloat = 0, maxShort: CGFloat = 0
        var hasSub = false
        let symbols = items.contains { $0.leadingSymbol != nil }
        symbolWidth = symbols ? SQMenuLayout.symbolColumn : 0
        for i in items where i.kind == .action {
            maxText = max(maxText, m.width(i.title, size: MenuFont.title))
            if let h = i.help, !h.isEmpty { maxText = max(maxText, min(SQMenuLayout.helpWidth, ceil(m.width(h, size: MenuFont.help)))) }
            maxShort = max(maxShort, m.width(i.shortcut, size: MenuFont.shortcut))
            hasSub = hasSub || i.submenu != nil
        }
        // Header rows start over the title column (`.mcap`), so their text counts like a title there.
        let headerIndent = SQMenuLayout.checkColumn + SQMenuLayout.gap - (iconWidth + symbolWidth + SQMenuLayout.gap)
        for i in items where i.kind == .header {
            maxText = max(maxText, m.width(i.title, size: MenuFont.header) + headerIndent)
        }
        let trailing: CGFloat = max(maxShort, hasSub ? 10 : 0)
        width = max(SQMenuLayout.minWidth, ceil(SQMenuLayout.inset * 2 + SQMenuLayout.rowPad + iconWidth + symbolWidth + SQMenuLayout.gap + maxText + (trailing > 0 ? 2 * SQMenuLayout.gap + trailing : 0) + SQMenuLayout.trailPad))
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
        c.shadow(roundedRect: bounds, radius: SQMenuLayout.cornerRadius, blur: 10, dy: 4, DrawColor(0, 0, 0, 0.25), opaqueAbove: true)
        let bg = bounds.insetBy(dx: 0.25, dy: 0.25)
        c.fill(roundedRect: bg, radius: SQMenuLayout.cornerRadius, t.overlay)
        c.stroke(roundedRect: bg, radius: SQMenuLayout.cornerRadius, width: 0.5, Self.overlayEdge(t))

        c.saveGState()
        c.clip(to: bounds)
        c.translateBy(x: 0, y: -scrollOffset)

        if let f = filterFrame {
            c.draw(filter, in: CGRect(x: f.minX + 8, y: f.minY, width: f.width - 8, height: f.height), fontSize: MenuFont.title, t.label)
            c.fill(CGRect(x: f.minX + SQMenuLayout.rowPad, y: f.maxY + SQMenuLayout.separatorHeight / 2 - 0.5,
                          width: f.width - 2 * SQMenuLayout.rowPad, height: 1), t.separator)
        }

        for (i, item) in items.enumerated() where rowFrames.indices.contains(i) {
            let r = rowFrames[i]
            switch item.kind {
            case .separator:
                c.fill(CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.midY - 0.5, width: r.width - 2 * SQMenuLayout.rowPad, height: 1), t.separator)
            case .header:
                // `.mcap`: text starts over the title column (padding-left 30); the 6/2 padding sits it 2 pt below center.
                let hx = r.minX + SQMenuLayout.rowPad + SQMenuLayout.checkColumn + SQMenuLayout.gap
                c.draw(item.title, in: CGRect(x: hx, y: r.minY + 2, width: r.maxX - hx, height: r.height), fontSize: MenuFont.header, t.label3)
            case .caption:
                let box = CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY + SQMenuLayout.captionPad,
                                 width: r.width - 2 * SQMenuLayout.rowPad, height: r.height - 2 * SQMenuLayout.captionPad)
                c.drawWrapped(item.title, in: box, fontSize: MenuFont.caption, lineHeight: SQMenuLayout.lineHeightPortable(MenuFont.caption), t.label2)
            case .action:
                drawRow(&c, item, in: r, active: highlighted == i, t)
            }
        }
        c.restoreGState()
        c.restoreGState()
    }

    private func drawRow(_ c: inout Canvas, _ item: SQMenuItem, in r: CGRect, active: Bool, _ t: DrawTheme) {
        if active { c.fill(roundedRect: r, radius: SQMenuLayout.rowRadius, t.accentFill) }
        let text: DrawColor = !item.isEnabled ? t.label3 : (active ? .white : t.label)
        let sub: DrawColor = !item.isEnabled ? t.label3 : (active ? DrawColor.white.alpha(0.8) : t.label3)

        let checkBox = CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY, width: SQMenuLayout.checkColumn, height: r.height)
        if item.isChecked { Self.drawCheck(&c, color: text, in: checkBox) }
        var tx = checkBox.maxX + SQMenuLayout.gap
        if case .swatch(let rgb) = item.icon {
            c.fill(ellipseIn: CGRect(x: tx, y: r.midY - 4, width: 8, height: 8), DrawColor(hex: rgb, alpha: item.isEnabled ? 1 : 0.4))
        }
        if iconWidth > SQMenuLayout.checkColumn { tx += SQMenuLayout.dotColumn }
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
            let size: CGFloat = 9   // `Theme.Typography.symbolSmall`
            c.draw(icon: .chevronRight, at: CGPoint(x: r.maxX - SQMenuLayout.trailPad - 10 + 1, y: r.midY - size / 2), size: size, sub)
        } else if !item.shortcut.isEmpty {
            // One shortcut style: every key, punctuation included, is a plain glyph (no key cap) in the right column.
            c.draw(item.shortcut, in: CGRect(x: r.minX, y: r.minY, width: r.width - SQMenuLayout.trailPad, height: min(r.height, SQMenuLayout.rowHeight)),
                   fontSize: MenuFont.shortcut, sub, align: .right)
        }
    }

    /// The board's check: a 1.5 pt stroke through (3, 7.5) (5.5, 10) (11, 4) in a 14 pt box.
    static func drawCheck(_ c: inout Canvas, color: DrawColor, in box: CGRect) {
        c.strokePolyline([CGPoint(x: box.minX + 3, y: box.midY + 0.5), CGPoint(x: box.minX + 5.5, y: box.midY + 3),
                          CGPoint(x: box.minX + 11, y: box.midY - 3)], width: 1.5, color)
    }

    /// `Theme.Colors.overlayEdge` (`Theme.ink(0.14)`).
    static func overlayEdge(_ t: DrawTheme) -> DrawColor {
        let i = t.palette.ink
        return DrawColor(Float(i.r) / 255, Float(i.g) / 255, Float(i.b) / 255, 0.14)
    }

    static func color(palette c: PaletteColor) -> DrawColor {
        DrawColor(Float(c.r / 255), Float(c.g / 255), Float(c.b / 255), Float(c.a))
    }

    static func color(_ tint: SQMenuTint) -> DrawColor {
        #if canImport(AppKit)
        let c = tint.usingColorSpace(.sRGB) ?? tint
        return DrawColor(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
        #else
        return color(palette: tint)
        #endif
    }
}

extension SQMenuLayout {
    /// Line height of the caption rows on both systems (the Mac reads it from the font, off the Mac `lineHeight`).
    static func lineHeightPortable(_ size: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        (size * 1.21).rounded(.up)
        #else
        lineHeight(size)
        #endif
    }
}
