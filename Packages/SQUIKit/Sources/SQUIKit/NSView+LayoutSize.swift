import AppKit

extension NSView {
    /// The size a manual layout (frames, no constraints) should give this view: its intrinsic size per axis, and the Auto Layout
    /// fitting size for an axis that has none. A stack view of pills reports `noIntrinsicMetric` (-1) as its intrinsic size, so
    /// layouts that read `intrinsicContentSize` directly collapsed the pills onto each other (the monitor Fit / Full pair).
    public var sqLayoutSize: NSSize {
        let i = intrinsicContentSize
        guard i.width < 0 || i.height < 0 else { return i }
        let f = fittingSize
        return NSSize(width: i.width < 0 ? f.width : i.width, height: i.height < 0 ? f.height : i.height)
    }
}
