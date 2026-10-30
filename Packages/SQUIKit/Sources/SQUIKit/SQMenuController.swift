import AppKit

/// Shows one SQMenu: a borderless floating panel per open level, driven by `SQMenuNavigator`. One menu at a time.
/// Mouse and keys are handled by local event monitors (the panels never become key), so the window under the menu keeps focus.
@MainActor
public final class SQMenuController {
    public static let shared = SQMenuController()

    private var nav = SQMenuNavigator(items: [])
    private var panels: [SQMenuPanel] = []
    private var views: [SQMenuListView] = []
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    /// The control the menu dropped from (a popup box, a "..." button): a press on it closes the menu and goes no
    /// further, so the control does not see the press, find the menu closed and open it again.
    private weak var anchorView: NSView?
    private var openedAt: TimeInterval = 0
    private var anchorTop: CGFloat?
    private var openPoint: CGPoint = .zero
    private var pressedInList = false

    public var isOpen: Bool { !panels.isEmpty }

    /// Shows `items` with the top-left corner at `screenPoint` (screen coordinates, y up).
    public func present(items: [SQMenuItem], at screenPoint: CGPoint, anchor anchorView: NSView? = nil, anchorTop: CGFloat? = nil) {
        dismiss()
        guard !items.isEmpty else { return }
        SQTooltip.shared.hide()
        self.anchorView = anchorView
        nav = SQMenuNavigator(items: items)
        openedAt = ProcessInfo.processInfo.systemUptime
        pressedInList = false
        openPoint = NSEvent.mouseLocation
        self.anchorTop = anchorTop
        anchor = screenPoint
        sync()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]) { [weak self] event in
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var out: NSEvent? = e
            MainActor.assumeIsolated { if let self { out = self.handle(e) } }
            return out
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        // The window under the menu changes (resized, closed, a sheet opens): the menu's place is stale. Panels (popovers,
        // tooltips) are left alone: a popover resizing itself must not close the menu opened from it. Hidden windows too:
        // no menu sits over them (and an off-screen window resized elsewhere, e.g. by a test, must not close it).
        let nc = NotificationCenter.default
        windowObservers = [NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification].map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                nonisolated(unsafe) let w = n.object as? NSWindow
                MainActor.assumeIsolated { if let w, !(w is NSPanel), w.isVisible { self?.dismiss() } }
            }
        }
    }

    public func dismiss() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers = []
        anchorView = nil
        for p in panels { p.orderOut(nil) }
        panels = []; views = []
    }

    private var anchor: CGPoint = .zero
    /// Set by arrow/Home/End keys: the next `sync()` scrolls the highlighted row into view (pointer hover never scrolls).
    private var keyboardMove = false

    // MARK: Panels follow the navigator

    private func sync() {
        while panels.count > nav.depth { panels.removeLast().orderOut(nil); views.removeLast() }
        for level in 0..<nav.depth {
            let items = nav.items(level: level)
            if level >= panels.count { addPanel(level: level, items: items) }
            else if views[level].items != items || views[level].filter != nav.filter(level: level) {
                views[level].filter = nav.filter(level: level)
                views[level].items = items
                let top = panels[level].frame.maxY
                panels[level].setContentSize(views[level].visibleSize)
                panels[level].setFrameTopLeftPoint(CGPoint(x: panels[level].frame.minX, y: top))
            }
            views[level].highlighted = nav.highlighted(level: level)
            if let h = views[level].highlighted, keyboardMove { views[level].reveal(row: h) }
        }
        keyboardMove = false
    }

    private func addPanel(level: Int, items: [SQMenuItem]) {
        let view = SQMenuListView(items: items)
        view.onPress = { [weak self] i in
            guard let self else { return }
            self.nav.hover(i, level: level)
            self.activate()
        }
        let screen = screenFrame(level: level)
        view.maxHeight = SQMenuLayout.maxHeight(screen: screen)
        // A value list dropped from a control scrolls after `maxListRows` (command menus with submenus keep their length).
        if level == 0, anchorView != nil, !items.contains(where: { $0.submenu != nil }) {
            view.maxHeight = min(view.maxHeight ?? .greatestFiniteMagnitude, SQMenuLayout.listCapHeight)
        }
        var frameOrigin: CGPoint?
        if level == 0 {
            let content = CGSize(width: view.contentSize.width, height: min(view.contentSize.height, view.maxHeight ?? .greatestFiniteMagnitude))
            let r = SQMenuLayout.placement(content: content, anchor: anchor, anchorTop: anchorTop, screen: screen)
            view.maxHeight = min(r.height, view.maxHeight ?? r.height)
            frameOrigin = r.origin
        }
        let size = view.visibleSize
        let panel = SQMenuPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
        panel.setFrameOrigin(frameOrigin ?? origin(for: level, size: size))
        panel.orderFrontRegardless()
        panels.append(panel); views.append(view)
    }

    /// Visible frame of the screen a new panel of `level` opens on.
    private func screenFrame(level: Int) -> CGRect {
        let screens = NSScreen.screens
        if level == 0 {
            return screens.first { $0.frame.contains(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        }
        return screens.first { $0.frame.intersects(panels[level - 1].frame) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func origin(for level: Int, size: CGSize) -> CGPoint {
        let screens = NSScreen.screens
        // Submenu: right of the parent at the parent row, flipped to the left when it does not fit.
        let parent = panels[level - 1], parentView = views[level - 1]
        let row = parentView.rowFrames[nav.highlighted(level: level - 1) ?? 0]
        let topY = SQMenuLayout.submenuTop(parentMaxY: parent.frame.maxY, rowMinY: row.minY, parentScroll: parentView.scrollOffset)   // flipped view -> screen
        let screen = screens.first { $0.frame.intersects(parent.frame) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var o = SQMenuLayout.origin(size: size, anchor: CGPoint(x: parent.frame.maxX - 3, y: topY), screen: screen)
        if parent.frame.maxX - 3 + size.width > screen.maxX { o.x = max(screen.minX, parent.frame.minX - size.width + 3) }
        return o
    }

    // MARK: Events

    private func levelAndRow(_ event: NSEvent) -> (level: Int, row: Int?)? {
        let p = screenPoint(event)
        for level in views.indices.reversed() {
            let panel = panels[level]
            guard panel.frame.contains(p) else { continue }
            let local = views[level].convert(panel.convertPoint(fromScreen: p), from: nil)
            return (level, views[level].index(at: local))
        }
        return nil
    }

    /// True when the press lands on the control the menu was opened from.
    func pressHitsAnchor(_ event: NSEvent) -> Bool {
        guard let a = anchorView, let w = a.window, w === event.window else { return false }
        return a.bounds.contains(a.convert(event.locationInWindow, from: nil))
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard isOpen else { return event }
        switch event.type {
        case .keyDown:
            handleKey(event); return nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if let hit = levelAndRow(event) {
                // Same row whose submenu is already open: leave it alone.
                if nav.depth > hit.level + 1, nav.highlighted(level: hit.level) == hit.row { return nil }
                nav.hover(hit.row, level: hit.level)
                if let r = hit.row, nav.items(level: hit.level)[r].submenu != nil { _ = nav.activate() }
                sync()
            }
            return nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if levelAndRow(event) != nil { pressedInList = true }
            if levelAndRow(event) == nil {
                // Click outside closes and still reaches its target, except the control the menu came from.
                let onAnchor = event.type == .leftMouseDown && pressHitsAnchor(event)
                dismiss()
                return onAnchor ? nil : event
            }
            return nil
        case .leftMouseUp, .rightMouseUp:
            // The release of the opening click never selects; see `SQMenuReleaseRule`.
            let held = ProcessInfo.processInfo.systemUptime - openedAt
            let p = screenPoint(event)
            let hit = levelAndRow(event)
            let outcome = SQMenuReleaseRule.outcome(pressedInList: pressedInList, overRow: hit?.row != nil, overAnchor: pressHitsAnchor(event),
                                                   moved: hypot(p.x - openPoint.x, p.y - openPoint.y), held: held)
            pressedInList = false
            switch outcome {
            case .activate:
                if let hit, let r = hit.row { nav.hover(r, level: hit.level); activate() }
            case .dismiss: dismiss()
            case .ignore: break
            }
            return nil
        case .scrollWheel:
            let p = screenPoint(event)
            let level = views.indices.reversed().first { panels[$0].frame.contains(p) } ?? views.indices.last
            if let level {
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                views[level].scroll(by: -dy)
            }
            return nil
        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent) {
        keyboardMove = true
        switch event.keyCode {
        case 125: nav.move(.down); keyboardMove = true
        case 126: nav.move(.up); keyboardMove = true
        case 115: nav.move(.first); keyboardMove = true
        case 119: nav.move(.last); keyboardMove = true
        case 124: _ = nav.rightKey()
        case 123: if !nav.leftKey() { dismiss(); return }
        case 36, 76, 49: activate(); return
        case 53: if nav.clearFilter() { break }; dismiss(); return
        case 51: nav.deleteFilterCharacter()
        default:
            if !event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers?.first, c.isLetter || c.isNumber {
                nav.typeFilter(c)
            }
        }
        sync()
    }

    private func activate() {
        switch nav.activate() {
        case .none: break
        case .openedSubmenu: sync()
        case .run(let path):
            let action = nav.item(at: path)?.action
            dismiss()
            // After the menu is gone and the event is done, so actions may open sheets or run modal panels.
            SQAfterEvent.run { action?() }
        }
    }
}

/// Entry point for views: shows `menu` for a right-click, custom or native according to `SQMenuSettings`.
@MainActor
public enum SQContextMenu {
    public static func show(_ menu: NSMenu?, for event: NSEvent, in view: NSView) {
        guard let menu, !menu.items.isEmpty else { return }
        guard SQMenuSettings.useCustomMenus() else {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        menu.delegate?.menuNeedsUpdate?(menu)
        let items = SQMenuItem.items(from: menu)
        guard !items.isEmpty else { return }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        SQMenuController.shared.present(items: items, at: screenPoint)
    }

    /// Dev aid (panel renders): when set, SQ rows are handed here instead of being shown.
    public static var capture: (([SQMenuItem]) -> Void)?

    /// Shows ready-made SQ rows at the mouse position of a right-click (no NSMenu involved).
    public static func show(items: [SQMenuItem], for event: NSEvent, in view: NSView) {
        guard !items.isEmpty else { return }
        if let capture { capture(items); return }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        SQMenuController.shared.present(items: items, at: screenPoint)
    }

    /// SQ rows at a view-local point (top-left of the menu there), for header "..." buttons and long-press slots.
    public static func popUp(items: [SQMenuItem], at point: NSPoint, in view: NSView, anchorTop: CGFloat? = nil) {
        guard !items.isEmpty else { return }
        if let capture { capture(items); return }
        guard let window = view.window else { return }
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: view.convert(point, to: nil)),
                                        anchor: view is NSControl ? view : nil,
                                        anchorTop: anchorTop.map { window.convertPoint(toScreen: view.convert(NSPoint(x: point.x, y: $0), to: nil)).y })
    }

    /// SQ rows below a control (a pull-down's drop-down), top-left at the control's lower-left corner.
    public static func popUp(items: [SQMenuItem], below view: NSView) {
        let y = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        popUp(items: items, at: NSPoint(x: view.bounds.minX, y: y), in: view, anchorTop: view.isFlipped ? view.bounds.minY : view.bounds.maxY)
    }

    /// SQ rows below a control, right edge aligned with the control's right edge and kept inside its window (top-bar menus).
    public static func popUp(items: [SQMenuItem], belowTrailing view: NSView) {
        guard !items.isEmpty, let window = view.window else { return }
        if let capture { capture(items); return }
        let width = SQMenuListView(items: items).contentSize.width
        let y = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        let low = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.maxX, y: y), to: nil))
        let right = min(low.x, window.frame.maxX - Theme.Spacing.sm)
        SQMenuController.shared.present(items: items, at: CGPoint(x: right - width, y: low.y - Theme.Spacing.xs), anchor: view)
    }

    /// Pop-up at a view-local point (the menu opens with its top-left there, like `NSMenu.popUp(positioning:at:in:)`).
    public static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        guard SQMenuSettings.useCustomMenus() else {
            menu.popUp(positioning: nil, at: point, in: view)
            return
        }
        menu.delegate?.menuNeedsUpdate?(menu)
        let items = SQMenuItem.items(from: menu)
        guard !items.isEmpty, let window = view.window else { return }
        let inWindow = view.convert(point, to: nil)
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: inWindow))
    }

    /// Opens a popup button's menu as an SQMenu below the control. Returns false (caller runs the native menu) when
    /// custom menus are off. A pull-down's item 0 is its title and is not listed; a pop-up selects the picked item first.
    public static func popUp(button: NSPopUpButton) -> Bool {
        guard SQMenuSettings.useCustomMenus(), let menu = button.menu, let window = button.window else { return false }
        menu.delegate?.menuNeedsUpdate?(menu)
        let skip = button.pullsDown ? 1 : 0
        var items: [SQMenuItem] = []
        let all = SQMenuItem.items(from: menu)
        // `items(from:)` drops hidden items, so map by walking the visible ones in step.
        let visible = menu.items.enumerated().filter { !$0.element.isHidden }
        for (n, entry) in all.enumerated() where n < visible.count {
            let (index, ns) = visible[n]
            if index < skip { continue }
            var item = entry
            if item.submenu == nil, !ns.isSeparatorItem, !ns.isSectionHeader {
                let orig = entry.action
                let pullsDown = button.pullsDown
                item.action = { [weak button] in
                    guard let button else { return }
                    let before = button.indexOfSelectedItem
                    orig?()
                    if !pullsDown, before != index, button.indexOfSelectedItem != index {
                        button.selectItem(at: index)
                        button.sendAction(button.action, to: button.target)
                    }
                }
                if !pullsDown { item.isChecked = button.indexOfSelectedItem == index }
            }
            items.append(item)
        }
        guard !items.isEmpty else { return true }
        let y = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        let inWindow = button.convert(NSPoint(x: button.bounds.minX, y: y), to: nil)
        let topY = button.isFlipped ? button.bounds.minY : button.bounds.maxY
        let top = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.minX, y: topY), to: nil)).y
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: inWindow), anchor: button, anchorTop: top)
        return true
    }

    /// Right-click, or Ctrl-click, on a view whose chain provides a menu: routes through the custom menu so plain
    /// `view.menu = ...` tables and outlines need no subclass. Call once at launch. Does nothing with `sq.customMenus` off.
    private static var routing: Any?
    public static func installGlobalRouting() {
        guard routing == nil else { return }
        routing = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var out: NSEvent? = e
            MainActor.assumeIsolated { if routeIfMenu(e) { out = nil } }
            return out
        }
    }

    private static func routeIfMenu(_ event: NSEvent) -> Bool {
        guard SQMenuSettings.useCustomMenus(), !SQMenuController.shared.isOpen else { return false }
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) { return false }
        guard let window = event.window, let content = window.contentView, !(window is NSPanel && window.styleMask.contains(.nonactivatingPanel)) else { return false }
        let p = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var v = content.hitTest(p)
        while let view = v {
            if view is NSPopUpButton || view is NSText || view is NSScroller { return false }
            if let menu = view.menu(for: event), !menu.items.isEmpty {
                show(menu, for: event, in: view)
                return true
            }
            v = view.superview
        }
        return false
    }
}
