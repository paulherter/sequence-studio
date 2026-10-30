import AppKit
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQUIKit

/// `SQ_SHARED_UI_FLOAT_PROBE=1`: a live self-test of the floating windows. Frame by frame it floats the Program monitor,
/// presses a key into the floating window, zooms and restores it, docks it back and floats the Library, writing one
/// `FLOATPROBE` line per fact to the log (~/Library/Logs/Sequence Studio), then quits. The floating state is neither
/// loaded nor saved, so the user's `floating-panels.json` is untouched.
@MainActor private var probeFrame = 0
@MainActor private var probeStart = 0

extension SharedUIController {
    static let floatProbeEnabled = ProcessInfo.processInfo.environment["SQ_SHARED_UI_FLOAT_PROBE"] == "1"

    func floatingProbe() {
        // Wait for the project's picture (the viewer is placed) before the first step.
        if probeStart == 0 {
            if [viewerClip, sourceClip].contains(where: { !$0.isHidden }) || probeFrame > 400 { probeStart = probeFrame } else { probeFrame += 1; return }
        }
        probeFrame += 1
        let f = shell.dock.floating
        // The shared log is rewritten by other runs (tests): the probe also appends to its own file.
        func log(_ s: String) {
            SQLog.info("FLOATPROBE \(s)")
            guard let path = ProcessInfo.processInfo.environment["SQ_SHARED_UI_FLOAT_PROBE_FILE"], let data = ("FLOATPROBE \(s)\n").data(using: .utf8) else { return }
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { FileManager.default.createFile(atPath: path, contents: data) }
        }
        func frameText(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        func report(_ tag: String, _ p: PanelID) {
            let w = floatingWindows[p]
            let clip = [viewerClip, sourceClip].first { !$0.isHidden }
            let host = clip.map { c -> String in
                if c.superview === w?.root { return "floating-root" }
                if c.superview === window?.contentView { return "main-root" }
                return "other"
            } ?? "none"
            let videoQuads = (canvasFrame?.quads ?? []).filter { DrawQuad.Kind(rawValue: $0.kind) == .video }.map { frameText(CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.w), height: CGFloat($0.h))) + " clipX1=\(Int($0.clipX1))" }
            let pr = canvasFrame.flatMap { SharedUIView.pictureRect($0, scale: CGFloat(screen.theme.scale)) }
            log("\(tag): pictureRect=\(pr.map { "quad \(frameText($0.quad)) clip \(frameText($0.clip))" } ?? "nil") host=\(pr.flatMap { floatingWindow(containing: $0.clip) } != nil) clips hidden=\(viewerClip.isHidden),\(sourceClip.isHidden) viewerFrame=\(frameText(viewerClip.frame))")
            log("\(tag): canvas=\(canvasFrame != nil) videoQuads=\(videoQuads) showsSource=\(monitors.source.isShown) windows=\(f.windows.count) os=\(w.map { frameText($0.frame) } ?? "-") shell=\(f.window(of: p).map { frameText($0.frame) } ?? "-") "
                + "active=\(NSApp.isActive) key=\(w?.isKeyWindow == true) keyWindow=\(NSApp.keyWindow.map { $0 === window ? "main" : $0 === w ? "floating" : "other" } ?? "none") zoomed=\(f.isZoomed(p)) viewer=\(host) clip=\(clip.map { frameText($0.frame) } ?? "-") "
                + "card=\(shell.dock.monitorCard.map(frameText) ?? "-") focus=\(String(describing: shell.dock.focused))")
        }
        switch probeFrame - probeStart {
        case 1:
            f.save = nil
            log("float \(f.float(.programMonitor))")
        case 21: report("floated", .programMonitor)
        case 26:
            // The app comes to the front and the floating window is the key window; Space goes through the app's event path.
            NSApp.activate(ignoringOtherApps: true)
            floatingWindows[.programMonitor]?.bringToFront()
        case 31:
            guard let w = floatingWindows[.programMonitor] else { log("no window"); return }
            let before = engine.rate.isPaused
            pressKey(49, " ", in: w)
            log("space into floating: paused \(before) -> \(engine.rate.isPaused) (active=\(NSApp.isActive), key window is floating: \(NSApp.keyWindow === w))")
            if !engine.rate.isPaused { pressKey(49, " ", in: w) }
        case 41: f.toggleZoom(.programMonitor)
        case 61: report("zoomed", .programMonitor)
        case 71: f.toggleZoom(.programMonitor)
        case 91: report("restored", .programMonitor)
        case 101: f.dockBack(.programMonitor)
        case 121:
            report("docked", .programMonitor)
            log("float library \(f.float(.library))")
        case 141: report("library", .library)
        case 146:
            guard let w = floatingWindows[.library] else { log("no library window"); return }
            NSApp.activate(ignoringOtherApps: true)
            w.bringToFront()
            // A click into the search field (x 40 / y 47 in the window: title row 28 + the field row), then typing.
            click(at: CGPoint(x: 40, y: 47), in: w)
        case 151:
            guard let w = floatingWindows[.library] else { return }
            pressKey(0, "a", in: w); pressKey(11, "b", in: w)
            log("typed into floating field: \"\(library.panel.searchText)\" (key window is floating: \(NSApp.keyWindow === w))")
        case 156, 161:
            // Esc leaves the field first (clears the text, then ends the edit): the panel stays floating.
            guard let w = floatingWindows[.library] else { return }
            pressKey(53, "\u{1b}", in: w)
            log("esc \((probeFrame - probeStart - 151) / 5): floating=\(f.isFloating(.library)) field=\"\(library.panel.searchText)\"")
        case 166:
            guard let w = floatingWindows[.library] else { return }
            let before = session.undoName
            session.addMarkerAtPlayhead()
            let edited = session.undoName
            pressKey(6, "z", in: w, flags: .command)
            log("cmd-z into floating : undo name \(before ?? "-") -> \(edited ?? "-") -> \(session.undoName ?? "-")")
        case 171:
            guard let w = floatingWindows[.library] else { return }
            pressKey(53, "\u{1b}", in: w)
            log("esc with nothing else to take it: floating=\(f.isFloating(.library))")
        case 181: exit(0)       // not terminate: the marker made the project dirty and the save prompt would stay
        default: break
        }
    }
}

extension SharedUIController {
    /// A key press (down and up) through the app's own event path, addressed to the window like a keystroke of the user.
    fileprivate func pressKey(_ code: UInt16, _ chars: String, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code) {
                // A shortcut (Cmd) first goes through the window's key-equivalent pass, as `NSApplication.sendEvent` does for an
                // active app; an inactive one (screen locked) keeps the event from there, so the probe calls the pass itself.
                if type == .keyDown, flags.contains(.command), w.performKeyEquivalent(with: ev) { continue }
                NSApp.sendEvent(ev)
            }
        }
    }

    /// A left click at a point of the window's view (y down from the top).
    fileprivate func click(at p: CGPoint, in w: NSWindow) {
        let loc = CGPoint(x: p.x, y: w.contentLayoutRect.height - p.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(ev) }
        }
    }
}
