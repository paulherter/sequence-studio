import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

// Item lanes, translated from TimelineView+ItemLanes and +ItemLaneMove: a Graphic clip has a disclosure arrow at its
// head (a text or shape clip too: pressing it makes the clip a Graphic through the host, then opens the lanes). Opened,
// one lane per item appears under the clip's row (top item first); the bar in a lane is the part of the clip the item
// shows in (`GraphicsLayer.range`), moved and trimmed inside the clip. A lane name drags its layer: within the Graphic
// it reorders, onto another Graphic it moves there, onto a free stretch of a video track it becomes a new Graphic
// (Option copies). Which clips are open is view state. One clip per track can be open.

/// Measures of the item lanes (the Mac `ItemLanes`, in points).
enum ItemLaneMetrics {
    static let laneHeight = DrawTheme.Metrics.trackOther.cg
    static let barInset = DrawTheme.Spacing.xxs.cg
    static let stubWidth: CGFloat = 4
    static let chevronSize: CGFloat = 12
    static let dragSlop: CGFloat = 3
    static let openerWidth: CGFloat = 34

    static func isAvailable(for clip: Clip) -> Bool { !(clip.graphics?.layers.isEmpty ?? true) }
    static func space(items count: Int) -> CGFloat { CGFloat(count) * laneHeight }
    /// Graphic, text and shape clips are flat (no thumbnail column), so the arrow sits right of the head trim handle.
    static var chevronOffset: CGFloat { TimelineGeometry.maxTrimHandleWidth + 2 }
    static func openerWidth(clipWidth: CGFloat) -> CGFloat { clipWidth >= 90 ? openerWidth : chevronSize }
    /// How far the clip name moves right for the arrow in front of it.
    static func chevronReserve(clipWidth: CGFloat) -> CGFloat {
        clipWidth >= 40 ? chevronOffset + openerWidth(clipWidth: clipWidth) - 2 : 0
    }

    static func chevronRect(rect: CGRect, visible: CGRect) -> CGRect? {
        guard rect.width >= 40 else { return nil }
        let left = max(rect.minX, visible.minX) + chevronOffset
        let w = openerWidth(clipWidth: rect.width)
        let r = w > chevronSize ? CGRect(x: left, y: rect.minY, width: w, height: rect.height)
                                : CGRect(x: left, y: rect.minY + 4, width: w, height: chevronSize)
        return r.maxX + 2 <= min(rect.maxX, visible.maxX) - TimelineGeometry.maxTrimHandleWidth ? r : nil
    }

    static func laneY(row: TrackRow, index: Int) -> CGFloat { row.maxY + CGFloat(index) * laneHeight }

    static func barRect(x0: CGFloat, x1: CGFloat, laneY y: CGFloat) -> CGRect {
        CGRect(x: x0, y: y + barInset, width: max(x1 - x0, stubWidth), height: laneHeight - 2 * barInset - 1)
    }
}

/// A press on a bar that may become a move or a trim.
struct ItemLaneBarDrag: Sendable {
    enum Mode: Sendable { case move, head, tail }
    var original: Clip
    var item: UUID
    var mode: Mode
    var startX: CGFloat
    /// Timeline time under the press: the drag is measured in time, so it stays right while the timeline scrolls.
    var startTime: Time
    var startRange: TimeRange
    var last: Clip
    var moved = false
    var points: [SnapPoint]
}

/// Where a dragged layer would land.
enum ItemLaneDropTarget: Equatable, Sendable {
    /// Inside its own Graphic: `gap` counts lanes from the top (0 = above the top lane).
    case reorder(gap: Int)
    /// Another Graphic: `gap` as above, nil = on top.
    case graphic(Clip.ID, gap: Int?)
    case newGraphic(Track.ID)
}

/// A press on a lane name that may become a move.
struct ItemLaneNameDrag: Sendable {
    var clip: Clip
    /// Bottom first, as in the document.
    var ids: [UUID]
    var name: String
    var startY: CGFloat
    var pointer: CGPoint
    var moved = false
    var copy = false
    var target: ItemLaneDropTarget?
    /// Where the target shows (an insertion line, or the dashed outline of the new Graphic).
    var indicator: CGRect?
}

/// What lies under the pointer.
enum ItemLaneHit {
    case chevron(Clip.ID)
    case bar(clip: Clip, item: UUID, mode: ItemLaneBarDrag.Mode)
    case header(clip: Clip, item: UUID)
    /// Lane space with nothing to grab: the press is swallowed.
    case space
}

/// View state of the item lanes (the Mac `ItemLaneState` without the prepared CoreText headers).
struct ItemLaneState: Sendable {
    var open: Set<Clip.ID> = []
    /// Text or shape clips the host was asked to make Graphics: they open when the timeline shows them as Graphics.
    var pendingOpen: Set<Clip.ID> = []
    var selectedClip: Clip.ID?
    var selectedItems: Set<UUID> = []
    var drag: ItemLaneBarDrag?
    var move: ItemLaneNameDrag?
    /// The bar drag sent a change whose undo step is still open.
    var stepOpen = false
    /// Cmd+C in a lane: the shown range of the copied item (Cmd+V gives it to the selected items).
    var copiedRange: TimeRange?
}

extension TimelinePanel {
    // MARK: State

    /// The Graphic clips whose item lanes are open.
    public var openItemLanes: Set<Clip.ID> { itemLanes.open }

    /// The arrow is offered: a Graphic, or a text or shape clip that can become one.
    func itemLanesOffered(_ c: Clip) -> Bool {
        ItemLaneMetrics.isAvailable(for: c) || (c.isTextOrShape && timeline.makeGraphicBlocker(c) == nil)
    }

    /// Opens or closes the item lanes of a clip. Opening closes another open clip on the same track; a text or shape clip
    /// is first made a Graphic by the host (`.makeGraphic`) and opens once the timeline shows it as one.
    public mutating func toggleItemLanes(_ id: Clip.ID) -> [TimelineAction] {
        if itemLanes.open.contains(id) {
            itemLanes.open.remove(id)
        } else {
            guard let track = timeline.tracks.first(where: { t in t.clips.contains { $0.id == id } }),
                  let clip = track.clips.first(where: { $0.id == id }) else { return [] }
            if !ItemLaneMetrics.isAvailable(for: clip) {
                guard itemLanesOffered(clip), !track.isLocked else { return [] }
                itemLanes.pendingOpen.insert(id)
                return [.makeGraphic(id)]
            }
            for c in track.clips where itemLanes.open.contains(c.id) { itemLanes.open.remove(c.id) }
            itemLanes.open.insert(id)
        }
        syncItemLanes()
        clampScroll()
        return []
    }

    /// The items selected in the monitor and in Controls (the host calls this when that selection changes).
    public mutating func setItemSelection(clip: Clip.ID?, items: Set<UUID>) {
        itemLanes.selectedClip = clip
        itemLanes.selectedItems = clip == nil ? [] : items
    }

    public var itemSelection: (clip: Clip.ID?, items: Set<UUID>) { (itemLanes.selectedClip, itemLanes.selectedItems) }

    func openItemLaneClip(on track: Track) -> Clip? {
        itemLanes.open.isEmpty ? nil : track.clips.first { itemLanes.open.contains($0.id) }
    }

    /// After a timeline change: converted clips open, clips that are gone or have no lanes close, the lane space follows.
    mutating func syncItemLanes() {
        if !itemLanes.pendingOpen.isEmpty {
            let pending = itemLanes.pendingOpen
            itemLanes.pendingOpen = []
            for t in timeline.tracks {
                guard let c = t.clips.first(where: { pending.contains($0.id) && ItemLaneMetrics.isAvailable(for: $0) }) else { continue }
                for o in t.clips where itemLanes.open.contains(o.id) { itemLanes.open.remove(o.id) }
                itemLanes.open.insert(c.id)
            }
        }
        var kept = Set<Clip.ID>()
        var space: [Track.ID: CGFloat] = [:]
        if !itemLanes.open.isEmpty {
            for t in timeline.tracks {
                guard let c = t.clips.first(where: { itemLanes.open.contains($0.id) && ItemLaneMetrics.isAvailable(for: $0) }) else { continue }
                kept.insert(c.id)
                space[t.id] = ItemLaneMetrics.space(items: c.graphics?.layers.count ?? 0)
            }
        }
        itemLanes.open = kept
        if geometry.laneSpace != space { geometry.laneSpace = space }
        interaction.geometry = geometry
    }

    // MARK: Layout

    var itemLaneContent: CGRect {
        CGRect(x: TimelineGeometry.contentOriginX, y: 0, width: max(size.width - TimelineGeometry.contentOriginX, 0), height: size.height)
    }

    func itemLaneChevronRect(_ c: Clip, y: CGFloat, height: CGFloat) -> CGRect? {
        let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
        return ItemLaneMetrics.chevronRect(rect: CGRect(x: x0, y: y, width: x1 - x0, height: height), visible: itemLaneContent)
    }

    func itemLaneHit(at p: CGPoint) -> ItemLaneHit? {
        guard p.y >= TimelineGeometry.rulerHeight, p.x >= TimelineGeometry.toolColumnWidth else { return nil }
        for row in rows where p.y >= row.y && p.y < row.bottom {
            guard let track = timeline.track(row.track) else { return nil }
            if p.y < row.maxY {
                guard p.x >= TimelineGeometry.contentOriginX,
                      let c = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }),
                      itemLanesOffered(c), toolState.timelineTool == .selection else { return nil }
                let r = itemLaneChevronRect(c, y: row.y, height: row.height)
                return r?.insetBy(dx: -2, dy: -2).contains(p) == true ? .chevron(c.id) : nil
            }
            guard let c = openItemLaneClip(on: track), let doc = c.graphics, !doc.layers.isEmpty else { return .space }
            let index = min(Int((p.y - row.maxY) / ItemLaneMetrics.laneHeight), doc.layers.count - 1)
            let layer = doc.layers[doc.layers.count - 1 - index]
            if p.x < TimelineGeometry.contentOriginX { return .header(clip: c, item: layer.id) }
            let r = doc.shownRange(of: layer, clipDuration: c.timeline.duration)
            let bar = ItemLaneMetrics.barRect(x0: geometry.x(for: c.timeline.start + r.start), x1: geometry.x(for: c.timeline.start + r.end),
                                              laneY: ItemLaneMetrics.laneY(row: row, index: index))
            guard p.x >= bar.minX, p.x < bar.maxX else { return .space }
            let handle = TimelineGeometry.trimHandleWidth(forClipWidth: bar.width)
            let mode: ItemLaneBarDrag.Mode = p.x < bar.minX + handle ? .head : p.x >= bar.maxX - handle ? .tail : .move
            return .bar(clip: c, item: layer.id, mode: mode)
        }
        return nil
    }

    // MARK: Mouse

    /// A press on a disclosure arrow, a lane name, a bar or lane space; nil when the press is not the lanes'.
    mutating func itemLaneDown(_ p: CGPoint, modifiers mods: InputModifiers) -> [TimelineAction]? {
        guard let hit = itemLaneHit(at: p) else { return nil }
        gesture = .itemLane
        switch hit {
        case .space: return []
        case .chevron(let id): return toggleItemLanes(id)
        case .header(let clip, let item):
            let out = selectItemLane(clip: clip.id, item: item, modifiers: mods)
            if !mods.contains(.shift), !mods.contains(.command) { beginItemLaneMove(clip: clip, item: item, at: p) }
            return out
        case .bar(let clip, let item, let mode):
            let out = selectItemLane(clip: clip.id, item: item, modifiers: mods)
            // A locked item (or track) is selected only, like in the monitor.
            guard toolState.timelineTool == .selection, let doc = clip.graphics, let layer = doc.layer(item), !layer.isLocked,
                  timeline.tracks.first(where: { t in t.clips.contains { $0.id == clip.id } })?.isLocked == false else { return out }
            let base = clip.timeline.start
            var points = timeline.snapPoints(playhead: playhead, markers: interaction.markers)
                .filter { $0.time >= base && $0.time <= clip.timeline.end }
            for l in doc.layers where l.id != item {
                guard let r = l.range else { continue }
                points.append(SnapPoint(time: base + r.start, kind: .clipEdge))
                points.append(SnapPoint(time: base + r.end, kind: .clipEdge))
            }
            points.sort { $0.time < $1.time }
            itemLanes.drag = ItemLaneBarDrag(original: clip, item: item, mode: mode, startX: p.x,
                                             startTime: geometry.unsnappedTime(atX: p.x),
                                             startRange: doc.shownRange(of: layer, clipDuration: clip.timeline.duration),
                                             last: clip, points: points)
            return out
        }
    }

    private mutating func selectItemLane(clip: Clip.ID, item: UUID, modifiers mods: InputModifiers) -> [TimelineAction] {
        var items: Set<UUID> = [item]
        if mods.contains(.shift) || mods.contains(.command), itemLanes.selectedClip == clip {
            items = itemLanes.selectedItems.symmetricDifference([item])
        }
        setItemSelection(clip: clip, items: items)
        return [.selectItems(clip: clip, items: items)]
    }

    mutating func itemLaneDragged(to p: CGPoint) -> [TimelineAction] {
        if itemLanes.move != nil { itemLaneMoveDragged(to: p); return [] }
        guard var d = itemLanes.drag else { return [] }
        if !d.moved {
            guard abs(p.x - d.startX) >= ItemLaneMetrics.dragSlop else { return [] }
            d.moved = true
        }
        lastDrag = p
        guard var doc = d.original.graphics else { return [] }
        let fd = timeline.frameDuration, base = d.original.timeline.start, length = d.original.timeline.duration
        let dt = geometry.unsnappedTime(atX: p.x) - d.startTime
        let points = snapping ? d.points : []
        let threshold = geometry.snapThreshold()
        var hit: SnapPoint?
        switch d.mode {
        case .move:
            let start = base + d.startRange.start + dt
            let s = snapMove(start: start, duration: d.startRange.duration, to: points, threshold: threshold, frameDuration: fd)
            hit = s.hit
            doc.moveItemRange(d.item, toStart: start + s.delta - base, clipDuration: length)
        case .head, .tail:
            let s = snap(base + (d.mode == .head ? d.startRange.start : d.startRange.end) + dt, to: points, threshold: threshold, frameDuration: fd)
            hit = s.hit
            doc.trimItemRange(d.item, edge: d.mode == .head ? .head : .tail, to: s.time - base, clipDuration: length, minimum: fd)
        }
        // The line shows only where the bar really ended up (the clip's ends clamp it).
        if let h = hit, let l = doc.layer(d.item) {
            let r = doc.shownRange(of: l, clipDuration: length)
            if base + r.start != h.time, base + r.end != h.time { hit = nil }
        }
        scrubSnapTime = hit?.time
        var c = d.last
        c.graphics = doc
        itemLanes.drag = d
        guard c != d.last else { return [] }
        d.last = c
        itemLanes.drag = d
        previewItemLaneClip(c)
        let continues = itemLanes.stepOpen
        itemLanes.stepOpen = true
        return [.replaceClip(c, undoName: "Item Range", continues: continues)]
    }

    mutating func itemLaneUp(at p: CGPoint) -> [TimelineAction] {
        defer { itemLanes.drag = nil; itemLanes.move = nil; scrubSnapTime = nil }
        if itemLanes.move != nil { return itemLaneMoveUp(at: p) }
        guard let d = itemLanes.drag else { return [] }
        var out = d.moved ? itemLaneDragged(to: p) : []
        if itemLanes.stepOpen { out.append(.endGesture); itemLanes.stepOpen = false }
        return out
    }

    /// Esc during a bar drag: the clip goes back to what it was before the drag (its open step closes with it).
    mutating func cancelItemLaneDrag() -> [TimelineAction] {
        defer { itemLanes.drag = nil; itemLanes.move = nil; itemLanes.stepOpen = false }
        guard let d = itemLanes.drag, itemLanes.stepOpen else { return [] }
        return [.replaceClip(d.original, undoName: "Item Range", continues: true), .endGesture]
    }

    /// Shows the edited clip at once; the session gets the same edit through the action.
    private mutating func previewItemLaneClip(_ c: Clip) {
        var t = timeline
        guard (try? t.replaceClip(c)) != nil else { return }
        timeline = t
    }

    // MARK: Keys (Cmd+D duplicate, Cmd+C copy range, Cmd+V paste range)

    /// The three keys for the items selected in an open lane; nil when none applies (the shell gets the key).
    mutating func itemLaneKey(_ ch: Character, modifiers mods: InputModifiers) -> [TimelineAction]? {
        guard mods == .command, ["d", "c", "v"].contains(ch), gesture == nil,
              let id = itemLanes.selectedClip, !itemLanes.selectedItems.isEmpty,
              itemLanes.open.contains(id), toolState.timelineTool == .selection,
              let track = timeline.tracks.first(where: { t in t.clips.contains { $0.id == id } }), !track.isLocked,
              let clip = track.clips.first(where: { $0.id == id }), var doc = clip.graphics else { return nil }
        let ids = itemLanes.selectedItems
        let order = doc.layers.map(\.id).filter { ids.contains($0) }
        guard !order.isEmpty else { return nil }
        var out: [TimelineAction] = []
        switch ch {
        case "c":
            guard let first = doc.layer(order[0]) else { return nil }
            itemLanes.copiedRange = doc.shownRange(of: first, clipDuration: clip.timeline.duration)
            return []
        case "v":
            guard let r = itemLanes.copiedRange else { return nil }
            doc.setRange(r, for: ids, clipDuration: clip.timeline.duration)
        default:
            let copies = doc.duplicate(order)
            guard !copies.isEmpty else { return nil }
            setItemSelection(clip: id, items: Set(copies))
            out.append(.selectItems(clip: id, items: Set(copies)))
        }
        var edited = clip
        edited.graphics = doc
        guard edited != clip else { return out }
        previewItemLaneClip(edited)
        return [.replaceClip(edited, undoName: "Item Range", continues: false), .endGesture] + out
    }

    // MARK: Lane name drag (TimelineView+ItemLaneMove)

    private mutating func beginItemLaneMove(clip: Clip, item: UUID, at p: CGPoint) {
        guard toolState.timelineTool == .selection, let doc = clip.graphics, let layer = doc.layer(item), !layer.isLocked,
              timeline.tracks.first(where: { t in t.clips.contains { $0.id == clip.id } })?.isLocked == false else { return }
        let ids = itemLanes.selectedClip == clip.id && itemLanes.selectedItems.contains(item)
            ? doc.layers.map(\.id).filter { itemLanes.selectedItems.contains($0) } : [item]
        itemLanes.move = ItemLaneNameDrag(clip: clip, ids: ids, name: layer.name, startY: p.y, pointer: p)
    }

    private mutating func itemLaneMoveDragged(to p: CGPoint) {
        guard var m = itemLanes.move else { return }
        if !m.moved {
            guard abs(p.y - m.startY) >= ItemLaneMetrics.dragSlop else { return }
            m.moved = true
        }
        m.pointer = p
        m.copy = dragModifiers.contains(.option)
        let hit = itemLaneDropTarget(at: p, move: m)
        m.target = hit?.target
        m.indicator = hit?.indicator
        itemLanes.move = m
    }

    private mutating func itemLaneMoveUp(at p: CGPoint) -> [TimelineAction] {
        guard itemLanes.move?.moved == true else { return [] }
        itemLaneMoveDragged(to: p)
        guard let m = itemLanes.move, let target = m.target else { return [] }
        switch target {
        case .reorder(let gap):
            guard !m.copy, let doc = m.clip.graphics else { return [] }
            let moving = Set(m.ids)
            let above = doc.layers.reversed().prefix(gap).filter { !moving.contains($0.id) }.count
            let rest = doc.layers.count - moving.count
            return [.reorderItems(clip: m.clip.id, ids: m.ids, toIndex: rest - above)]
        case .graphic(let id, let gap):
            let count = timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }?.graphics?.layers.count ?? 0
            return [.moveItemsOut(clip: m.clip.id, ids: m.ids, to: .graphic(id, index: gap.map { count - $0 }), copy: m.copy)]
        case .newGraphic(let track):
            return [.moveItemsOut(clip: m.clip.id, ids: m.ids, to: .newGraphic(track: track), copy: m.copy)]
        }
    }

    /// The drop under the pointer, nil when the layers cannot land there (nothing is highlighted then).
    func itemLaneDropTarget(at p: CGPoint, move m: ItemLaneNameDrag) -> (target: ItemLaneDropTarget, indicator: CGRect)? {
        guard p.x >= TimelineGeometry.toolColumnWidth, p.y >= TimelineGeometry.rulerHeight, let doc = m.clip.graphics else { return nil }
        let spans = doc.extractedCopies(m.ids, clipStart: m.clip.timeline.start, clipDuration: m.clip.timeline.duration).map(\.span)
        guard let from = spans.map(\.start).min(), let to = spans.map(\.end).max() else { return nil }
        let union = TimeRange(start: from, end: max(to, from + timeline.frameDuration))
        for row in rows where p.y >= row.y && p.y < row.bottom {
            guard row.kind == .video, let track = timeline.track(row.track), !track.isLocked else { return nil }
            if p.y >= row.maxY {
                guard let c = openItemLaneClip(on: track), let d = c.graphics else { return nil }
                let gap = min(max(Int(((p.y - row.maxY) / ItemLaneMetrics.laneHeight).rounded()), 0), d.layers.count)
                let line = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.maxY + CGFloat(gap) * ItemLaneMetrics.laneHeight - 1,
                                  width: max(geometry.x(for: c.timeline.end) - TimelineGeometry.toolColumnWidth, 0), height: 2)
                if c.id == m.clip.id { return m.copy ? nil : (.reorder(gap: gap), line) }
                guard spans.allSatisfy({ $0.overlaps(c.timeline) }) else { return nil }
                return (.graphic(c.id, gap: gap), line)
            }
            if let c = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }) {
                guard c.isGraphics, c.id != m.clip.id, spans.allSatisfy({ $0.overlaps(c.timeline) }) else { return nil }
                return (.graphic(c.id, gap: nil), CGRect(x: geometry.x(for: c.timeline.start), y: row.y,
                                                         width: geometry.width(of: c.timeline.duration), height: row.height - 1))
            }
            guard !track.clips.contains(where: { $0.timeline.overlaps(union) }) else { return nil }
            return (.newGraphic(track.id), CGRect(x: geometry.x(for: union.start), y: row.y,
                                                  width: max(geometry.width(of: union.duration), 2), height: row.height - 1))
        }
        return nil
    }

    // MARK: Drawing

    /// The disclosure arrow (with the layer count on a wide clip) at a clip's head.
    func drawItemLaneChevron(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect) {
        guard itemLanesOffered(c), let r = ItemLaneMetrics.chevronRect(rect: rect, visible: visible) else { return }
        let open = itemLanes.open.contains(c.id)
        let box = r.width > ItemLaneMetrics.chevronSize
            ? CGRect(x: r.minX, y: r.minY + 4, width: ItemLaneMetrics.chevronSize, height: ItemLaneMetrics.chevronSize) : r
        cv.draw(icon: open ? .chevronDown : .chevronRight, at: CGPoint(x: box.midX - 4.5, y: box.midY - 4.5), size: 9, theme.label)
        guard r.width > ItemLaneMetrics.chevronSize else { return }
        cv.draw("\(c.graphics?.layers.count ?? 0)", at: CGPoint(x: box.maxX + 2, y: box.minY - 1),
                fontSize: DrawTheme.TypeSize.caption.cg, theme.label)
    }

    /// Lanes and bars of the open clips, inside the content clip.
    func drawItemLanes(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        guard !itemLanes.open.isEmpty else { return }
        let laneH = ItemLaneMetrics.laneHeight
        for row in rows where row.laneSpace > 0 && row.maxY < clip.maxY && row.bottom > clip.minY {
            guard let track = timeline.track(row.track), let c = openItemLaneClip(on: track), let doc = c.graphics else { continue }
            let start = c.timeline.start, length = c.timeline.duration
            let x0 = max(geometry.x(for: start), clip.minX), x1 = min(geometry.x(for: c.timeline.end), clip.maxX)
            guard x1 > x0 else { continue }
            let selectedClip = itemLanes.selectedClip == c.id
            for (index, layer) in doc.layers.reversed().enumerated() {
                let y = row.maxY + CGFloat(index) * laneH
                guard y < clip.maxY, y + laneH > clip.minY else { continue }
                cv.fill(CGRect(x: x0, y: y, width: x1 - x0, height: laneH), theme.lane)
                cv.fill(CGRect(x: x0, y: y + laneH - 1, width: x1 - x0, height: 1), theme.trackRowLine)
                let r = layer.range ?? TimeRange(start: .zero, duration: length)
                let bar = ItemLaneMetrics.barRect(x0: geometry.x(for: start + r.start), x1: geometry.x(for: start + r.end), laneY: y)
                let shown = CGRect(x: max(bar.minX, clip.minX - 8), y: bar.minY,
                                   width: min(bar.maxX, clip.maxX + 8) - max(bar.minX, clip.minX - 8), height: bar.height)
                guard shown.width > 0 else { continue }
                let selected = selectedClip && itemLanes.selectedItems.contains(layer.id)
                cv.fill(roundedRect: shown, radius: DrawTheme.Radius.small.cg, selected ? theme.accent : theme.accent.alpha(0.45))
                if selected {
                    cv.stroke(roundedRect: shown.insetBy(dx: 0.5, dy: 0.5), radius: DrawTheme.Radius.small.cg, width: 1, theme.yellow)
                }
            }
        }
    }

    /// Icon and name of every lane in the header column.
    func drawItemLaneHeaders(_ cv: inout Canvas, rows: [TrackRow]) {
        guard !itemLanes.open.isEmpty else { return }
        let x = TimelineGeometry.toolColumnWidth, w = TimelineGeometry.headerWidth, laneH = ItemLaneMetrics.laneHeight
        let bottom = zoomBarRect.minY
        let sm = DrawTheme.Spacing.sm.cg
        for row in rows where row.laneSpace > 0 {
            guard let track = timeline.track(row.track), let c = openItemLaneClip(on: track), let doc = c.graphics else { continue }
            for (index, l) in doc.layers.reversed().enumerated() {
                let r = CGRect(x: x, y: row.maxY + CGFloat(index) * laneH, width: w, height: laneH)
                guard r.minY >= TimelineGeometry.rulerHeight, r.maxY <= bottom else { continue }
                let sel = itemLanes.selectedClip == c.id && itemLanes.selectedItems.contains(l.id)
                cv.fill(r, theme.panel)
                if sel { cv.fill(r, theme.selection) }
                cv.fill(CGRect(x: x, y: r.maxY - 1, width: w, height: 1), theme.trackHeaderLine)
                let color = sel ? theme.label : theme.label2
                let iconBox = CGRect(x: x + sm, y: r.minY, width: ItemLaneMetrics.chevronSize, height: laneH - 1)
                cv.draw(icon: LayerListLogic.symbol(l), at: CGPoint(x: iconBox.midX - 5, y: iconBox.midY - 5), size: 10, color)
                let textX = iconBox.maxX + DrawTheme.Spacing.xs.cg
                cv.draw(l.name, in: CGRect(x: textX, y: r.minY, width: max(r.maxX - sm - textX, 0), height: laneH - 1),
                        fontSize: DrawTheme.TypeSize.body.cg, color)
            }
        }
    }

    /// The lane name drag's ghost: the target (insertion line or dashed clip) and the name chip under the pointer.
    func drawItemLaneMoveGhost(_ cv: inout Canvas) {
        guard let m = itemLanes.move, m.moved else { return }
        let radius = DrawTheme.Radius.small.cg, ghostAlpha: Float = 0.55       // `Theme.OnPicture.clipGhostAlpha`
        if let r = m.indicator {
            if r.height <= 2 { cv.fill(r, theme.accent) }
            else {
                cv.fill(roundedRect: r, radius: radius, theme.clip(.videoDefault).alpha(ghostAlpha))
                cv.strokeDashed(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: radius, width: 1, on: 4, off: 3, theme.accent)
            }
        }
        let laneH = ItemLaneMetrics.laneHeight
        let chip = CGRect(x: m.pointer.x - TimelineGeometry.headerWidth / 2, y: m.pointer.y - laneH / 2,
                          width: TimelineGeometry.headerWidth, height: laneH)
        cv.fill(roundedRect: chip, radius: radius, theme.accent.alpha(m.target == nil ? ghostAlpha / 2 : ghostAlpha))
        let label = m.ids.count > 1 ? "\(m.name) +\(m.ids.count - 1)" : m.name
        cv.draw(label, in: chip, fontSize: DrawTheme.TypeSize.body.cg, theme.label, inset: DrawTheme.Spacing.sm.cg)
    }
}
