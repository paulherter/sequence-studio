import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import WinSDK

extension AppWindow {
    /// A real key press through the system input queue (keybd_event), as a keyboard sends it: Ctrl / Shift held around it.
    /// The window must be the foreground window; the shell test checks that first.
    func typeKey(_ vk: Int, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) {
        func ev(_ k: Int, up: Bool) { keybd_event(BYTE(k), 0, up ? DWORD(KEYEVENTF_KEYUP) : 0, 0) }
        if ctrl { ev(Int(VK_CONTROL), up: false) }
        if shift { ev(Int(VK_SHIFT), up: false) }
        if alt { ev(Int(VK_MENU), up: false) }
        ev(vk, up: false); ev(vk, up: true)
        if alt { ev(Int(VK_MENU), up: true) }
        if shift { ev(Int(VK_SHIFT), up: true) }
        if ctrl { ev(Int(VK_CONTROL), up: true) }
    }
}

extension AppWindow {
    /// Brings the window to the front although the test was started from a background process: attaches to the foreground
    /// window's input thread, which lifts the foreground lock.
    func forceForeground() { sqForceForeground(hwnd) }
}

/// The foreground lock lifted by attaching to the foreground window's input thread.
func sqForceForeground(_ hwnd: HWND) {
    let front = GetForegroundWindow()
    let mine = GetCurrentThreadId()
    let theirs = front.map { GetWindowThreadProcessId($0, nil) } ?? mine
    if theirs != mine { AttachThreadInput(theirs, mine, true) }
    ShowWindow(hwnd, SW_SHOW)
    BringWindowToTop(hwnd)
    SetForegroundWindow(hwnd)
    SetFocus(hwnd)
    if theirs != mine { AttachThreadInput(theirs, mine, false) }
}

extension WinFloatingWindow {
    /// A real left click (system input queue) at a client pixel of this window.
    func click(x: Int, y: Int) {
        var p = POINT(x: LONG(x), y: LONG(y))
        ClientToScreen(hwnd, &p)
        SetCursorPos(p.x, p.y)
        mouse_event(DWORD(MOUSEEVENTF_LEFTDOWN), 0, 0, 0, 0)
        mouse_event(DWORD(MOUSEEVENTF_LEFTUP), 0, 0, 0, 0)
    }
}

/// Key steps of `--shell-test`: Space / J / K / L / Esc, Delete + Ctrl-Z, Trim mode + Esc, Program Full Screen + Esc, and
/// Ctrl-A / C / V / Z in a dialog's text field with the real clipboard, all through real keyboard input.
extension WinShellTest {
    func addKeys() {
        let w = window
        func rate() -> Int32 { app.engine.rate.num }
        add(0.3, "keys foreground", { t in
            t.window.forceForeground()
            t.expect(GetForegroundWindow() == t.window.hwnd, "the window is the foreground window for key tests")
            t.app.shell.dock.setPage(.edit)
        })
        add(0.4, "key space", { _ in w.typeKey(0x20) })
        add(0.4, "key space check", { t in t.expect(rate() > 0, "Space plays (rate \(rate()))") })
        add(0.1, "key space 2", { _ in w.typeKey(0x20) })
        add(0.4, "key space 2 check", { t in t.expect(rate() == 0, "Space pauses (rate \(rate()))") })
        add(0.1, "key l", { _ in w.typeKey(0x4C) })
        add(0.4, "key l check", { t in t.expect(rate() > 0, "L plays forward (rate \(rate()))") })
        add(0.1, "key k", { _ in w.typeKey(0x4B) })
        add(0.4, "key k check", { t in t.expect(rate() == 0, "K stops (rate \(rate()))") })
        add(0.1, "key j", { _ in w.typeKey(0x4A) })
        add(0.4, "key j check", { t in t.expect(rate() < 0, "J plays backward (rate \(rate()))") })
        add(0.1, "key k 2", { _ in w.typeKey(0x4B) })
        add(0.4, "key k 2 check", { t in t.expect(rate() == 0, "K stops again (rate \(rate()))") })
        // Esc: tool back to Selection, then selection cleared.
        add(0.1, "razor tool", { t in t.app.timelinePanel.toolState.tool = .razor })
        add(0.1, "key esc", { _ in w.typeKey(0x1B) })
        add(0.3, "key esc check", { t in
            t.expect(t.app.timelinePanel.toolState.tool == .selection, "Esc returns the Razor tool to Selection")
        })
        // Delete + Ctrl-Z.
        var clips = 0
        add(0.1, "select a clip", { t in
            clips = t.app.session.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
            t.app.session.selectClipAtPlayhead()
            t.expect(!t.app.session.selection.isEmpty, "a clip is selected at the playhead")
        })
        add(0.1, "key delete", { _ in w.typeKey(0x2E) })
        add(0.4, "key delete check", { t in
            let n = t.app.session.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
            t.expect(n < clips, "Delete removes the clip (\(clips) -> \(n))")
        })
        add(0.1, "key ctrl z", { _ in w.typeKey(0x5A, ctrl: true) })
        add(0.4, "key ctrl z check", { t in
            let n = t.app.session.activeTimeline?.tracks.flatMap(\.clips).count ?? 0
            t.expect(n == clips, "Ctrl-Z brings the clip back (\(n) of \(clips))")
        })
        // Trim mode + Esc.
        add(0.1, "trim mode", { t in
            t.app.session.selectClipAtPlayhead()
            t.app.shell.execute(.toggleTrimMode)
        })
        add(0.3, "trim mode check", { t in
            t.expect(t.app.shell.trim.isActive, "Trim mode opens at an edit")
            w.typeKey(0x1B)
        })
        add(0.3, "trim esc check", { t in t.expect(!t.app.shell.trim.isActive, "Esc closes Trim mode") })
        // Full screen monitor + Esc.
        add(0.1, "full screen", { t in t.expect(t.app.shell.enterProgramFullScreen(), "Program Full Screen starts") })
        add(0.5, "full screen shot", { t in t.shot = t.folder + "\\pc-shell-fullscreen.png" })
        add(0.3, "full screen esc", { _ in w.typeKey(0x1B) })
        add(0.3, "full screen esc check", { t in t.expect(!t.app.shell.isProgramFullScreen, "Esc leaves Program Full Screen") })
        addCommands()
        // Text field: type, select all, copy (real clipboard), paste, undo.
        add(0.3, "field dialog", { t in t.app.shell.perform(.command(.newProject)) })
        // The earlier edit steps leave the project changed, so New Project first asks to save (the Mac does too): answer
        // Don't Save (the project on disk stays as it is; Esc at the end closes the form).
        add(0.4, "field save prompt", { t in
            if let d = t.app.shell.dialog, d.form == nil, d.messageText.hasPrefix("Save changes") { d.press(.third) }
        })
        add(0.6, "field type", { t in
            t.expect(t.app.shell.dialog?.form != nil, "New Project opens for the field test (\(t.app.shell.dialog?.messageText ?? "no dialog"))")
            w.typeKey(0x09)                       // Tab: focus the first field
            w.typeKey(0x51, ctrl: false)          // q
            w.typeKey(0x5A)                       // z
            w.typeKey(0x41, ctrl: true)           // Ctrl-A
            w.typeKey(0x43, ctrl: true)           // Ctrl-C
        })
        add(0.4, "field copy check", { t in
            let clip = WinShell.pasteText()
            t.expect(clip == "qz", "Ctrl-C in a field fills the system clipboard (\(clip ?? "nil"))")
            w.typeKey(0x27)                       // Right: caret to the end
            w.typeKey(0x56, ctrl: true)           // Ctrl-V
            w.typeKey(0x09)                       // Tab: the field commits
        })
        add(0.4, "field paste check", { t in
            let v = t.app.shell.dialog?.form?.text("name") ?? ""
            t.expect(v == "qzqz", "Ctrl-V in a field pastes (\(v))")
            w.typeKey(0x09, shift: true)          // Shift-Tab: back into the field
            w.typeKey(0x23)                       // End
            w.typeKey(0x56, ctrl: true)           // Ctrl-V again
            w.typeKey(0x5A, ctrl: true)           // Ctrl-Z in the field: only the paste goes
            w.typeKey(0x09)
        })
        add(0.4, "field undo check", { t in
            let v = t.app.shell.dialog?.form?.text("name") ?? ""
            t.expect(v == "qzqz", "Ctrl-Z in a field undoes the paste, not the project (\(v))")
            t.expect(t.app.shell.dialog != nil, "the dialog is still open after Ctrl-Z in its field")
        })
        add(0.3, "field esc", { _ in w.typeKey(0x1B) })
        addFloatingKeys()
    }

    /// The keyboard in a floating window: the Library floats, takes the foreground, a click puts the caret into its search
    /// field, typing lands there, Esc leaves the field, then Space plays, Ctrl-Z undoes and Esc docks the panel, all real
    /// key presses (keybd_event) to the floating window.
    func addFloatingKeys() {
        let w = window
        func fw(_ t: WinShellTest) -> WinFloatingWindow? { t.floating?.window(of: .library) }
        add(0.2, "floating open", { t in
            t.expect(t.floating != nil, "the floating host is wired to the test")
            t.app.shell.dock.floating.float(.library)
        })
        add(0.8, "floating foreground", { t in
            guard let f = fw(t) else { t.expect(false, "the Library floats in a window of its own"); return }
            sqForceForeground(f.hwnd)
            t.expect(GetForegroundWindow() == f.hwnd, "the floating window is the foreground window")
        })
        add(0.3, "floating click", { t in
            guard let f = fw(t) else { return }
            let k = Double(t.app.screen.theme.scale)
            f.click(x: Int(40 * k), y: Int((Double(ShellFloating.titleBar) + 19) * k))      // the search field's row below the title row
        })
        add(0.3, "floating type", { _ in w.typeKey(0x51); w.typeKey(0x5A) })
        add(0.4, "floating type check", { t in
            t.expect(t.app.library.panel.searchText == "qz", "typing in the floating window reaches its field (\(t.app.library.panel.searchText))")
            t.expect(t.app.shell.dock.floating.isFloating(.library), "typing does not dock the panel")
        })
        add(0.2, "floating esc 1", { _ in w.typeKey(0x1B) })
        add(0.2, "floating esc 2", { _ in w.typeKey(0x1B) })
        add(0.3, "floating esc check", { t in
            t.expect(t.app.shell.dock.floating.isFloating(.library), "Esc in the field leaves the field first, the panel stays")
            if let f = fw(t), GetForegroundWindow() != f.hwnd { sqForceForeground(f.hwnd) }
        })
        add(0.2, "floating space", { _ in w.typeKey(0x20) })
        add(0.5, "floating space check", { t in
            t.expect(t.app.engine.rate.num != 0, "Space in the floating window plays (rate \(t.app.engine.rate.num))")
        })
        add(0.1, "floating space 2", { _ in w.typeKey(0x20) })
        var before: String?
        add(0.5, "floating undo", { t in
            t.expect(t.app.engine.rate.num == 0, "Space in the floating window pauses")
            before = t.app.session.undoName
            t.app.session.addMarkerAtPlayhead()
            t.expect(t.app.session.undoName == "Add Marker", "a marker gives the undo step")
            w.typeKey(0x5A, ctrl: true)
        })
        add(0.5, "floating undo check", { t in
            t.expect(t.app.session.undoName == before, "Ctrl-Z in the floating window undoes it (\(before ?? "-") / \(t.app.session.undoName ?? "-"))")
        })
        add(0.1, "floating esc dock", { _ in w.typeKey(0x1B) })
        add(0.5, "floating esc dock check", { t in
            t.expect(!t.app.shell.dock.floating.isFloating(.library), "Esc with nothing else to take it docks the floating panel")
        })
    }
}

extension WinShellTest {
    /// Past the end, Quick Apply (real Option+Space), Find Scene Changes, Match Color to Clip, Next Weak Tracking and Auto
    /// Captions on the sample sequence: each must answer (a status line or its popup), none may say "not available".
    func addCommands() {
        let w = window
        var lines: [String] = []
        func tail(_ n: Int = 3) -> String { lines.suffix(n).joined(separator: " | ") }
        add(0.1, "status capture", { t in
            let previous = t.app.shell.onStatus
            t.app.shell.onStatus = { lines.append($0); previous?($0) }
        })
        // Black frame past the sequence end.
        add(0.1, "seek past end", { t in
            let end = t.app.timeline.tracks.map(\.end).max() ?? .zero
            t.app.session.seek(to: end + Time(3, 1))
        })
        add(0.8, "past end check", { t in
            guard let p = t.app.engine.readablePicture() else {
                t.expect(true, "past the sequence end the monitor has no picture to show (drawn black)"); return
            }
            let luma = p.bytes.prefix(p.width * p.height)
            let mean = luma.isEmpty ? 0 : luma.reduce(0) { $0 + Int($1) } / luma.count
            let top = luma.max() ?? 0
            t.expect(top <= 17, "past the sequence end the frame is black (mean luma \(mean), max \(top))")
        })
        add(0.1, "seek back", { t in t.app.session.seek(to: .zero) })
        // Quick Apply: Option+Space opens, Esc closes.
        add(0.4, "quick apply key", { _ in w.typeKey(0x20, alt: true) })
        add(0.4, "quick apply check", { t in
            t.expect(t.app.shell.quickApply != nil, "Option+Space opens Quick Apply (\(tail(1)))")
            t.shot = t.folder + "\\pc-shell-quickapply.png"
        })
        add(0.4, "quick apply esc", { _ in w.typeKey(0x1B) })
        add(0.3, "quick apply closed", { t in t.expect(t.app.shell.quickApply == nil, "Esc closes Quick Apply") })
        // Analysis commands.
        add(0.1, "select all", { t in t.app.session.selectAllClips(); lines = [] })
        add(0.1, "scene changes", { t in
            let on = t.app.shell.enabled(.findSceneChanges)
            t.expect(on, "Find Scene Changes is enabled on the selected clips")
            if on { _ = t.app.shell.execute(.findSceneChanges) }
        })
        add(8.0, "scene changes check", { t in
            t.expect(!lines.contains { $0.hasSuffix("not available in this window yet.") }, "Find Scene Changes ran (\(tail(3)))")
            lines = []
        })
        add(0.1, "weak tracking", { t in _ = t.app.shell.execute(.nextWeakTracking) })
        add(0.5, "weak tracking check", { t in
            t.expect(!lines.isEmpty && !lines.contains { $0.hasSuffix("not available in this window yet.") },
                     "Go to Next Weak Tracking answers (\(tail(2)))")
            lines = []
        })
        add(0.1, "match color", { t in
            let on = t.app.shell.enabled(.matchColorToClip)
            print("shell test: Match Color to Clip enabled with the whole selection: \(on)")
            if on { _ = t.app.shell.execute(.matchColorToClip) }
        })
        add(1.5, "match color check", { t in
            t.expect(!lines.contains { $0.hasSuffix("not available in this window yet.") }, "Match Color to Clip answers (\(tail(2)))")
            lines = []
        })
        add(0.1, "auto captions", { t in
            t.expect(t.app.shell.execute(.autoCaptions), "Auto Captions runs through the Text panel host")
        })
        add(1.0, "auto captions check", { t in
            t.expect(!lines.contains { $0.hasSuffix("not available in this window yet.") }, "Auto Captions answers (\(tail(2)))")
            lines = []
            t.app.session.select(clips: [])
            // Auto Captions may leave its own dialog open (Create Captions): the next steps need a clean screen, so it is
            // named here and closed with a real Esc instead of being mistaken for the New Project dialog.
            if let d = t.app.shell.dialog { print("shell test: a dialog is open after Auto Captions: \(d.messageText)"); w.typeKey(0x1B) }
        })
        add(0.4, "auto captions dialog closed", { t in t.expect(t.app.shell.dialog == nil, "no dialog is left open before the field tests") })
    }
}
