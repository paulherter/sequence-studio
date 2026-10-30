import Foundation
import SQCore
import SQDrawKit

/// The timeline panel: header strip, track headers, ruler, track rows with clips, playhead. Zoom and scroll are view
/// state; positions are whole frames times `pixelsPerFrame` so drawing never converts time through Double.
public struct TimelineView {
    public enum Tool: Sendable, Equatable { case select, razor }

    public var tool: Tool = .select
    /// Zoom: pixels per frame (device pixels).
    public var pixelsPerFrame: Float = 2
    /// First visible frame at the left edge of the track area.
    public var scrollFrames: Float = 0

    public struct Row: Sendable, Equatable { public var track: Track.ID; public var kind: TrackKind; public var name: String; public var y: Float; public var h: Float }
    public private(set) var rows: [Row] = []
    public private(set) var frame = DrawRect.zero
    public private(set) var header = DrawRect.zero
    public private(set) var ruler = DrawRect.zero
    public private(set) var tracksArea = DrawRect.zero
    public private(set) var headerColumn = DrawRect.zero

    private enum Drag: Equatable {
        case scrub
        case clip(id: Clip.ID, track: Track.ID, start: Time, grabX: Float, grabY: Float, moved: Bool)
    }
    private var drag: Drag?
    /// Live offset of a dragged clip (frames, target row) for the ghost.
    private var dragFrames: Int64 = 0
    private var dragRow: Track.ID?

    public init() {}

    // MARK: Layout

    public mutating func layout(_ rect: DrawRect, timeline: Timeline, theme: DrawTheme) {
        frame = rect
        var r = rect
        header = r.sliceTop(theme.px(DrawTheme.Metrics.panelHeader))
        headerColumn = DrawRect(x: r.x, y: r.y, w: theme.px(DrawTheme.Metrics.trackHeader), h: r.h)
        _ = r.sliceLeft(headerColumn.w)
        ruler = r.sliceTop(theme.px(DrawTheme.Metrics.ruler))
        tracksArea = r
        let video = timeline.tracks.filter { $0.kind == .video }
        let audio = timeline.tracks.filter { $0.kind == .audio }
        var y = tracksArea.y
        rows = []
        for (i, t) in video.enumerated().reversed() {
            let h = theme.px(Float(t.height))
            rows.append(Row(track: t.id, kind: .video, name: t.name.isEmpty ? "V\(i + 1)" : t.name, y: y, h: h)); y += h
        }
        for (i, t) in audio.enumerated() {
            let h = theme.px(Float(t.height))
            rows.append(Row(track: t.id, kind: .audio, name: t.name.isEmpty ? "A\(i + 1)" : t.name, y: y, h: h)); y += h
        }
    }

    // MARK: Coordinates

    public func x(of t: Time, frameDuration: Time) -> Float {
        tracksArea.x + (Float(t.frameIndex(frameDuration: frameDuration)) - scrollFrames) * pixelsPerFrame
    }
    /// The frame under x (rounded to the nearest frame boundary).
    public func time(atX x: Float, frameDuration: Time) -> Time {
        let f = max(0, ((x - tracksArea.x) / pixelsPerFrame + scrollFrames).rounded())
        return frameDuration * Int64(f)
    }
    /// The frame containing x (razor: the cut lands where the pointer is).
    func frameTime(atX x: Float, frameDuration: Time) -> Time {
        frameDuration * Int64(max(0, ((x - tracksArea.x) / pixelsPerFrame + scrollFrames).rounded()))
    }
    public func row(atY y: Float) -> Row? { rows.first { y >= $0.y && y < $0.y + $0.h } }

    public func clip(atX x: Float, y: Float, in timeline: Timeline) -> (Clip, Track)? {
        guard tracksArea.contains(x, y), let row = row(atY: y), let track = timeline.tracks.first(where: { $0.id == row.track })
        else { return nil }
        let fd = timeline.format.frameDuration
        for c in track.clips where x >= self.x(of: c.start, frameDuration: fd) && x < self.x(of: c.timeline.end, frameDuration: fd) {
            return (c, track)
        }
        return nil
    }

    // MARK: Zoom

    public mutating func zoom(by factor: Float, anchorX: Float) {
        let frameAtAnchor = (anchorX - tracksArea.x) / pixelsPerFrame + scrollFrames
        pixelsPerFrame = min(max(pixelsPerFrame * factor, 0.02), 40)
        scrollFrames = max(0, frameAtAnchor - (anchorX - tracksArea.x) / pixelsPerFrame)
    }

    /// Fits `frames` into the track area.
    public mutating func zoomToFit(frames: Int64) {
        guard frames > 0, tracksArea.w > 0 else { return }
        pixelsPerFrame = min(max(tracksArea.w * 0.95 / Float(frames), 0.02), 40)
        scrollFrames = 0
    }

    // MARK: Drawing

    public func draw(_ list: inout DrawList, _ s: EditorSnapshot, theme: DrawTheme, atlas: GlyphAtlas) {
        let fd = s.frameDuration
        list.fill(frame, theme.panel, radius: theme.px(DrawTheme.Radius.panel))
        // Header strip: title, sequence name, tool.
        let small = theme.px(DrawTheme.TypeSize.body), cap = theme.px(DrawTheme.TypeSize.caption)
        let pad = theme.px(DrawTheme.Spacing.md)
        let titleW = list.text("Timeline", in: header, pixelSize: small, color: theme.label, atlas: atlas, inset: pad)
        var nameRect = header
        nameRect.x += pad + titleW + theme.px(DrawTheme.Spacing.sm)
        nameRect.w = max(0, header.maxX - nameRect.x - theme.px(120))
        list.text(s.timeline.name, in: nameRect, pixelSize: small, color: theme.label3, atlas: atlas)
        list.text(tool == .razor ? "Razor (C)" : "Select (V)", in: header, pixelSize: cap, color: theme.label2, atlas: atlas,
                  align: .right, inset: pad)
        list.fill(DrawRect(x: header.x, y: header.maxY - 1, w: header.w, h: 1), theme.separator)

        // Track header column.
        list.pushClip(DrawRect(x: headerColumn.x, y: ruler.maxY, w: headerColumn.w, h: tracksArea.h))
        for row in rows {
            let r = DrawRect(x: headerColumn.x, y: row.y, w: headerColumn.w, h: row.h)
            list.text(row.name, in: r, pixelSize: small, color: theme.label2, atlas: atlas, inset: pad)
            list.fill(DrawRect(x: r.x, y: r.maxY - 1, w: r.w, h: 1), theme.trackHeaderLine)
        }
        list.popClip()
        list.fill(DrawRect(x: headerColumn.maxX - 1, y: header.maxY, w: 1, h: frame.maxY - header.maxY), theme.separator)

        // Ruler.
        list.fill(ruler, theme.content)
        list.pushClip(ruler)
        drawRuler(&list, fd: fd, theme: theme, atlas: atlas)
        list.popClip()
        list.fill(DrawRect(x: ruler.x, y: ruler.maxY - 1, w: ruler.w, h: 1), theme.rulerMinor)

        // Rows and clips.
        list.fill(tracksArea, theme.timeline)
        list.pushClip(tracksArea)
        for row in rows {
            list.fill(DrawRect(x: tracksArea.x, y: row.y + row.h - 1, w: tracksArea.w, h: 1), theme.trackRowLine)
        }
        for track in s.timeline.tracks {
            guard let row = rows.first(where: { $0.track == track.id }) else { continue }
            for c in track.clips {
                drawClip(&list, c, row: row, selected: s.selection.contains(c.id), label: s.labels.label(for: c), fd: fd,
                         theme: theme, atlas: atlas)
            }
        }
        if case .clip(let id, _, let start, _, _, true)? = drag, let c = s.timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), let target = rows.first(where: { $0.track == dragRow }) {
            let ghostStart = max(.zero, start + fd * dragFrames)
            let x0 = x(of: ghostStart, frameDuration: fd), x1 = x(of: ghostStart + c.duration, frameDuration: fd)
            list.stroke(DrawRect(x: x0, y: target.y + 1, w: x1 - x0, h: target.h - 3), theme.label.alpha(0.8), width: theme.px(1),
                        radius: theme.px(DrawTheme.Radius.small))
        }
        list.popClip()

        // Playhead: 2 pt line over ruler and rows, a head in the ruler.
        let px = x(of: s.playhead, frameDuration: fd).rounded()
        list.pushClip(DrawRect(x: ruler.x, y: ruler.y, w: ruler.w, h: frame.maxY - ruler.y))
        let lw = theme.px(2)
        list.fill(DrawRect(x: px - (lw / 2).rounded(.down), y: ruler.y, w: lw, h: frame.maxY - ruler.y), theme.playhead)
        let hw = theme.px(11)
        list.fill(DrawRect(x: px - (hw / 2).rounded(.down), y: ruler.maxY - theme.px(10), w: hw, h: theme.px(10)), theme.playhead,
                  radius: theme.px(2))
        list.popClip()
    }

    private func drawRuler(_ list: inout DrawList, fd: Time, theme: DrawTheme, atlas: GlyphAtlas) {
        let fps = max(1, Int64((Double(fd.timescale) / Double(max(1, fd.value))).rounded()))
        // Major step: the smallest of these (in frames) at least 90 px apart.
        let steps: [Int64] = [1, 2, 5, 10, fps / 2, fps, 2 * fps, 5 * fps, 10 * fps, 30 * fps, 60 * fps, 300 * fps, 600 * fps, 1800 * fps, 3600 * fps]
        let minGap = theme.px(90)
        let major = steps.filter { $0 > 0 }.first { Float($0) * pixelsPerFrame >= minGap } ?? 3600 * fps
        let minor = major % 5 == 0 ? major / 5 : (major % 2 == 0 ? major / 2 : major)
        let first = Int64(max(0, scrollFrames)) / minor * minor
        let last = Int64(scrollFrames + ruler.w / pixelsPerFrame) + 1
        var f = first
        let cap = theme.px(DrawTheme.TypeSize.caption)
        while f <= last {
            let x = (ruler.x + (Float(f) - scrollFrames) * pixelsPerFrame).rounded()
            if f % major == 0 {
                list.fill(DrawRect(x: x, y: ruler.y + theme.px(4), w: 1, h: ruler.h - theme.px(4)), theme.rulerLine)
                list.text(TimecodeText.string(fd * f, frameDuration: fd), x: x + theme.px(4), baseline: ruler.y + theme.px(13),
                          pixelSize: cap, color: theme.label3, atlas: atlas)
            } else {
                list.fill(DrawRect(x: x, y: ruler.maxY - theme.px(6), w: 1, h: theme.px(6)), theme.rulerMinor)
            }
            f += minor
        }
    }

    private func drawClip(_ list: inout DrawList, _ c: Clip, row: Row, selected: Bool, label: LabelColor, fd: Time,
                          theme: DrawTheme, atlas: GlyphAtlas) {
        let x0 = x(of: c.start, frameDuration: fd).rounded(), x1 = x(of: c.timeline.end, frameDuration: fd).rounded()
        guard x1 > tracksArea.x, x0 < tracksArea.maxX else { return }
        let r = DrawRect(x: x0, y: row.y + 1, w: max(1, x1 - x0 - 1), h: row.h - 3)
        let radius = theme.px(DrawTheme.Radius.small)
        list.fill(r, c.isEnabled ? theme.clip(label) : theme.clip(label).alpha(0.4), radius: radius)
        list.stroke(r, theme.clipEdge(label), width: 1, radius: radius)
        let band = DrawRect(x: r.x, y: r.y, w: r.w, h: theme.px(DrawTheme.Metrics.clipNameBand) + theme.px(2))
        list.pushClip(r.inset(1))
        list.text(c.name, in: band, pixelSize: theme.px(DrawTheme.TypeSize.clipName), color: theme.onClip, atlas: atlas,
                  inset: theme.px(DrawTheme.Spacing.xs))
        list.popClip()
        if selected { list.stroke(r, theme.yellow, width: theme.px(2), radius: radius) }
    }

    // MARK: Input

    public mutating func handle(_ e: InputEvent, _ s: EditorSnapshot) -> [EditorIntent] {
        let fd = s.frameDuration
        switch e {
        case .mouseDown(let x, let y, let mods):
            if ruler.contains(x, y) {
                drag = .scrub
                return [.beginScrub, .scrub(time(atX: x, frameDuration: fd))]
            }
            guard tracksArea.contains(x, y) else { return [] }
            guard let (clip, track) = clip(atX: x, y: y, in: s.timeline) else { return [.select([])] }
            if tool == .razor { return [.razor(at: frameTime(atX: x, frameDuration: fd), track: track.id)] }
            var sel: Set<Clip.ID> = [clip.id]
            if mods.contains(.shift) { sel = s.selection.symmetricDifference([clip.id]) }
            drag = .clip(id: clip.id, track: track.id, start: clip.start, grabX: x, grabY: y, moved: false)
            dragFrames = 0; dragRow = track.id
            return sel == s.selection ? [] : [.select(sel)]
        case .mouseDragged(let x, let y):
            switch drag {
            case .scrub?: return [.scrub(time(atX: x, frameDuration: fd))]
            case .clip(let id, let track, let start, let gx, let gy, let moved)?:
                let df = Int64(((x - gx) / pixelsPerFrame).rounded())
                let isMoved = moved || abs(x - gx) >= 3 || abs(y - gy) >= 3
                drag = .clip(id: id, track: track, start: start, grabX: gx, grabY: gy, moved: isMoved)
                dragFrames = df
                if let r = row(atY: y), let from = rows.first(where: { $0.track == track }), r.kind == from.kind { dragRow = r.track }
                return []
            case nil: return []
            }
        case .mouseUp:
            defer { drag = nil; dragFrames = 0; dragRow = nil }
            switch drag {
            case .scrub?: return [.endScrub]
            case .clip(let id, let track, let start, _, _, true)?:
                let to = max(.zero, start + fd * dragFrames)
                let target = dragRow ?? track
                return to == start && target == track ? [] : [.move(id, to: to, track: target)]
            default: return []
            }
        case .scroll(let x, let y, let dx, let dy, let mods):
            guard frame.contains(x, y) else { return [] }
            if mods.contains(.command) || mods.contains(.option) {
                zoom(by: dy > 0 ? 1.25 : 0.8, anchorX: max(x, tracksArea.x))
            } else {
                let d = dx != 0 ? dx : dy
                scrollFrames = max(0, scrollFrames - d / pixelsPerFrame)
            }
            return []
        case .mouseMoved, .keyDown: return []
        }
    }

    /// True while a clip or the playhead is being dragged.
    public var isDragging: Bool { drag != nil }
}
