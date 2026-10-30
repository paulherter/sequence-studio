import Foundation
import SQCore
import SQDrawKit
import SQEditorSession

/// Moving items between folders by dragging inside the Project panel, the Mac outline's `validateDrop` / `acceptDrop` and the
/// icon grid's `validateDrop` / `onDropOnto`: the middle of a folder row drops into it, the middle of any other row into
/// that row's folder, the top and bottom quarter of a row insert between rows, empty space appends to
/// the root, and a folder never goes into itself.
extension ProjectListView {
    struct MoveTarget: Equatable {
        var bin: Bin.ID
        /// The index among the folder's children before the moved items are removed; nil appends.
        var index: Int?
        /// Where the cue is drawn: a folder row or tile outlined, or an insertion line.
        var cue: CGRect
        var isLine: Bool
    }

    /// The edge band of a row that reads as "between rows".
    static let insertBand: CGFloat = 0.25

    /// Where dropping the dragged `refs` at `p` would put them, nil when nothing accepts them there.
    func moveTarget(at p: CGPoint, moving refs: [BinItemRef]) -> MoveTarget? {
        guard let model, listRect.contains(p), !refs.isEmpty,
              case .move(let items) = model.classifyDrop(items: refs, files: []) else { return nil }
        let project = model.project
        func accepts(_ bin: Bin.ID) -> Bool {
            for case .bin(let id) in items {
                if id == bin { return false }
                if let moving = project.bin(id), moving.bin(bin) != nil { return false }   // into itself or a descendant
            }
            return true
        }
        if viewMode == .icons {
            guard let i = tile(at: p), case .bin(let id) = gridItems()[i], accepts(id) else { return nil }
            return MoveTarget(bin: id, index: nil, cue: tileRect(i), isLine: false)
        }
        let list = rows()
        guard let i = row(at: p) else {
            let root = project.rootBin.id
            guard accepts(root) else { return nil }
            return MoveTarget(bin: root, index: nil, cue: listRect, isLine: false)
        }
        let rr = rowRect(i), ref = list[i].ref
        let parent = project.rootBin.parent(of: ref) ?? project.rootBin.id
        // Between rows the line shows in every order, like the Mac outline; only where the order is the bin's own (no sort,
        // no filter, no grouped root) does the drop carry an index, otherwise it appends (the Mac `acceptDrop`).
        let ordered = model.sortColumn == nil && !model.isFiltering
        let edge = rr.height * Self.insertBand
        if p.y < rr.minY + edge || p.y > rr.maxY - edge, accepts(parent), let bin = project.bin(parent) {
            let rootGrouped = parent == project.rootBin.id && list.filter({ $0.depth == 0 }).map(\.ref) != bin.children.map(\.ref)
            let at = bin.children.firstIndex(where: { $0.ref == ref })
            let before = p.y < rr.midY
            let y = before ? rr.minY : rr.maxY
            let index: Int? = ordered && !rootGrouped ? at.map { before ? $0 : $0 + 1 } : nil
            return MoveTarget(bin: parent, index: index, cue: CGRect(x: rr.minX, y: y - 1, width: rr.width, height: 2), isLine: true)
        }
        if case .bin(let id) = ref {
            return accepts(id) ? MoveTarget(bin: id, index: nil, cue: rr, isLine: false) : nil
        }
        return accepts(parent) ? MoveTarget(bin: parent, index: nil, cue: rr, isLine: false) : nil
    }

    /// Drops the moved items on `target` (the Mac `acceptDrop` index rule: the index counts the children after the moved
    /// items were taken out).
    @discardableResult
    func dropMove(_ refs: [BinItemRef], on target: MoveTarget) -> Bool {
        guard let model, let dest = model.project.bin(target.bin) else { return false }
        var at: Int?
        if let index = target.index {
            let before = dest.children.prefix(index).filter { refs.contains($0.ref) }.count
            at = index - before
        }
        _ = model.move(refs, to: target.bin, at: at)
        return true
    }

    func drawMoveTarget(_ c: inout Canvas, theme: DrawTheme) {
        guard let t = moveTarget else { return }
        if t.isLine {
            c.fill(t.cue, theme.accent)
        } else {
            c.stroke(roundedRect: t.cue.insetBy(dx: 1, dy: 1), radius: CGFloat(DrawTheme.Radius.small), width: 2, theme.accent)
        }
    }
}
