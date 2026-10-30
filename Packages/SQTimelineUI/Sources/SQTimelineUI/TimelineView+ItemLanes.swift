import AppKit
import CoreText
import SQCore

// Item lanes: a Graphic clip has a disclosure arrow at its head (a text or shape clip has it too: pressing it makes the
// clip a Graphic through the host, then opens the lanes). Opened, one lane per item
// appears under the clip's row (top item first); the bar in a lane is the part of the clip the item shows in
// (`GraphicsLayer.range`). A bar can be moved and trimmed inside the clip. Which clips are open is view state.
// One clip per track can be open, so the lane names in the header column are unambiguous.

/// Measures, drawing pieces and layout of the item lanes.
@MainActor
public enum ItemLanes {
    /// Height of one lane: the compact track height.
    public static let laneHeight = Theme.Metrics.trackOther
    /// Space between a bar and its lane's edges.
    static let barInset = Theme.Spacing.xxs
    static let barRadius = Theme.Radius.small
    /// The least width a bar is drawn and grabbed with (an item whose range was clamped to nothing still shows a stub).
    static let stubWidth: CGFloat = 4
    static let chevronSize: CGFloat = 12
    /// Pointer travel before a press on a bar becomes a drag.
    static let dragSlop: CGFloat = 3

    /// The clip can be opened: a Graphic with at least one item.
    public static func isAvailable(for clip: Clip) -> Bool { !(clip.graphics?.layers.isEmpty ?? true) }

    /// Lane space under the row of a track whose opened clip has `count` items.
    public static func space(items count: Int) -> CGFloat { CGFloat(count) * laneHeight }

    /// The arrow's left edge, measured from where the clip's name area starts (after the thumbnail column `thumb`, or the
    /// left edge of the view while the head is scrolled out): always right of the head trim handle.
    static func chevronOffset(thumb: CGFloat) -> CGFloat { max(TimelineGeometry.maxTrimHandleWidth - thumb, 0) + 2 }

    /// Width of the opener: a 34 pt full-height strip with the arrow and the layer count on a clip at least 90 pt wide,
    /// the bare arrow below that.
    static let openerWidth: CGFloat = 34
    static func openerWidth(clipWidth: CGFloat) -> CGFloat { clipWidth >= 90 ? openerWidth : chevronSize }

    /// How far the clip name moves right for the disclosure arrow in front of it (`ClipDrawing.draw(leadingReserve:)`).
    public static func chevronReserve(clipWidth: CGFloat, thumb: CGFloat) -> CGFloat {
        clipWidth >= 40 ? chevronOffset(thumb: thumb) + openerWidth(clipWidth: clipWidth) - 2 : 0
    }

    /// The disclosure arrow of a clip drawn in `rect`: at the head, in front of the name and clear of both trim handles;
    /// nil when the clip is too narrow. `thumb`: width of the clip's thumbnail column (0 = none).
    public static func chevronRect(rect: CGRect, visible: CGRect, thumb: CGFloat) -> CGRect? {
        guard rect.width >= 40 else { return nil }
        let left = max(rect.minX + thumb, visible.minX) + chevronOffset(thumb: thumb)
        let w = openerWidth(clipWidth: rect.width)
        let r = w > chevronSize ? CGRect(x: left, y: rect.minY, width: w, height: rect.height)
                                : CGRect(x: left, y: rect.minY + 4, width: w, height: chevronSize)
        return r.maxX + 2 <= min(rect.maxX, visible.maxX) - TimelineGeometry.maxTrimHandleWidth ? r : nil
    }

    /// The lane of the item at `index` from the top (0 = top item) under a row.
    public static func laneY(row: TrackRow, index: Int) -> CGFloat { row.maxY + CGFloat(index) * laneHeight }

    /// The bar of a range inside a lane starting at `y`; `x0`/`x1` are the range's ends.
    static func barRect(x0: CGFloat, x1: CGFloat, laneY y: CGFloat) -> CGRect {
        CGRect(x: x0, y: y + barInset, width: max(x1 - x0, stubWidth), height: laneHeight - 2 * barInset - 1)
    }

    // MARK: Drawing pieces (built once)

    static let laneFill = Theme.Colors.lane.cgColor
    static let laneLine = Theme.Colors.trackRowLine.cgColor
    public static let barFill = Theme.TimelineSkin.itemBar.cgColor
    static let barFillSelected = Theme.Colors.accent.cgColor
    static let barOutline = Theme.Colors.clipSelect.cgColor
    static let headerFill = Theme.Colors.panel.cgColor
    static let headerSelected = Theme.Colors.selection.cgColor
    static let headerLine = Theme.Colors.trackHeaderLine.cgColor
    static let chevronClosed = icon(.chevronRight, color: Theme.Colors.label, size: 9)
    static let chevronOpen = icon(.chevronDown, color: Theme.Colors.label, size: 9)

    /// An icon as a tinted bitmap (2x), for drawing without AppKit image work per frame.
    static func icon(_ name: SQIcon, color: NSColor, size: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard let img = Theme.symbol(name, size: size) else { return nil }
        let s = img.size
        guard s.width > 0, s.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((s.width * 2).rounded(.up)), pixelsHigh: Int((s.height * 2).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = s
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = CGRect(origin: .zero, size: s)
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage.map { ($0, s) }
    }

    /// Draws a bitmap upright in a flipped view, centered in `rect`.
    static func draw(_ icon: (image: CGImage, size: CGSize), centeredIn rect: CGRect, cg: CGContext) {
        let x = (rect.midX - icon.size.width / 2).rounded(), y = (rect.midY - icon.size.height / 2).rounded()
        cg.saveGState()
        cg.translateBy(x: x, y: y + icon.size.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(icon.image, in: CGRect(origin: .zero, size: icon.size))
        cg.restoreGState()
    }

    static func drawChevron(rect: CGRect, visible: CGRect, open: Bool, thumb: CGFloat, count: Int = 0) {
        guard let r = chevronRect(rect: rect, visible: visible, thumb: thumb), let cg = NSGraphicsContext.current?.cgContext,
              let icon = open ? chevronOpen : chevronClosed else { return }
        guard r.width > chevronSize else { draw(icon, centeredIn: r, cg: cg); return }
        // Opener strip: arrow on the left, layer count right of it, both centered on the row.
        draw(icon, centeredIn: CGRect(x: r.minX, y: r.minY + 4, width: chevronSize, height: chevronSize), cg: cg)
        let text = NSAttributedString(string: "\(count)", attributes: [.font: Theme.Typography.caption,
                                                                      .foregroundColor: Theme.Colors.label])
        let s = text.size()
        text.draw(at: CGPoint(x: r.minX + chevronSize + 2, y: r.minY + 4 + (chevronSize - s.height) / 2))
    }

    /// A rounded rectangle path in the context (no path object).
    static func addRounded(_ r: CGRect, radius: CGFloat, to cg: CGContext) {
        let k = min(radius, r.width / 2, r.height / 2)
        cg.beginPath()
        cg.move(to: CGPoint(x: r.minX + k, y: r.minY))
        cg.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: k)
        cg.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: k)
        cg.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: k)
        cg.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: k)
        cg.closePath()
    }
}

/// One prepared lane name in the header column.
struct ItemLaneHeader {
    var item: UUID
    var line: CTLine
    var icon: (image: CGImage, size: CGSize)?
    var selected: Bool
}

/// What a header was built from (rebuilt only when this changes).
struct ItemLaneHeaderKey: Equatable {
    var track: Track.ID
    var item: UUID
    var name: String
    var symbol: SQIcon
    var selected: Bool
}

/// A press on a bar that may become a move or a trim.
struct ItemLaneDrag {
    enum Mode { case move, head, tail }
    var original: Clip
    var item: UUID
    var mode: Mode
    var startX: CGFloat
    /// Timeline time under the press: the drag is measured in time, so it stays right while the timeline scrolls under it.
    var startTime: Time
    var startRange: TimeRange
    var last: Clip
    var moved = false
    var points: [SnapPoint]
}

/// What lies under the pointer.
enum ItemLaneHit {
    case chevron(Clip.ID)
    case bar(clip: Clip, item: UUID, mode: ItemLaneDrag.Mode)
    case header(clip: Clip, item: UUID)
    /// Lane space with nothing to grab: the press is swallowed.
    case space
}

/// View state of the item lanes (kept in `TimelineView.itemLanes`).
struct ItemLaneState {
    var open: Set<Clip.ID> = []
    /// Text or shape clips the host was asked to make Graphics: they open when the timeline shows them as Graphics.
    var pendingOpen: Set<Clip.ID> = []
    var selectedClip: Clip.ID?
    var selectedItems: Set<UUID> = []
    var drag: ItemLaneDrag?
    /// A press on a lane name (TimelineView+ItemLaneMove.swift).
    var move: ItemLaneMove?
    /// Cmd+C in a lane: the shown range of the copied item (Cmd+V gives it to the selected items).
    var copiedRange: TimeRange?
    /// A press in lane space that started no drag: its drags and its release are swallowed too.
    var swallowing = false
    var headers: [Track.ID: [ItemLaneHeader]] = [:]
    var headerKey: [ItemLaneHeaderKey] = []
    var icons: [String: (image: CGImage, size: CGSize)] = [:]
}

extension TimelineView {
    // MARK: State

    /// The Graphic clips whose item lanes are open.
    public var openItemLanes: Set<Clip.ID> { itemLanes.open }

    /// The arrow is offered: a Graphic, or a text or shape clip that can become one.
    func itemLanesOffered(_ c: Clip) -> Bool {
        ItemLanes.isAvailable(for: c) || (c.isTextOrShape && timeline.makeGraphicBlocker(c) == nil)
    }

    /// Opens or closes the item lanes of a Graphic clip. Opening closes another open clip on the same track. A text or
    /// shape clip is first made a Graphic by the host (`onItemLanesMakeGraphic`).
    public func toggleItemLanes(_ id: Clip.ID) {
        if itemLanes.open.contains(id) {
            itemLanes.open.remove(id)
        } else {
            guard let track = timeline.tracks.first(where: { t in t.clips.contains { $0.id == id } }),
                  let clip = track.clips.first(where: { $0.id == id }) else { return }
            if !ItemLanes.isAvailable(for: clip) {
                guard itemLanesOffered(clip), !track.isLocked, let ask = onItemLanesMakeGraphic else { return }
                itemLanes.pendingOpen.insert(id)
                ask(id)
                return
            }
            for c in track.clips where itemLanes.open.contains(c.id) { itemLanes.open.remove(c.id) }
            itemLanes.open.insert(id)
        }
        setTimeline(timeline)          // rows move: headers, scroll range and the content follow
    }

    /// The items selected in the monitor and in Controls (the host calls this when that selection changes).
    public func setItemSelection(clip: Clip.ID?, items: Set<UUID>) {
        let items = clip == nil ? [] : items
        guard clip != itemLanes.selectedClip || items != itemLanes.selectedItems else { return }
        itemLanes.selectedClip = clip
        itemLanes.selectedItems = items
        guard !itemLanes.open.isEmpty else { return }
        rebuildItemLaneHeaders()
        needsDisplay = true
    }

    /// The open clip of a track.
    func openItemLaneClip(on track: Track) -> Clip? {
        itemLanes.open.isEmpty ? nil : track.clips.first { itemLanes.open.contains($0.id) }
    }

    /// After a timeline change: closes clips that are gone or have no lanes any more, and lays out the lane space.
    func syncItemLanes() {
        if !itemLanes.pendingOpen.isEmpty {
            // Converted clips open now; the ones that did not convert (or are gone) are forgotten.
            let pending = itemLanes.pendingOpen
            itemLanes.pendingOpen = []
            for t in timeline.tracks {
                guard let c = t.clips.first(where: { pending.contains($0.id) && ItemLanes.isAvailable(for: $0) }) else { continue }
                for o in t.clips where itemLanes.open.contains(o.id) { itemLanes.open.remove(o.id) }
                itemLanes.open.insert(c.id)
            }
        }
        guard !itemLanes.open.isEmpty else {
            setLaneSpace([:])
            if !itemLanes.headers.isEmpty { itemLanes.headers = [:]; itemLanes.headerKey = [] }
            return
        }
        var kept = Set<Clip.ID>()
        var space: [Track.ID: CGFloat] = [:]
        for t in timeline.tracks {
            guard let c = t.clips.first(where: { itemLanes.open.contains($0.id) && ItemLanes.isAvailable(for: $0) }) else { continue }
            kept.insert(c.id)
            space[t.id] = ItemLanes.space(items: c.graphics?.layers.count ?? 0)
        }
        itemLanes.open = kept
        setLaneSpace(space)
        rebuildItemLaneHeaders()
    }

    private func rebuildItemLaneHeaders() {
        var key: [ItemLaneHeaderKey] = []
        var layers: [(Track.ID, GraphicsLayer, Bool)] = []
        for t in timeline.tracks {
            guard let c = openItemLaneClip(on: t), let doc = c.graphics else { continue }
            for l in doc.layers.reversed() {
                let sel = itemLanes.selectedClip == c.id && itemLanes.selectedItems.contains(l.id)
                key.append(ItemLaneHeaderKey(track: t.id, item: l.id, name: l.name, symbol: LayerListLogic.symbol(l), selected: sel))
                layers.append((t.id, l, sel))
            }
        }
        guard key != itemLanes.headerKey else { return }
        itemLanes.headerKey = key
        var out: [Track.ID: [ItemLaneHeader]] = [:]
        let textWidth = Double(TimelineGeometry.headerWidth - 2 * Theme.Spacing.sm - ItemLanes.chevronSize - Theme.Spacing.iconToLabel)
        for (k, (track, l, sel)) in zip(key, layers) {
            let color = sel ? Theme.Colors.label : Theme.Colors.label2
            let full = CTLineCreateWithAttributedString(NSAttributedString(
                string: l.name, attributes: [.font: Theme.Typography.body, .foregroundColor: color]))
            let line = CTLineCreateTruncatedLine(full, textWidth, .end, nil) ?? full
            let iconKey = k.symbol.rawValue + (sel ? "+" : "")
            if itemLanes.icons[iconKey] == nil { itemLanes.icons[iconKey] = ItemLanes.icon(k.symbol, color: color, size: 10) }
            out[track, default: []].append(ItemLaneHeader(item: l.id, line: line, icon: itemLanes.icons[iconKey], selected: sel))
        }
        itemLanes.headers = out
    }

    // MARK: Layout

    private var contentArea: CGRect {
        CGRect(x: TimelineGeometry.contentOriginX, y: 0, width: max(bounds.width - TimelineGeometry.contentOriginX, 0), height: bounds.height)
    }

    /// Width of the thumbnail column the clip is drawn with in a row of `rowHeight` (0 = none), as `drawClips` passes it.
    func itemLaneThumbWidth(_ c: Clip, kind: TrackKind, rowHeight: CGFloat) -> CGFloat {
        let flat = c.generator != nil || c.sequence != nil
        guard thumbnails != nil, !flat, kind == .video else { return 0 }
        if thumbnailMode == .continuous && thumbnailFrame != nil { return 0 }      // the strip sits under the name
        return ClipDrawing.thumbnailColumn(clipWidth: geometry.x(for: c.timeline.end) - geometry.x(for: c.timeline.start),
                                           rowHeight: rowHeight, width: ClipDrawing.thumbnailWidth)
    }

    /// The disclosure arrow of `c` in a row at `y` of `height` (nil: too narrow or off screen).
    func itemLaneChevronRect(_ c: Clip, kind: TrackKind, y: CGFloat, height: CGFloat) -> CGRect? {
        let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
        return ItemLanes.chevronRect(rect: CGRect(x: x0, y: y, width: x1 - x0, height: height), visible: contentArea,
                                     thumb: itemLaneThumbWidth(c, kind: kind, rowHeight: height))
    }

    /// The disclosure arrow of a clip in view space (nil: not a Graphic with lanes, too narrow or off screen).
    func itemLaneChevronRect(clip id: Clip.ID) -> CGRect? {
        for row in layoutRows() {
            guard let c = drawTrack(row.track)?.clips.first(where: { $0.id == id }), itemLanesOffered(c) else { continue }
            return itemLaneChevronRect(c, kind: row.kind, y: row.y, height: row.height)
        }
        return nil
    }

    /// The bar of an item of an open clip in view space.
    func itemLaneBarRect(clip id: Clip.ID, item: UUID) -> CGRect? {
        for row in layoutRows() where row.laneSpace > 0 {
            guard let c = drawTrack(row.track)?.clips.first(where: { $0.id == id }), itemLanes.open.contains(id),
                  let doc = c.graphics, let i = doc.layers.firstIndex(where: { $0.id == item }) else { continue }
            let r = doc.shownRange(of: doc.layers[i], clipDuration: c.timeline.duration)
            return ItemLanes.barRect(x0: geometry.x(for: c.timeline.start + r.start), x1: geometry.x(for: c.timeline.start + r.end),
                                     laneY: ItemLanes.laneY(row: row, index: doc.layers.count - 1 - i))
        }
        return nil
    }

    func itemLaneHit(at p: CGPoint) -> ItemLaneHit? {
        guard p.y >= TimelineGeometry.rulerHeight, p.x >= TimelineGeometry.toolColumnWidth else { return nil }
        for row in layoutRows() where p.y >= row.y && p.y < row.bottom {
            guard let track = drawTrack(row.track) else { return nil }
            if p.y < row.maxY {
                guard p.x >= TimelineGeometry.contentOriginX,
                      let c = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }),
                      itemLanesOffered(c) else { return nil }
                // The arrow is a Select tool control (Razor, Slip and the others act on the clip under it); its hit area
                // stays clear of both trim handles.
                guard toolState.timelineTool == .selection else { return nil }
                let r = itemLaneChevronRect(c, kind: row.kind, y: row.y, height: row.height)
                return r?.insetBy(dx: -2, dy: -2).contains(p) == true ? .chevron(c.id) : nil
            }
            guard let c = openItemLaneClip(on: track), let doc = c.graphics, !doc.layers.isEmpty else { return .space }
            let index = min(Int((p.y - row.maxY) / ItemLanes.laneHeight), doc.layers.count - 1)
            let layer = doc.layers[doc.layers.count - 1 - index]
            if p.x < TimelineGeometry.contentOriginX { return .header(clip: c, item: layer.id) }
            let r = doc.shownRange(of: layer, clipDuration: c.timeline.duration)
            let bar = ItemLanes.barRect(x0: geometry.x(for: c.timeline.start + r.start), x1: geometry.x(for: c.timeline.start + r.end),
                                        laneY: ItemLanes.laneY(row: row, index: index))
            guard p.x >= bar.minX, p.x < bar.maxX else { return .space }
            let handle = TimelineGeometry.trimHandleWidth(forClipWidth: bar.width)
            let mode: ItemLaneDrag.Mode = p.x < bar.minX + handle ? .head : p.x >= bar.maxX - handle ? .tail : .move
            return .bar(clip: c, item: layer.id, mode: mode)
        }
        return nil
    }

    // MARK: Mouse

    /// A press on a disclosure arrow, a lane name or a bar. True when the press is taken.
    func beginItemLaneDrag(at p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let hit = itemLaneHit(at: p) else { return false }
        itemLanes.swallowing = true
        switch hit {
        case .space: break
        case .chevron(let id): toggleItemLanes(id)
        case .header(let clip, let item):
            selectItemLane(clip: clip.id, item: item, modifiers: modifiers)
            if !modifiers.contains(.shift), !modifiers.contains(.command) { beginItemLaneMove(clip: clip, item: item, at: p) }
        case .bar(let clip, let item, let mode):
            selectItemLane(clip: clip.id, item: item, modifiers: modifiers)
            // A locked item (or track) is selected only, like in the monitor.
            guard toolState.timelineTool == .selection, let doc = clip.graphics, let layer = doc.layer(item), !layer.isLocked,
                  timeline.tracks.first(where: { t in t.clips.contains { $0.id == clip.id } })?.isLocked == false else { break }
            let base = clip.timeline.start
            var points = timeline.snapPoints(playhead: playhead, markers: interaction.markers)
                .filter { $0.time >= base && $0.time <= clip.timeline.end }
            for l in doc.layers where l.id != item {
                guard let r = l.range else { continue }
                points.append(SnapPoint(time: base + r.start, kind: .clipEdge))
                points.append(SnapPoint(time: base + r.end, kind: .clipEdge))
            }
            points.sort { $0.time < $1.time }
            itemLanes.drag = ItemLaneDrag(original: clip, item: item, mode: mode, startX: p.x, startTime: geometry.unsnappedTime(atX: p.x),
                                          startRange: doc.shownRange(of: layer, clipDuration: clip.timeline.duration),
                                          last: clip, points: points)
        }
        return true
    }

    private func selectItemLane(clip: Clip.ID, item: UUID, modifiers: NSEvent.ModifierFlags) {
        var items: Set<UUID> = [item]
        if modifiers.contains(.shift) || modifiers.contains(.command), itemLanes.selectedClip == clip {
            items = itemLanes.selectedItems.symmetricDifference([item])
        }
        setItemSelection(clip: clip, items: items)
        onItemLaneSelect?(clip, items)
    }

    func updateItemLaneDrag(to p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        if itemLanes.move != nil { return updateItemLaneMove(to: p, modifiers: modifiers) }
        guard var d = itemLanes.drag else { return itemLanes.swallowing }
        if !d.moved {
            guard abs(p.x - d.startX) >= ItemLanes.dragSlop else { return true }
            d.moved = true
            onPointerDown?()
            onItemLaneEdit?(d.original, .began)
            if let k = Self.itemLaneCursor(d.mode) { TimelineCursors.cursor(for: k).set() }
        }
        guard var doc = d.original.graphics else { return true }
        let fd = timeline.frameDuration, base = d.original.timeline.start, length = d.original.timeline.duration
        let dt = geometry.unsnappedTime(atX: p.x) - d.startTime
        let snapping = toolState.snapping != interaction.snapInverted
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
        showSnapLine(hit?.time)
        var c = d.last
        c.graphics = doc
        itemLanes.drag = d
        guard c != d.last else { return true }
        d.last = c
        itemLanes.drag = d
        previewItemLaneClip(c)
        onItemLaneEdit?(c, .changed)
        return true
    }

    func endItemLaneDrag(at p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        if itemLanes.move != nil { endItemLaneMove(at: p, modifiers: modifiers); return true }
        guard itemLanes.drag != nil else {
            defer { itemLanes.swallowing = false }
            return itemLanes.swallowing
        }
        if itemLanes.drag?.moved == true { _ = updateItemLaneDrag(to: p, modifiers: modifiers) }
        if let d = itemLanes.drag, d.moved { onItemLaneEdit?(d.last, .ended) }
        finishItemLaneDrag()
        return true
    }

    /// Escape, a tool change or losing the window: the clip goes back to what it was before the drag.
    func cancelItemLaneDrag() {
        cancelItemLaneMove()
        if let d = itemLanes.drag, d.moved {
            if d.last != d.original {
                previewItemLaneClip(d.original)
                onItemLaneEdit?(d.original, .changed)
            }
            onItemLaneEdit?(d.original, .ended)
        }
        finishItemLaneDrag()
    }

    private func finishItemLaneDrag() {
        if itemLanes.drag?.moved == true { NSCursor.arrow.set() }
        itemLanes.drag = nil
        itemLanes.swallowing = false
        showSnapLine(nil)
    }

    /// Shows the edited clip at once; the host applies the same edit to the session.
    private func previewItemLaneClip(_ c: Clip) {
        var t = timeline
        guard (try? t.replaceClip(c)) != nil else { return }
        let drag = itemLanes.drag
        setTimeline(t)
        itemLanes.drag = drag
    }

    // MARK: Keys (Cmd+D duplicate, Cmd+C copy range, Cmd+V paste range)

    /// Handles the three keys for the items selected in an open lane; false when none applies (the menu gets the key).
    func handleItemLaneKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let key = event.charactersIgnoringModifiers, ["d", "c", "v"].contains(key),
              itemLanes.drag == nil, let id = itemLanes.selectedClip, !itemLanes.selectedItems.isEmpty,
              itemLanes.open.contains(id), toolState.timelineTool == .selection,
              let track = timeline.tracks.first(where: { t in t.clips.contains { $0.id == id } }), !track.isLocked,
              let clip = track.clips.first(where: { $0.id == id }), var doc = clip.graphics else { return false }
        let ids = itemLanes.selectedItems
        let order = doc.layers.map(\.id).filter { ids.contains($0) }
        guard !order.isEmpty else { return false }
        switch key {
        case "c":
            guard let first = doc.layer(order[0]) else { return false }
            itemLanes.copiedRange = doc.shownRange(of: first, clipDuration: clip.timeline.duration)
            return true
        case "v":
            guard let r = itemLanes.copiedRange else { return false }
            doc.setRange(r, for: ids, clipDuration: clip.timeline.duration)
        default:
            let copies = doc.duplicate(order)
            guard !copies.isEmpty else { return false }
            var edited = clip
            edited.graphics = doc
            applyItemLaneEdit(edited, original: clip)
            setItemSelection(clip: id, items: Set(copies))
            onItemLaneSelect?(id, Set(copies))
            return true
        }
        var edited = clip
        edited.graphics = doc
        applyItemLaneEdit(edited, original: clip)
        return true
    }

    private func applyItemLaneEdit(_ edited: Clip, original: Clip) {
        guard edited != original else { return }
        onItemLaneEdit?(original, .began)
        previewItemLaneClip(edited)
        onItemLaneEdit?(edited, .changed)
        onItemLaneEdit?(edited, .ended)
    }

    // MARK: Cursors

    /// A bar's cursor is a clip's: the trim cursors on its ends, the arrow over its body (a move).
    static func itemLaneCursor(_ mode: ItemLaneDrag.Mode) -> TimelineCursorKind? {
        switch mode {
        case .head: .trimIn
        case .tail: .trimOut
        case .move: nil
        }
    }

    /// Trim cursors on both ends of every bar that can be dragged. Lane space itself is not part of a clip row, so no
    /// clip cursor reaches into it.
    func addItemLaneCursorRects(in content: CGRect) {
        for (rect, kind) in itemLaneCursorRects(in: content) { addCursorRect(rect, cursor: TimelineCursors.cursor(for: kind)) }
    }

    /// The zones of `addItemLaneCursorRects`: exactly where `itemLaneHit` answers a head or tail trim, so the whole lane
    /// height above and below the drawn bar counts (a press there trims, and the cursor says so).
    func itemLaneCursorRects(in content: CGRect) -> [(rect: CGRect, kind: TimelineCursorKind)] {
        guard toolState.timelineTool == .selection, !itemLanes.open.isEmpty else { return [] }
        var out: [(rect: CGRect, kind: TimelineCursorKind)] = []
        for row in layoutRows() where row.laneSpace > 0 && row.bottom > content.minY && row.maxY < content.maxY {
            guard let track = drawTrack(row.track), !track.isLocked, let c = openItemLaneClip(on: track), let doc = c.graphics else { continue }
            let base = c.timeline.start, count = doc.layers.count
            for (i, l) in doc.layers.enumerated() where !l.isLocked {
                let r = doc.shownRange(of: l, clipDuration: c.timeline.duration)
                let laneY = ItemLanes.laneY(row: row, index: count - 1 - i)
                let bar = ItemLanes.barRect(x0: geometry.x(for: base + r.start), x1: geometry.x(for: base + r.end), laneY: laneY)
                let h = TimelineGeometry.trimHandleWidth(forClipWidth: bar.width)
                for (x, mode) in [(bar.minX, ItemLaneDrag.Mode.head), (bar.maxX - h, .tail)] {
                    let rect = CGRect(x: x, y: laneY, width: h, height: ItemLanes.laneHeight).intersection(content)
                    guard !rect.isNull, rect.width >= 0.5, rect.height >= 0.5, let k = Self.itemLaneCursor(mode) else { continue }
                    out.append((rect, k))
                }
            }
        }
        return out
    }

    // MARK: Drawing

    /// Lanes and bars of the open clips (part of the cached content). No allocation: colors and paths are prepared or
    /// built inside the context.
    func drawItemLanes(rows: [TrackRow], clip: CGRect, visible: CGRect) {
        guard !itemLanes.open.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
        for row in rows where row.laneSpace > 0 && row.maxY < clip.maxY && row.bottom > clip.minY {
            guard let track = drawTrack(row.track), let c = openItemLaneClip(on: track), let doc = c.graphics else { continue }
            let start = c.timeline.start, length = c.timeline.duration
            let x0 = max(geometry.x(for: start), clip.minX), x1 = min(geometry.x(for: c.timeline.end), clip.maxX)
            guard x1 > x0 else { continue }
            let selectedClip = itemLanes.selectedClip == c.id
            var y = row.maxY
            var i = doc.layers.count - 1
            while i >= 0 {
                defer { i -= 1; y += ItemLanes.laneHeight }
                guard y < clip.maxY, y + ItemLanes.laneHeight > clip.minY else { continue }
                let layer = doc.layers[i]
                cg.setFillColor(ItemLanes.laneFill)
                cg.fill(CGRect(x: x0, y: y, width: x1 - x0, height: ItemLanes.laneHeight))
                cg.setFillColor(ItemLanes.laneLine)
                cg.fill(CGRect(x: x0, y: y + ItemLanes.laneHeight - 1, width: x1 - x0, height: 1))
                let r = layer.range ?? TimeRange(start: .zero, duration: length)
                let bar = ItemLanes.barRect(x0: geometry.x(for: start + r.start), x1: geometry.x(for: start + r.end), laneY: y)
                // Only the part on screen is built (a bar can be far wider than the view at a deep zoom).
                let shown = CGRect(x: max(bar.minX, visible.minX - 8), y: bar.minY,
                                   width: min(bar.maxX, visible.maxX + 8) - max(bar.minX, visible.minX - 8), height: bar.height)
                guard shown.width > 0, shown.maxX > clip.minX, shown.minX < clip.maxX else { continue }
                let selected = selectedClip && itemLanes.selectedItems.contains(layer.id)
                cg.setFillColor(selected ? ItemLanes.barFillSelected : ItemLanes.barFill)
                ItemLanes.addRounded(shown, radius: ItemLanes.barRadius, to: cg)
                cg.fillPath()
                if selected {
                    cg.setStrokeColor(ItemLanes.barOutline)
                    cg.setLineWidth(1)
                    ItemLanes.addRounded(shown.insetBy(dx: 0.5, dy: 0.5), radius: ItemLanes.barRadius, to: cg)
                    cg.strokePath()
                }
            }
        }
    }

    /// Icon and name of every lane in the header column (drawn from the prepared headers).
    func drawItemLaneHeaders(rows: [TrackRow], dirty: CGRect) {
        guard !itemLanes.headers.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
        let x = TimelineGeometry.toolColumnWidth, w = TimelineGeometry.headerWidth
        let bottom = bounds.height - ZoomScrollBar.height
        for row in rows where row.laneSpace > 0 {
            guard let headers = itemLanes.headers[row.track] else { continue }
            var y = row.maxY
            for h in headers {
                defer { y += ItemLanes.laneHeight }
                let r = CGRect(x: x, y: y, width: w, height: ItemLanes.laneHeight)
                guard r.intersects(dirty), r.minY >= TimelineGeometry.rulerHeight, r.maxY <= bottom else { continue }
                cg.setFillColor(ItemLanes.headerFill)
                cg.fill(r)
                if h.selected { cg.setFillColor(ItemLanes.headerSelected); cg.fill(r) }
                cg.setFillColor(ItemLanes.headerLine)
                cg.fill(CGRect(x: x, y: r.maxY - 1, width: w, height: 1))
                let iconBox = CGRect(x: x + Theme.Spacing.sm, y: y, width: ItemLanes.chevronSize, height: ItemLanes.laneHeight - 1)
                if let icon = h.icon { ItemLanes.draw(icon, centeredIn: iconBox, cg: cg) }
                cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                cg.textPosition = CGPoint(x: iconBox.maxX + Theme.Spacing.iconToLabel, y: y + ItemLanes.laneHeight - 6)
                CTLineDraw(h.line, cg)
            }
        }
    }
}
