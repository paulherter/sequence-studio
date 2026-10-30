import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The icon grid translated from the Mac `ProjectIconView`: one folder at a time (`ProjectPanelModel.browseBin`), tiles of
/// `ProjectIconCell.cellSize` spread evenly over the width, the poster (or the kind glyph) on a plate, the name under it,
/// the duration on the poster, the selection ring of `LibraryTile`.
extension ProjectListView {
    /// `LibraryTile.aspect` 10 : 16, `nameGap` 4, `nameHeight` 14, `ringWidth` 2; `ProjectIconCell` pads 6 around a tile.
    static let tileAspect: CGFloat = 10.0 / 16.0
    static let tileNameGap: CGFloat = CGFloat(DrawTheme.Spacing.xs)
    static let tileNameHeight: CGFloat = 14
    static let tilePad: CGFloat = 6
    static let ringWidth: CGFloat = 2

    var thumbHeight: CGFloat { (thumbSize * Self.tileAspect).rounded() }
    /// `ProjectIconCell.cellSize(thumb:)`.
    var cellSize: CGSize {
        CGSize(width: thumbSize + 2 * Self.tilePad, height: thumbHeight + Self.tileNameGap + Self.tileNameHeight + 2 * Self.tilePad)
    }
    var gridColumns: Int { max(1, Int(listRect.width / cellSize.width)) }

    /// The items of the folder the grid shows; at the top the sequences come first, as in the list.
    func gridItems() -> [BinItemRef] {
        guard let model, let bin = model.displayBin(model.browseBin) ?? Optional(model.project.rootBin) else { return [] }
        let all = model.children(of: bin).map(\.ref)
        guard bin.id == model.project.rootBin.id else { return all }
        func isSequence(_ r: BinItemRef) -> Bool { if case .sequence = r { true } else { false } }
        return all.filter(isSequence) + all.filter { !isSequence($0) }
    }

    var gridHeight: CGFloat {
        let n = gridItems().count
        return CGFloat((n + gridColumns - 1) / gridColumns) * cellSize.height + 8
    }

    /// The cell of item `i` in window points (scrolled).
    func tileRect(_ i: Int) -> CGRect {
        let cell = cellSize, cols = gridColumns
        let spacing = (listRect.width - CGFloat(cols) * cell.width) / CGFloat(cols + 1)
        return CGRect(x: listRect.minX + spacing + CGFloat(i % cols) * (cell.width + spacing),
                      y: listRect.minY + 4 + CGFloat(i / cols) * cell.height - scroll, width: cell.width, height: cell.height)
    }

    func thumbRect(_ i: Int) -> CGRect {
        let t = tileRect(i)
        return CGRect(x: t.minX + Self.tilePad, y: t.minY + Self.tilePad, width: thumbSize, height: thumbHeight)
    }

    func tile(at p: CGPoint) -> Int? {
        guard viewMode == .icons, listRect.contains(p) else { return nil }
        let n = gridItems().count
        return (0..<n).first { tileRect($0).contains(p) }
    }

    /// Double-click on a folder tile: the grid shows its content.
    public func enter(_ id: Bin.ID) {
        guard let model else { return }
        model.browseBin = id
        model.currentBin = id
        selection = []
        scroll = 0
    }

    /// The path row: back to the folder around the one shown.
    public func goUp() {
        guard let model, model.browseBin != model.project.rootBin.id else { return }
        let from = model.browseBin
        enter(model.project.rootBin.parent(of: .bin(from)) ?? model.project.rootBin.id)
        selection = [.bin(from)]
    }

    func drawGrid(_ c: inout Canvas, theme: DrawTheme, model: ProjectPanelModel) {
        let items = gridItems()
        for (i, ref) in items.enumerated() {
            let tile = tileRect(i)
            guard tile.maxY >= listRect.minY, tile.minY <= listRect.maxY else { continue }
            let thumb = thumbRect(i)
            let radius = CGFloat(DrawTheme.Radius.control)
            c.fill(roundedRect: thumb, radius: radius, theme.fill)
            var offline = false
            if case .media(let m) = ref { offline = model.isOffline(m) }
            if offline {
                drawGlyph(&c, .warning, in: thumb, Self.offlineRed)
            } else if case .media(let m) = ref, let p = tilePoster(i, media: m) {
                c.draw(imageSlot: p.slot, in: thumb, source: p.cropped(toFill: thumb))
                drawScrubLine(&c, theme: theme, item: i)
            } else {
                let kind = model.itemKind(of: ref)
                let glyph: SQIcon = switch ref {
                case .bin: .folderFilled
                case .sequence: .sequence
                case .media: SQIcon(rawValue: ProjectItemIcon.icon(for: kind).symbol) ?? .unknown
                }
                drawGlyph(&c, glyph, in: thumb, theme.clip(model.label(of: ref)))
            }
            // The label strip under the poster and the duration on it (media and sequences).
            if case .bin = ref {} else {
                c.fill(CGRect(x: thumb.minX, y: thumb.maxY - 3, width: thumb.width, height: 3), theme.clip(model.label(of: ref)))
                let d = model.cellText(.duration, ref)
                if !d.isEmpty {
                    let w = c.size(of: d, fontSize: 9).width + 8
                    let badge = CGRect(x: thumb.maxX - w - 4, y: thumb.maxY - 3 - 4 - 14, width: w, height: 14)
                    c.fill(roundedRect: badge, radius: CGFloat(DrawTheme.Radius.small), theme.viewerHUD)
                    c.draw(d, in: badge, fontSize: 9, theme.onClip, align: .center)
                }
            }
            if selection.contains(ref) {
                c.stroke(roundedRect: thumb.insetBy(dx: -Self.ringWidth, dy: -Self.ringWidth), radius: radius + Self.ringWidth,
                         width: Self.ringWidth, theme.accent)
            }
            let name = CGRect(x: tile.minX + 2, y: thumb.maxY + Self.tileNameGap, width: tile.width - 4, height: Self.tileNameHeight)
            c.draw(model.cellText(.name, ref), in: name, fontSize: CGFloat(DrawTheme.TypeSize.body),
                   offline ? Self.offlineRed : theme.label, align: .center)
        }
    }

    /// The kind glyph centered on the plate at 28% of the thumbnail width (`ProjectIconView.symbol`).
    private func drawGlyph(_ c: inout Canvas, _ icon: SQIcon, in r: CGRect, _ color: DrawColor) {
        let s = (thumbSize * 0.28).rounded()
        c.draw(icon: icon, at: CGPoint(x: r.midX - s / 2, y: r.midY - s / 2), size: s, color)
    }
}
