import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQUIKit

/// The Templates tab of the Text panel on the shared toolkit: `TextTemplatesTabView` translated. A search field, the
/// hint, then every text and graphic template (the user's saved ones first, then the built-ins) as 140 × 104 tiles; a
/// click places the template at the playhead (the host's `onPick`).
/// A tile shows its picture from the host's `TextTemplateTileAtlas` (the saved PNG, else the rendered look), the sample
/// text in the look's font until that is made. Dragging a tile onto a track is Mac-only until the Windows timeline takes
/// template drops.
/// Coordinates: points, y down, (0, 0) = the tab's top-left.
@MainActor public final class TextTemplatesTabDraw {
    public var theme = DrawTheme()
    public var size = CGSize(width: 320, height: 400)
    /// Called with the picked tile; the host places it (it knows the session and the Library).
    public var onPick: (@MainActor (TextTemplateTile) -> Void)?
    /// All tiles before the search filter.
    public var allTiles: [TextTemplateTile] = [] { didSet { if oldValue != allTiles { refilter() } } }
    /// The tiles shown now (after the search).
    public private(set) var shownTiles: [TextTemplateTile] = []
    /// The tile's picture in the host's image slot (`TextTemplateTileAtlas.picture(for:)`); nil: the sample text.
    public var picture: ((TextTemplateTile) -> TextTemplateTilePicture?)?

    public enum Control: Hashable { case search, tile(Int) }

    private(set) var search = TextFieldControl()
    private(set) var scrollY: CGFloat = 0
    private var hover: Control?
    private var pressed: Control?

    public init() {
        search.alignment = .left
        search.fontSize = CGFloat(DrawTheme.TypeSize.body)
    }

    // MARK: Layout (TextTemplatesTabView.layout)

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 6; upgrade when SQUIKit's
    // tokens move into a portable file.
    static let pad: CGFloat = 6
    static let searchHeight: CGFloat = 24
    static let tileSize = CGSize(width: 140, height: 104)
    static let hintSize = CGFloat(DrawTheme.TypeSize.body), hintLine: CGFloat = 15
    static let hint = "Click a template to place it at the playhead, or drag it onto a track. Save your own from the timeline menu: Save as Template or Save to Library."

    private var query: String { search.editor?.string ?? search.text }

    private func refilter() {
        shownTiles = TextTemplateTile.filter(allTiles, query: query)
        scrollY = min(scrollY, maxScroll)
    }

    /// The scrolling area below the search field.
    var scrollFrame: CGRect {
        let top = Self.pad + Self.searchHeight + Self.pad
        return CGRect(x: 0, y: top, width: size.width, height: max(size.height - top, 0))
    }

    var columns: Int { max(1, Int((size.width - Self.pad) / (Self.tileSize.width + Self.pad))) }

    /// Hint lines at the panel width; measured with the canvas the panel drew last (no atlas: one line per 50 points).
    private var hintLines = 3

    private var tilesTop: CGFloat { Self.pad + CGFloat(hintLines) * Self.hintLine + Self.pad }

    private var contentHeight: CGFloat {
        let rows = (shownTiles.count + columns - 1) / columns
        return tilesTop + CGFloat(rows) * (Self.tileSize.height + Self.pad)
    }

    private var maxScroll: CGFloat { max(contentHeight - scrollFrame.height, 0) }

    func frame(_ k: Control) -> CGRect {
        switch k {
        case .search: return CGRect(x: Self.pad, y: Self.pad, width: max(size.width - 2 * Self.pad, 0), height: Self.searchHeight)
        case .tile(let i):
            let cols = columns, tw = Self.tileSize.width, th = Self.tileSize.height, pad = Self.pad
            let gap = cols > 1 ? max(pad, (size.width - 2 * pad - CGFloat(cols) * tw) / CGFloat(cols - 1)) : pad
            return CGRect(x: pad + CGFloat(i % cols) * (tw + gap),
                          y: scrollFrame.minY - scrollY + tilesTop + CGFloat(i / cols) * (th + pad), width: tw, height: th)
        }
    }

    func control(at p: CGPoint) -> Control? {
        if frame(.search).contains(p) { return .search }
        guard scrollFrame.contains(p) else { return nil }
        return shownTiles.indices.first { frame(.tile($0)).contains(p) }.map { .tile($0) }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        let sf = frame(.search)
        var f = search
        f.hovering = hover == .search
        f.draw(&c, in: sf, theme: t, focused: search.isEditing)
        if f.text.isEmpty, !f.isEditing {
            c.draw(SQL10n.string("Search templates"), in: sf.insetBy(dx: 6, dy: 0), fontSize: f.fontSize, t.label3)
        }

        let area = scrollFrame
        c.saveGState()
        c.clip(to: area)
        let hint = SQL10n.string(Self.hint), hw = max(size.width - 2 * Self.pad, 0)
        if c.atlas != nil { hintLines = max(c.wrap(hint, width: hw, fontSize: Self.hintSize).count, 1) }
        _ = c.drawWrapped(hint, in: CGRect(x: Self.pad, y: area.minY - scrollY + Self.pad, width: hw, height: CGFloat(hintLines) * Self.hintLine),
                          fontSize: Self.hintSize, lineHeight: Self.hintLine, t.label3)
        for (i, tile) in shownTiles.enumerated() {
            let r = frame(.tile(i))
            guard r.maxY > area.minY, r.minY < area.maxY else { continue }
            drawTile(&c, tile, in: r, hovering: hover == .tile(i))
        }
        c.restoreGState()
    }

    /// `TextTemplateTileView.draw`: the well, the sample text, the outline (accent on hover), the name below.
    private func drawTile(_ c: inout Canvas, _ tile: TextTemplateTile, in r: CGRect, hovering: Bool) {
        let t = theme, radius = CGFloat(DrawTheme.Radius.control)
        let well = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 18).insetBy(dx: 1, dy: 1)
        c.fill(roundedRect: well, radius: radius, hovering ? t.fillHover : t.content)
        c.saveGState()
        c.clip(to: well)
        // The saved or rendered picture (`TextTemplateTileAtlas`); until it is made, the template's own font and color
        // when it has a style, the UI face and ink otherwise.
        if let pic = picture?(tile) {
            c.draw(imageSlot: pic.slot, in: well, source: pic.source)
        } else if let st = tile.style {
            let face = c.face(family: st.fontName, weight: st.weight, italic: st.italic)
            let col = st.color, ink = col.alpha > 0.05
                ? DrawColor(Float(col.red), Float(col.green), Float(col.blue), Float(col.alpha)) : t.label2
            c.draw(tile.sampleText, in: well.insetBy(dx: 4, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.title), ink, align: .center,
                   face: face)
        } else {
            c.draw(tile.sampleText, in: well.insetBy(dx: 4, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.title), t.label2, align: .center)
        }
        c.restoreGState()
        c.stroke(roundedRect: well, radius: radius, width: 1, hovering ? t.accent : t.separator)
        c.draw(tile.name, in: CGRect(x: r.minX, y: r.maxY - 15, width: r.width, height: 14),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2, align: .center)
    }

    // MARK: Pointer and keys

    public func mouseMoved(to p: CGPoint?) { hover = p.flatMap(control) }

    public func mouseDown(at p: CGPoint) {
        let k = control(at: p)
        pressed = k
        if k == .search {
            search.mouseDown()
        } else if search.isEditing {
            _ = search.commit()
            refilter()
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { pressed = nil }
        guard let k = pressed, control(at: p) == k, case .tile(let i) = k, shownTiles.indices.contains(i) else { return }
        onPick?(shownTiles[i])
    }

    /// The wheel scrolls the tiles.
    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard scrollFrame.contains(p), maxScroll > 0 else { return false }
        scrollY = min(max(scrollY - dy, 0), maxScroll)
        return true
    }

    /// Typing goes to the search field; every key filters at once (the Mac search field is incremental).
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        guard search.isEditing else { return false }
        if k == .escape { search.cancel(); search.text = ""; refilter(); return true }      // Esc clears, as NSSearchField
        if search.key(k, modifiers: m) != nil { search.mouseDown() }      // Return keeps the field open, as the Mac one
        refilter()
        return true
    }

    public func help(at p: CGPoint) -> String? {
        if case .tile(let i)? = control(at: p), shownTiles.indices.contains(i) { return shownTiles[i].name }
        return nil
    }

    /// Typing in the search field (the host keeps IME on while it is open).
    public var isEditingText: Bool { search.isEditing }
}
