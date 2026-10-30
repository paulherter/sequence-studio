import AppKit
import ObjectiveC

/// The one place that positions the system close / minimize / zoom buttons in an SQ window (editor, Color page, Start,
/// Settings, Shortcuts, Import from card). All of them use a full-size content view under a transparent title bar with
/// our own bar at the top. AppKit's title bar container is only about 28 pt tall and would put the buttons about 2 cm
/// too high and show them on hover only, so the container is grown to the bar's height, pinned to the window top, and
/// the buttons are centered vertically in it with the first one's center at `firstCenterX`. AppKit lays the container
/// out again on resize, full screen, activation and tab switches; `install` re-applies the placement then.
/// Full screen: the system hides the buttons itself; nothing is moved.
@MainActor
public final class SQWindowLights {
    public struct Layout: Equatable, Sendable {
        /// Height of our top bar (the lights are centered in it).
        public var barHeight: CGFloat
        /// Distance from the window's left edge to the first button's center.
        public var firstCenterX: CGFloat
        /// Center-to-center distance (system pitch: 14 pt button + 6 pt gap).
        public var pitch: CGFloat
        public init(barHeight: CGFloat, firstCenterX: CGFloat, pitch: CGFloat = 20) {
            self.barHeight = barHeight; self.firstCenterX = firstCenterX; self.pitch = pitch
        }
        /// The editor's top bar: the v9 design dots (12 pt, 8 apart, 16 from the left) in a `topBar` high bar.
        public static var editor: Layout {
            Layout(barHeight: ShellMetrics.topBar, firstCenterX: ShellMetrics.topLeading + ShellMetrics.windowLight / 2,
                   pitch: ShellMetrics.windowLight + ShellMetrics.windowLightGap)
        }
        /// Windows with the 38 pt `SQWindowTitleStrip`.
        @MainActor public static var titleStrip: Layout {
            Layout(barHeight: SQWindowTitleStrip.height, firstCenterX: ShellMetrics.topLeading + ShellMetrics.windowLight / 2,
                   pitch: ShellMetrics.windowLight + ShellMetrics.windowLightGap)
        }
    }

    public static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Button origins inside the (unflipped) bar of height `layout.barHeight`; pure, for tests.
    public static func origins(layout: Layout, buttonSize: CGSize) -> [CGPoint] {
        (0..<kinds.count).map { i in
            CGPoint(x: (layout.firstCenterX + CGFloat(i) * layout.pitch - buttonSize.width / 2).rounded(),
                    y: ((layout.barHeight - buttonSize.height) / 2).rounded())
        }
    }

    /// Container frame in the window frame's coordinates: the bar's height, pinned to the top.
    public nonisolated static func containerFrame(windowSize: CGSize, barHeight: CGFloat) -> CGRect {
        CGRect(x: 0, y: windowSize.height - barHeight, width: windowSize.width, height: barHeight)
    }

    /// Places the buttons now; true when they were placed (false in full screen or without a title bar).
    @discardableResult
    public static func place(in window: NSWindow, layout: Layout) -> Bool {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview else { return false }
        container.frame = containerFrame(windowSize: window.frame.size, barHeight: layout.barHeight)
        bar.frame = container.bounds
        let buttons = kinds.compactMap { window.standardWindowButton($0) }
        let origins = origins(layout: layout, buttonSize: close.frame.size)
        for (b, o) in zip(buttons, origins) {
            b.isHidden = false
            b.alphaValue = 1
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
        return true
    }

    /// Places the buttons and keeps them there after resize, full screen exit, becoming key and page/tab switches
    /// (those make AppKit lay the title bar out again). Safe to call once per window; a second call replaces the layout.
    public static func install(in window: NSWindow, layout: Layout) {
        if let old = objc_getAssociatedObject(window, &key) as? SQWindowLights { old.stop() }
        let lights = SQWindowLights(window: window, layout: layout)
        objc_setAssociatedObject(window, &key, lights, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lights.apply()
    }

    /// Re-applies the placement of an installed window (call after anything that may reset the title bar).
    public static func reapply(in window: NSWindow) {
        (objc_getAssociatedObject(window, &key) as? SQWindowLights)?.apply()
    }

    private nonisolated(unsafe) static var key: UInt8 = 0

    private weak var window: NSWindow?
    private let layout: Layout
    private var tokens: [NSObjectProtocol] = []

    private init(window: NSWindow, layout: Layout) {
        self.window = window; self.layout = layout
        let names: [NSNotification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didExposeNotification, NSWindow.didChangeScreenNotification]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
    }

    private func stop() { tokens.forEach(NotificationCenter.default.removeObserver); tokens = [] }

    /// Now, and once more after AppKit's own layout pass.
    private func apply() {
        guard let window else { return }
        Self.place(in: window, layout: layout)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                Self.place(in: window, layout: self.layout)
            }
        }
    }

    isolated deinit { stop() }
}
