import Foundation

/// The overlay scroller of the shared lists (macOS overlay style, same on Windows): a thin knob at the right edge that
/// fades in while the list scrolls or the pointer is over its edge, fades out after a moment, and can be dragged.
/// The knob is proportional to the visible share of the content. State lives in the list's `ScrollBody`.
public enum ScrollerBar {
    /// Seconds the knob stays fully visible after the last scroll or pointer move.
    public static let visibleFor = 0.8
    public static let fade = 0.3
    public static let trackWidth: CGFloat = 12
    public static let minKnob: CGFloat = 28

    /// The knob rectangle (points) for a scroll position, nil when the content fits.
    public static func knob(viewport v: CGRect, content: CGFloat, offset: Double, wide: Bool) -> CGRect? {
        guard content > v.height + 0.5, v.height > 0 else { return nil }
        let track = v.insetBy(dx: 0, dy: 2)
        let h = min(max(track.height * v.height / content, minKnob), track.height)
        let maxOff = Double(content - v.height)
        let f = CGFloat(min(max(offset / maxOff, 0), 1))
        let w: CGFloat = wide ? 10 : 6
        return CGRect(x: v.maxX - 2 - w, y: track.minY + (track.height - h) * f, width: w, height: h)
    }
}

extension ScrollBody {
    /// 0...1 opacity of the knob at `now`.
    public func scrollerAlpha(now: Double) -> Float {
        if scrollerDragging { return 1 }
        let t = now - lastActive - ScrollerBar.visibleFor
        return t <= 0 ? 1 : Float(max(0, 1 - t / ScrollerBar.fade))
    }

    /// Draws the knob over the list's `viewport` (points) after its content.
    public func drawScroller(_ c: inout Canvas, viewport: CGRect, content: CGFloat, theme t: DrawTheme, now: Double = HostScroll.now()) {
        let o = offset
        let a = scrollerAlpha(now: now)
        guard a > 0.01, let k = ScrollerBar.knob(viewport: viewport, content: content, offset: o, wide: scrollerDragging || scrollerHover)
        else { return }
        c.fill(roundedRect: k, radius: k.width / 2, (scrollerDragging ? t.label2 : t.label3).alpha(a * 0.9))
    }

    /// Mouse events on the scroller: true when it took the event (a drag of the knob, a click on the track).
    public func scrollerEvent(_ e: InputEvent, scale: Float, viewport: CGRect, content: CGFloat, now: Double = HostScroll.now()) -> Bool {
        let s = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / s, y: CGFloat(y) / s) }
        let track = CGRect(x: viewport.maxX - ScrollerBar.trackWidth, y: viewport.minY, width: ScrollerBar.trackWidth, height: viewport.height)
        guard content > viewport.height + 0.5 else { scrollerDragging = false; return false }
        switch e {
        case .mouseMoved(let x, let y):
            scrollerHover = track.contains(pt(x, y))
            if scrollerHover { touch(now) }
            return false
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            guard track.contains(p), scrollerAlpha(now: now) > 0.05 || scrollerHover else { return false }
            let off = offset
            let k = ScrollerBar.knob(viewport: viewport, content: content, offset: off, wide: true)
            scrollerDragging = true
            scrollerGrab = Double(k.map { $0.contains(p) ? p.y - $0.minY : $0.height / 2 } ?? 0)
            stop(); mode = .idle
            drag(to: p.y, viewport: viewport, content: content, now: now)
            return true
        case .mouseDragged(let x, let y):
            guard scrollerDragging else { return false }
            drag(to: pt(x, y).y, viewport: viewport, content: content, now: now)
            return true
        case .mouseUp:
            guard scrollerDragging else { return false }
            scrollerDragging = false
            touch(now)
            return true
        default:
            return false
        }
    }

    private func drag(to y: CGFloat, viewport: CGRect, content: CGFloat, now: Double) {
        let track = viewport.insetBy(dx: 0, dy: 2)
        let h = min(max(track.height * viewport.height / content, ScrollerBar.minKnob), track.height)
        let room = max(Double(track.height - h), 1)
        let f = min(max((Double(y) - scrollerGrab - Double(track.minY)) / room, 0), 1)
        mode = .idle
        pos = f * Double(content - viewport.height)
        touch(now)
    }
}
