import Foundation
import SQCore
import SQDrawKit
import SQUIKit

/// The pure layout of the Color page's Clips strip, shared by the Mac `ColorClipsPanelView` and `ColorSourcesDraw`.
public enum ColorSourcesLayout {
    /// Strip padding and the gap between tiles (design source: 14 / 14).
    public static let pad: CGFloat = 14
    /// Thumbnail to name, and name to the uses line.
    public static let lineGap: CGFloat = 5
    public static let ring: CGFloat = 2

    /// The sources a tile stands for: picture sources only.
    public static func tiles(_ timeline: Timeline?, project: Project) -> [ColorSourceListItem] {
        ColorSourceListItem.items(timeline, project: project).filter { !$0.isAdjustment }
    }

    /// Thumbnail size in the shape of the sequence: 104 x 184 for portrait, 184 x 104 for landscape, 144 square.
    public static func thumbSize(_ f: ColorPageFormat) -> CGSize {
        switch f {
        case .portrait: CGSize(width: 104, height: 184)
        case .landscape: CGSize(width: 184, height: 104)
        case .square: CGSize(width: 144, height: 144)
        }
    }

    /// What the empty state says (nil = there are tiles).
    public static func emptyState(hasSequence: Bool, itemCount: Int) -> (title: String, hint: String)? {
        if !hasSequence { return ("No sequence open", "Open a sequence to grade its clips.") }
        if itemCount == 0 { return ("No video clips", "Add clips to the sequence to grade them.") }
        return nil
    }

    /// The tile an arrow key moves to: the next/previous one, none beyond the ends; from no tile the first/last.
    public static func steppedIndex(from: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let from else { return forward ? 0 : count - 1 }
        return min(max(from + (forward ? 1 : -1), 0), count - 1)
    }

    /// The media time a tile shows: the middle of the source range its first cut uses (the frame the cut is about,
    /// not the media's poster). nil when the tile has no cut.
    public static func frameTime(of item: ColorSourceListItem, in timeline: Timeline?) -> Time? {
        guard let id = item.clips.first, let c = timeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              c.source.duration > .zero else { return nil }
        let mid = c.source.start + Time(c.source.duration.value, c.source.duration.timescale * 2)
        return min(mid, max(c.source.start, c.source.end - Time(1, 1000)))
    }

    /// The part (normalized u0, v0, u1, v1) of a `pixelSize` picture at `source` that fills a `box` sized tile without
    /// distortion: centered, the longer side cut (the Mac tile draws the image aspect-filled).
    public static func fillSource(pixelSize: CGSize, box: CGSize,
                                  source s: (Float, Float, Float, Float) = (0, 0, 1, 1)) -> (Float, Float, Float, Float) {
        guard pixelSize.width > 0, pixelSize.height > 0, box.width > 0, box.height > 0 else { return s }
        let pic = pixelSize.width / pixelSize.height, tile = box.width / box.height
        var u0 = s.0, v0 = s.1, u1 = s.2, v1 = s.3
        if pic > tile {             // wider picture: cut left and right
            let keep = Float(tile / pic), cut = (u1 - u0) * (1 - keep) / 2
            u0 += cut; u1 -= cut
        } else if pic < tile {      // taller picture: cut top and bottom
            let keep = Float(pic / tile), cut = (v1 - v0) * (1 - keep) / 2
            v0 += cut; v1 -= cut
        }
        return (u0, v0, u1, v1)
    }

    /// The tile of the source being graded: the one holding `picked` (none while the whole sequence is graded).
    public static func highlighted(_ items: [ColorSourceListItem], wholeSequence: Bool, picked: Clip.ID?) -> Int? {
        guard !wholeSequence, let picked else { return nil }
        return items.firstIndex { $0.clips.contains(picked) }
    }

    /// The menu of a tile: copy / paste of the grade, "Link All Cuts" for a source used more than once.
    @MainActor
    public static func menu(_ item: ColorSourceListItem?, controller: ColorGradeController) -> [SQMenuItem] {
        var entries: [SQMenuItem] = [
            SQMenuItem(title: "Copy Grade", shortcut: "\u{2318}C") { [weak controller] in _ = controller?.copyGrade() },
            SQMenuItem(title: "Paste Grade", shortcut: "\u{2318}V", isEnabled: controller.canPasteGrade) { [weak controller] in
                _ = controller?.pasteGrade()
            },
        ]
        if let item, item.clips.count > 1 {
            entries.append(.separator)
            entries.append(SQMenuItem(title: "Link All Cuts") { [weak controller] in controller?.linkAllUses(item) })
        }
        return entries
    }
}

/// The Clips strip of the Color page as shared-toolkit draw code (Windows; translated from `ColorClipsPanelView`): one
/// tile per source file of the active sequence in one row, the graded source with the yellow ring; click grades every
/// use, right-click opens the grade menu, the arrow keys step through the sources. Scrolls sideways.
/// Tile pictures come from `thumbnail` (the host's image slots: on Windows the timeline's thumbnail atlas), the frame of
/// the first cut (`ColorSourcesLayout.frameTime`), aspect-filled; a plain fill until it is decoded.
@MainActor
public final class ColorSourcesDraw {
    public let controller: ColorGradeController
    public var theme = DrawTheme()
    public var size = CGSize(width: 600, height: 200)
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// A source's picture at a media time (nil = the poster): image slot, normalized part of the slot and its pixel
    /// size; nil while it is not decoded yet.
    public var thumbnail: (@MainActor (_ media: UUID, _ at: Time?) -> Thumbnail?)?
    public struct Thumbnail: Sendable {
        public var slot: Int
        public var source: (Float, Float, Float, Float)
        public var pixelSize: CGSize
        public init(slot: Int, source: (Float, Float, Float, Float), pixelSize: CGSize) {
            self.slot = slot; self.source = source; self.pixelSize = pixelSize
        }
    }
    public private(set) var scrollX: CGFloat = 0
    private(set) var hovered: Int?

    public init(controller: ColorGradeController) { self.controller = controller }

    var session: EditorSession { controller.session }
    var items: [ColorSourceListItem] { ColorSourcesLayout.tiles(session.activeTimeline, project: session.project) }
    var highlighted: Int? {
        ColorSourcesLayout.highlighted(items, wholeSequence: controller.isWholeSequence, picked: controller.target.pick)
    }
    private var lineHeight: CGFloat { CGFloat(DrawTheme.TypeSize.body) + 4 }

    var tileSize: CGSize {
        let t = ColorSourcesLayout.thumbSize(controller.format)
        return CGSize(width: t.width, height: t.height + 2 * (ColorSourcesLayout.lineGap + lineHeight))
    }

    /// Tile `i` in panel coordinates (the scroll applied).
    func tileRect(_ i: Int) -> CGRect {
        let p = ColorSourcesLayout.pad, s = tileSize
        return CGRect(x: p + CGFloat(i) * (s.width + p) - scrollX, y: p, width: s.width, height: s.height)
    }

    var contentWidth: CGFloat {
        let n = CGFloat(items.count), p = ColorSourcesLayout.pad
        return 2 * p + n * tileSize.width + max(n - 1, 0) * p
    }

    func tileIndex(at p: CGPoint) -> Int? { items.indices.first { tileRect($0).contains(p) } }

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        let bounds = CGRect(origin: .zero, size: size)
        c.fill(bounds, t.content)
        let list = items
        if let e = ColorSourcesLayout.emptyState(hasSequence: session.activeTimeline != nil, itemCount: list.count) {
            c.draw(SQL10n.string(e.title), in: CGRect(x: 0, y: bounds.midY - 18, width: bounds.width, height: 18),
                   fontSize: CGFloat(DrawTheme.TypeSize.title), t.label2, align: .center, face: c.semibold)
            c.draw(SQL10n.string(e.hint), in: CGRect(x: 0, y: bounds.midY + 2, width: bounds.width, height: 16),
                   fontSize: fs, t.label3, align: .center)
            return
        }
        clampScroll()
        let ts = ColorSourcesLayout.thumbSize(controller.format), gap = ColorSourcesLayout.lineGap, lh = lineHeight
        let ring = highlighted, radius = CGFloat(DrawTheme.Radius.control)
        c.saveGState()
        c.clip(to: bounds)
        for (i, item) in list.enumerated() {
            let r = tileRect(i)
            guard r.maxX >= -4, r.minX <= bounds.maxX + 4 else { continue }
            let thumb = CGRect(x: r.minX, y: r.minY, width: ts.width, height: ts.height)
            c.fill(roundedRect: thumb, radius: radius, i == hovered ? t.fillHover : t.fill)
            if let p = thumbnail?(item.media, ColorSourcesLayout.frameTime(of: item, in: session.activeTimeline)) {
                c.draw(imageSlot: p.slot, in: thumb,
                       source: ColorSourcesLayout.fillSource(pixelSize: p.pixelSize, box: thumb.size, source: p.source))
            }
            if i == ring {
                let w = ColorSourcesLayout.ring
                c.stroke(roundedRect: thumb.insetBy(dx: -w / 2, dy: -w / 2), radius: radius + w / 2, width: w, t.yellow)
            }
            c.draw(item.name, at: CGPoint(x: r.minX, y: thumb.maxY + gap), fontSize: fs, t.label, maxWidth: r.width)
            c.draw(SQL10n.string(ColorUses.tileLine(uses: item.clips.count, grade: item.gradeText)),
                   at: CGPoint(x: r.minX, y: thumb.maxY + 2 * gap + lh), fontSize: fs, t.label3, maxWidth: r.width)
        }
        c.restoreGState()
    }

    private func clampScroll() { scrollX = min(max(scrollX, 0), max(contentWidth - size.width, 0)) }

    public func mouseMoved(to p: CGPoint?) { hovered = p.flatMap(tileIndex) }

    /// The tip under the pointer (HostHover): the tile's whole name (names are cut at the tile width).
    public func help(at p: CGPoint) -> String? { tileIndex(at: p).map { items[$0].name } }

    /// A click grades every use of the tile's source; secondary opens the grade menu.
    public func mouseDown(at p: CGPoint, modifiers: InputModifiers = []) {
        guard let i = tileIndex(at: p) else { return }
        let list = items
        controller.pickSource(list[i])
        if modifiers.contains(.secondary) {
            onMenu?(ColorSourcesLayout.menu(list[i], controller: controller), CGRect(x: p.x, y: p.y, width: 1, height: 1))
        }
    }

    public func scroll(dx: CGFloat, dy: CGFloat) {
        scrollX += abs(dx) > abs(dy) ? -dx : -dy
        clampScroll()
    }

    /// The arrow keys step through the sources and grade the one reached (and scroll it into view).
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        let forward: Bool
        switch k {
        case .right, .down: forward = true
        case .left, .up: forward = false
        default: return false
        }
        let list = items
        guard let i = ColorSourcesLayout.steppedIndex(from: highlighted, count: list.count, forward: forward) else { return true }
        controller.pickSource(list[i])
        let r = tileRect(i), p = ColorSourcesLayout.pad
        if r.minX < p { scrollX += r.minX - p } else if r.maxX > size.width - p { scrollX += r.maxX - size.width + p }
        clampScroll()
        return true
    }
}
