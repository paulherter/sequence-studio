import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// Painting, translated from `TimelineView.drawTimeline`, `ClipDrawing`, `TimelineView+Transitions` and the gesture
/// overlay: the same rects, colors and order, drawn through `Canvas` instead of NSBezierPath.
extension TimelinePanel {
    var skin: TimelineSkin { TimelineSkin(theme: theme) }

    /// Draws the panel into `list` (device pixels at `frame`).
    public func draw(into list: inout DrawList, atlas: GlyphAtlas?) {
        var cv = Canvas(list: list, atlas: atlas, scale: scale)
        cv.saveGState()
        cv.translateBy(x: CGFloat(frame.x / scale), y: CGFloat(frame.y / scale))
        cv.clip(to: CGRect(origin: .zero, size: size))
        drawTimeline(&cv)
        cv.restoreGState()
        list = cv.list
    }

    func drawTimeline(_ cv: inout Canvas) {
        let bounds = CGRect(origin: .zero, size: size)
        let origin = TimelineGeometry.contentOriginX, ruler = TimelineGeometry.rulerHeight
        cv.fill(bounds, theme.timeline)
        let content = CGRect(x: origin, y: ruler, width: max(size.width - origin, 0), height: max(size.height - ruler, 0))
        let rows = self.rows
        cv.saveGState()
        cv.clip(to: content)
        drawLanes(&cv, rows: rows, clip: content)
        drawItemLanes(&cv, rows: rows, clip: content)
        drawCaptionLanes(&cv, clip: content)
        drawTransitions(&cv, rows: rows, clip: content)
        drawSilencePreview(&cv, clip: content)
        drawInOutTint(&cv, clip: content)
        drawPlayheadLine(&cv, clip: content)
        drawSkimmer(&cv)
        drawGestureOverlay(&cv, rows: rows, clip: content)
        drawDropPreview(&cv, rows: rows, clip: content)
        drawKeystoneOverlay(&cv, rows: rows)
        drawItemLaneMoveGhost(&cv)
        drawSpeedTip(&cv)
        drawWordField(&cv, clip: content)
        cv.restoreGState()
        drawHeaders(&cv, rows: rows)
        drawItemLaneHeaders(&cv, rows: rows)
        drawZoomBar(&cv)           // over the header column's foot, like the Mac footer subview
        drawRuler(&cv)
    }

    // MARK: Lanes and clips (`drawLanes`)

    func drawLanes(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        let split = Self.splitRow(rows)
        let soloActive = Self.audioSoloActive(in: timeline)
        // shortcut: the sync offsets are recomputed per draw (the Mac keeps them with the timeline); cache them when a
        // large timeline draws slowly.
        let syncBadges = timeline.syncOffsets()
        let visibleX = CGRect(x: clip.minX, y: 0, width: clip.width, height: size.height)
        let mainRow = fastCutMainRow(rows)
        let magneticHosts = mainRow == nil ? [] : FastCutMarks.attachHosts(of: selection, in: timeline)
        let duck = duckContext()                                 // N8b: the live duck curve on Music tracks
        var threads: [(rect: CGRect, x: CGFloat)] = []
        for (rowIndex, row) in rows.enumerated() {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = timeline.tracks.first(where: { $0.id == row.track }) else { continue }
            let laneColor = Self.isAltLane(rowIndex, in: rows) ? theme.lane : theme.timeline
            cv.fill(laneRect, laneColor)
            if let mainRow, row.track == mainRow.track { drawSpacers(&cv, track: track, row: row, clip: clip) }
            // Design v9: 1 pt lane line, 2 pt strong line under the last video row (`.lane.vsplit`).
            let lineHeight: CGFloat = rowIndex == split ? 2 : 1
            cv.fill(CGRect(x: clip.minX, y: row.maxY - lineHeight, width: clip.width, height: lineHeight),
                    rowIndex == split ? theme.trackHeaderLine : theme.trackRowLine)
            let ink = track.kind == .audio ? waveformInk(track) : .clear
            for c in track.clips {
                let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                guard x1 >= clip.minX, x0 <= clip.maxX else { continue }
                let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
                let selected = selection.contains(c.id)
                drawClip(&cv, c, rect: rect, visible: clip, selected: selected, track: track)
                if !(c.markers ?? []).isEmpty { drawClipMarkerFlags(&cv, c, rect: rect, visible: clip) }
                if rect.width >= 3 {                       // the LOD sliver draws the body only
                    if let n = syncBadges[c.id] { drawSyncBadge(&cv, frames: n, rect: rect, visible: visibleX) }
                    if track.kind == .audio {
                        drawWaveform(&cv, c, rect: rect, visible: clip, ink: ink)
                        if VolumeLine.isAvailable(rowHeight: row.height) { drawVolumeLine(&cv, c, rect: rect, visible: clip, selected: selected) }
                        if let duck, duck.clips.contains(c.id) { drawDuckCurve(&cv, clipRect: rect, visible: visibleX, ranges: duck.ranges, ducking: duck.ducking) }
                    } else {
                        if speedBandClips.contains(c.id), SpeedBand.isAvailable(rowHeight: row.height) {
                            drawSpeedBand(&cv, c, rect: rect, visible: clip, selected: selected)
                        }
                        if OpacityLine.isVisible(clip: c, selected: selected, rowHeight: row.height), !speedBandClips.contains(c.id) {
                            drawOpacityLine(&cv, c, rect: rect, visible: clip, selected: selected)
                        }
                        if FXBadge.state(for: c) == .applied { drawFXBadge(&cv, rect: rect, visible: visibleX) }
                    }
                    if keyLanes != nil { drawKeyLane(&cv, c, rect: rect, visible: visibleX, selected: selected) }
                    if gradeOutline.contains(c.id) { drawGradeOutline(&cv, rect: rect) }
                    if let p = analysisProgress[c.id] { drawAnalysisProgress(&cv, rect: rect, progress: p) }
                }
                if track.kind == .video { drawTrackConfidence(&cv, c, rect: rect, visible: visibleX) }
                if magneticHosts.contains(c.id) { drawMagneticHint(&cv, rect: rect) }
                if let mainRow, row.track != mainRow.track, let a = c.attachment {
                    threads.append((rect, geometry.x(for: c.timeline.start + a.point)))
                }
                let inactive = Self.isInactive(track, soloActive: soloActive)
                if let fade: CGFloat = inactive ? (selected ? 0.5 : 0.72) : (c.isEnabled ? nil : 0.68) {
                    let body = rect.insetBy(dx: 0, dy: 1)
                    cv.fill(roundedRect: body, radius: min(DrawTheme.Radius.small.cg, body.height / 2), laneColor.alpha(Float(fade)))
                }
            }
        }
        if let mainRow {
            for t in threads where t.x >= clip.minX - 4 && t.x <= clip.maxX + 4 { drawAttachThread(&cv, clipRect: t.rect, x: t.x, main: mainRow) }
        }
    }

    /// `ClipDrawing.draw`: body, trim hints, edge, selection ring, thumbnail well and name.
    func drawClip(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, selected: Bool, track: Track) {
        let body = rect.insetBy(dx: 0, dy: 1)
        let offline = isOffline(c)
        let fillColor = offline ? skin.offlineClip : theme.clip(labels.label(for: c))
        if body.width < 3 {                                   // LOD: a sliver is one plain fill
            cv.fill(body, selected ? theme.yellow : fillColor)
            return
        }
        // Clamp to the visible span (8 pt slack) so a long clip's rounded ends never draw far off-screen.
        let x0 = max(body.minX, visible.minX - 8), x1 = min(body.maxX, visible.maxX + 8)
        let drawn = CGRect(x: x0, y: body.minY, width: max(x1 - x0, 0), height: body.height)
        let radius = min(DrawTheme.Radius.small.cg, body.height / 2)
        cv.fill(roundedRect: drawn, radius: radius, fillColor)
        if selected { drawTrimHints(&cv, body: body, drawn: drawn) }
        cv.stroke(roundedRect: drawn.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, skin.clipEdge)
        if selected {
            cv.stroke(roundedRect: drawn.insetBy(dx: 1, dy: 1), radius: max(radius - 1, 0), width: 2, theme.yellow)
        }
        let flat = c.generator != nil || c.sequence != nil || offline
        let tall = !flat && drawn.height >= ClipBodyMetrics.bodyMinHeight
        let thumbs = tall && track.kind == .video
            ? drawThumbnails(&cv, c, rect: rect, body: body, drawn: drawn, radius: radius, selected: selected, visible: visible)
            : (head: 0, tail: 0)
        let thumbW = thumbs.head
        let fxReserve = track.kind == .video && FXBadge.state(for: c) == .applied ? fxBadgeReserve(clipWidth: rect.width, size: &cv) : 0
        drawItemLaneChevron(&cv, c, rect: rect, visible: visible)
        let laneReserve = itemLanesOffered(c) ? ItemLaneMetrics.chevronReserve(clipWidth: rect.width) : 0
        let textLeft = max(body.minX + thumbW, visible.minX) + 6 + laneReserve
        let textWidth = min(body.maxX, visible.maxX) - textLeft - 4 - fxReserve - thumbs.tail
        guard textWidth >= 14 else { return }
        let name = offline ? "Media offline" : c.name + SpeedLabel.nameSuffix(for: c)
        let color = offline ? skin.offlineText : TimelineSkin.text(on: fillColor)
        let size = DrawTheme.TypeSize.clipName.cg
        let lineH = cv.size(of: "Ag", fontSize: size, face: cv.medium).height
        // Name baseline in the 13 pt name strip; a flat clip (no media strip) taller than 18 pt centers it a little lower.
        let mid = flat && body.height >= 18 ? body.minY + 12.5 - 3.5 : body.minY + 10 - 3.5
        cv.saveGState()
        cv.clip(to: CGRect(x: textLeft, y: body.minY, width: textWidth, height: min(body.height, DrawTheme.Metrics.clipNameBand.cg + 6)))
        cv.draw(name, at: CGPoint(x: textLeft, y: (mid - lineH / 2).rounded()), fontSize: size, color, maxWidth: textWidth, face: cv.medium)
        cv.restoreGState()
    }

    /// `ClipDrawing.drawTrimHints`: shaded bars at both ends with a grip line, as wide as the trim handle.
    func drawTrimHints(_ cv: inout Canvas, body: CGRect, drawn: CGRect) {
        let w = TimelineGeometry.trimHandleWidth(forClipWidth: body.width)
        guard w >= 3 else { return }
        let gripH = min(body.height - 6, 8)
        for left in [true, false] {
            let x = left ? body.minX : body.maxX - w
            guard x + w >= drawn.minX, x <= drawn.maxX else { continue }
            cv.fill(CGRect(x: x, y: body.minY, width: w, height: body.height), skin.clipShade)
            if gripH > 0 {
                cv.fill(CGRect(x: (x + w / 2 - 0.5).rounded(), y: body.midY - gripH / 2, width: 1, height: gripH), theme.label2)
            }
        }
    }

    /// A clip whose media is missing from the project (the Mac also reads the media status; this has the project only).
    func isOffline(_ c: Clip) -> Bool { c.generator == nil && c.sequence == nil && media?.isOffline(media: c.media) == true }

    /// `ClipMarkerFlags.draw`: a flag in the marker's color at the clip's bottom edge.
    func drawClipMarkerFlags(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect) {
        guard rect.width >= ClipMarkerFlags.minClipWidth else { return }
        let w = ClipMarkerFlags.flagWidth, h = ClipMarkerFlags.flagHeight
        for m in c.visibleMarkers(frameDuration: geometry.frameDuration) {
            let x = geometry.x(for: c.start + m.time)
            guard x >= visible.minX - w, x <= visible.maxX + w else { continue }
            cv.fill(polygon: [CGPoint(x: x, y: rect.maxY), CGPoint(x: x + w / 2, y: rect.maxY - h), CGPoint(x: x - w / 2, y: rect.maxY - h)],
                    skin.marker(m.color))
        }
    }

    // MARK: Transitions (`TimelineView+Transitions`)

    func drawTransitions(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        let fd = timeline.format.frameDuration
        for row in rows {
            guard row.maxY > clip.minY, row.y < clip.maxY, let track = timeline.tracks.first(where: { $0.id == row.track }),
                  !track.transitions.isEmpty else { continue }
            for r in track.resolvedTransitions(frameDuration: fd) {
                let box = TransitionLayout.rect(r, row: row, geometry: geometry)
                guard box.maxX >= clip.minX, box.minX <= clip.maxX else { continue }
                drawTransition(&cv, r, box: box, selected: r.id == selectedTransition)
            }
        }
        drawTransitionLayers(&cv, rows: rows, clip: clip)
    }

    /// `TimelineView.heldHatchRects`, copied (the Mac copy lives in an AppKit file).
    static func heldHatchRects(_ r: ResolvedTransition, box: CGRect) -> [CGRect] {
        let total = Double(r.frames)
        guard total > 0, r.isHeld else { return [] }
        let fd = r.frameDuration
        let before = Double(r.before.frameIndex(frameDuration: fd)), after = Double(r.after.frameIndex(frameDuration: fd))
        let cutX = box.minX + box.width * CGFloat(before / total)
        var out: [CGRect] = []
        if r.heldBefore > 0 {
            let w = box.width * CGFloat(Double(r.heldBefore) / total)
            out.append(CGRect(x: cutX - w, y: box.minY, width: w, height: box.height))
        }
        if r.heldAfter > 0 {
            let w = box.width * CGFloat(min(Double(r.heldAfter), after) / total)
            out.append(CGRect(x: cutX, y: box.minY, width: w, height: box.height))
        }
        return out
    }

    func drawTransition(_ cv: inout Canvas, _ r: ResolvedTransition, box: CGRect, selected: Bool) {
        let shape = box.insetBy(dx: 0.5, dy: 0.5)
        let radius = DrawTheme.Radius.small.cg
        cv.fill(roundedRect: shape, radius: radius, skin.clipShade)
        cv.strokeLine(from: CGPoint(x: box.minX + 1, y: box.maxY - 2), to: CGPoint(x: box.maxX - 1, y: box.minY + 2), width: 1,
                      selected ? theme.onClip : theme.label2)
        cv.stroke(roundedRect: shape, radius: radius, width: selected ? TimelineSkin.selectionOutlineWidth : 1,
                  selected ? skin.selectionOutline : theme.label2)
        for area in Self.heldHatchRects(r, box: box) {
            cv.saveGState()
            cv.clip(to: area.insetBy(dx: 0, dy: 1))
            var x = area.minX - area.height
            while x < area.maxX {
                cv.strokeLine(from: CGPoint(x: x, y: area.minY), to: CGPoint(x: x + area.height, y: area.maxY), width: 1, skin.transitionIssue)
                x += 5
            }
            cv.restoreGState()
        }
        if r.isClamped { cv.fill(CGRect(x: box.maxX - 3, y: box.minY + 1, width: 2, height: box.height - 2), skin.red) }
        if box.width >= 74, box.height >= 28 {
            let name = r.kind.name, fs = DrawTheme.TypeSize.caption.cg
            let s = cv.size(of: name, fontSize: fs)
            if s.width + 10 < box.width {
                cv.draw(name, at: CGPoint(x: box.midX - s.width / 2, y: box.maxY - s.height - 3), fontSize: fs, theme.onClip)
            }
        }
    }

    // MARK: In/Out tint, playhead line, gesture overlay

    func drawInOutTint(_ cv: inout Canvas, clip: CGRect) {
        guard let io = timeline.inOut, !io.isEmpty else { return }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        guard x1 > clip.minX, x0 < clip.maxX else { return }
        cv.fill(CGRect(x: x0, y: clip.minY, width: x1 - x0, height: clip.height).intersection(clip), skin.inOutBand)
        if x0 >= clip.minX { cv.fill(CGRect(x: x0, y: clip.minY, width: 1, height: clip.height), skin.inOutBandEdge) }
        if x1 - 1 <= clip.maxX { cv.fill(CGRect(x: x1 - 1, y: clip.minY, width: 1, height: clip.height), skin.inOutBandEdge) }
    }

    func drawPlayheadLine(_ cv: inout Canvas, clip: CGRect) {
        let x = geometry.x(for: playhead)
        guard x >= clip.minX - 2, x <= clip.maxX + 2 else { return }
        cv.fill(TimelineSkin.lineFrame(centerX: x, y: clip.minY, height: clip.height), theme.playhead)
    }

    func drawGestureOverlay(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        // Razor guide lines (`razorGuideRects`): white 1 pt over the tracks the cut will reach.
        if toolState.timelineTool == .razor, let p = hoverPoint, gesture == nil, p.x >= clip.minX, p.y >= clip.minY {
            let x = geometry.x(for: interaction.razorCutTime(atX: p.x)).rounded()
            for id in interaction.razorGuideTracks(at: p, shift: false) {
                guard let row = rows.first(where: { $0.track == id }) else { continue }
                cv.fill(CGRect(x: x - 0.5, y: row.y + 1, width: 1, height: row.height - 2), .white)
            }
        }
        if let t = interaction.snapTime ?? scrubSnapTime {
            let x = geometry.x(for: t).rounded()
            cv.fill(CGRect(x: x - 0.5, y: clip.minY, width: 1, height: clip.height), skin.snapLine)
        }
        let bold = DrawTheme.TypeSize.body.cg
        let audioRows = rows.filter { $0.kind == .audio }
        if let g = interaction.splitRollGhost, !audioRows.isEmpty {
            let x = geometry.x(for: g.cut).rounded()
            for row in audioRows { cv.fill(CGRect(x: x - 1, y: row.y + 1, width: 2, height: row.height - 2), theme.label2) }
            let label = g.label(frameDuration: timeline.frameDuration)
            let s = cv.size(of: label, fontSize: bold)
            let box = CGRect(x: geometry.x(for: g.cut + g.offset) + 6, y: audioRows[0].y + 4, width: s.width + 10, height: s.height + 4)
            cv.fill(roundedRect: box, radius: DrawTheme.Radius.small.cg, skin.hudFill)
            cv.draw(label, at: CGPoint(x: box.minX + 5, y: box.minY + 2), fontSize: bold, theme.onClip)
        }
        if let g = interaction.reorderGhost, let row = rows.first(where: { $0.track == g.track }) {
            let x0 = geometry.x(for: g.range.start), x1 = geometry.x(for: g.range.end)
            let r = CGRect(x: x0, y: row.y + 1, width: max(x1 - x0, 2), height: row.height - 2)
            cv.fill(roundedRect: r, radius: DrawTheme.Radius.small.cg, skin.hudFill)
            cv.stroke(roundedRect: r, radius: DrawTheme.Radius.small.cg, width: 1.5, skin.snapLine)
            cv.draw(g.name, at: CGPoint(x: r.minX + 6, y: r.minY + 4), fontSize: bold, theme.onClip, maxWidth: max(r.width - 12, 0))
        }
        if let g = interaction.gapSelection, let row = rows.first(where: { $0.track == g.track }) {
            let r = CGRect(x: geometry.x(for: g.range.start), y: row.y + 1,
                           width: geometry.x(for: g.range.end) - geometry.x(for: g.range.start), height: row.height - 2)
            let w = TimelineSkin.selectionOutlineWidth
            cv.stroke(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), radius: 0, width: w, skin.selectionOutline)
        }
        if let e = interaction.edgeSelection {
            let color = e.ripple ? skin.warning : theme.accent
            for ref in e.edges {
                guard let t = EdgeEdits.time(of: ref, in: timeline), let (_, tr) = clipAndTrack(ref.clip),
                      let row = rows.first(where: { $0.track == tr }) else { continue }
                let x = geometry.x(for: t).rounded()
                cv.fill(CGRect(x: ref.edge == .head ? x : x - 3, y: row.y + 1, width: 3, height: row.height - 2), color)
            }
        }
        if case .zoom(let a, let b, _)? = gesture, hypot(b.x - a.x, b.y - a.y) >= TimelineInteraction.dragThreshold {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            cv.fill(r, skin.accentTint)
            cv.stroke(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: 0, width: 1, theme.accent)
        }
        if let m = interaction.marquee {
            cv.fill(m, skin.accentTint)
            cv.stroke(roundedRect: m.insetBy(dx: 0.5, dy: 0.5), radius: 0, width: 1, theme.accent)
        }
    }

    func clipAndTrack(_ id: Clip.ID) -> (Clip, Track.ID)? {
        for t in timeline.tracks { if let c = t.clips.first(where: { $0.id == id }) { return (c, t.id) } }
        return nil
    }
}

extension Float {
    var cg: CGFloat { CGFloat(self) }
}
