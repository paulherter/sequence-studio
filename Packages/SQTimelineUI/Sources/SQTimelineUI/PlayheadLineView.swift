import AppKit

/// A 2 pt playhead line (`width`, the one thickness everywhere) as its own layer: moving it never redraws the view underneath. Mouse events pass through.
public final class PlayheadLineView: NSView {
    /// Thickness of every playhead line (timeline, ruler, Controls lanes and curves).
    public static let width: CGFloat = Theme.PlayheadSkin.lineWidth
    /// Frame of the line centered on `x` (rounded to a whole point), `height` tall from `y`.
    public static func frame(centerX x: CGFloat, y: CGFloat = 0, height: CGFloat) -> NSRect {
        Theme.PlayheadSkin.lineFrame(centerX: x, y: y, height: height)
    }
    public init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The playhead head as its own layer: drawn once with `Theme.PlayheadSkin`, moved by `frame.origin`. Its center line is
/// `PlayheadHeadView.size.width / 2` from the left edge.
public final class PlayheadHeadView: NSView {
    public static let size = Theme.PlayheadSkin.headSize
    public override init(frame: NSRect) { fatalError("use init()") }
    public init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public nonisolated override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.PlayheadSkin.drawHead(centerX: Self.size.width / 2)
    }
}
