import Foundation
import SQDrawKit

/// Rubber-band selection on the grid's empty background: the AppKit grid is an `NSCollectionView`, which selects the tiles a
/// drag from empty space crosses (Cmd or Shift keeps the earlier selection). The list has none (`NSTableView`).
extension LibraryDrawPanel {
    struct Marquee {
        /// Content coordinates (y from the list top, before scrolling), so scrolling keeps the band on its tiles.
        var start: CGPoint
        var current: CGPoint
        var base: Set<String>
        var rect: CGRect {
            CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
        }
    }

    func contentPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - listRect.minX, y: p.y - listRect.minY + scroll) }

    func beginMarquee(at p: CGPoint, modifiers m: InputModifiers) {
        guard model.viewMode == .grid, !m.contains(.secondary), listRect.contains(p) else { return }
        let q = contentPoint(p)
        marquee = Marquee(start: q, current: q, base: m.contains(.command) || m.contains(.shift) ? selected : [])
    }

    func dragMarquee(to p: CGPoint) {
        guard var mq = marquee else { return }
        mq.current = contentPoint(CGPoint(x: min(max(p.x, listRect.minX), listRect.maxX), y: p.y))
        marquee = mq
        let hit = placed().filter { !cells[$0.index].isHeader && $0.frame.intersects(mq.rect) }.map { cells[$0.index].key }
        let next = mq.base.union(hit)
        guard next != selected else { return }
        selected = next
        previewSelection()
    }

    func drawMarquee(_ c: inout Canvas) {
        guard let mq = marquee, mq.rect.width > 0 || mq.rect.height > 0 else { return }
        let r = mq.rect.offsetBy(dx: listRect.minX, dy: listRect.minY - scroll)
        c.fill(r, theme.accent.alpha(0.18))
        c.stroke(roundedRect: r, radius: 0, width: 1, theme.accent)
    }
}
