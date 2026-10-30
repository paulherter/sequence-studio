import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditAPI
import SQEditorSession
import SQExport
import SQUIKit
import WinSDK

/// `--shell-test <folder>`: the shared shell's screens on the real window, as the Mac shared UI shows them. Without a
/// project it checks the start screen; then About, New Project and Export (until its picture arrives) each get a
/// screenshot and close (Escape, About with Enter); the wheel route posts real WM_MOUSEWHEEL messages over the timeline (a mouse
/// notch scrolls, Ctrl + notch zooms, a touchpad pinch zooms and ends by itself); the sequence plays 3 s. Every frame
/// gap is measured: the window must keep answering. Prints "shell test: … ok|FAIL" lines.
/// Every step has a name; the frames after it (screenshot frames left out) are timed, and a step whose run or frames
/// take over 100 ms on the main thread prints a "timing:" line and fails the stall check.
/// Preferences > Advanced switches the Edit API on, talks to it over 127.0.0.1 (state, wrong key, an agent marker as one
/// undo step and its undo) and switches it off again (the user's setting comes back). The clip menu also opens in a
/// 1024 x 640 pt window, where its 39 rows must scroll inside the window to the last row.
@MainActor final class WinShellTest {
    let app: AppController
    let window: AppWindow
    let folder: String
    var failures = 0
    /// The floating windows (set by the main loop), for the floating keyboard steps.
    var floating: WinFloatingHost?
    private struct Step { let wait: Double; let name: String; let run: @MainActor (WinShellTest) -> Void }
    private var steps: [Step] = []
    private var next = 0, at = 0.0
    private var lastTick: Double?
    private var worstGap = 0.0, worstAfter = 0
    /// Per step index: the run's milliseconds and the longest frame after it until the next step.
    private var runMs: [Int: Double] = [:], frameMs: [Int: Double] = [:]
    /// The frame that just ended took a screenshot (readback + PNG): its gap is not the app's.
    private var skipGap = false
    static let stallMs = 100.0
    private var zoom = 0.0, scrollY: CGFloat = 0, scrollX: CGFloat = 0
    private var played = (shown: 0, dropped: 0)
    /// A screenshot the main loop takes after the next frame.
    var shot: String?
    var done: Bool { next >= steps.count }

    func add(_ wait: Double, _ name: String, _ run: @escaping @MainActor (WinShellTest) -> Void) {
        steps.append(Step(wait: wait, name: name, run: run))
    }

    /// The main loop took a screenshot in the frame that just ended.
    func screenshotTaken() { skipGap = true }

    init(app: AppController, window: AppWindow, folder: String) {
        self.app = app; self.window = window; self.folder = folder
        AppController.printTiming = true
        if app.shell.isStartShown {
            add(0.8, "start screen", { $0.expect($0.app.shell.isStartShown, "start screen shown without a project") })
            add(0.1, "start shot", { $0.shot = $0.folder + "\\pc-shell-start.png" })
            add(0.4, "about opens", { $0.dialog(.about, "about") })
            add(0.8, "about shot", { $0.shot = $0.folder + "\\pc-shell-about.png" })
            add(0.3, "about closes", { $0.enter("about") })
            add(0.4, "report", { $0.report() })
            return
        }
        // --only-floating: just the floating keyboard steps (a short run on the shared PC).
        if CommandLine.arguments.contains("--only-floating") {
            add(0.5, "keys foreground", { t in
                t.window.forceForeground()
                t.app.shell.dock.setPage(.edit)
            })
            addFloatingKeys()
            add(0.3, "report", { $0.report() })
            return
        }
        add(0.6, "about opens", { $0.dialog(.about, "about") })
        add(0.8, "about card", { $0.expectAbout() })
        add(0.1, "about shot", { $0.shot = $0.folder + "\\pc-shell-about.png" })
        add(0.3, "about closes", { $0.enter("about") })
        add(0.4, "new project opens", { $0.dialog(.command(.newProject), "new project") })
        add(0.8, "new project shot", { $0.shot = $0.folder + "\\pc-shell-newproject.png" })
        add(0.3, "new project closes", { $0.escape("new project") })
        add(0.4, "export opens", { $0.dialog(.command(.export), "export") })
        add(0.25, "export picture wait", { $0.waitExportPicture() })
        add(0.1, "export picture", { $0.expectExportPicture() })
        add(0.1, "export shot", { $0.shot = $0.folder + "\\pc-shell-export.png" })
        add(0.3, "export closes", { $0.escape("export") })
        add(0.5, "wheel start", { $0.wheelStart() })
        add(0.1, "wheel notch", { $0.wheel(delta: -120, control: false) })
        add(0.3, "wheel notch check", { $0.expectWheel("mouse notch scrolls, keeps the zoom", zoomed: false) })
        add(0.1, "ctrl wheel", { $0.wheel(delta: 120, control: true) })
        add(0.3, "ctrl wheel check", { $0.expectWheel("Ctrl + notch zooms in", zoomed: true) })
        add(0.1, "pinch start", { $0.wheelStart() })
        for _ in 0..<5 { add(0.02, "pinch", { $0.wheel(delta: 24, control: true) }) }
        add(0.4, "pinch check", { $0.expectWheel("touchpad pinch zooms in and ends", zoomed: true) })
        add(0.1, "swipe start", { $0.wheelStart() })
        for _ in 0..<5 { add(0.02, "swipe", { $0.wheel(delta: -30, control: false, horizontal: true) }) }
        add(0.4, "swipe check", { $0.expectSwipe() })
        add(0.2, "play", { $0.play() })
        add(3.0, "pause", { $0.pause() })
        add(0.4, "played shot", { $0.shot = $0.folder + "\\pc-shell-played.png" })
        addKeys()
        addScreens()
        addSmallWindowMenu()
        addColorPro()
        add(0.3, "report", { $0.report() })
    }

    /// The Color page in Pro mode (the shared draw-list panel, tabs Primaries ... Effects): opened on the selected clip, the
    /// Pro grade made active, photographed per tab, then back to the Edit page.
    private func addColorPro() {
        add(0.3, "color page", { $0.app.shell.dock.setPage(.color) })
        add(0.6, "color pro", { t in
            let model = t.app.colorPage.controller.model
            t.expect(model != nil, "the Color page has a model for the selected clip")
            model?.setActiveGrade(.pro)
            model?.startEmptyGraph()
        })
        add(0.8, "color pro check", { t in
            t.expect(t.app.colorPage.controller.model?.shownGrade == .pro, "the Color page shows the Pro grade")
            t.shot = t.folder + "\\pc-shell-color-pro.png"
        })
        add(0.3, "edit page", { $0.app.shell.dock.setPage(.edit) })
    }

    // MARK: Screens (dialogs and menus: opened, layout-checked, photographed, closed)

    private func addScreens() {
        func show(_ name: String, _ open: @escaping @MainActor (WinShellTest) -> Void) {
            add(0.4, "\(name) opens", { open($0) })
            add(0.9, "\(name) check", { $0.checkDialog(name); $0.shot = $0.folder + "\\pc-shell-\(name).png" })
            add(0.3, "\(name) closes", { $0.closeDialog(name) })
        }
        show("marker") { t in
            guard let m = t.app.session.markAtPlayhead() else { return t.expect(false, "marker made") }
            t.expect(t.app.shell.editMarker(m.id), "marker dialog opens")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        add(0.4, "preferences opens", { $0.app.shell.perform(.command(.preferences)); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) })
        for p in ShellPreferences.Page.allCases {
            if p == .advanced, app.shell.editAPI == nil {
                add(0.1, "advanced missing", { $0.expect(false, "preferences Advanced page shown (the Edit API is wired)") })
                continue
            }
            add(0.6, "preferences \(p.title)", { t in
                if p != .general { t.app.shell.dialog?.form?.onChange?("page", .index(p.rawValue)) }
            })
            add(0.9, "preferences \(p.title) check", { t in
                t.checkDialog("preferences \(p.title)")
                t.shot = t.folder + "\\pc-shell-prefs-\(p.title.lowercased()).png"
            })
            if p == .advanced { addEditAPI() }
        }
        add(0.3, "preferences closes", { $0.closeDialog("preferences") })
        show("find") { t in t.app.shell.perform(.command(.find)); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Go to Timecode opens the monitor's timecode field (as the Mac), no dialog.
        add(0.4, "timecode opens", { t in
            t.app.shell.perform(.command(.goToTimecode)); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expect(t.app.shell.dialog == nil && t.app.monitors.monitor.panel.isEditingTimecode, "Go to Timecode edits the monitor's timecode field")
        })
        add(0.9, "timecode check", { $0.shot = $0.folder + "\\pc-shell-timecode.png" })
        add(0.3, "timecode closes", { t in
            t.app.handle(.keyDown(.escape, modifiers: []))
            t.expect(!t.app.monitors.monitor.panel.isEditingTimecode, "Go to Timecode closes with Escape")
        })
        // The Text card's Transcribe tab: the portable model works, the speech engine says unavailable.
        add(0.4, "transcribe tab opens", { t in
            t.app.shell.dock.show(.text); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.expect(t.app.captions.panel.tabs.contains(.transcript) && t.app.captions.panel.tab == .transcript, "Text card has the Transcribe tab (tabs: \(t.app.captions.panel.tabs.map(\.title).joined(separator: ", ")))")
        })
        add(0.9, "transcribe tab check", { t in t.shot = t.folder + "\\pc-shell-transcribe.png" })
        add(0.3, "transcribe tab back", { t in t.app.shell.dock.show(.effectControls) })
        addEditorDialogs()
        addMacDialogs()
        // The export queue popover over the status bar's ring, with one job per state (the queue itself is detached so
        // its refresh does not replace them).
        add(0.4, "export queue opens", { t in
            let s = t.app.shell
            t.savedQueue = s.exportQueue
            s.exportQueue = nil
            s.backgroundJobs = { [.init(id: "proxy-1", title: "Proxy: sample.mp4", progress: 0.6), .init(id: "proxy-2", title: "Proxy: broll.mov", progress: 0)] }
            s.showExportQueue(at: CGPoint(x: s.size.width - 60, y: s.size.height - 12))
            s.queuePopover?.update([
                .init(id: UUID(), name: "Oppo - Final.mp4", state: .running, progress: 0.42),
                .init(id: UUID(), name: "Oppo - Social.mp4", state: .waiting, progress: 0),
                .init(id: UUID(), name: "Oppo - Draft.mp4", state: .done(URL(fileURLWithPath: "C:\\Temp\\Draft.mp4")), progress: 1),
                .init(id: UUID(), name: "Oppo - Test.mp4", state: .failed("disk full"), progress: 0)])
            s.queuePopover?.layout(in: CGRect(origin: .zero, size: s.size))
            t.expect(s.queuePopover != nil, "export queue popover opens")
        })
        add(0.6, "export queue check", { t in
            if let f = t.app.shell.queuePopover?.frame { t.expect(CGRect(origin: .zero, size: t.app.shell.size).contains(f), "export queue popover sits inside the window (\(Int(f.width))x\(Int(f.height)) pt)") }
            t.shot = t.folder + "\\pc-shell-exportqueue.png"
        })
        add(0.3, "export queue closes", { t in
            t.app.handle(.keyDown(.escape, modifiers: []))
            t.app.shell.exportQueue = t.savedQueue
            t.app.shell.backgroundJobs = nil
            t.expect(t.app.shell.queuePopover == nil, "export queue popover closes with Escape")
        })
        show("notes") { t in t.app.shell.perform(.command(.projectNotes)); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        menu("clipmenu") { $0.openClipMenu() }
        menu("projectmenu") { t in
            let f = t.app.projectList.frame
            t.app.shell.menuBar.controller.present(items: t.app.projectList.menu(), at: CGPoint(x: f.midX, y: f.midY), pointer: CGPoint(x: f.midX, y: f.midY))
        }
        // Every menu of the bar, with its shortcut column checked for Mac glyphs (the Mac model, Ctrl instead of Cmd).
        add(0.1, "menu shortcut texts", { t in
            let glyphs = Set("\u{2318}\u{2325}\u{21E7}\u{2303}")
            func texts(_ items: [SQMenuItem]) -> [String] { items.flatMap { [$0.shortcut] + texts($0.submenu ?? []) }.filter { !$0.isEmpty } }
            var bad: [String] = [], total = 0
            for m in t.app.shell.menuBar.menus {
                let k = texts(m.items); total += k.count
                bad += k.filter { $0.contains { glyphs.contains($0) } }
                print("shell test: menu \(m.title): \(m.items.filter { $0.kind == .action || $0.submenu != nil }.count) rows, \(k.count) shortcuts, e.g. \(k.prefix(4).joined(separator: " ")) | \(k.filter { $0.hasPrefix("Ctrl") }.count) with Ctrl")
            }
            t.expect(bad.isEmpty && total > 40, "menu shortcuts use Ctrl/Alt/Shift words, no Mac glyphs (\(total) shortcuts\(bad.isEmpty ? "" : ", glyphs in " + bad.joined(separator: ",")))")
        })
        for title in ["Sequence Studio", "File", "Edit", "Clip", "Sequence", "Markers", "View", "Window", "Help"] {
            menu("menu-\(title == "Sequence Studio" ? "app" : title.lowercased())") { t in
                guard let i = t.app.shell.menuBar.menus.firstIndex(where: { $0.title == title }) else { return t.expect(false, "\(title) menu exists") }
                t.app.shell.menuBar.openMenu(i)
            }
        }
    }

    /// The shared timeline editor dialogs (`TimelineEditorDialogs`), each opened through the timeline's own request path.
    /// A dialog that needs a selection the demo project lacks (title clips, two angles, a styled clip) is noted, not failed.
    private func addEditorDialogs() {
        func editor(_ name: String, required: Bool = true, _ request: @escaping @MainActor (AppController) -> TimelineEditorRequest?) {
            add(0.4, "\(name) opens", { t in
                guard let r = request(t.app) else { return print("shell test: skipped \(name): nothing to open it on") }
                _ = t.app.openTimelineEditor(r)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if t.app.shell.dialog == nil, !required { print("shell test: skipped \(name): the demo selection does not allow it") }
                else { t.expect(t.app.shell.dialog != nil, "\(name) dialog opens") }
            })
            add(0.9, "\(name) check", { t in
                guard t.app.shell.dialog != nil else { return }
                t.checkDialog(name); t.shot = t.folder + "\\pc-shell-\(name).png"
            })
            add(0.3, "\(name) closes", { t in if t.app.shell.dialog != nil { t.closeDialog(name) } })
        }
        func track(_ app: AppController, _ name: String) -> Track.ID? { app.timeline.tracks.first { $0.name == name }?.id }
        editor("trackmix") { a in (track(a, "A1") ?? a.timeline.tracks.first?.id).map { .trackMix($0) } }
        editor("seqvolume") { _ in .sequenceVolume }
        editor("colormatte") { _ in .newColorMatte }
        editor("saveclippreset", required: false) { a in
            // A styled clip: the first V1 clip at half opacity (a preset needs Motion, Opacity or effect changes).
            guard var c = a.timeline.tracks.first(where: { $0.name == "V1" })?.clips.first else { return nil }
            c.animation.opacity = AnimatedProperty(0.5)
            a.session.replaceClip(c, name: "Opacity", continuesGesture: false)
            a.session.select(clips: [c.id])
            return .saveClipPreset
        }
        // The title clip (SQ_SAMPLE_TITLE=1: V2 over Shot A) with the playhead inside it, so the template gets a preview.
        func selectTitle(_ a: AppController) -> Bool {
            guard let c = a.timeline.tracks.first(where: { $0.name == "V2" })?.clips.first else { return false }
            a.session.select(clips: [c.id])
            a.session.seek(to: c.start + a.timeline.frameDuration * 3)
            return true
        }
        add(0.5, "select the title", { t in _ = selectTitle(t.app) })   // the Program frame follows the playhead
        editor("savetemplate", required: false) { a in selectTitle(a) ? .saveTemplate : nil }
        add(0.1, "template thumbnail", { t in
            guard let make = timelineEditors.dialogs?.templateThumbnail, t.app.session.playheadIsInsideSelectedVideo else { return }
            Task { @MainActor in
                let png = await make()
                t.expect(png.map { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) && $0.count > 1000 } == true, "the template preview is a PNG (\(png?.count ?? 0) bytes)")
                let still = png.flatMap { WinStillDecoder.decode($0) }
                t.expect(still != nil && PortablePNG.decode(png!) != nil, "the template preview decodes with alpha through PortablePNG (\(still?.width ?? 0)x\(still?.height ?? 0))")
            }
        })
        editor("savetitleblock", required: false) { a in selectTitle(a) ? .saveTitleBlock : nil }
        editor("angles", required: false) { a in
            a.session.select(clips: Set(a.timeline.tracks.flatMap(\.clips).map(\.id)))
            return .createAnglesClip
        }
    }

    /// The clip menu over the middle of the first V1 clip (selected first, as a right click does).
    private func openClipMenu() {
        let p = app.timelinePanel, f = p.frame, s = p.scale
        let v1 = app.timeline.tracks.first { $0.name == "V1" && !$0.clips.isEmpty }
            ?? app.timeline.tracks.first { $0.kind == .video && !$0.clips.isEmpty }   // a real project names it "Video 1"
        guard let c = v1?.clips.first, let y = p.pixelY(bodyOf: v1!.id) else { return expect(false, "V1 has a clip") }
        let fd = app.timeline.frameDuration
        let x = p.pixelX(for: c.start + fd * (c.duration.frameIndex(frameDuration: fd) / 2))
        app.session.select(clips: [c.id])
        app.showTimelineMenu(at: CGPoint(x: CGFloat(x - f.x) / CGFloat(s), y: CGFloat(y - f.y) / CGFloat(s)))
    }

    private func menu(_ name: String, _ open: @escaping @MainActor (WinShellTest) -> Void) {
        add(0.4, "\(name) opens", { t in t.app.shell.menuBar.controller.dismiss(); open(t) })
        add(0.6, "\(name) check", { t in t.checkMenu(name); t.shot = t.folder + "\\pc-shell-\(name).png" })
        add(0.3, "\(name) closes", { t in
            t.app.handle(.keyDown(.escape, modifiers: []))
            t.expect(!t.app.shell.menuBar.controller.isOpen, "\(name) closes with Escape")
        })
    }

    // MARK: Small window: the clip menu is taller than the window

    private var savedRect = RECT()
    private var savedQueue: ExportQueue?
    /// A media file moved aside for the Reconnect Media screen: (original, moved).
    var skipped = ""
    var moved: (from: String, to: String)?
    func restoreMoved() {
        guard let m = moved else { return }
        try? FileManager.default.moveItem(atPath: m.to, toPath: m.from)
        moved = nil
    }

    private func addSmallWindowMenu() {
        add(0.3, "window to 1024x640", { t in
            GetWindowRect(t.window.hwnd, &t.savedRect)
            if IsZoomed(t.window.hwnd) { ShowWindow(t.window.hwnd, SW_RESTORE) }
            let s = Float(GetDpiForWindow(t.window.hwnd)) / 96
            SetWindowPos(t.window.hwnd, nil, 40, 40, Int32(1024 * s), Int32(640 * s), UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        })
        add(1.0, "small clip menu opens", { t in t.app.shell.menuBar.controller.dismiss(); t.openClipMenu() })
        add(0.6, "small clip menu check", { t in
            t.checkMenu("clipmenu in a 1024x640 window")
            let c = t.app.shell.menuBar.controller
            guard let v = c.views.first else { return }
            t.expect(v.maxScroll > 0 || v.contentSize.height <= t.app.shell.size.height, String(format: "clip menu taller than the window scrolls (%.0f of %.0f pt shown, window %.0f pt)",
                                             v.visibleSize.height, v.contentSize.height, t.app.shell.size.height))
            t.shot = t.folder + "\\pc-shell-clipmenu-small.png"
        })
        add(0.3, "small clip menu scroll", { t in
            let c = t.app.shell.menuBar.controller
            guard let v = c.views.first else { return }
            let s = t.app.timelinePanel.scale
            let x = Float(v.frame.midX) * s, y = Float(v.frame.midY) * s
            // Wheel notches down until the end (one notch more than needed: the offset must stop at the bottom).
            for _ in 0..<Int(v.maxScroll / 40 + 2) {
                t.app.handle(.scroll(x: x, y: y, dx: 0, dy: -40 * s, modifiers: []))
            }
        })
        add(0.4, "small clip menu bottom", { t in
            let c = t.app.shell.menuBar.controller
            guard let v = c.views.first, let last = v.rowFrames.last else { return t.expect(false, "clip menu still open after scrolling") }
            let shown = last.maxY - v.scrollOffset <= v.visibleSize.height + 0.5
            t.expect(abs(v.scrollOffset - v.maxScroll) < 0.5 && shown,
                     String(format: "wheel scrolls the clip menu to its last row (offset %.0f of %.0f pt)", v.scrollOffset, v.maxScroll))
            t.shot = t.folder + "\\pc-shell-clipmenu-small-bottom.png"
        })
        add(0.3, "small clip menu closes", { t in
            t.app.handle(.keyDown(.escape, modifiers: []))
            t.expect(!t.app.shell.menuBar.controller.isOpen, "small clip menu closes with Escape")
            let r = t.savedRect
            SetWindowPos(t.window.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        })
    }

    // MARK: Edit API (Preferences > Advanced)

    private var apiWasOn = false
    private var apiWaits = 0
    private var apiDone = false

    /// Switch on in the form, wait for "Listening", run the requests (off the main actor, the app keeps drawing), switch off.
    private func addEditAPI() {
        add(0.2, "edit api on", { t in
            t.apiWasOn = WinEditAPI.isEnabled
            t.toggleAPI(true)
        })
        add(0.2, "edit api listening wait", { t in
            t.apiWaits += 1
            let text = t.app.shell.editAPI?.state().text ?? ""
            if !text.hasPrefix("Listening"), t.apiWaits < 25 { t.next -= 1; return }
            t.expect(text.hasPrefix("Listening"), "Advanced switch starts the Edit API (\(text))")
            t.shot = t.folder + "\\pc-shell-prefs-advanced-on.png"
            t.apiWaits = 0
            Task { @MainActor in await t.talkToAPI(); t.apiDone = true }
        })
        add(0.2, "edit api requests wait", { t in
            t.apiWaits += 1
            if !t.apiDone, t.apiWaits < 50 { t.next -= 1; return }
            t.expect(t.apiDone, "Edit API requests finished")
        })
        add(0.2, "edit api off", { t in
            t.toggleAPI(false)
            let text = t.app.shell.editAPI?.state().text ?? ""
            t.expect(text == "Not running" && !FileManager.default.fileExists(atPath: EditAPIDiscovery.defaultURL.path),
                     "Advanced switch stops the Edit API and removes the connection file (\(text))")
            WinEditAPI.isEnabled = t.apiWasOn
            t.app.editAPI?.sync()
        })
    }

    /// What a click on the check does: the form value, then its change handler.
    private func toggleAPI(_ on: Bool) {
        guard let f = app.shell.dialog?.form else { return expect(false, "Advanced form open") }
        f.set("api", .bool(on))
        f.onChange?("api", .bool(on))
    }

    private func talkToAPI() async {
        guard let data = try? Data(contentsOf: EditAPIDiscovery.defaultURL),
              let d = try? JSONDecoder().decode(EditAPIDiscovery.self, from: data) else {
            return expect(false, "Edit API connection file readable")
        }
        expect(d.pid == ProcessInfo.processInfo.processIdentifier, "connection file names this process (port \(d.port))")
        let base = "http://127.0.0.1:\(d.port)"
        let state = await Self.http("GET", base + "/v1/state", token: d.token)
        let seqs = ((try? JSONSerialization.jsonObject(with: state.1)) as? [String: Any])?["sequences"] as? [Any]
        expect(state.0 == 200 && seqs != nil, "GET /v1/state answers 200 (\(seqs?.count ?? 0) sequences)")
        let wrong = await Self.http("GET", base + "/v1/state", token: "wrong")
        expect(wrong.0 == 401, "a wrong key gets 401 (\(wrong.0))")
        let before = app.timeline.markers.count
        let at = app.timeline.frameDuration * 12
        let req = CommitRequest(sequence: app.timeline.id, name: "Shell Test Marker", operations: [.addMarker(at: at, name: "shell test")])
        let commit = await Self.http("POST", base + "/v1/commit", token: d.token, body: try? JSONEncoder().encode(req))
        let undoName = app.session.undoName ?? "none"
        expect(commit.0 == 200 && app.timeline.markers.count == before + 1 && undoName == "Agent: Shell Test Marker",
               "POST /v1/commit adds a marker as one undo step (\(commit.0), undo \"\(undoName)\")")
        let undo = await Self.http("POST", base + "/v1/undo", token: d.token, body: Data("{}".utf8))
        expect(undo.0 == 200 && app.timeline.markers.count == before, "POST /v1/undo takes the agent marker back (\(undo.0))")
    }

    /// One request, answered off the main actor (URLSession's own queue).
    nonisolated private static func http(_ method: String, _ url: String, token: String, body: Data? = nil) async -> (Int, Data) {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.timeoutInterval = 5
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let req = r
        return await withCheckedContinuation { (k: CheckedContinuation<(Int, Data), Never>) in
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                k.resume(returning: ((resp as? HTTPURLResponse)?.statusCode ?? -1, data ?? Data()))
            }.resume()
        }
    }

    /// Layout facts of the open dialog: card and buttons inside the window, buttons clear of each other and of the form,
    /// no two form rows on top of each other.
    func checkDialog(_ name: String) {
        guard let d = app.shell.dialog else { return expect(false, "\(name) is open") }
        let win = CGRect(origin: .zero, size: app.shell.size)
        var problems: [String] = []
        if !win.contains(d.card) { problems.append("card outside the window") }
        let bs = d.buttonFrames.values.sorted { $0.minX < $1.minX }
        for b in bs where !d.card.insetBy(dx: -0.5, dy: -0.5).contains(b) { problems.append("button outside the card") }
        for (a, b) in zip(bs, bs.dropFirst()) where a.intersects(b.insetBy(dx: 0.5, dy: 0.5)) { problems.append("buttons overlap") }
        if let f = d.form {
            for (a, b) in zip(f.rowFrames, f.rowFrames.dropFirst()) where a.intersection(b).height > 0.5 && abs(a.minY - b.minY) > 0.5 { problems.append("rows overlap") }
            for (r, c) in zip(f.rowFrames, f.controlFrames) where c.width > 0 && c.maxX > r.maxX + 0.5 { problems.append("control leaves its row") }
            for b in bs where b.intersects(d.formViewport.insetBy(dx: 0, dy: 1)) { problems.append("button over the form") }
        }
        expect(problems.isEmpty, "\(name) layout (\(Int(d.card.width))x\(Int(d.card.height)) pt, \(d.form?.rowFrames.count ?? 0) rows)"
               + (problems.isEmpty ? "" : ": " + Set(problems).sorted().joined(separator: ", ")))
    }

    /// Esc closes; with a text field open the first Esc only ends the edit (a decision of the shared form, as on the
    /// Mac), the second closes. Preferences has only Done: Enter then.
    func closeDialog(_ name: String) {
        app.handle(.keyDown(.escape, modifiers: []))
        if app.shell.dialog != nil {
            app.handle(.keyDown(.escape, modifiers: []))
            if app.shell.dialog == nil { expect(true, "\(name) closes with a second Escape (the first ended the text edit)"); return }
            app.handle(.keyDown(.enter, modifiers: []))
            expect(app.shell.dialog == nil, "\(name) closes with Enter (Escape did not)")
        } else { expect(true, "\(name) closes with Escape") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func checkMenu(_ name: String) {
        let c = app.shell.menuBar.controller
        guard c.isOpen else { return expect(false, "\(name) is open") }
        let bounds = c.bounds
        var problems: [String] = []
        for v in c.views {
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(v.frame) { problems.append("menu outside the window") }
            for (a, b) in zip(v.rowFrames, v.rowFrames.dropFirst()) where a.intersection(b).height > 0.5 { problems.append("rows overlap") }
            for r in v.rowFrames where r.maxX > v.width + 0.5 { problems.append("row wider than the menu") }
        }
        let titles = c.rootItems.map(\.title).filter { !$0.isEmpty }
        expect(problems.isEmpty && titles.count > 3, "\(name) layout (\(titles.count) rows: \(titles.prefix(4).joined(separator: ", "))...)"
               + (problems.isEmpty ? "" : ": " + Set(problems).sorted().joined(separator: ", ")))
    }

    /// Runs the steps that are due (call once per frame with the seconds since launch).
    func tick(_ t: Double) {
        if let l = lastTick, !done, next > 0, !skipGap {
            let gap = t - l
            if gap > worstGap { worstGap = gap; worstAfter = next - 1 }
            frameMs[next - 1] = max(frameMs[next - 1] ?? 0, gap * 1000)
        }
        skipGap = false
        lastTick = t
        guard !done, t >= at else { return }
        let i = next
        next += 1
        let t0 = Date()
        steps[i].run(self)
        runMs[i] = max(runMs[i] ?? 0, Date().timeIntervalSince(t0) * 1000)
        at = t + (next < steps.count ? steps[next].wait : 0)
    }

    func expect(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        print("shell test: \(what) \(ok ? "ok" : "FAIL")")
    }

    private func dialog(_ a: ShellAction, _ name: String) {
        let t0 = Date()
        app.shell.perform(a)
        let ms = Date().timeIntervalSince(t0) * 1000
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(app.shell.dialog != nil, String(format: "\(name) opens (%.0f ms)", ms))
    }

    private func escape(_ name: String) {
        app.handle(.keyDown(.escape, modifiers: []))
        expect(app.shell.dialog == nil, "\(name) closes with Escape")
    }

    /// About has only Done (default) and Acknowledgments, no Cancel: Escape does nothing there, as on the Mac.
    private func enter(_ name: String) {
        app.handle(.keyDown(.enter, modifiers: []))
        expect(app.shell.dialog == nil, "\(name) closes with Enter")
    }

    private func expectAbout() {
        let about = app.shell.dialog?.content as? ShellAboutContent
        let n = WinShell.supporters().count
        // SUPPORTERS.md beside the exe (or the repo's): it lists nobody yet, the Mac About shows 0 too.
        expect(about != nil, "about card (\(n) supporters listed\(n == 0 ? ", SUPPORTERS.md has no names yet" : ""))")
    }

    private var exportWaits = 0
    /// Repeats itself (up to 10 s) until the sheet's picture arrives.
    private func waitExportPicture() {
        exportWaits += 1
        if app.shell.exportPreviewImage == nil, exportWaits < 40 { next -= 1 }
    }

    private func expectExportPicture() {
        let sheet = app.shell.dialog?.content as? ShellExportSheet
        let img = app.shell.exportPreviewImage
        expect(sheet != nil && img != nil,
               "export sheet picture \(img.map { "\($0.1.width)x\($0.1.height)" } ?? "missing (\(sheet?.preview.note ?? "no sheet"))")")
    }

    // MARK: Wheel

    private var timelineCenter: (Int32, Int32) {
        let f = app.timelinePanel.frame
        return (Int32(f.x + f.w / 2), Int32(f.y + f.h * 0.6))
    }

    private func wheelStart() {
        zoom = app.timelinePanel.geometry.pointsPerSecond
        scrollX = app.timelinePanel.geometry.scrollX
        scrollY = app.timelinePanel.geometry.scrollY
    }

    private func wheel(delta: Int, control: Bool, horizontal: Bool = false) {
        let (x, y) = timelineCenter
        window.postWheel(delta: delta, horizontal: horizontal, control: control, x: x, y: y)
    }

    private func expectWheel(_ what: String, zoomed: Bool) {
        let z = app.timelinePanel.geometry.pointsPerSecond
        let ok = zoomed ? z > zoom * 1.01 : abs(z - zoom) < 1e-9
        expect(ok, String(format: "\(what) (%.1f -> %.1f pt/s)", zoom, z))
        zoom = z
    }

    private func expectSwipe() {
        let x = app.timelinePanel.geometry.scrollX
        expect(x != scrollX || app.timelinePanel.geometry.pointsPerSecond == zoom,
               String(format: "touchpad swipe scrolls sideways (x %.0f -> %.0f pt)", scrollX, x))
    }

    // MARK: Play

    private func play() {
        if app.engine.rate.isPaused { app.apply(.playPause) }
    }

    private func pause() {
        played = (app.engine.shownFrames, app.engine.skippedFrames)
        if !app.engine.rate.isPaused { app.apply(.playPause) }
        expect(played.shown > 30, "plays 3 s: \(played.shown) frames shown, \(played.dropped) dropped")
    }

    /// The steps whose run or following frames held the main thread over `stallMs` (screenshot frames left out). A
    /// step's frame gap includes its own run; the steps that wait 50 ms on purpose (dialog opening) stay under the limit.
    private func report() {
        var stalls: [String] = []
        for i in steps.indices {
            let run = runMs[i] ?? 0, frame = frameMs[i] ?? 0
            guard max(run, frame) > Self.stallMs else { continue }
            let line = String(format: "%@: run %.0f ms, longest frame %.0f ms", steps[i].name, run, frame)
            print("timing: " + line)
            stalls.append(steps[i].name)
        }
        expect(stalls.isEmpty, "no main-thread stall over \(Int(Self.stallMs)) ms"
               + (stalls.isEmpty ? "" : " (\(Set(stalls).sorted().joined(separator: ", ")))"))
        expect(worstGap < 1.0, String(format: "window answers (longest frame gap %.0f ms, after \"%@\")", worstGap * 1000,
                                      steps.indices.contains(worstAfter) ? steps[worstAfter].name : "start"))
        print("shell test: \(failures == 0 ? "passed" : "\(failures) failed")")
    }
}
