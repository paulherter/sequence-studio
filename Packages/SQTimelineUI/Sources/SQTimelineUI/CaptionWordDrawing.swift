import AppKit
import CoreText
import SQCore

/// Draws a caption as word boxes. One shaped line per distinct word text is kept, so scrolling, zooming and playback
/// never lay text out again.
@MainActor
enum CaptionWordDrawing {
    private static var lines: [String: (line: CTLine, width: CGFloat)] = [:]
    /// Words shaped since launch (tests: no layout while scrolling).
    private(set) static var shapedCount = 0

    private static func line(_ text: String) -> (line: CTLine, width: CGFloat) {
        if let l = lines[text] { return l }
        if lines.count > 8000 { lines.removeAll(keepingCapacity: true) }
        // The color comes from the context at draw time, so a cached line follows an appearance change.
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: Theme.Typography.clipName,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        let entry = (l, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)))
        lines[text] = entry
        shapedCount += 1
        return entry
    }

    /// The colors of one draw pass, resolved in the appearance that is current while drawing (never cached).
    @MainActor
    private struct Palette {
        let bodyFill, boxFill, edge, ring, text, unsure: CGColor
        init() {
            bodyFill = Theme.Colors.clipCaption.withAlphaComponent(Theme.State.captionPlateAlpha).cgColor
            boxFill = Theme.Colors.clipCaptionWord.cgColor
            edge = ClipStyle.caption.edge.cgColor
            ring = Theme.Colors.yellow.cgColor
            text = Theme.Colors.onClip.cgColor
            unsure = Theme.Colors.warning.cgColor
        }
    }

    /// Text inset inside a word box, and the narrowest box that shows any text.
    static let textInset = Theme.Spacing.xs
    static let minTextBox = Theme.Spacing.lg
    /// Baseline below the box center that centers the capitals.
    private static let baselineDrop = Theme.Typography.clipName.capHeight / 2

    /// - Parameters:
    ///   - rect: the caption's row rectangle. - visible: the horizontal range being drawn.
    ///   - selectedWord: index of the selected word of this caption. - hiddenWord: a word under the inline field.
    static func draw(_ item: CaptionItem, rect: CGRect, row: CaptionRow, geometry: TimelineGeometry, visible: CGRect,
                     isSelected: Bool, selectedWord: Int?, hiddenWord: Int? = nil) {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        let radius = min(Theme.Radius.small, body.height / 2)
        let colors = Palette()
        let ringWidth = 2 * Theme.Metrics.focusRingWidth
        // The body: a quiet plate, so the pauses between words read as part of the caption.
        let minX = max(body.minX, visible.minX - Theme.Spacing.sm), maxX = min(body.maxX, visible.maxX + Theme.Spacing.sm)
        guard maxX > minX else { return }
        cg.saveGState()
        cg.clip(to: CGRect(x: minX, y: body.minY, width: maxX - minX, height: body.height))
        let plate = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cg.addPath(plate)
        cg.setFillColor(colors.bodyFill)
        cg.fillPath()
        let inset: CGFloat = (isSelected ? ringWidth : ClipDrawing.edgeLineWidth) / 2
        let r = max(radius - inset, 0)
        cg.addPath(CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: r, cornerHeight: r, transform: nil))
        cg.setStrokeColor(isSelected ? colors.ring : colors.edge)
        cg.setLineWidth(isSelected ? ringWidth : ClipDrawing.edgeLineWidth)
        cg.strokePath()
        cg.restoreGState()

        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)        // flipped view: glyphs upright
        for (i, w) in item.effectiveWords.enumerated() {
            let box = CaptionWordLayout.box(w.range, geometry: geometry, row: row)
            if box.maxX < visible.minX - Theme.Spacing.xxs { continue }
            if box.minX > visible.maxX + Theme.Spacing.xxs { break }
            if i == hiddenWord { continue }
            // One step inside the plate's radius: the boxes sit inset in it.
            let br = min(Theme.Radius.small - Theme.Metrics.focusRingWidth, box.width / 2)
            cg.addPath(CGPath(roundedRect: box, cornerWidth: br, cornerHeight: br, transform: nil))
            cg.setFillColor(colors.boxFill)
            cg.fillPath()
            if i == selectedWord, box.width >= Theme.Spacing.xs {
                let w = 1.5 * Theme.Metrics.focusRingWidth, ir = max(br - w / 2, 0)
                cg.addPath(CGPath(roundedRect: box.insetBy(dx: w / 2, dy: w / 2), cornerWidth: ir, cornerHeight: ir, transform: nil))
                cg.setStrokeColor(colors.text)
                cg.setLineWidth(w)
                cg.strokePath()
            }
            guard box.width >= minTextBox else { continue }
            let l = line(w.text)
            let room = box.width - 2 * textInset
            cg.saveGState()
            cg.clip(to: box.insetBy(dx: textInset - 1, dy: 0))
            // Centered while it fits (the box is the word's time span); from the left, cut off, when it does not.
            let x = l.width <= room ? box.midX - l.width / 2 : box.minX + textInset
            cg.textPosition = CGPoint(x: x, y: box.midY + baselineDrop)
            cg.setFillColor(colors.text)
            CTLineDraw(l.line, cg)
            cg.restoreGState()
            if w.isUnsure { drawUnsureMark(in: box, color: colors.unsure, cg) }
        }
    }

    /// The mark of a word the recognizer was unsure about: a 1 pt line in the warning color under the text. Timeline only:
    /// the rendered caption (CaptionBurnIn) reads text and ranges, never `CaptionWord.confidence`.
    static func drawUnsureMark(in box: CGRect, color: CGColor, _ cg: CGContext) {
        let width = Theme.Metrics.focusRingWidth
        let x0 = box.minX + textInset, x1 = box.maxX - textInset
        guard x1 > x0 else { return }
        let y = box.midY + baselineDrop + Theme.Spacing.xxs
        cg.setFillColor(color)
        cg.fill(CGRect(x: x0, y: y, width: x1 - x0, height: width))
    }
}
