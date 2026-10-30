import AppKit
import SQCore
import SQEditorUI
import SQPremiereImport
import SwiftUI

/// Render harness: `SQ_RENDER_PANELS=<dir>` renders every panel and dialog of the real app offscreen to PNG (1x and 2x),
/// writes `index.txt` and a contact sheet, and quits. Driven by `scripts/render-panels.sh`.
///
/// No window is ever shown (activation policy is `.prohibited`, the main window is not ordered front) and no screen capture
/// API is used: each view draws itself into a bitmap through `cacheDisplay`. Panels are captured in place, inside the real
/// main window laid out at 1440x900 pt, so they have the size and neighbors they have in the app. Metal layers (the
/// Program and Source monitor picture) do not appear in `cacheDisplay`: the monitors render their chrome and an empty frame.
/// `SQ_RENDER_ONLY=<name>` renders one entry; `SQ_NO_RECOVERY=1` is set by the script. The demo project is
/// `RenderDemoProject`. Not part of the shipped UI.
@MainActor
enum RenderPanels {
    static let isRequested = ProcessInfo.processInfo.environment["SQ_RENDER_PANELS"] != nil

    static func runIfRequested(_ c: AppController) {
        guard let dir = ProcessInfo.processInfo.environment["SQ_RENDER_PANELS"] else { return }
        let only = ProcessInfo.processInfo.environment["SQ_RENDER_ONLY"]
        Task { @MainActor in
            let r = Renderer(dir: URL(fileURLWithPath: dir, isDirectory: true), only: only)
            do { try await r.run(c) } catch { NSLog("SQRENDER failed: \(error)"); exit(1) }
            exit(0)
        }
    }

    private struct Entry { var name: String; var pixels: String; var source: String }

    @MainActor
    private final class Renderer {
        let dir: URL
        let only: String?
        var entries: [Entry] = []
        var skipped: [(String, String)] = []
        var hosts: [NSWindow] = []     // standalone hosts stay alive until the run ends
        var selectedID: Clip.ID?
        static let background = Theme.Colors.panel

        init(dir: URL, only: String?) { self.dir = dir; self.only = only }

        func wants(_ name: String) -> Bool {
            guard let only else { return true }
            return only.split(separator: ",").contains { name == $0 || name.hasPrefix("\($0)-") }
        }

        func skip(_ name: String, _ reason: String) {
            if wants(name) { skipped.append((name, reason)) }
        }

        // MARK: Capture

        func capture(_ view: NSView, name: String, note: String = "") {
            guard wants(name) else { return }
            view.layoutSubtreeIfNeeded()
            let b = view.bounds
            guard b.width >= 1, b.height >= 1 else { skipped.append((name, "view has zero size")); return }
            var px1 = ""
            for scale in [1, 2] {
                let w = Int((b.width * CGFloat(scale)).rounded(.up)), h = Int((b.height * CGFloat(scale)).rounded(.up))
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                    skipped.append((name, "no bitmap")); return
                }
                rep.size = b.size
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    Self.background.setFill()
                    NSRect(x: 0, y: 0, width: w, height: h).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.cacheDisplay(in: b, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { skipped.append((name, "png encode failed")); return }
                try? png.write(to: dir.appendingPathComponent("\(name)@\(scale)x.png"))
                if scale == 1 { px1 = "\(w)x\(h)" }
            }
            entries.append(Entry(name: name, pixels: px1, source: String(describing: type(of: view)) + (note.isEmpty ? "" : " (\(note))")))
        }

        /// A view that has no window yet: gets an unshown window of the given size so layout and appearance are real.
        @discardableResult
        func host(_ view: NSView, size: CGSize? = nil) -> NSView {
            let s = size ?? (view.frame.size == .zero ? view.fittingSize : view.frame.size)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.borderless], backing: .buffered, defer: true)
            w.appearance = Theme.windowAppearance
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.Colors.panel
            w.contentView = view
            view.frame = NSRect(origin: .zero, size: s)
            hosts.append(w)
            return view
        }

        func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }

        // MARK: Run

        func run(_ c: AppController) async throws {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Only the render's own files: old renders of other names stay for `--only`.
            if only == nil {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".png") || f == "index.txt" {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
            // Never touch the user's saved layout or window frame.
            c.window.setFrameAutosaveName("")
            c.store = WorkspaceStore()
            let built = try RenderDemoProject.make()
            RenderDemoProject.load(built, into: c.session)
            c.window.setContentSize(NSSize(width: 1440, height: 900))
            c.applyWorkspace()
            await settle(1.5)
            openProjectBins(c)
            c.window.setContentSize(NSSize(width: 1440, height: 900))

            selectedID = built.selected
            try await renderWindows(c)
            try await renderOnlineStates(c, offline: built)
            renderSubviews(c)
            await renderMenus(c)
            await renderDialogs(c)
            renderOverlays(c)
            await renderWindowsExtra(c)
            try await renderPanels(c)     // last: standalone panels take the views out of the main window
            try writeIndex()
            if only == nil { ContactSheet.write(entries: entries.map(\.name), dir: dir) }   // a partial run keeps the full sheet
        }

        /// Board Project panel: Footage and Audio open, C2156.MP4 selected.
        func openProjectBins(_ c: AppController) {
            let media = c.session.project.media
            for name in ["Music – Late Sun.mp3", "C2156.MP4"] {
                if let m = media.first(where: { $0.name == name }) { c.panels.projectView.reveal(media: m.id) }
            }
        }

        func layoutWindow(_ c: AppController) {
            c.window.contentView?.layoutSubtreeIfNeeded()
            c.window.contentView?.displayIfNeeded()
        }

        /// `--only check-page-switch`: a plain click on "Color" in the Edit | Color switch, through the window's own hit
        /// test and event dispatch (no direct `press`). Writes `check-page-switch.txt`: what the hit test returned and
        /// the page after the click, then the same back to "Edit".
        func checkPageSwitch(_ c: AppController) async {
            guard only != nil, wants("check-page-switch") else { return }
            let seg = c.toolbar.bar.pageSwitch
            var lines: [String] = []
            for (index, name) in [(1, "Color"), (0, "Edit")] {
                layoutWindow(c)
                let local = NSPoint(x: seg.bounds.width * (index == 1 ? 0.75 : 0.25), y: seg.bounds.midY)
                let inWindow = seg.convert(local, to: nil)
                let frameView = c.window.contentView?.superview
                let hit = frameView?.hitTest(frameView?.superview?.convert(inWindow, from: nil) ?? inWindow)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                        NSApp.sendEvent(e)
                    }
                }
                await settle()
                var note = ""
                if c.store.page != (index == 1 ? .color : .edit) {       // diagnosis: does the view itself take the click?
                    if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        hit?.mouseDown(with: e)
                    }
                    await settle()
                    // The render window is never ordered in, and AppKit drops events sent to a window that is not visible.
                    note = " (NSApp.sendEvent did not reach the view, window visible: \(c.window.isVisible); mouseDown went to the hit view directly)"
                }
                let ok = hit === seg && seg.segment(at: local) == index && c.store.page == (index == 1 ? .color : .edit)
                lines.append("\(ok ? "OK" : "FAILED") click on \(name) at \(inWindow): hitTest = \(hit.map { String(describing: type(of: $0)) } ?? "nil"), "
                             + "segment = \(seg.segment(at: local).map(String.init) ?? "nil"), page after = \(c.store.page)\(note)")
            }
            NSLog("SQRENDER check-page-switch: %@", lines.joined(separator: " | "))
            try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("check-page-switch.txt"), atomically: true, encoding: .utf8)
        }

        func renderWindows(_ c: AppController) async throws {
            c.store.setPage(.edit)
            c.applyWorkspace()
            c.window.setContentSize(NSSize(width: 1440, height: 900))
            await settle()
            layoutWindow(c)
            if let v = c.window.contentView { capture(v, name: "window-edit", note: "1440x900 pt") }
            await checkPageSwitch(c)
            c.store.setPage(.color)
            c.applyWorkspace()
            c.window.setContentSize(NSSize(width: 1440, height: 900))
            await settle()
            layoutWindow(c)
            if let v = c.window.contentView { capture(v, name: "window-color", note: "1440x900 pt") }
            c.store.setPage(.edit)
            c.applyWorkspace()
            await settle()
        }

        /// Windows with the demo footage ONLINE (tiny real files, thumbnails and waveforms): real clip colors instead of the
        /// red offline clips. Swaps the demo project and puts the offline one back afterwards.
        func renderOnlineStates(_ c: AppController, offline built: RenderDemoProject.Built) async throws {
            let names = ["window-edit-online", "window-color-online", "window-color-clips-online", "timeline-online",
                         "window-color-pro-online", "window-color-pro-empty-online", "window-color-pro-off-online", "window-color-pro-groups-online",
                         "window-color-timeline-online", "window-color-wide-online", "window-color-pro-wide-online", "window-color-expanded-online"] + Self.contextNames
            guard names.contains(where: wants) else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderDemoMedia", isDirectory: true)
            try await RenderDemoProject.writeMedia(into: dir)
            let online = try RenderDemoProject.make(mediaDir: dir)
            RenderDemoProject.load(online, into: c.session)
            selectedID = online.selected
            c.store.setPage(.edit)
            c.applyWorkspace()
            c.window.setContentSize(NSSize(width: 1440, height: 900))
            await settle(6)      // thumbnails and waveforms load in the background
            openProjectBins(c)
            layoutWindow(c)
            if let v = c.window.contentView { capture(v, name: "window-edit-online", note: "1440x900 pt, demo footage online") }
            capture(c.panels.timelineView, name: "timeline-online", note: "timeline view, footage online")
            await renderContext(c)
            c.store.setPage(.color)
            c.applyWorkspace()
            c.window.setContentSize(NSSize(width: 1440, height: 900))
            await settle(3)
            layoutWindow(c)
            if let v = c.window.contentView { capture(v, name: "window-color-online", note: "1440x900 pt, demo footage online") }
            if wants("window-color-wide-online") {      // a wide window: the Color rows stop at their cap
                c.window.setContentSize(NSSize(width: 2560, height: 1440))
                await settle(2)
                layoutWindow(c)
                if let v = c.window.contentView { capture(v, name: "window-color-wide-online", note: "2560x1440 pt, Simple grade") }
                c.window.setContentSize(NSSize(width: 1440, height: 900))
                await settle(2)
                layoutWindow(c)
            }
            if wants("window-color-expanded-online"), let m = c.panels.colorView.controller.model {      // every Simple section and Input color open
                for e in m.effects { for k in ColorSectionKind.allCases { m.setCollapsed(ColorPanelKey(e.id, k), false) } }
                NotificationCenter.default.post(name: Notification.Name("sq.color.setInputOpen"), object: true)
                c.window.setContentSize(NSSize(width: 1440, height: 2600))
                await settle(3)
                layoutWindow(c)
                if let v = c.window.contentView { capture(v, name: "window-color-expanded-online", note: "1440x2600 pt, all Simple sections open") }
                c.window.setContentSize(NSSize(width: 1440, height: 900))
                await settle(2)
                layoutWindow(c)
            }
            if wants("window-color-pro-empty-online") {      // version 9: Pro on a clip without a Color Graph
                if let m = c.panels.colorView.controller.model, m.graph == nil {
                    m.setActiveGrade(.pro)
                    await settle(3)
                    c.applyWorkspace()
                    layoutWindow(c)
                    await settle(3)
                    layoutWindow(c)
                    if let v = c.window.contentView { capture(v, name: "window-color-pro-empty-online", note: "1440x900 pt, empty Pro page") }
                    m.setActiveGrade(.simple)
                    await settle(2)
                }
            }
            if wants("window-color-pro-online") || wants("window-color-pro-wide-online") || wants("window-color-pro-off-online") || wants("window-color-pro-groups-online") {      // version 9: the Pro grade (Steps graph, Scopes beside the monitor)
                if let m = c.panels.colorView.controller.model {
                    m.startEmptyGraph()
                    m.addStep(after: m.selectedStep)
                    m.addStep(after: m.selectedStep)
                    await settle(3)
                    c.applyWorkspace()
                    layoutWindow(c)
                    await settle(3)
                    layoutWindow(c)
                    if let v = c.window.contentView { capture(v, name: "window-color-pro-online", note: "1440x900 pt, Pro grade") }
                    if wants("window-color-pro-wide-online") {
                        c.window.setContentSize(NSSize(width: 2560, height: 1440))
                        await settle(2)
                        layoutWindow(c)
                        if let v = c.window.contentView { capture(v, name: "window-color-pro-wide-online", note: "2560x1440 pt, Pro grade") }
                        c.window.setContentSize(NSSize(width: 1440, height: 900))
                        await settle(2)
                        layoutWindow(c)
                    }
                    for (i, name) in ["curves", "qualifier", "window", "lut", "effects"].enumerated() where wants("window-color-pro-online-\(name)") {
                        NotificationCenter.default.post(name: Notification.Name("sq.color.selectProTab"), object: i + 1)
                        await settle(1)
                        layoutWindow(c)
                        if let v = c.window.contentView { capture(v, name: "window-color-pro-online-\(name)", note: "1440x900 pt, Pro grade, \(name) tab") }
                    }
                    NotificationCenter.default.post(name: Notification.Name("sq.color.selectProTab"), object: 0)
                    if wants("window-color-pro-online-input") {
                        NotificationCenter.default.post(name: Notification.Name("sq.color.setInputOpen"), object: true)
                        await settle(1)
                        layoutWindow(c)
                        if let v = c.window.contentView { capture(v, name: "window-color-pro-online-input", note: "1440x900 pt, Pro grade, Input color open") }
                        NotificationCenter.default.post(name: Notification.Name("sq.color.setInputOpen"), object: false)
                    }
                    if wants("window-color-pro-off-online"), let id = m.selectedStep {
                        m.setStepEnabled(id, false)
                        await settle(2)
                        layoutWindow(c)
                        if let v = c.window.contentView { capture(v, name: "window-color-pro-off-online", note: "1440x900 pt, Pro grade, Step off") }
                        m.setStepEnabled(id, true)
                    }
                    if wants("window-color-pro-groups-online"), let first = m.graph?.steps.first?.id {      // serial chain + one Parallel + one Layer group
                        m.addStep(after: first, kind: .parallel)
                        m.addStep(after: m.selectedStep, kind: .serial)
                        m.addStep(after: m.selectedStep, kind: .serial)
                        m.addStep(after: m.selectedStep, kind: .layer)
                        m.tidyUpSteps()
                        await settle(3)
                        layoutWindow(c)
                        await settle(2)
                        layoutWindow(c)
                        if let v = c.window.contentView { capture(v, name: "window-color-pro-groups-online", note: "1440x900 pt, Pro grade, serial chain with a Parallel and a Layer group") }
                    }
                    m.setActiveGrade(.simple)
                    await settle(2)
                }
            }
            if wants("window-color-timeline-online") {      // the lower panel on Timeline
                c.mutateWorkspace { $0.show(.timeline) }
                await settle(2)
                layoutWindow(c)
                if let v = c.window.contentView { capture(v, name: "window-color-timeline-online", note: "1440x900 pt, lower panel on Timeline") }
            }
            if wants("window-color-clips-online") {      // design board "ColorClips": the lower group on Sources
                c.mutateWorkspace { $0.show(.colorClips) }
                await settle(3)
                layoutWindow(c)
                if let v = c.window.contentView { capture(v, name: "window-color-clips-online", note: "1440x900 pt, Clips strip") }
                c.mutateWorkspace { $0.show(.timeline) }
            }
            c.store.setPage(.edit)
            c.applyWorkspace()
            RenderDemoProject.load(built, into: c.session)
            selectedID = built.selected
            await settle(1)
        }

        /// Shows `p` in the first workspace that has it (tab selected, nothing hidden) and returns its container.
        func showInPlace(_ p: PanelID, _ c: AppController) async -> (NSView, String)? {
            let colorPage = c.store.colorPage     // the page for the demo sequence's shape (9:16: portrait)
            let layouts: [Workspace] = [.colorInspector, .colorClips, .steps, .scopes].contains(p) ? [colorPage, .editingPC] : [.editingPC, colorPage]
            for base in layouts where base.root.panels.contains(p) {
                var w = base
                w.hidden = []; w.maximized = nil
                w.selectTab(p)
                c.window.setContentSize(NSSize(width: 1440, height: 900))
                c.shell.host.apply(w)
                await settle(0.3)
                layoutWindow(c)
                if let container = Self.container(showing: p, in: c.shell.host) { return (container, base.name) }
            }
            return nil
        }

        /// Size and tab group of every panel on the Panels board in its main state (docs/design-source/gen_panels.py).
        /// `nil` size: the board has no fixed size for it, the panel is captured in place.
        static func boardSpec(_ p: PanelID) -> (group: [PanelID], size: CGSize?) {
            let controls: [PanelID] = [.effectControls, .text, .graphics]
            switch p {
            case .effectControls: return (controls, CGSize(width: 360, height: 900))
            case .text: return (controls, CGSize(width: 332, height: 580))           // Captions · List
            case .graphics: return (controls, CGSize(width: 332, height: 930))       // Graphics · text layer selected
            case .keystones: return ([.project, .keystones], CGSize(width: 260, height: 300))
            case .markerList: return ([.markerList], CGSize(width: 420, height: 300))
            case .library: return ([.library, .effects], CGSize(width: 480, height: 580))     // grid
            case .effects: return ([.library, .effects], CGSize(width: 300, height: 580))
            case .project: return ([.project, .keystones], CGSize(width: 400, height: 580))   // list
            case .colorInspector: return ([.colorInspector], CGSize(width: 420, height: 1160))
            case .colorClips: return ([.steps, .timeline, .colorClips], nil)
            case .steps: return ([.steps, .timeline, .colorClips], nil)
            case .scopes: return ([.scopes], CGSize(width: 320, height: 270))
            case .programMonitor, .sourceMonitor: return ([.programMonitor, .sourceMonitor], CGSize(width: 380, height: 620))
            case .audioMeter: return ([.audioMeter], CGSize(width: 48, height: 300))
            case .timeline: return ([.timeline], CGSize(width: 1316, height: 330))
            }
        }

        /// Every PanelID alone at its Panels-board size (own container with its tab strip). Runs last: it takes the panel
        /// views out of the main window.
        func renderPanels(_ c: AppController) async throws {
            for p in PanelID.allCases {
                let name = "panel-\(p.rawValue)"
                guard wants(name) else { continue }
                let spec = Self.boardSpec(p)
                guard let size = spec.size else {
                    if let (container, layout) = await showInPlace(p, c) { capture(container, name: name, note: "in \(layout), selected tab, no board size") }
                    else { skip(name, "no layout has this panel") }
                    continue
                }
                let container = standalone(p, group: spec.group, c)
                host(container, size: size)
                await settle(0.25)
                capture(container, name: name, note: "alone at the board size \(Int(size.width))x\(Int(size.height)), tab group \(spec.group.map(\.rawValue).joined(separator: "/"))")
            }
            await renderPanelStates(c)
        }

        /// Extra states of panels (Panels board): Graphics with layers, Effects with Video open.
        func renderPanelStates(_ c: AppController) async {
            if wants("panel-effectcontrols-mask") {
                // A clip with a rectangle mask, at the Effect Controls minimum width (300): every mask control must fit.
                if let id = selectedID, c.session.activeTimeline?.tracks.flatMap(\.clips).contains(where: { $0.id == id }) == true {
                    c.session.select(clips: [id])
                    if c.panels.effectModel.addMask(.rectangle) != nil {
                        let spec = Self.boardSpec(.effectControls)
                        let container = standalone(.effectControls, group: spec.group, c)
                        host(container, size: CGSize(width: 300, height: 700))
                        await settle(0.3)
                        capture(container, name: "panel-effectcontrols-mask", note: "rectangle mask added, 300 pt wide (panel minimum)")
                        _ = c.session.undo()
                    } else { skip("panel-effectcontrols-mask", "addMask refused") }
                    c.session.select(clips: [])
                } else { skip("panel-effectcontrols-mask", "demo clip not found") }
            }
            for gyro in [false, true] {
                // Stabilize effect: Standard mid-analysis (progress + Cancel), Gyroflow grayed with its reason.
                let name = gyro ? "panel-effectcontrols-stabilize-gyroflow" : "panel-effectcontrols-stabilize"
                guard wants(name) else { continue }
                guard let id = selectedID, c.session.activeTimeline?.tracks.flatMap(\.clips).contains(where: { $0.id == id }) == true else {
                    skip(name, "demo clip not found"); continue
                }
                c.session.select(clips: [id])
                let ask = c.session.onStabilizerNeedsAnalysis
                c.session.onStabilizerNeedsAnalysis = nil      // no real analysis in a render
                defer { c.session.onStabilizerNeedsAnalysis = ask }
                guard c.session.addStabilizer(to: [id]),
                      let clip = c.session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.id == id }),
                      let eid = clip.stabilizerID else { skip(name, "addStabilizer refused"); continue }
                let m = c.panels.effectModel
                if gyro {
                    var g = clip
                    g.setParameter(eid, ClipEffect.stabilizeMethodKey, to: Double(StabilizerMethod.gyroflow.rawValue))
                    c.session.replaceDisplayedClip(g, name: "Method", continuesGesture: false)
                } else {
                    m.stabilizeRun = StabilizeRunState(clips: [id], progress: 0.42)
                }
                let container = standalone(.effectControls, group: Self.boardSpec(.effectControls).group, c)
                host(container, size: CGSize(width: 420, height: 700))
                await settle(0.3)
                capture(container, name: name, note: gyro ? "Gyroflow method, grayed (no gyro data / engine)" : "Standard, analyzing 42 %")
                m.stabilizeRun = nil
                if gyro { _ = c.session.undo() }
                _ = c.session.undo()
                c.session.select(clips: [])
            }
            if wants("panel-effectcontrols-graph") || wants("panel-effectcontrols-graph-peak") || wants("panel-effectcontrols-graph-down")
                || wants("panel-effectcontrols-keys-closed") || wants("panel-effectcontrols-keys-selected") {
                // Opacity keyed three times, the first segment Smooth at 60 % influence, the row opened: the speed graph.
                if let id = selectedID, let clip = c.session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.id == id }) {
                    c.session.select(clips: [id])
                    let m = c.panels.effectModel
                    let start = clip.start, d = clip.duration
                    c.session.seek(to: start + Time(d.value / 10, d.timescale)); m.playhead = c.session.playhead
                    m.toggleStopwatch(.opacity)
                    c.session.seek(to: start + Time(d.value / 2, d.timescale)); m.playhead = c.session.playhead
                    m.setValue(.opacity, to: 0.3)
                    c.session.seek(to: start + Time(d.value * 9 / 10, d.timescale)); m.playhead = c.session.playhead
                    m.setValue(.opacity, to: 0.9)
                    m.graphMode = .speed
                    // Keyframe states of one row: closed (diamonds only), then one key selected.
                    let specKeys = Self.boardSpec(.effectControls)
                    let keysContainer = standalone(.effectControls, group: specKeys.group, c)
                    host(keysContainer, size: CGSize(width: 1100, height: 520))
                    await settle(0.3)
                    capture(keysContainer, name: "panel-effectcontrols-keys-closed", note: "Opacity keyed three times, row closed: diamonds on the lane")
                    if let k = m.track(.opacity)?.keyIDs, k.count == 3 {
                        m.setSelection(for: .opacity, ids: [k[1]])
                        await settle(0.2)
                        capture(keysContainer, name: "panel-effectcontrols-keys-selected", note: "middle key selected (row closed)")
                        m.setSelection(for: .opacity, ids: [])
                    }
                    m.toggleOpen(.opacity)
                    if let keys = m.track(.opacity)?.keyIDs, keys.count == 3 {
                        m.setSelection(for: .opacity, ids: [keys[0], keys[1]])
                        m.applySpeedChip(.smooth, for: .opacity)
                        m.setReach(0.6, side: .both, for: .opacity)
                    }
                    let spec = Self.boardSpec(.effectControls)
                    let container = standalone(.effectControls, group: spec.group, c)
                    host(container, size: CGSize(width: 1100, height: 520))
                    await settle(0.3)
                    capture(container, name: "panel-effectcontrols-graph", note: "Opacity row opened: speed graph, Smooth at 60 % influence")
                    // Both handles pulled to the middle as far as they go: a sharp peak that runs off the top.
                    m.setReach(1, side: .both, for: .opacity)
                    await settle(0.2)
                    capture(container, name: "panel-effectcontrols-graph-peak", note: "speed graph, both handles at 100 % influence")
                    for _ in 0..<2 { _ = c.session.undo() }      // reach, reach
                    // Mid key pulled to 0 (1 down to 0 then up): the falling hill still rises from the baseline.
                    m.playhead = c.session.playhead
                    c.session.seek(to: start + Time(d.value / 2, d.timescale)); m.playhead = c.session.playhead
                    m.setValue(.opacity, to: 0.0)
                    await settle(0.2)
                    capture(container, name: "panel-effectcontrols-graph-down", note: "speed graph of a falling value: the hill still rises")
                    for _ in 0..<5 { _ = c.session.undo() }      // value, stopwatch, two values, preset
                    m.expanded.remove(.opacity)
                    c.session.select(clips: [])
                } else { skip("panel-effectcontrols-graph", "demo clip not found") }
            }
            if wants("panel-graphics-layers") {
                // A new graphics clip with four layers, the text layer selected (the board's layer list).
                if c.panels.graphics.newGraphicsClip() != nil {
                    c.panels.graphics.addShape(.line)
                    c.panels.graphics.addShape(.ellipse)
                    c.panels.graphics.addShape(.rectangle)
                    c.panels.graphics.addText("FOLGEN")
                    let spec = Self.boardSpec(.graphics)
                    let container = standalone(.graphics, group: spec.group, c)
                    host(container, size: spec.size ?? CGSize(width: 332, height: 930))
                    await settle(0.3)
                    capture(container, name: "panel-graphics-layers", note: "new graphics clip with four layers, text layer selected")
                } else { skip("panel-graphics-layers", "no graphics clip") }
            }
            if ["panel-library-grid", "panel-library-list", "panel-library-sections-grid", "panel-library-sections-list", "panel-library-preview-audio", "panel-library-presets-grid"].contains(where: wants) { await renderLibraryPopulated(c) }
            if wants("panel-effects-video") {
                let d = UserDefaults.standard
                let old = d.stringArray(forKey: "sq.effects.expandedFolders")
                d.set(["folder.builtin.Video Effects"], forKey: "sq.effects.expandedFolders")
                let view = EffectsPanelView()
                let spec = Self.boardSpec(.effects)
                let container = standalone(.effects, group: spec.group, c, view: view)
                host(container, size: spec.size ?? CGSize(width: 300, height: 580))
                await settle(0.3)
                capture(container, name: "panel-effects-video", note: "Video folder open, own view")
                if let old { d.set(old, forKey: "sq.effects.expandedFolders") } else { d.removeObject(forKey: "sq.effects.expandedFolders") }
            }
        }

        /// Library with watched folders as on the Panels board (Music, SFX, Overlays, B-Roll): Overlays as a grid of tiles,
        /// SFX as a list of sounds. Fixture files live in a temp folder (images drawn here, silent WAVs).
        func renderLibraryPopulated(_ c: AppController) async {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-render-library-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.removeItem(at: root)
            let fm = FileManager.default
            func dir(_ n: String) -> URL { let u = root.appendingPathComponent(n); try? fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
            let overlays = ["Dirt", "Fire", "Fog", "Green Screen", "Film Grain", "Light Leak", "Dust", "Bokeh", "Rain", "Flare", "Smoke", "Sparks"]
            for (i, n) in overlays.enumerated() {
                let size = 96
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size * 5 / 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                Theme.Palette.graphCurve[i % Theme.Palette.graphCurve.count].setFill()
                NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: dir("Overlays").appendingPathComponent("\(n).png"))
            }
            func wav(_ url: URL, samples: Int = 4410) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var d = Data("RIFF".utf8); func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
                func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
                let n = samples; u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
                d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2)); d.append(Data(count: n * 2)); try? d.write(to: url)
            }
            for n in ["Whoosh 01", "Whoosh 02", "Riser Short", "Click Soft", "Pop", "Camera Shutter", "Impact Low", "Swish Paper"] { wav(dir("SFX").appendingPathComponent("\(n).wav")) }
            // Music with categories (subfolders, one nested) as in the Library sections.
            let music = dir("Music")
            for n in ["Late Sun", "Open Road"] { wav(music.appendingPathComponent("\(n).wav"), samples: 44100 * 95) }
            for n in ["Morning Haze", "Slow Tide", "Paper Moon"] { wav(music.appendingPathComponent("Calm/\(n).wav"), samples: 44100 * 140) }
            for n in ["Keys One", "Keys Two"] { wav(music.appendingPathComponent("Calm/Piano/\(n).wav"), samples: 44100 * 75) }
            for n in ["Drive", "Rising Storm", "Final Push", "Anthem"] { wav(music.appendingPathComponent("Epic/\(n).wav"), samples: 44100 * 120) }
            for n in ["Tick Tock", "Lo-Fi Beat"] { wav(music.appendingPathComponent("Chill/\(n).wav"), samples: 44100 * 110) }
            _ = dir("B-Roll")
            let model = c.panels.libraryModel
            model.onFoldersChanged = nil
            var ids: [String: UUID] = [:]
            for n in ["Music", "SFX", "Overlays", "B-Roll"] { ids[n] = await model.addFolder(url: dir(n)).id }
            let spec = Self.boardSpec(.library)
            let size = spec.size ?? CGSize(width: 480, height: 580)
            let view = c.panels.view(for: .library)
            for (name, folder, mode) in [("panel-library-grid", "Overlays", LibraryViewMode.grid), ("panel-library-list", "SFX", .list)] where wants(name) {
                model.selection = .folder(ids[folder]!); model.viewMode = mode
                model.clearKindFilter(); if mode == .grid { model.toggleKind(.image) }
                let container = standalone(.library, group: spec.group, c, view: view)
                host(container, size: size)
                await settle(1.5)
                capture(container, name: name, note: "\(folder) folder fixture, \(mode.rawValue), board size")
            }
            // Folder with subfolders: All first, then one section per subfolder; a selected audio item shows the transport bar.
            for (name, mode, selectItem) in [("panel-library-sections-grid", LibraryViewMode.grid, false), ("panel-library-sections-list", .list, false),
                                             ("panel-library-preview-audio", .list, true)] where wants(name) {
                model.selection = .folder(ids["Music"]!); model.viewMode = mode; model.clearKindFilter()
                if mode == .grid { model.toggleKind(.audio); model.toggleGroup("*") }   // All collapsed so the category sections show
                if selectItem, let item = model.items.first(where: { $0.entry.name == "Morning Haze.wav" }) {
                    model.selectItemForPreview(item)
                    await settle(1.0)
                    model.preview.pause(); model.preview.seek(to: 42)
                }
                let container = standalone(.library, group: spec.group, c, view: view)
                host(container, size: size)
                await settle(1.5)
                capture(container, name: name, note: "Music folder with subfolders (Calm/Piano, Epic, Chill), \(mode.rawValue)\(selectItem ? ", audio item selected: transport bar" : "")")
                model.selectItemForPreview(nil)
                if mode == .grid { model.toggleGroup("*") }
            }
            // Presets section as a grid: every text template drawn in its own style by the real text renderer.
            if wants("panel-library-presets-grid") {
                model.selection = .presets(nil); model.viewMode = .grid; model.clearKindFilter()
                let container = standalone(.library, group: spec.group, c, view: view)
                host(container, size: size)
                await settle(1.5)
                capture(container, name: "panel-library-presets-grid", note: "Presets section, grid: text templates rendered in their own styles")
            }
            try? fm.removeItem(at: root)
        }

        /// A panel's own container as the shell builds it: tab strip with the header items of the panel (monitor popup and
        /// zoom badge, "..." buttons, "2 uses" detail) and the page's viewer header when it replaces the strip.
        func standalone(_ p: PanelID, group: [PanelID], _ c: AppController, view: NSView? = nil) -> PanelContainerView {
            let container = PanelContainerView(panels: group, selected: p, content: view ?? c.panels.view(for: p),
                                               header: c.panels.headerView(for: p, panels: group), onSelect: { _ in })
            let items = c.panels.headerItems(for: p)
            container.strip.accessories = items.accessories
            container.strip.detail = items.detail
            container.strip.leading = items.leading
            container.strip.trailing = items.trailing
            container.strip.onMore = items.more; container.strip.hidesMore = items.hidesMore
            return container
        }

        static func container(showing p: PanelID, in root: NSView) -> NSView? {
            if let v = root as? PanelContainerView, v.selected == p { return v }
            for s in root.subviews { if let f = container(showing: p, in: s) { return f } }
            return nil
        }

        /// Parts of the timeline panel that are named in the plan.
        func renderSubviews(_ c: AppController) {
            c.store.setPage(.edit)
            c.applyWorkspace()
            layoutWindow(c)
            capture(c.panels.timelineHost.header, name: "timeline-header-bar")
            capture(c.panels.meterView, name: "audio-meter")
        }

        // MARK: In-context modals

        static let contextNames = ["ctx-settings-general", "ctx-settings-playback", "ctx-settings-editing", "ctx-export", "ctx-new-project",
                                   "ctx-sequence-settings", "ctx-alert", "ctx-keyboard-shortcuts", "ctx-menu"]

        /// `ctx-<thing>`: the WHOLE main window (1440x900, footage online) with the modal presented through its real path
        /// (`beginSheetModal`, `SQModalSheet.present`, `NewProjectSheet.run`), so the scrim and what shows behind it are visible.
        /// The window content (with the dim backdrop view) is drawn first, then the sheet window's content (the card) on top.
        func renderContext(_ c: AppController) async {
            let win: NSWindow = c.window
            let fmt = c.session.activeTimeline?.format ?? SequenceFormat(width: 1080, height: 1920, frameDuration: RenderDemoProject.frame)
            func ctx(_ name: String, _ trigger: () -> Void) async {
                await drive(c, name, note: "whole window with the modal on top", context: true, trigger)
            }
            await ctx("ctx-settings-general") { c.settingsWindow.show(page: .general, over: win) }
            await ctx("ctx-settings-playback") { c.settingsWindow.show(page: .playback, over: win) }
            await ctx("ctx-settings-editing") { c.settingsWindow.show(page: .editing, over: win) }
            await ctx("ctx-export") { c.exports.presentDialog(for: c.session, on: win) }
            await ctx("ctx-new-project") { _ = NewProjectSheet.run(templates: ProjectTemplate.builtIn, over: win) }
            await ctx("ctx-sequence-settings") { SequenceSettingsSheet.present(on: win, settings: SequenceSettings(name: "Main", format: fmt), isNew: false) { _ in } }
            await ctx("ctx-alert") {
                let alert = SQDialog()
                alert.style = .warning
                alert.messageText = "Media offline"
                alert.informativeText = "2 files could not be found. Reconnect them to see the picture again."
                alert.beginSheetModal(for: win)
            }
            await ctx("ctx-keyboard-shortcuts") { c.shortcutsWindow.show(over: win) }
            if wants("ctx-menu"), let base = win.contentView {
                layoutWindow(c)
                let menu = SQMenuRender.view(items: [SQMenuItem(title: "Cut"), SQMenuItem(title: "Copy"), SQMenuItem(title: "Paste"),
                                                     SQMenuItem(title: "Delete")])
                host(menu, size: menu.frame.size)
                composite(base: base, layers: [(menu, NSPoint(x: 560, y: 380))], name: "ctx-menu", note: "SQMenu rows over the window at (560, 380)")
            }
        }

        /// Draws `layers` (view and top-left origin inside `base`) over `base`, at 1x and 2x.
        func composite(base: NSView, layers: [(NSView, NSPoint)], name: String, note: String) {
            guard wants(name) else { return }
            base.layoutSubtreeIfNeeded()
            for case let b as SQModalBackdropView in base.subviews { b.alphaValue = 1 }
            let size = base.bounds.size
            var px1 = ""
            func rep(_ s: CGSize, _ scale: Int) -> NSBitmapImageRep? {
                let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((s.width * CGFloat(scale)).rounded(.up)), pixelsHigh: Int((s.height * CGFloat(scale)).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                r?.size = s
                return r
            }
            for scale in [1, 2] {
                guard let out = rep(size, scale), let ctx = NSGraphicsContext(bitmapImageRep: out) else { skipped.append((name, "no bitmap")); return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                Self.background.setFill()
                NSRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()
                base.cacheDisplay(in: base.bounds, to: out)
                for (v, topLeft) in layers {
                    v.layoutSubtreeIfNeeded()
                    guard let lr = rep(v.bounds.size, scale) else { continue }
                    v.cacheDisplay(in: v.bounds, to: lr)
                    let image = NSImage(size: v.bounds.size)
                    image.addRepresentation(lr)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                    // Bottom-left coordinates: the layer's top edge sits `topLeft.y` below the base's top edge.
                    image.draw(in: NSRect(x: topLeft.x, y: size.height - topLeft.y - v.bounds.height, width: v.bounds.width, height: v.bounds.height),
                               from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                guard let png = out.representation(using: .png, properties: [:]) else { skipped.append((name, "png encode failed")); return }
                try? png.write(to: dir.appendingPathComponent("\(name)@\(scale)x.png"))
                if scale == 1 { px1 = "\(Int(size.width))x\(Int(size.height))" }
            }
            entries.append(Entry(name: name, pixels: px1, source: "composite: \(note)"))
        }

        // MARK: Dialogs

        func renderDialogs(_ c: AppController) async {
            // Export dialog with the demo sequence; the live preview is switched off (it would render async).
            if wants("dialog-export") {
                if let model = c.exports.makeModel(for: c.session) {
                    model.previewSource = nil
                    // The board's state: loudness normalizing on, no captions, In to Out.
                    model.normalizeLoudness = true
                    model.captions = .none
                    if model.canUseInOut { model.useInOut = true }
                    model.outputDirectory = URL(fileURLWithPath: "/Users/demo/Exports", isDirectory: true)
                    let view = ExportDialogView(model: model, onExport: {}, onCancel: {})
                    let sheet = SQModalSheet(card: view, size: ExportDialogView.size, onCancel: {})
                    hosts.append(sheet.window)
                    sheet.window.setContentSize(NSSize(width: 1100, height: 800))      // room for the card: a smaller window shrinks it
                    await settle(0.3)
                    capture(view, name: "dialog-export", note: "SQModalSheet card, preview off")
                    view.close()
                } else { skip("dialog-export", "no sequence to export") }
            }
            // Settings: the six pages. Effect Defaults fixture as on the board: Blur and Dissolve (the harness home is empty).
            if wants("window-settings-media") { SettingsWindowController.renderUsedOverride = "4.2 GB" }
            if wants("window-settings-editing") { UserDefaults.standard.set(15, forKey: "settings.videoTransitionFrames") }
            if wants("window-settings-editing"), let blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind) {
                EffectDefaultsLibrary.shared.update {
                    $0.effects[ClipEffect.gaussianBlurKind] = blur
                    $0.transitions[TransitionKind.crossDissolve.rawValue] = TransitionPreset(kind: .crossDissolve, duration: Time(1, 2))
                }
            }
            for sp in SettingsPage.allCases where wants("window-settings-\(sp.slug)") {
                let page = sp.slug
                if let v = c.settingsWindow.renderPage(sp) { await settle(0.2); capture(v, name: "window-settings-\(page)", note: "window content, no title bar") }
                else { skip("window-settings-\(page)", "no window content") }
            }
            // Start window with fixed recents (the real one reads the user's).
            if wants("window-start") {
                let now = Date()
                let recents = [("TikTok Schnitt-Tricks", "/Users/demo/Projects/TikTok Schnitt-Tricks.sqproj", 0.0),
                               ("TCL C8L", "/Users/demo/Projects/TCL C8L.sqproj", -86_400),
                               ("Studio Tour", "/Users/demo/Projects/Studio Tour.sqproj", -6 * 86_400),
                               ("Old Draft", "/Users/demo/Projects/Old Draft.sqproj", -20 * 86_400)]
                    .map { RecentProjects.Entry(path: $0.1, name: $0.0, opened: now.addingTimeInterval($0.2)) }
                var templates = ProjectTemplate.builtIn
                for n in ["My TikTok", "Product Review"] {
                    var t = ProjectTemplate.builtIn[0]; t.id = "user-" + n; t.name = n; templates.append(t)
                }
                let view = StartWindowView(templates: templates, recents: recents, missing: ["/Users/demo/Projects/Old Draft.sqproj"],
                                           infos: [recents[0].path: StartProjectInfo(width: 1080, height: 1920, fps: 30, seconds: 134),
                                                   recents[1].path: StartProjectInfo(width: 3840, height: 2160, fps: 25, seconds: 642),
                                                   recents[2].path: StartProjectInfo(width: 1080, height: 1350, fps: 29.97, seconds: 58)],
                                           onCreate: { _ in }, onOpen: { _ in },
                                           onOpenOther: {}, onDeleteTemplate: { _ in }, onRemoveRecent: { _ in }, onClearRecents: {},
                                           onSaveTemplate: {}, reopenLast: true)
                let hostView = NSHostingView(rootView: view)
                host(hostView, size: Theme.Metrics.startWindowSize)
                capture(hostView, name: "window-start", note: "fixed recents, 1100x720 window content")
            }
            await renderDriven(c)
        }

        // MARK: Menus

        func renderMenu(_ name: String, _ rows: [SQMenuItem]?, note: String = "") {
            guard wants(name) else { return }
            guard let rows, !rows.isEmpty else { skip(name, "no menu for this state"); return }
            try? MenuOutline.text(rows).write(to: dir.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            let v = SQMenuRender.view(items: rows)
            host(v, size: v.frame.size)
            capture(v, name: name, note: note.isEmpty ? "one level" : note)
        }

        static func slug(_ s: String) -> String {
            let t = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            return t.split(separator: "-").joined(separator: "-").prefix(32).description
        }

        func renderMenus(_ c: AppController) async {
            // Menu bar menus.
            for item in NSApp.mainMenu?.items ?? [] {
                guard let sub = item.submenu, !sub.title.isEmpty || !item.title.isEmpty else { continue }
                // The system menu bar stays an NSMenu: it is the only place that still needs the NSMenu bridge.
                renderMenu("menu-bar-\(Self.slug(item.title.isEmpty ? sub.title : item.title))", SQMenuItem.items(from: sub), note: "menu bar, submenus not drawn")
            }
            renderMenu("menu-popup-workspace", c.workspaceItems(), note: "workspace popup list")

            // Timeline context menus through the timeline's own provider, at points computed from the demo layout.
            c.store.setPage(.edit)
            c.applyWorkspace()
            await settle(0.3)
            layoutWindow(c)
            let tv = c.panels.timelineView
            let rows = tv.geometry.rows(for: tv.timeline)
            func rowMid(_ label: String) -> CGFloat? { rows.first { $0.label == label }.map { $0.y + $0.height / 2 } }
            let g = tv.geometry
            let x150 = g.x(for: RenderDemoProject.frames(150) + RenderDemoProject.frames(10))
            if let y = rowMid("V1") { renderMenu("menu-timeline-clip", tv.contextMenuProvider?(CGPoint(x: x150, y: y))) }
            else { skip("menu-timeline-clip", "no V1 row") }
            if let y = rowMid("A2") { renderMenu("menu-timeline-empty", tv.contextMenuProvider?(CGPoint(x: g.x(for: RenderDemoProject.frames(200)), y: y))) }
            else { skip("menu-timeline-empty", "no A2 row") }
            renderMenu("menu-timeline-ruler", tv.contextMenuProvider?(CGPoint(x: g.x(for: RenderDemoProject.frames(300)), y: TimelineGeometry.rulerHeight / 2)))
            let hx = TimelineGeometry.toolColumnWidth + 24
            if let y = rowMid("V1") { renderMenu("menu-timeline-track-header-v1", tv.contextMenuProvider?(CGPoint(x: hx, y: y))) }
            if let y = rowMid("A3") { renderMenu("menu-timeline-track-header-a3", tv.contextMenuProvider?(CGPoint(x: hx, y: y))) }
            if let id = selectedID { c.session.select(clips: [id]) }

            // Panel menus: every view of a panel whose right-click opens SQ rows at its center (rows, headers, lanes); distinct menus only.
            for p in PanelID.allCases where p != .timeline && p != .audioMeter {
                guard wants("menu-\(p.rawValue)-1") || only == nil || (only?.hasPrefix("menu-\(p.rawValue)-") ?? false) else { continue }
                guard let (container, _) = await showInPlace(p, c) else { continue }
                var seen = Set<String>()
                var n = 0
                func walk(_ v: NSView) {
                    if n >= 5 { return }
                    let isSystem = Bundle(for: type(of: v)) == Bundle(for: NSView.self) && !(v is NSTableView)
                    if !isSystem, !(v is NSTextField), !(v is NSTextView), v.bounds.width >= 20, v.bounds.height >= 12, let w = v.window {
                        let centre = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                        if let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: centre, modifierFlags: [], timestamp: 0,
                                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            final class Shown: @unchecked Sendable { var items: [SQMenuItem] = [] }
                            let box = Shown()
                            if ProcessInfo.processInfo.environment["SQ_RENDER_TRACE"] != nil { NSLog("SQRENDER probe \(type(of: v)) in \(p.rawValue)") }
                            SQContextMenu.capture = { box.items = $0 }
                            _ = v.menu(for: ev)                       // tables and outlines show their rows from here
                            if box.items.isEmpty { v.rightMouseDown(with: ev) }
                            SQContextMenu.capture = nil
                            let shown = box.items
                            let key = shown.map(\.title).joined(separator: "|")
                            if !shown.isEmpty, seen.insert(key).inserted {
                                n += 1
                                renderMenu("menu-\(p.rawValue)-\(n)-\(Self.slug(shown.first { $0.kind == .action }?.title ?? "menu"))", shown,
                                           note: "\(type(of: v)) in \(p.rawValue)")
                            }
                        }
                    }
                    for s in v.subviews { walk(s) }
                }
                walk(container)
            }
            c.store.setPage(.edit)
            c.applyWorkspace()
            await settle(0.3)
            layoutWindow(c)
        }

        // MARK: Other windows

        /// A window's content view is transparent over the window's own background, which a content-view capture misses.
        func paintWindowBackground(_ w: NSWindow) {
            guard let v = w.contentView else { return }
            v.wantsLayer = true
            v.layer?.backgroundColor = w.backgroundColor.cgColor
        }

        func renderWindowsExtra(_ c: AppController) async {
            if wants("window-shortcuts") {
                c.shortcutsWindow.show()
                if let v = c.shortcutsWindow.cardView {
                    v.window?.makeFirstResponder(nil)   // the board shows no focus ring
                    c.shortcutsWindow.applyRenderState()
                    await settle(0.3)
                    capture(v, name: "window-shortcuts", note: "L modal card, \(Int(v.bounds.width))x\(Int(v.bounds.height))")
                    c.shortcutsWindow.close()
                } else { skip("window-shortcuts", "no window appeared") }
            }
            if wants("window-card-import") {
                // A card with the five demo clips (the board shows 24 clips of a camera card).
                let media = FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderDemoMedia", isDirectory: true)
                try? await RenderDemoProject.writeMedia(into: media)
                let volume = FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderCard", isDirectory: true)
                try? FileManager.default.removeItem(at: volume)
                try? FileManager.default.createDirectory(at: volume.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
                // Eight clips C0012...C0019, newest first as on the board (3 Oct 2026, 14:12 and 5 minutes older each).
                let demoSources = ["C2140.MP4", "C2147.MP4", "C2152.MP4", "C2156.MP4", "C2160.MP4"]
                let newest = DateComponents(calendar: .current, year: 2026, month: 10, day: 3, hour: 14, minute: 12).date ?? Date()
                for i in 0..<8 {
                    let dst = volume.appendingPathComponent("DCIM/C00\(12 + i).MP4")
                    try? FileManager.default.copyItem(at: media.appendingPathComponent(demoSources[i % demoSources.count]), to: dst)
                    try? FileManager.default.setAttributes([.modificationDate: newest.addingTimeInterval(-Double(i) * 300)], ofItemAtPath: dst.path)
                }
                let ctl = CardImportWindowController(volume: volume, importFiles: { _ in }, projectFolder: { nil })
                ctl.show()
                if let v = ctl.cardView {
                    await settle(1.5)       // the card scan and the thumbnails
                    ctl.applyRenderState(selecting: [0, 1, 3], preview: 0)
                    await settle(1.5)
                    capture(v, name: "window-card-import", note: "L modal card, eight demo clips, three ticked")
                    ctl.close()
                } else { skip("window-card-import", "no window appeared") }
                withExtendedLifetime(ctl) {}
            }
            if wants("window-splash") {
                var log = StartupLog(expected: 12)
                for step in ["Fonts", "Editor panels", "Effect presets", "Main window"] { log.begin(step) }
                if let v = StartupSplashRender.view(log: log) {
                    let w = host(v, size: v.frame.size)
                    capture(w, name: "window-splash", note: "splash content with sample steps, not driven by the real startup")
                } else { skip("window-splash", "no content") }
            }
        }

        // MARK: Driven dialogs

        /// Watches for the dialog or sheet a trigger opens (a sheet on the main window, or an app-modal SQDialog), makes it
        /// invisible at once, captures its card and dismisses it with Cancel. Runs in a run-loop timer so it also works while
        /// `runModal` blocks inside the trigger.
        @MainActor
        final class Probe {
            let before: Set<ObjectIdentifier>
            let parent: NSWindow
            let start = Date()
            var firstSeen: Date?
            var done = false
            var captured = false
            var onCard: (NSView) -> Void = { _ in }
            var settleBeforeCapture = 0.35
            init(parent: NSWindow) { self.parent = parent; before = Set(NSApp.windows.map(ObjectIdentifier.init)) }

            func tick() {
                if done { return }
                let w = parent.sqAttachedSheet ?? NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && ($0 is SQDialogWindow || String(describing: type(of: $0)) == "SheetPanel") }
                if let w {
                    if firstSeen == nil { firstSeen = Date(); w.alphaValue = 0 }
                    if Date().timeIntervalSince(firstSeen ?? Date()) > settleBeforeCapture {
                        if let v = w.contentView { w.makeFirstResponder(nil); v.layoutSubtreeIfNeeded(); onCard(v); captured = true }   // boards show no focus ring: render unfocused
                        done = true
                        if let d = w as? SQDialogWindow { d.cancelOperation(nil) }
                        else if String(describing: type(of: w)) == "SheetPanel" { w.cancelOperation(nil) }
                        if parent.sqAttachedSheet === w { parent.endSheet(w) }
                        if NSApp.modalWindow === w { NSApp.stopModal() }
                        w.orderOut(nil)
                    }
                } else if Date().timeIntervalSince(start) > 3 {
                    done = true
                    if NSApp.modalWindow != nil { NSApp.stopModal() }
                }
            }
        }

        func drive(_ c: AppController, _ name: String, note: String = "", context: Bool = false, _ trigger: () -> Void) async {
            guard wants(name) else { return }
            let probe = Probe(parent: c.window)
            probe.settleBeforeCapture = context ? 1.0 : 0.35
            probe.onCard = { [self] v in
                if context, let base = c.window.contentView {
                    // The sheet window is as large as the host window; align its top-left with the content view's.
                    composite(base: base, layers: [(v, .zero)], name: name, note: note)
                } else { capture(v, name: name, note: note.isEmpty ? "dialog card" : note) }
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { [probe] _ in MainActor.assumeIsolated { probe.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            trigger()
            let t0 = Date()
            while !probe.done && Date().timeIntervalSince(t0) < 5 { await settle(0.05) }
            timer.invalidate()
            if !probe.captured { skip(name, "no dialog window appeared within 3 s") }
            await settle(0.1)
            if c.window.sqAttachedSheet != nil, let s = c.window.sqAttachedSheet { c.window.endSheet(s); s.orderOut(nil) }
        }

        func renderDriven(_ c: AppController) async {
            let win: NSWindow = c.window
            let f = RenderDemoProject.frame
            let fmt = c.session.activeTimeline?.format ?? SequenceFormat(width: 1080, height: 1920, frameDuration: f)
            let clips = c.session.activeTimeline?.tracks.flatMap(\.clips) ?? []
            let selected = clips.first { $0.id == selectedID }
            c.session.select(clips: [])

            await drive(c, "dialog-new-project") { _ = NewProjectSheet.run(templates: ProjectTemplate.builtIn) }
            await drive(c, "dialog-new-sequence") { SequenceSettingsSheet.present(on: win, settings: SequenceSettings(name: "Sequence 02", format: fmt), isNew: true) { _ in } }
            await drive(c, "dialog-sequence-settings") { SequenceSettingsSheet.present(on: win, settings: SequenceSettings(name: "Main", format: fmt), isNew: false) { _ in } }
            await drive(c, "dialog-change-format") { ChangeFormatSheet.present(on: win, current: fmt, hasSelection: true, name: nil) { _ in } }
            await drive(c, "dialog-new-sequence-from-template") { c.newSequenceFromTemplate(nil) }
            await drive(c, "dialog-save-sequence-template") { c.saveSequenceAsTemplate(nil) }
            await drive(c, "dialog-relink") { RelinkSheet.present(session: c.session, over: win, onFolderChosen: { _ in }, onClose: { _, _ in }) }
            await drive(c, "dialog-import-report") {
                var r = PRImportReport()
                r.note("Lumetri Color", .approximated, "Mapped to the color grade; curves are simplified.")
                r.note("Cross Dissolve", .mapped)
                r.note("Warp Stabilizer", .dropped, "No equivalent yet.")
                ImportReportSheet.present(r, fileName: "TikTok Schnitt-Tricks.prproj", over: win, completion: {})
            }
            if let clip = selected {
                await drive(c, "dialog-speed") {
                    SpeedDurationSheet.present(on: win, model: SpeedDialogModel(clips: [clip], frameDuration: f),
                                               timecode: Timecode(frameDuration: f, dropFrame: false)) { _ in }
                }
            } else { skip("dialog-speed", "demo clip not found") }
            await drive(c, "dialog-color-matte") { ColorMatteDialog.present(on: win) { _ in } }
            await drive(c, "dialog-audio-gain") {
                AudioGainDialog.present(on: win, items: [AudioGainPlan.Item(id: UUID(), name: "C2156.MP4", gainDB: 0, peak: 0.5)]) { _, _ in }
            }
            await drive(c, "dialog-track-mix") { TrackMixDialog.present(on: win, trackName: "Music", volumeDB: -3, pan: 0) { _, _ in } }
            await drive(c, "dialog-sequence-volume") {
                TrackMixDialog.presentSequenceVolume(on: win, sequenceName: "Sequence 01", volumeDB: -2) { _, _ in }
            }
            await drive(c, "dialog-remove-silences") {
                RemoveSilencesDialog.present(on: win, clipName: "C2156.MP4", initial: .standard, preview: { _ in (12, Time(41, 10)) }) { _, _ in }
            }
            await drive(c, "dialog-anonymize") {
                AnonymizeDialog.present(on: win, clipName: "C2156.MP4", people: [0.2, 0.7].map { x in
                    AnonymizePerson(label: 1, point: Vec2(x, 0.5), box: AnonymizeBox(x: x - 0.1, y: 0.2, width: 0.2, height: 0.7), face: nil)
                }) { _ in }
            }
            await drive(c, "dialog-check-cuts") { c.requestCheckCuts() }
            if let first = clips.first(where: { $0.kind == .video && $0.name == "C2140.MP4" }), let second = clips.first(where: { $0.kind == .video && $0.name == "C2147.MP4" }) {
                c.session.select(clips: [first.id, second.id])
                await drive(c, "dialog-punch-in-cuts") { c.requestPunchInCuts() }
                c.session.select(clips: [])
            }
            await drive(c, "dialog-paste-settings") { _ = PasteAttributesDialog.run(choices: PasteAttributeGroup.allCases) }
            if let m = c.session.activeTimeline?.markers.first {
                await drive(c, "dialog-marker") { c.panels.editMarker(m.id) }
            }
            await drive(c, "dialog-transition-duration") {
                TransitionDurationSheet.present(on: win, name: "Cross Dissolve", duration: RenderDemoProject.frames(15), frameDuration: f) { _ in }
            }
            await drive(c, "dialog-transition-preset") { TransitionPresetSheet.present(on: win, defaultName: "My Transition") { _ in } }
            await drive(c, "dialog-save-preset") { PresetSaveSheet.present(on: win, defaultName: "My Look") { _ in } }
            // Create Angles Clip from the first three V1 clips (the shared shot selects the same ones).
            if let v1 = c.session.activeTimeline?.tracks.first(where: { $0.kind == .video }) {
                let ids = v1.clips.sorted { $0.start < $1.start }.prefix(3).map(\.id)
                c.session.select(clips: Set(ids))
                let angles = c.session.angleCandidates(clips: c.session.angleSelection)
                await drive(c, "dialog-create-angles") {
                    AnglesDialog.present(on: win, angles: angles, fromTimeline: true, existingNames: ["Main"]) { _ in }
                }
                c.session.select(clips: [])
            }
            await drive(c, "dialog-combine") { NestSheet.present(on: win, existingNames: ["Main", "Combined 01"]) { _ in } }
            await drive(c, "dialog-save-workspace") { c.saveLayoutAs(nil) }
            await drive(c, "dialog-collect") { c.collectFiles(nil) }
            await drive(c, "dialog-about") { c.showAbout(nil) }
            await drive(c, "dialog-find") { c.panels.projectView.showFind() }
            await drive(c, "dialog-notice-warning") { c.presentMessage("Media offline", "2 files could not be found. Reconnect them to see the picture again.") }
            await drive(c, "dialog-notice-error") {
                c.presentError("Project could not be saved", NSError(domain: "SQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk is full."]))
            }
            await drive(c, "dialog-confirm-destructive") { _ = SQDialog.runConfirm("Delete preset “My Look”?", message: "This cannot be undone.", confirm: "Delete") }

            // Dialogs that were private: now opened through the real code path.
            if let model = c.panels.textView.captionsModel {
                await drive(c, "dialog-create-captions") { CreateCaptionsRender.present(on: win, model: model) }
            } else { skip("dialog-create-captions", "no captions model") }
            await drive(c, "dialog-name-this-project") { _ = c.askVideoName(suggested: "Untitled", template: ProjectTemplate.builtIn[0]) }
            if let clip = selected {
                c.session.select(clips: [clip.id])
                await drive(c, "dialog-rename") { c.panels.renameSelectedClip() }
                c.session.select(clips: [])
            } else { skip("dialog-rename", "demo clip not found") }
            if let track = c.session.activeTimeline?.tracks.first {
                await drive(c, "dialog-rename-track") { c.panels.renameTrack(track) }
            }
            // Own workspace selected so Rename and Delete are allowed; removed again afterwards.
            c.store.saveCurrentAsNew(base: "My Layout")
            await drive(c, "dialog-rename-workspace") { c.renameWorkspace(nil) }
            await drive(c, "dialog-delete-workspace") { c.deleteWorkspace(nil) }
            _ = c.store.deleteCurrent()
            // Save changes: a real edit makes the session dirty, undone afterwards.
            if let clip = selected {
                c.session.select(clips: [clip.id])
                c.session.renameSelectedClip(to: clip.name + " ")
                c.session.select(clips: [])
                await drive(c, "dialog-save-changes") { Task { @MainActor in _ = await c.confirmDiscardChanges() } }
                _ = c.session.undo()
            }
            await drive(c, "dialog-recovery") {
                AppController.makeRecoveryDialog(projectName: "TikTok Schnitt-Tricks", date: Date(timeIntervalSince1970: 1_790_000_000))
                    .beginSheetModal(for: win) { _ in }
            }
            await drive(c, "dialog-replace-transcript") { CaptionsPanelView.makeOverwriteDialog().beginSheetModal(for: win) { _ in } }
            await drive(c, "dialog-sequence-match") {
                _ = c.askChangeSequenceFormat(fmt, SequenceFormat(width: 1920, height: 1080, frameDuration: f))
            }

            for (n, why) in [("dialog-export-running", "the app has no Export running sheet yet (exports run in the queue popover)"),
                             ("dialog-quick-apply", "pointer-anchored overlay, not instantiable without a live event"),
                             ("dialog-color-picker", "pointer-anchored popover, not instantiable without a live event"),
                             ("dialog-lut-picker", "pointer-anchored popover, not instantiable without a live event"),
                             ("dialog-curve-picker", "pointer-anchored popover, not instantiable without a live event"),
                             ("dialog-look-popup", "pointer-anchored popup, not instantiable without a live event"),
                             ("dialog-font-list", "pointer-anchored popup, not instantiable without a live event")] {
                skip(n, why)
            }
            c.session.select(clips: selectedID.map { [$0] } ?? [])
        }

        // MARK: Shared overlays

        func renderOverlays(_ c: AppController) {
            if wants("overlay-sqdialog") {
                let d = SQDialog()
                d.messageText = "Delete the selected clips?"
                d.informativeText = "This removes 3 clips from the sequence. You can undo it with Cmd+Z."
                d.addButton("Delete", role: .default)
                d.addButton("Cancel", role: .cancel)
                if let card = d.renderedCard() { capture(card, name: "overlay-sqdialog") } else { skip("overlay-sqdialog", "no card") }
            }
            if wants("overlay-sqdialog-warning") {
                let d = SQDialog()
                d.style = .warning
                d.messageText = "Media is offline"
                d.informativeText = "2 files could not be found. Reconnect them to see the picture again."
                d.addButton("Reconnect…", role: .default)
                d.addButton("Later", role: .cancel)
                if let card = d.renderedCard() { capture(card, name: "overlay-sqdialog-warning") } else { skip("overlay-sqdialog-warning", "no card") }
            }
            if wants("overlay-sqmenu") {
                let items: [SQMenuItem] = [
                    .header("Clip"),
                    SQMenuItem(title: "Cut", shortcut: "⌘X"),
                    SQMenuItem(title: "Copy", shortcut: "⌘C"),
                    SQMenuItem(title: "Paste", shortcut: "⌘V", isEnabled: false),
                    .separator,
                    SQMenuItem(title: "Speed", submenu: [SQMenuItem(title: "50%"), SQMenuItem(title: "200%")]),
                    SQMenuItem(title: "Snapping", isChecked: true),
                    SQMenuItem(title: "Delete", shortcut: "⌫"),
                ]
                let v = SQMenuRender.view(items: items)
                host(v, size: v.frame.size)
                capture(v, name: "overlay-sqmenu", note: "sample model, one level")
            }
            if wants("overlay-multiband-window") {
                let v = MultibandEditor.renderedWindow()
                host(v, size: v.frame.size)
                capture(v, name: "overlay-multiband-window", note: "floating window, Broadcast preset, no audio feed")
            }
            for stage in ["running", "confirm", "done", "failed"] where wants("overlay-export-progress-\(stage)") {
                let v = ExportProgressWindow.renderedWindow(stage: stage)
                host(v, size: v.frame.size)
                capture(v, name: "overlay-export-progress-\(stage)", note: "export progress window, \(stage)")
            }
            if wants("overlay-sqpopover") {
                let content = NSTextField(labelWithString: "Sample popover content")
                content.font = Theme.Typography.title
                content.textColor = Theme.Colors.label
                content.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
                content.alignment = .center
                let frame = SQPopover.renderedFrame(content: content, inset: Theme.Spacing.md)
                host(frame, size: frame.frame.size)
                capture(frame, name: "overlay-sqpopover", note: "chrome around sample content")
            }
        }

        // MARK: Index

        func writeIndex() throws {
            var lines = entries.map { "\($0.name) | \($0.pixels) | \($0.source)" }
            lines += skipped.map { "SKIPPED \($0.0) | \($0.1)" }
            let url = dir.appendingPathComponent("index.txt")
            if only != nil, let old = try? String(contentsOf: url, encoding: .utf8) {
                // `--only`: replace the lines of the re-rendered names, keep the rest.
                let names = Set(entries.map(\.name) + skipped.map(\.0))
                let kept = old.split(separator: "\n").map(String.init).filter { line in
                    let key = line.hasPrefix("SKIPPED ") ? String(line.dropFirst(8)) : line
                    return !names.contains(String(key.prefix { $0 != " " }))
                }
                lines = kept + lines
            }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Contact sheet: every 1x render tiled in rows, name under each tile. Tiles are scaled down to fit, never up.
@MainActor
private enum ContactSheet {
    static func write(entries: [String], dir: URL) {
        let maxW: CGFloat = 700, maxH: CGFloat = 520, pad: CGFloat = 16, caption: CGFloat = 22, sheetW: CGFloat = 2400
        struct Tile { var name: String; var image: NSImage; var size: CGSize }
        var tiles: [Tile] = []
        for name in entries {
            guard let img = NSImage(contentsOf: dir.appendingPathComponent("\(name)@1x.png")), let rep = img.representations.first else { continue }
            let px = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            let k = min(1, maxW / px.width, maxH / px.height)
            tiles.append(Tile(name: name, image: img, size: CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())))
        }
        // Shelf layout.
        var rows: [[Tile]] = [[]]
        var x = pad
        for t in tiles {
            if x + t.size.width + pad > sheetW, !rows[rows.count - 1].isEmpty { rows.append([]); x = pad }
            rows[rows.count - 1].append(t); x += t.size.width + pad
        }
        let rowH = rows.map { ($0.map(\.size.height).max() ?? 0) + caption + pad }
        let sheetH = Int(pad + rowH.reduce(0, +))
        guard sheetH > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sheetW), pixelsHigh: sheetH, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.translateBy(x: 0, y: CGFloat(sheetH)); ctx.cgContext.scaleBy(x: 1, y: -1)   // top-left origin
        Theme.Colors.divider.setFill()
        NSRect(x: 0, y: 0, width: sheetW, height: CGFloat(sheetH)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body,
                                                    .foregroundColor: Theme.Colors.label2]
        var y = pad
        for (i, row) in rows.enumerated() {
            var x = pad
            for t in row {
                let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
                NSGraphicsContext.current = flipped
                t.image.draw(in: NSRect(x: x, y: y, width: t.size.width, height: t.size.height), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSAttributedString(string: t.name, attributes: attrs).draw(at: NSPoint(x: x, y: y + t.size.height + 4))
                x += t.size.width + pad
            }
            y += rowH[i]
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("sheet.png"))
    }
}
