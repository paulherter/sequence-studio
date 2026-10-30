#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQText

/// Captions in the Program monitor: where a caption's text sits (same geometry as the picture and the export burn-in,
/// `CaptionLayout`) and which caption a double-click hits, so it can be edited in place.
public enum CaptionMonitorHit {
    /// Hit slop around the text (sequence px).
    public static let slop = 12.0

    /// The edit box of a caption: sequence px from the canvas center, y down (what the in-place editor covers).
    public static func editBox(canvas: SequenceFormat, position: CaptionPosition = .default) -> (centre: Vec2, box: TextBox) {
        let c = CaptionLayout.boxCentre(canvasWidth: Double(canvas.layoutFormat.width), canvasHeight: Double(canvas.height), position: position)
        return (Vec2(c.x, c.y), CaptionLayout.box(canvasWidth: Double(canvas.layoutFormat.width), canvasHeight: Double(canvas.height)))
    }

    /// What the in-place editor of the Program monitor needs to sit over a caption: the caption box as a stand-in target
    /// (position = box center, size = box) and the style the caption is drawn with (aligned by the caption position).
    public static func editTarget(for item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn)
        -> (target: OverlayTarget, style: TextStyle, box: TextBox) {
        let position = item.position ?? library.position
        let (centre, box) = editBox(canvas: canvas, position: position)
        var style = library.style(for: item.styleRef.isEmpty ? nil : item.styleRef)
        CaptionLayout.align(&style, position)
        let target = OverlayTarget(clip: item.id, size: CGSize(width: box.width, height: box.height), isText: true,
                                   baseTransform: ClipTransform(position: centre), shift: .zero,
                                   positionTrack: KeyframeTrack<Vec2>())
        return (target, style, box)
    }

    /// The drawn text block of a caption (its lines and background), sequence px from the canvas center. An empty caption
    /// has a one-line placeholder at the bottom of the box, so it can still be clicked.
    public static func textRect(of item: CaptionItem, canvas: SequenceFormat, library: CaptionPresetLibrary = .builtIn) -> CGRect {
        let style = library.style(for: item.styleRef.isEmpty ? nil : item.styleRef)
        let position = item.position ?? library.position
        let w = Double(canvas.layoutFormat.width), h = Double(canvas.height)
        let t = CaptionLayout.template(text: item.lines.joined(separator: "\n"), style: style, canvasWidth: w, canvasHeight: h,
                                       position: position)
        let (centre, box) = editBox(canvas: canvas, position: position)
        let left = centre.x - box.width / 2, top = centre.y - box.height / 2
        let layout = TextLayout.layout(text: t.text, style: t.style, maxWidth: box.width, boxHeight: box.height)
        var r: TextRect?
        for l in layout.lines { r = r.map { $0.union(l.rect) } ?? l.rect }
        if let bg = layout.backgroundRect { r = r.map { $0.union(bg) } ?? bg }
        guard let r else {
            let lineH = style.size * 1.25
            let y: Double = switch position.vertical {
            case .top: top
            case .middle: centre.y - lineH / 2
            case .bottom: top + box.height - lineH
            }
            return CGRect(x: centre.x - 120, y: y, width: 240, height: lineH)
        }
        return CGRect(x: left + r.x, y: top + r.y, width: r.width, height: r.height)
    }

    /// The topmost caption (visible tracks) under `time` whose text block contains `p`. "Under `time`" is what the
    /// renderer draws (`Timeline.captionSlots(at:)`, so a caption held through a small gap is clickable); an empty
    /// caption is not drawn but stays clickable inside its own range, so it can be typed into.
    public static func caption(at p: Vec2, in timeline: Timeline, time: Time, library: CaptionPresetLibrary = .builtIn) -> CaptionItem.ID? {
        // Draw order reversed (topmost first): the drawn captions, then the blank ones, which draw nothing and so
        // only count where no drawn caption covers the point.
        let shown = timeline.captionSlots(at: time)
        var items = shown.map(\.item).reversed() as [CaptionItem]
        for a in timeline.captions(at: time).reversed() where a.item.isBlank && !shown.contains(where: { $0.track == a.track }) {
            items.append(a.item)
        }
        for item in items {
            let r = textRect(of: item, canvas: timeline.format, library: library).insetBy(dx: -slop, dy: -slop)
            if r.contains(CGPoint(x: p.x, y: p.y)) { return item.id }
        }
        return nil
    }
}
