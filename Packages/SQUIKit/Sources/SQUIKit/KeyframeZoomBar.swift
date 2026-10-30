import AppKit
import SQCore

/// Thin vertical divider between the properties and the keyframe area. Drag to resize; the owner clamps and persists.
public final class EffectControlsDivider: NSView {
    /// Called with the total horizontal movement since the press.
    public var onDrag: ((CGFloat) -> Void)?
    public var onBegin: (() -> Void)?
    public var onEnd: (() -> Void)?
    private var originX: CGFloat = 0
    /// Hovered or dragged: the line brightens (INTERACTION-AUDIT §7).
    public private(set) var isHot = false { didSet { if oldValue != isHot { needsDisplay = true } } }
    private var dragging = false
    private var tracking: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    public override func mouseEntered(with event: NSEvent) { isHot = true }
    public override func mouseExited(with event: NSEvent) { if !dragging { isHot = false } }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    public override func draw(_ dirtyRect: NSRect) {
        (isHot ? Theme.Colors.label3 : Theme.Colors.divider).setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    public override func mouseDown(with event: NSEvent) { originX = event.locationInWindow.x; dragging = true; isHot = true; onBegin?() }
    public override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - originX) }
    public override func mouseUp(with event: NSEvent) {
        dragging = false
        isHot = bounds.contains(convert(event.locationInWindow, from: nil))
        onEnd?()
    }
}
