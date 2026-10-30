import AppKit

/// The one observer of `UIScale.didChange`: rebuilds every open window so a new scale shows without a restart.
/// Token reads (`Theme.Row`, `Theme.Typography`, `Theme.Metrics`) are computed and already return the new values;
/// this pass makes views ask again: layout, intrinsic size, redraw, list row heights, and fonts that a control stored.
@MainActor public enum UIScaleRelayout {
    private static var installed = false
    private static var applied = UIScale.current

    public static func install() {
        guard !installed else { return }
        installed = true
        applied = UIScale.current
        NotificationCenter.default.addObserver(forName: UIScale.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { relayoutAll() }
        }
    }

    public static func relayoutAll() {
        let old = applied, new = UIScale.current
        guard old != new else { return }
        applied = new
        for window in NSApp.windows {
            if let root = window.contentView { relayout(root, from: old, to: new) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func relayout(_ view: NSView, from old: Double, to new: Double) {
        if let control = view as? NSControl, let font = control.font {
            control.font = NSFont(descriptor: font.fontDescriptor, size: UIScale.rescaled(font.pointSize, from: old, to: new)) ?? font
        }
        if let table = view as? NSTableView {
            table.rowHeight = UIScale.rescaled(table.rowHeight, from: old, to: new)
            table.reloadData()
        }
        for sub in view.subviews { relayout(sub, from: old, to: new) }
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.needsDisplay = true
    }
}
