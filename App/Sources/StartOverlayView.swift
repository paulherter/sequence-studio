import AppKit
import SQCore
import SQEditorUI
import SwiftUI

/// The start screen's own window (design B): about Finder's size, resizable, frame remembered. No editor chrome and no
/// editor behind it; the editor opens in its own window when a project is created, opened or imported.
@MainActor
final class StartWindowController: NSObject, NSWindowDelegate {
    static let autosaveName = "SequenceStudioStart"
    let window: NSWindow
    let content: StartContentView
    /// The user closed the window (red button, Cmd+W).
    var onUserClose: (() -> Void)?

    init(rootView: StartWindowView) {
        content = StartContentView(rootView: rootView)
        let size = Theme.Metrics.startWindowSize
        window = StartNSWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Sequence Studio"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // System traffic lights stay (decision 2026-10-10); the transparent title bar lets the top bar sit under them.
        window.appearance = Theme.windowAppearance
        window.backgroundColor = Theme.Colors.canvas
        window.contentMinSize = Theme.Metrics.startWindowMinSize
        window.contentView = content
        window.delegate = self
        window.setFrameAutosaveName(Self.autosaveName)
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.initialFirstResponder = content
        positionLightsSoon()
    }

    func show() {
        SplashHandoff.present(window) { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(content)
            positionLightsSoon()
        }
    }

    func hide() { window.orderOut(nil) }

    var isVisible: Bool { window.isVisible }

    /// The system close / miniaturize / zoom buttons, centered `Metrics.startTop / 2` below the window top and 16 pt from
    /// the left edge (the bar leaves `Metrics.startLights` for them); the one helper `SQWindowLights` places them.
    private func positionLights() {
        SQWindowLights.install(in: window, layout: .init(barHeight: Theme.Metrics.startTop,
                                                         firstCenterX: Theme.Metrics.startS4 + 7,
                                                         pitch: 14 + Theme.Metrics.startS2 - 2))
    }

    private func positionLightsSoon() {
        positionLights()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.positionLights() } }
    }

    func windowDidResize(_ notification: Notification) { positionLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionLightsSoon() }
    func windowDidEndLiveResize(_ notification: Notification) { positionLights() }
    func windowDidEnterFullScreen(_ notification: Notification) { positionLightsSoon() }
    func windowDidExitFullScreen(_ notification: Notification) { positionLightsSoon() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onUserClose?()
        return true
    }
}

/// Window subclass so Esc reaches the content even when a button inside has the focus.
private final class StartNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        (contentView as? StartContentView)?.escape()
    }
}

/// Content of the start window: the SwiftUI start view plus its keyboard (Up/Down through recents, Return opens,
/// Tab walks the buttons, Esc closes it when a project is open).
@MainActor
final class StartContentView: NSView {
    private let host: NSHostingView<AnyView>
    private(set) var view: StartWindowView
    /// Esc: closes the window when a real project is open in the editor.
    var onEscape: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var appearancePopover: SQPopover?

    init(rootView: StartWindowView) {
        view = rootView
        host = NSHostingView(rootView: AnyView(rootView.sqLiveAppearance()))
        super.init(frame: .zero)
        view.onAppearance = { [weak self] r in self?.showAppearance(at: r) }
        host.rootView = AnyView(view.sqLiveAppearance())
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Start")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Same selection and fields, new data. Keeps the Up/Down choice while it still exists.
    func refresh(_ new: StartWindowView) {
        var v = new
        v.onAppearance = { [weak self] r in self?.showAppearance(at: r) }
        if let p = view.selectedPath, new.recents.contains(where: { $0.path == p && !new.missing.contains($0.path) }) { v.selectedPath = p }
        view = v
        host.rootView = AnyView(v.sqLiveAppearance())
    }

    /// The Appearance popover above the rail's appearance button. Its own window, so the live rebuild of the start view
    /// never interrupts a slider drag.
    private func showAppearance(at rect: CGRect) {
        if let p = appearancePopover, p.isShown { p.close(); return }
        let content = NSHostingView(rootView: AppearancePopoverView { [weak self] in self?.appearancePopover?.close() })
        content.frame.size = content.fittingSize
        let p = SQPopover(contentView: content)
        p.inset = Theme.Metrics.startS3
        p.mode = .transient
        p.onClose = { [weak self] in self?.appearancePopover = nil }
        appearancePopover = p
        p.show(relativeTo: rect, of: self, preferredEdge: .minY)
    }

    private var openableRecents: [RecentProjects.Entry] { view.recents.filter { !view.missing.contains($0.path) } }

    private func moveSelection(_ delta: Int) {
        let list = openableRecents
        guard !list.isEmpty else { return }
        let cur = view.selectedPath ?? list.first?.path
        let i = list.firstIndex { $0.path == cur } ?? 0
        view.selectedPath = list[max(0, min(list.count - 1, i + delta))].path
        host.rootView = AnyView(view.sqLiveAppearance())
    }

    private func buttons() -> [SQButton] {
        var out: [SQButton] = []
        func walk(_ v: NSView) {
            for s in v.subviews where !s.isHidden {
                if let b = s as? SQButton, b.isEnabled { out.append(b) } else { walk(s) }
            }
        }
        walk(host)
        return out
    }

    private func moveFocus(backwards: Bool) {
        let all = buttons()
        guard !all.isEmpty else { return }
        let cur = window?.firstResponder as? SQButton
        let i = cur.flatMap { c in all.firstIndex { $0 === c } }
        let next = i.map { (($0 + (backwards ? -1 : 1)) + all.count) % all.count } ?? (backwards ? all.count - 1 : 0)
        window?.makeFirstResponder(all[next])
    }

    /// Return opens the selected recent (or the newest, like "Continue").
    private func openSelected() {
        let list = openableRecents
        guard let p = view.selectedPath ?? list.first?.path, let e = list.first(where: { $0.path == p }) else { return }
        view.onOpen(e.url)
    }

    func escape() {
        // Esc inside an editable field (search, template name) belongs to the field.
        if let tv = window?.firstResponder as? NSTextView, tv.isEditable { return }
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: moveSelection(-1)                                  // Up
        case 125: moveSelection(1)                                   // Down
        case 36, 76: openSelected()                                  // Return, Enter
        case 48: moveFocus(backwards: event.modifierFlags.contains(.shift))   // Tab
        case 53: escape()
        default: super.keyDown(with: event)
        }
    }
}

/// Windows that open during launch wait until the startup splash has faded out completely, then come up with a plain
/// alpha fade (no scale or slide) and become key. Once the splash is gone (or never shown) they show directly.
@MainActor enum SplashHandoff {
    static let fadeDuration: TimeInterval = 0.18

    static func present(_ w: NSWindow, then: (@MainActor () -> Void)? = nil) {
        StartupReporter.shared.whenSplashGone { fadeIn in
            if fadeIn { w.alphaValue = 0 }
            w.makeKeyAndOrderFront(nil)
            then?()
            guard fadeIn else { w.alphaValue = 1; return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeDuration
                w.animator().alphaValue = 1
            }
        }
    }
}
