import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// The caption tracks, translated from `TimelineView.drawCaptionLanes`, `drawCaptionHeaders` and `CaptionWordDrawing`:
/// the same rows (`captionRows`), culling, slivers, word boxes (`CaptionWordLayout`) and flat preview blocks.
extension TimelinePanel {
    /// `Theme.Colors.clipCaption` (the caption label color) and `clipCaptionWord`.
    var captionFill: DrawColor { theme.clip(.captionDefault) }
    var captionWordFill: DrawColor { DrawColor(hex: 0x7F591B) }

    func drawCaptionLanes(_ cv: inout Canvas, clip: CGRect) {
        let visibleX = CGRect(x: clip.minX, y: 0, width: clip.width, height: size.height)
        for row in geometry.captionRows(for: timeline) {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = timeline.captionTrack(row.track) else { continue }
            cv.fill(laneRect, theme.timeline)                                  // design v9: a plain lane
            cv.fill(CGRect(x: clip.minX, y: row.maxY - 1, width: clip.width, height: 1), theme.trackRowLine)
            let items = track.items
            var i = max(CaptionWordLayout.firstIndex(endingAfter: geometry.time(atX: clip.minX - 2), in: items) - 1, 0)
            let wordZoom = geometry.pointsPerSecond >= CaptionWordLayout.wordLevelPointsPerSecond
            var lastSliver = -CGFloat.greatestFiniteMagnitude
            let shown = interaction.wordSelection
            while i < items.count {
                let item = items[i]
                i += 1
                let x0 = geometry.x(for: item.range.start), x1 = geometry.x(for: item.range.end)
                if x1 < clip.minX { continue }
                if x0 > clip.maxX { break }
                let selected = captionSelection.contains(item.id)
                let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
                if x1 - x0 < CaptionWordLayout.sliverWidth {
                    // Zoomed far out a caption is narrower than its own outline: one plain sliver per pixel column.
                    let column = floor(x0)
                    if column == lastSliver, !selected { continue }
                    lastSliver = column
                    cv.fill(CGRect(x: x0, y: row.y + 1, width: max(x1 - x0, 1), height: row.height - 2), selected ? theme.yellow : captionFill)
                } else if wordZoom, CaptionWordLayout.showsWords(item, geometry: geometry) {
                    drawCaptionWords(&cv, item, rect: rect, row: row, visible: clip, selected: selected,
                                     selectedWord: shown?.caption == item.id ? shown?.index : nil,
                                     hiddenWord: wordField?.hiddenWord(in: item.id))
                } else {
                    drawCaptionBlock(&cv, name: CaptionDrawing.preview(item), rect: rect, visible: visibleX, selected: selected)
                }
            }
        }
    }

    /// `ClipDrawing.draw(name:style: .caption, flat: true)`: a flat clip-style block named with the caption's text.
    func drawCaptionBlock(_ cv: inout Canvas, name: String, rect: CGRect, visible: CGRect, selected: Bool) {
        let body = rect.insetBy(dx: 0, dy: 1)
        let x0 = max(body.minX, visible.minX - 8), x1 = min(body.maxX, visible.maxX + 8)
        guard x1 > x0 else { return }
        let drawn = CGRect(x: x0, y: body.minY, width: x1 - x0, height: body.height)
        let radius = min(DrawTheme.Radius.small.cg, body.height / 2)
        cv.fill(roundedRect: drawn, radius: radius, captionFill)
        cv.stroke(roundedRect: drawn.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, skin.clipEdge)
        if selected { cv.stroke(roundedRect: drawn.insetBy(dx: 1, dy: 1), radius: max(radius - 1, 0), width: 2, theme.yellow) }
        let textLeft = max(body.minX, visible.minX) + 6
        let textWidth = min(body.maxX, visible.maxX) - textLeft - 4
        guard textWidth >= 14, !name.isEmpty else { return }
        let size = DrawTheme.TypeSize.clipName.cg
        let lineH = cv.size(of: "Ag", fontSize: size).height
        let mid = body.height >= 18 ? body.minY + 12.5 - 3.5 : body.minY + 10 - 3.5
        cv.saveGState()
        cv.clip(to: CGRect(x: textLeft, y: body.minY, width: textWidth, height: body.height))
        cv.draw(name, at: CGPoint(x: textLeft, y: (mid - lineH / 2).rounded()), fontSize: size, TimelineSkin.text(on: captionFill), maxWidth: textWidth)
        cv.restoreGState()
    }

    /// `CaptionWordDrawing.draw`: the quiet plate, its edge or selection ring, one box per word, the shown word's ring,
    /// the word text (centered while it fits) and the unsure mark.
    func drawCaptionWords(_ cv: inout Canvas, _ item: CaptionItem, rect: CGRect, row: CaptionRow, visible: CGRect,
                          selected: Bool, selectedWord: Int?, hiddenWord: Int? = nil) {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0 else { return }
        let radius = min(DrawTheme.Radius.small.cg, body.height / 2)
        let ringWidth: CGFloat = 2, edgeWidth: CGFloat = 0.5
        let minX = max(body.minX, visible.minX - 8), maxX = min(body.maxX, visible.maxX + 8)   // Spacing.sm
        guard maxX > minX else { return }
        cv.saveGState()
        cv.clip(to: CGRect(x: minX, y: body.minY, width: maxX - minX, height: body.height))
        cv.fill(roundedRect: body, radius: radius, captionFill.alpha(0.32))    // `Theme.State.captionPlateAlpha`
        let inset = (selected ? ringWidth : edgeWidth) / 2
        cv.stroke(roundedRect: body.insetBy(dx: inset, dy: inset), radius: max(radius - inset, 0),
                  width: selected ? ringWidth : edgeWidth, selected ? theme.yellow : skin.clipEdge)
        cv.restoreGState()

        let textInset: CGFloat = 4, minTextBox: CGFloat = 16                    // Spacing.xs, Spacing.lg
        let size = DrawTheme.TypeSize.clipName.cg
        let lineH = cv.size(of: "Ag", fontSize: size).height
        for (i, w) in item.effectiveWords.enumerated() {
            let box = CaptionWordLayout.box(w.range, geometry: geometry, row: row)
            if box.maxX < visible.minX - 2 { continue }
            if box.minX > visible.maxX + 2 { break }
            if i == hiddenWord { continue }                                      // the open field stands on it
            let br = min(DrawTheme.Radius.small.cg - 1, box.width / 2)
            cv.fill(roundedRect: box, radius: br, captionWordFill)
            if i == selectedWord, box.width >= textInset {
                let lw: CGFloat = 1.5
                cv.stroke(roundedRect: box.insetBy(dx: lw / 2, dy: lw / 2), radius: max(br - lw / 2, 0), width: lw, theme.onClip)
            }
            guard box.width >= minTextBox else { continue }
            let tw = cv.size(of: w.text, fontSize: size).width, room = box.width - 2 * textInset
            let x = tw <= room ? box.midX - tw / 2 : box.minX + textInset
            let y = (box.midY - lineH / 2).rounded()
            cv.saveGState()
            cv.clip(to: box.insetBy(dx: textInset - 1, dy: 0))
            cv.draw(w.text, at: CGPoint(x: x, y: y), fontSize: size, theme.onClip)
            cv.restoreGState()
            if w.isUnsure, box.maxX - textInset > box.minX + textInset {   // `drawUnsureMark`: 1 pt under the text
                cv.fill(CGRect(x: box.minX + textInset, y: y + lineH, width: box.width - 2 * textInset, height: 1), skin.warning)
            }
        }
    }

    // MARK: Headers

    /// `captionEyeRect`: the same place and size as a video track's eye.
    func captionEyeRect(in row: CaptionRow) -> CGRect {
        let s = Self.buttonSize(rowHeight: row.height)
        let right = TimelineGeometry.toolColumnWidth + TimelineGeometry.headerWidth - Self.rightPadding
        return CGRect(x: right - s, y: row.y + ((row.height - s) / 2).rounded(), width: s, height: s)
    }

    /// The caption track whose eye is under `p` (3 pt slack, like the Mac).
    func captionEyeHit(_ p: CGPoint) -> CaptionTrack.ID? {
        guard p.y >= TimelineGeometry.rulerHeight,
              let row = geometry.captionRows(for: timeline).first(where: { captionEyeRect(in: $0).insetBy(dx: -3, dy: -3).contains(p) }),
              timeline.captionTrack(row.track) != nil else { return nil }
        return row.track
    }

    /// `drawCaptionHeaders` with `drawHeaderRow`: panel fill, row line, separator, chip, name, eye.
    func drawCaptionHeaders(_ cv: inout Canvas) {
        let x = TimelineGeometry.toolColumnWidth, width = TimelineGeometry.headerWidth
        for row in geometry.captionRows(for: timeline) {
            guard row.maxY > TimelineGeometry.rulerHeight, row.y < size.height else { continue }
            let track = timeline.captionTrack(row.track)
            let r = CGRect(x: x, y: row.y, width: width, height: row.height)
            cv.fill(r, theme.panel)
            cv.fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), theme.trackRowLine)
            cv.fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), theme.separator)
            let chip = Self.chipRect(height: row.height).offsetBy(dx: x + patchColumnOffset, dy: row.y)
            if !row.label.isEmpty {
                cv.fill(roundedRect: chip, radius: DrawTheme.Radius.small.cg, theme.fill)
                cv.draw(row.label, in: chip, fontSize: 10, theme.label2, align: .center)
            }
            let eye = captionEyeRect(in: row)
            let name = track?.name ?? "Captions"
            let nameX = chip.maxX + Self.buttonGap, w = eye.minX - Self.buttonGap - nameX
            if !name.isEmpty, w > 12 {
                cv.draw(name, at: CGPoint(x: nameX, y: (row.y + (row.height - 14) / 2).rounded()), fontSize: DrawTheme.TypeSize.body.cg,
                        theme.label2, maxWidth: w)
            }
            let visible = track?.isVisible ?? true
            cv.draw(icon: visible ? .eye : .eyeOff, at: CGPoint(x: eye.midX - 6, y: eye.midY - 6), size: 12,
                    visible ? theme.label3 : skin.warning)
        }
    }
}
