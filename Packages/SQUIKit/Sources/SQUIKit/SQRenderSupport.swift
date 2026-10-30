import AppKit

/// Entry points for the panel render harness (`scripts/render-panels.sh`): the shared overlays as plain views, without
/// showing a window. No behavior of its own.
extension SQDialog {
    /// The laid-out dialog card (the window's content view), sized like the real dialog.
    public func renderedCard() -> NSView? { layout().contentView }
}

public enum SQMenuRender {
    /// One menu level as the menu panel shows it.
    @MainActor
    public static func view(items: [SQMenuItem]) -> NSView {
        let v = SQMenuListView(items: items)
        v.frame = CGRect(origin: .zero, size: v.contentSize)
        return v
    }
}
