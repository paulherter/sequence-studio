import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// Find and replace on the caption tracks (`TimelineView.showCaptionSearch` / `makeCaptionSearch`): Edit > Find with the
/// timeline focused opens `CaptionSearchControl` under the first caption row, at the content's left edge + 12. The host
/// draws it over the cards (`drawCaptionSearch`) and sends it events first (`handleCaptionSearch`).
extension TimelinePanel {
    public var isCaptionSearchShown: Bool { captionSearch != nil }

    /// Opens the card (shown: focuses its find field). False when the timeline has no captions: the caller keeps its own
    /// Find. `window` (points) keeps the card on screen like the Mac popover's screen clamp (6 pt margin).
    public mutating func showCaptionSearch(window: CGSize) -> Bool {
        guard timeline.captionTracks.contains(where: { !$0.items.isEmpty }),
              let row = geometry.captionRows(for: timeline).first else { return false }
        _ = finishWordField(commit: true)
        var s = captionSearch ?? CaptionSearchControl()
        let k = CGFloat(max(scale, 0.01))
        let o = CGPoint(x: CGFloat(frame.x) / k, y: CGFloat(frame.y) / k)
        let y = min(max(row.y, TimelineGeometry.rulerHeight), max(size.height - row.height, 0))
        var p = CGPoint(x: o.x + TimelineGeometry.contentOriginX + CGFloat(DrawTheme.Spacing.md), y: o.y + y + row.height + 4)
        let margin: CGFloat = 6
        if p.y + CaptionSearchControl.height > window.height - margin { p.y = o.y + y - 4 - CaptionSearchControl.height }
        p.x = max(margin, min(p.x, window.width - margin - CaptionSearchControl.width))
        p.y = max(margin, min(p.y, window.height - margin - CaptionSearchControl.height))
        s.origin = p
        s.focusFind(in: timeline, from: playhead)
        captionSearch = s
        return true
    }

    public mutating func closeCaptionSearch() { captionSearch = nil }

    /// An event for the card (window pixels, the host's scale). nil when it does not take it: the press landed outside
    /// (the card stays open) or a key came while neither field is open.
    public mutating func handleCaptionSearch(_ e: InputEvent) -> [TimelineAction]? {
        guard var s = captionSearch else { return nil }
        let k = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        let answers: [CaptionSearchControl.Answer]?
        switch e {
        case .mouseDown(let x, let y, _): answers = s.mouseDown(pt(x, y), timeline: timeline, playhead: playhead)
        case .mouseUp(let x, let y):
            guard s.pressed != nil else { captionSearch = s; return nil }
            answers = s.mouseUp(pt(x, y), timeline: timeline, playhead: playhead)
        case .mouseDragged: answers = s.pressed != nil ? [] : nil
        case .mouseMoved(let x, let y):
            s.mouseMoved(pt(x, y))
            captionSearch = s
            return s.frame.contains(pt(x, y)) ? [] : nil
        case .keyDown(let key, let m): answers = s.key(key, modifiers: m, timeline: timeline, playhead: playhead)
        case .scroll(let x, let y, _, _, _): answers = s.frame.contains(pt(x, y)) ? [] : nil
        }
        captionSearch = s
        guard let answers else { return nil }
        var out: [TimelineAction] = []
        for a in answers {
            switch a {
            case .close: captionSearch = nil
            case .highlight(let m): out += selectWord(CaptionWordRef(caption: m.caption, index: m.words.lowerBound))
            case .show(let m):
                out += selectWord(CaptionWordRef(caption: m.caption, index: m.words.lowerBound))
                out.append(.seek(m.time))
                reveal(m.time)
            case .replace(let t, let name):
                out += applyCaptionEdit(t, undoName: name, captions: captionSelection, word: nil)
            }
        }
        return out
    }

    /// The card over everything the panel draws (window points).
    public func drawCaptionSearch(_ c: inout Canvas) {
        captionSearch?.draw(&c, theme: theme)
    }
}
