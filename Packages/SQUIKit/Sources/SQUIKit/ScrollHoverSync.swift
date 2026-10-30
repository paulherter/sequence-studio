import AppKit

/// Keeps hover correct while a list scrolls under a resting pointer. AppKit sends no mouseExited / mouseEntered for
/// that (the pointer did not move), so every row that passed under it kept its hover fill. A view that shows hover
/// owns one of these: it re-reads the pointer whenever the enclosing clip view scrolls (and on demand, e.g. when a
/// row view is reused) and hands the result to `apply`.
@MainActor
public final class ScrollHoverSync {
    private weak var view: NSView?
    private let apply: (NSPoint?) -> Void
    private var observer: NSObjectProtocol?

    /// `apply` gets the pointer in `view`'s coordinates when the pointer is over `view` (not covered by another
    /// view, window active), else nil.
    public init(view: NSView, apply: @escaping (NSPoint?) -> Void) {
        self.view = view
        self.apply = apply
    }

    /// Call from `viewDidMoveToWindow` (and after the view joined a scroll view): observes the enclosing clip view.
    public func attach() {
        detach()
        guard let clip = view?.enclosingScrollView?.contentView, view?.window != nil else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Recomputes hover from the current pointer location.
    public func refresh() { apply(Self.pointer(over: view)) }

    /// The pointer in `view`'s coordinates if it is over `view` or one of its subviews, else nil.
    public static func pointer(over view: NSView?) -> NSPoint? {
        guard let view, let window = view.window, window.isVisible, NSApp.isActive else { return nil }
        return pointer(over: view, atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }

    /// Same with an explicit window point (tests).
    public static func pointer(over view: NSView, atWindowPoint p: NSPoint) -> NSPoint? {
        guard let window = view.window, let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(p), hit === view || hit.isDescendant(of: view) else { return nil }
        return view.convert(p, from: nil)
    }
}
