import AppKit
import SQCore
import SQDrawKit
import SQDrawLibrary
import SQDrawShell
import SQDrawTimeline
import SQAppShell
import SQEditorSession
import SQInspectorUI
import SQTimelineUI
import SQUIKit

/// `SQ_SHARED_UI=1 SQ_SHARED_UI_SHOT=<dir>`: renders the shared UI offscreen through `CoreGraphicsRenderer` (no window,
/// no screen capture) at 1440x900 pt, 2x: `shared-start.png` (the start screen) and `shared-edit.png` (the render
/// harness's demo project open), `shared-color.png` (its Color page), `shared-menu.png`, `shared-preferences.png`, prints quad counts and frame times, and quits. Compare with `scripts/render-panels.sh
/// --only window-edit` (the AppKit UI on the same project).
@MainActor
enum SharedUIShot {
    /// Milliseconds of a second draw of `list` into one bitmap context with one atlas mask.
    static func warmDraw(_ list: DrawList, width: Int, height: Int, atlas: GlyphAtlas) -> Double {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        CoreGraphicsRenderer.flipped(ctx, height: height)
        let mask = CoreGraphicsRenderer.mask(atlas)
        CoreGraphicsRenderer.draw(list, in: ctx, glyphs: mask)
        let t = Date()
        CoreGraphicsRenderer.draw(list, in: ctx, glyphs: mask)
        let ms = Date().timeIntervalSince(t) * 1000
        // SQ_SHOT_PROFILE=<n>: n more draws, for `sample` to attach to.
        for _ in 0..<(Int(ProcessInfo.processInfo.environment["SQ_SHOT_PROFILE"] ?? "") ?? 0) {
            CoreGraphicsRenderer.draw(list, in: ctx, glyphs: mask)
        }
        return ms
    }

    /// The right-click menus of the Mac parity audit, as `render-panels.sh` probes them (`renderMenus`): the timeline at
    /// the same points (clip, empty track, ruler, V1 / A3 headers), then every other panel's tab and a grid over its
    /// content; each distinct menu is written as `shared-menu-<panel>-<n>-<first row>.txt` (MenuOutline), the timeline
    /// clip menu also as a PNG.
    static func menuSweep(_ c: SharedUIController, into dir: URL, shot: (String) -> Void) async {
        let menus = c.shell.menuBar.controller
        func write(_ name: String, _ items: [SQMenuItem]) {
            try? MenuOutline.text(items).write(to: dir.appendingPathComponent("shared-\(name).txt"), atomically: true, encoding: .utf8)
        }
        /// Right press at window point `p` (pt); the menu it opened, closed again. `png`: called with the menu open.
        func probe(_ p: CGPoint, png: ([SQMenuItem]) -> Void = { _ in }) -> [SQMenuItem] {
            menus.dismiss()
            c.handle(.mouseDown(x: Float(p.x * 2), y: Float(p.y * 2), modifiers: .secondary))
            let items = menus.isOpen ? menus.rootItems : []
            if !items.isEmpty { png(items) }
            menus.dismiss()
            c.handle(.mouseUp(x: Float(p.x * 2), y: Float(p.y * 2)))
            return items
        }
        // Earlier sweeps may leave a dialog or alert open: it would swallow the right press ("no menu").
        for _ in 0..<4 {
            guard let d = c.shell.dialog else { break }
            if let r = d.model.response(forReturn: false) { d.press(r) }
            try? await Task.sleep(for: .milliseconds(150))   // the dialog goes away after its completion ran
            if c.shell.dialog === d { c.handle(.keyDown(.escape, modifiers: [])); try? await Task.sleep(for: .milliseconds(150)) }
        }
        menus.dismiss()
        c.session.select(clips: [])
        if ProcessInfo.processInfo.environment["SQ_SHOT_DEBUG"] != nil {
            print("menu sweep state: dialog \(c.shell.dialog != nil) start \(c.shell.isStartShown) fullscreen \(c.shell.isProgramFullScreen) trim \(c.shell.trim.isActive) quick \(c.shell.quickApply != nil) queue \(c.shell.queuePopover != nil)")
        }
        c.shell.dock.setPage(.edit)
        _ = c.frame(width: 2880, height: 1800)
        let tp = c.timelinePanel
        let origin = CGPoint(x: CGFloat(tp.frame.x / tp.scale), y: CGFloat(tp.frame.y / tp.scale))
        let g = tp.geometry
        let rows = g.rows(for: tp.timeline)
        func rowMid(_ label: String) -> CGFloat? { rows.first { $0.label == label }.map { $0.y + $0.height / 2 } }
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
        let hx = TimelineGeometry.toolColumnWidth + 24
        var probes: [(String, CGPoint)] = []
        if let y = rowMid("V1") { probes.append(("menu-timeline-clip", at(g.x(for: RenderDemoProject.frames(160)), y))) }
        if let y = rowMid("A2") { probes.append(("menu-timeline-empty", at(g.x(for: RenderDemoProject.frames(200)), y))) }
        probes.append(("menu-timeline-ruler", at(g.x(for: RenderDemoProject.frames(300)), TimelineGeometry.rulerHeight / 2)))
        if let y = rowMid("V1") { probes.append(("menu-timeline-track-header-v1", at(hx, y))) }
        if let y = rowMid("A3") { probes.append(("menu-timeline-track-header-a3", at(hx, y))) }
        for (name, p) in probes {
            let items = probe(p) { _ in shot("shared-\(name).png") }
            if items.isEmpty { print("shared ui shot: \(name) no menu"); continue }
            write(name, items)
        }
        for panel in PanelID.allCases where panel != .timeline && panel != .audioMeter {
            c.shell.dock.show(panel)
            _ = c.frame(width: 2880, height: 1800)
            guard let group = c.shell.dock.groups.first(where: { $0.selected == panel }),
                  let i = group.panels.firstIndex(of: panel) else { continue }
            var points = [CGPoint(x: group.tabs[i].midX, y: group.tabs[i].midY)]
            let r = group.content
            for gy in 0..<10 { for gx in 0..<6 {
                points.append(CGPoint(x: r.minX + r.width * (CGFloat(gx) + 0.5) / 6, y: r.minY + r.height * (CGFloat(gy) + 0.5) / 10))
            } }
            var seen = Set<String>(), n = 0
            for p in points where n < 6 {
                let items = probe(p) { items in
                    let key = items.map(\.title).joined(separator: "|")
                    guard !seen.contains(key) else { return }
                    let first = items.first { $0.kind == .action }?.title ?? "menu"
                    let slug = first.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                        .split(separator: "-").joined(separator: "-").prefix(32)
                    shot("shared-menu-\(panel.rawValue)-\(n + 1)-\(slug).png")
                }
                let key = items.map(\.title).joined(separator: "|")
                guard !items.isEmpty, seen.insert(key).inserted else { continue }
                n += 1
                let first = items.first { $0.kind == .action }?.title ?? "menu"
                let slug = first.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                    .split(separator: "-").joined(separator: "-").prefix(32)
                write("menu-\(panel.rawValue)-\(n)-\(slug)", items)
            }
        }
    }

    /// `render-panels.sh` panel-graphics-layers: a new graphics clip with four layers (line, ellipse, rectangle, text "FOLGEN"),
    /// the text layer selected; the clip is removed again.
    static func graphicsLayersShot(_ c: SharedUIController, shot: (String) -> Void) async {
        let e = c.graphics.editor
        guard e.newGraphicsClip() != nil else { print("shared ui shot: no graphics clip"); return }
        e.addShape(.line); e.addShape(.ellipse); e.addShape(.rectangle); e.addText("FOLGEN")
        _ = c.shell.execute(.focusPanel(.graphics))
        _ = c.frame(width: 2880, height: 1800)
        try? await Task.sleep(for: .milliseconds(400)); c.shell.dock.focused = nil
        shot("shared-panel-graphics-layers.png")
        c.session.select(clips: [])
        _ = c.session.undo()
    }

    /// Effect Controls with the selected clip carrying several effect types (`render-panels.sh` panel-effectcontrols-mask /
    /// -stabilize): the panel maximized, then a rectangle mask, the Stabilizer mid-analysis, and a stack of effects.
    static func effectControlsSweep(_ c: SharedUIController, selected: UUID, shot: (String) -> Void) async {
        c.session.select(clips: [selected])
        _ = c.shell.execute(.focusPanel(.effectControls))
        c.shell.dock.toggleMaximize(.effectControls)
        func settle() async {
            _ = c.frame(width: 2880, height: 1800)
            try? await Task.sleep(for: .milliseconds(400)); c.shell.dock.focused = nil
        }
        let m = c.inspector.model
        if m.addMask(.rectangle) != nil { await settle(); shot("shared-ec-mask.png"); _ = c.session.undo() }
        let ask = c.session.onStabilizerNeedsAnalysis
        c.session.onStabilizerNeedsAnalysis = nil
        if c.session.addStabilizer(to: [selected]) {
            m.stabilizeRun = StabilizeRunState(clips: [selected], progress: 0.42)
            await settle(); shot("shared-ec-stabilize.png")
            m.stabilizeRun = nil
            _ = c.session.undo()
        }
        c.session.onStabilizerNeedsAnalysis = ask
        var added = 0
        for kind in [ClipEffect.gaussianBlurKind, ClipEffect.dropShadowKind, ClipEffect.cropKind, ClipEffect.lumaKeyKind,
                     ClipEffect.agedFilmKind, ClipEffect.roundedCornersKind] where c.session.addEffect(kind: kind, to: [selected]) { added += 1 }
        if added > 0 { await settle(); shot("shared-ec-effects.png") }
        for _ in 0..<added { _ = c.session.undo() }
        c.shell.dock.toggleMaximize(.effectControls)
        c.session.select(clips: [])
    }

    /// The Library states of `render-panels.sh` (`renderLibraryPopulated`): Overlays grid, SFX list, Music with sections
    /// (grid, list, audio item selected with its transport bar), Presets grid; same fixture folders.
    static func librarySweep(_ c: SharedUIController, shot: (String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shot-library-\(ProcessInfo.processInfo.processIdentifier)")
        RenderLibraryFixture.make(at: root)
        let model = c.library.model
        var ids: [String: UUID] = [:]
        for n in ["Music", "SFX", "Overlays", "B-Roll"] { ids[n] = await model.addFolder(url: root.appendingPathComponent(n)).id }
        _ = c.shell.execute(.focusPanel(.library))
        func settle(_ s: Double = 1.5) async {
            _ = c.frame(width: 2880, height: 1800)      // the first draw requests the thumbnails
            try? await Task.sleep(for: .seconds(s)); c.shell.dock.focused = nil
        }
        for (name, folder, mode) in [("grid", "Overlays", LibraryViewMode.grid), ("list", "SFX", .list)] {
            model.selection = .folder(ids[folder]!); model.viewMode = mode
            model.clearKindFilter(); if mode == .grid { model.toggleKind(.image) }
            await settle(); shot("shared-library-\(name).png")
        }
        for (name, mode, selectItem) in [("sections-grid", LibraryViewMode.grid, false), ("sections-list", .list, false),
                                         ("preview-audio", .list, true)] {
            model.selection = .folder(ids["Music"]!); model.viewMode = mode; model.clearKindFilter()
            if mode == .grid { model.toggleKind(.audio); model.toggleGroup("*") }
            if selectItem, let item = model.items.first(where: { $0.entry.name == "Morning Haze.wav" }) {
                model.selectItemForPreview(item)
                await settle(1.0)
                model.preview.pause(); model.preview.seek(to: 42)
            }
            await settle(); shot("shared-library-\(name).png")
            model.selectItemForPreview(nil)
            if mode == .grid { model.toggleGroup("*") }
        }
        model.selection = .presets(nil); model.viewMode = .grid; model.clearKindFilter()
        await settle(); shot("shared-library-presets-grid.png")
        try? FileManager.default.removeItem(at: root)
    }

    static func run(_ c: SharedUIController, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        c.setScale(2)
        // The built-in default layout, as `render-panels.sh` draws the AppKit UI (not the user's saved workspaces).
        c.shell.dock.save = { _ in }
        c.shell.dock.load(WorkspaceStore())
        c.shell.saveRecents = nil                // the demo project is not added to the user's recents
        var w = 2880, h = 1800
        let metal = MetalDrawListRenderer()
        func shot(_ name: String) {
            let t0 = Date()
            // The AppKit render shows a dialog's first field unfocused (the offscreen window is not key): no focus ring.
            c.shell.dialog?.form?.blur()
            _ = c.frame(width: w, height: h)        // the first layout settles the dock and the zoom
            let list = c.frame(width: w, height: h)
            let t1 = Date()
            // Every dock group's content rect (pt) at this shot, for cropping against the AppKit panel renders.
            let rects = c.shell.dock.groups.map { g in
                "\(name) | \(g.selected.rawValue) | \(Int(g.content.minX)) \(Int(g.content.minY)) \(Int(g.content.width)) \(Int(g.content.height))"
            }.joined(separator: "\n") + "\n" + c.shell.menuBar.controller.views.map { v in
                "\(name) | menu | \(Int(v.frame.minX)) \(Int(v.frame.minY)) \(Int(v.frame.width)) \(Int(v.frame.height))\n"
            }.joined()
            if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("rects.txt")) { h.seekToEndOfFile(); h.write(Data(rects.utf8)); try? h.close() }
            else { try? rects.write(to: dir.appendingPathComponent("rects.txt"), atomically: true, encoding: .utf8) }
            guard let img = CoreGraphicsRenderer.render(list, width: w, height: h, clear: c.screen.theme.divider, atlas: c.atlas) else {
                print("shared ui shot: \(name) render failed"); return
            }
            let t2 = Date()
            do { try img.pngData().write(to: dir.appendingPathComponent(name)) } catch { print("shared ui shot: \(error)") }
            // The live view's case: the atlas mask and its cells cached, the context reused (`SharedUIView.draw`).
            let warm = warmDraw(list, width: w, height: h, atlas: c.atlas)
            print(String(format: "shared ui shot: %@ %dx%d, %d quads, frame %.1f ms (2 layouts), CoreGraphics %.1f ms cold, %.1f ms warm",
                         name, w, h, list.quads.count, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, warm))
            metalShot(list, name: name, reference: img)
        }
        /// The live view's GPU path on the same list: `metal-<name>.png`, warm CPU (encode + wait) and GPU time, and the
        /// mean channel difference against the CoreGraphics shot.
        func metalShot(_ list: DrawList, name: String, reference: RGBAImage) {
            guard let metal else { return }
            metal.setAtlas(c.atlas)
            for (slot, img, gen) in c.imageSources() { metal.setImage(slot: slot, img, generation: gen) }
            _ = metal.render(list, width: w, height: h, clear: c.screen.theme.divider)
            let t = Date()
            guard let (img, gpu) = metal.render(list, width: w, height: h, clear: c.screen.theme.divider) else { return }
            let cpu = Date().timeIntervalSince(t) * 1000
            try? img.pngData().write(to: dir.appendingPathComponent("metal-" + name))
            var sum = 0
            for i in 0..<min(img.pixels.count, reference.pixels.count) where i % 4 != 3 {
                sum += abs(Int(img.pixels[i]) - Int(reference.pixels[i]))
            }
            // The live view's frame: encode into a private target, commit, wait (no readback).
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metal.pixelFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget]; d.storageMode = .private
            var live = 0.0
            if let target = metal.device.makeTexture(descriptor: d) {
                let t0 = Date()
                if let cb = metal.encode(list, into: target, clear: c.screen.theme.divider, punchesVideo: true) {
                    cb.commit(); cb.waitUntilCompleted()
                }
                live = Date().timeIntervalSince(t0) * 1000
            }
            print(String(format: "shared ui shot: %@ Metal %.1f ms live (encode + GPU wait), %.1f ms with readback, GPU %.2f ms, mean diff to CoreGraphics %.2f",
                         name, live, cpu, gpu, Double(sum) / Double(w * h * 3)))
        }
        _ = c.library      // its user folders load detached; the edit shot below waits for them
        // The Mac start window (1100x720 content) with the fixed recents of `render-panels.sh` (`window-start`) and its own
        // preferences suite, so the shot reads neither the user's recents nor the saved tab, sort and "open last project".
        do {
            let suite = UserDefaults(suiteName: "sq.shot.start") ?? .standard
            suite.removePersistentDomain(forName: "sq.shot.start")
            suite.set(true, forKey: ShellStartScreen.reopenLastKey)
            let now = Date()
            let rows: [(String, Double, Int, Int, Double, Double)] = [
                ("TikTok Schnitt-Tricks", 0, 1080, 1920, 30, 134), ("TCL C8L", -86_400, 3840, 2160, 25, 642),
                ("Studio Tour", -6 * 86_400, 1080, 1350, 29.97, 58), ("Old Draft", -20 * 86_400, 0, 0, 0, 0)]
            let saved = c.shell.recents
            c.shell.recents = RecentProjects(entries: rows.map {
                RecentProjects.Entry(path: "/Users/demo/Projects/\($0.0).sqproj", name: $0.0, opened: now.addingTimeInterval($0.1))
            })
            c.shell.startWindowSize = CGSize(width: 1100, height: 720)
            c.shell.showStart(defaults: suite)
            if let start = c.shell.startScreen {
                start.missing = ["/Users/demo/Projects/Old Draft.sqproj"]
                start.userTemplates = ["My TikTok", "Product Review"].map { n in
                    var t = ProjectTemplate.builtIn[0]; t.id = "user-" + n; t.name = n; return t
                }
                start.infos = Dictionary(uniqueKeysWithValues: rows.filter { $0.2 > 0 }.map {
                    ("/Users/demo/Projects/\($0.0).sqproj", StartProjectInfo(width: $0.2, height: $0.3, fps: $0.4, seconds: Int64($0.5)))
                })
            }
            let (sw, sh) = (w, h)
            w = 2200; h = 1440
            shot("shared-start-window.png")
            w = sw; h = sh
            c.shell.startWindowSize = nil
            c.shell.hideStart()
            c.shell.recents = saved
        }
        c.shell.showStart(defaults: .standard)
        // The card facts (size, length: the badges and the "1080 × 1920" line) load detached; the shot reads them here.
        if let start = c.shell.startScreen {
            start.infos = StartProjectInfo.read(c.shell.recents.entries.map(\.path).filter { !start.missing.contains($0) })
        }
        shot("shared-start.png")
        do {
            let built = try RenderDemoProject.make()
            // Named after the project, so the title bar reads as in the AppKit harness.
            let url = dir.appendingPathComponent("\(built.project.name).sqproj")
            try? FileManager.default.removeItem(at: url)
            try ProjectFile.write(built.project, to: url)
            Task { @MainActor in
                await c.shell.openProject(at: url)
                // As `RenderDemoProject.load`: the tabs "Main | Combined 01" with Main active. The AppKit harness has no file on
                // disk (no "Edited just now" after the name), so the demo file goes once it is open.
                let ids = built.project.timelines.map(\.id)
                for id in ids.reversed() { c.session.openSequenceTab(id) }
                c.session.moveSequenceTab(root: ids[0], to: 0)
                try? FileManager.default.removeItem(at: url)
                c.session.select(clips: [built.selected])
                c.session.seek(to: built.playhead)
                c.projectModel.refreshOffline()   // the open's offline check runs detached; the shot waits for none
                // As `RenderPanels.openProjectBins`: Footage and Audio open, C2156.MP4 selected.
                for name in ["Music – Late Sun.mp3", "C2156.MP4"] {
                    if let m = c.session.project.media.first(where: { $0.name == name }) { c.projectList.reveal(media: m.id) }
                }
                try? await Task.sleep(for: .seconds(1.5))   // the Library's folder restore and first scan
                // The AppKit window shot shows Effect Controls selected in its group and no panel focused.
                c.shell.dock.select(.effectControls)
                c.shell.dock.focused = nil
                shot("shared-edit.png")
                if ProcessInfo.processInfo.environment["SQ_SHOT_ONLY"] == "keys" {
                    await keySweep(c)
                    exit(0)
                }
                if ProcessInfo.processInfo.environment["SQ_SHOT_ONLY"] == "menu" {
                    await menuSweep(c, into: dir, shot: shot)
                    exit(0)
                }
                if ProcessInfo.processInfo.environment["SQ_SHOT_ONLY"] == "graphics" {
                    await graphicsLayersShot(c, shot: shot)
                    exit(0)
                }
                if ProcessInfo.processInfo.environment["SQ_SHOT_ONLY"] == "alerts-menu" {
                    await alertSweep(c, selected: built.selected, shot: { _ in })
                    await menuSweep(c, into: dir, shot: shot)
                    exit(0)
                }
                if ProcessInfo.processInfo.environment["SQ_SHOT_ONLY"] == "color" {
                    await colorSweep(c, resize: { w = $0; h = $1 }, shot: shot)
                    exit(0)
                }
                // The Text panel's tabs (`render-panels.sh` panel-text: Transcribe first, idle).
                _ = c.shell.execute(.focusPanel(.text))
                try? await Task.sleep(for: .milliseconds(300))
                c.shell.dock.focused = nil   // the AppKit render shows the panel unfocused (quiet underline)
                for t in c.captions.panel.tabs {
                    c.captions.panel.select(t)
                    try? await Task.sleep(for: .milliseconds(200))
                    shot("shared-text-\(t).png")
                }
                c.captions.panel.select(c.captions.panel.tabs[0])
                c.shell.dock.setPage(.color)
                try? await Task.sleep(for: .seconds(2))
                shot("shared-color.png")
                _ = c.shell.execute(.focusPanel(.scopes))
                try? await Task.sleep(for: .milliseconds(300))
                shot("shared-scopes.png")
                c.shell.dock.setPage(.edit)
                // The menu bar as text (`render-panels.sh` menu-bar-*.txt): `diff` the two for the parity audit.
                for menu in c.shell.menuBar.refresh?() ?? c.shell.menuBar.menus {
                    let slug = menu.title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                        .split(separator: "-").joined(separator: "-")
                    try? MenuOutline.text(menu.items).write(to: dir.appendingPathComponent("shared-menu-bar-\(slug).txt"), atomically: true, encoding: .utf8)
                }
                _ = c.shell.execute(.focusPanel(.markerList))
                try? await Task.sleep(for: .milliseconds(300))
                shot("shared-markerlist.png")
                // Every other dock panel once, for the AppKit comparison (`render-panels.sh` panel-*).
                for panel in [PanelID.graphics, .keystones, .effects, .sourceMonitor, .project, .library, .effectControls] {
                    _ = c.shell.execute(.focusPanel(panel))
                    try? await Task.sleep(for: .milliseconds(300))
                    c.shell.dock.focused = nil
                    shot("shared-panel-\(panel.rawValue).png")
                }
                await graphicsLayersShot(c, shot: shot)
                await librarySweep(c, shot: shot)
                await effectControlsSweep(c, selected: built.selected, shot: shot)
                Task { @MainActor in await c.shell.showAbout() }   // closed by the next dialog's Return press below
                try? await Task.sleep(for: .milliseconds(400))
                shot("shared-dialog-about.png")
                c.shell.menuBar.controller.dismiss()
                if let title = c.shell.menuBar.titleFrames.first {
                    c.handle(.mouseDown(x: Float(title.midX * 2), y: Float(title.midY * 2), modifiers: []))
                    c.handle(.mouseUp(x: Float(title.midX * 2), y: Float(title.midY * 2)))
                    shot("shared-menu.png")
                }
                c.shell.menuBar.controller.dismiss()
                // The fixture of `render-panels.sh` (`window-settings-editing`): a Blur effect and a Cross Dissolve default,
                // in memory so the user's own defaults file stays out of the picture.
                let lib = EffectDefaultsLibrary(fileURL: nil)
                if let blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind) {
                    lib.update {
                        $0.effects[ClipEffect.gaussianBlurKind] = blur
                        $0.transitions[TransitionKind.crossDissolve.rawValue] = TransitionPreset(kind: .crossDissolve, duration: Time(1, 2))
                    }
                }
                c.shell.effectDefaultsLibrary = lib
                Task { @MainActor in await c.shell.showPreferences() }   // stays open: the shot quits under it
                try? await Task.sleep(for: .milliseconds(200))
                shot("shared-preferences.png")
                // Every page, as `render-panels.sh` draws `window-settings-<page>`.
                for page in ShellPreferences.Page.allCases.dropFirst() {
                    c.shell.dialog?.form?.onChange?("page", .index(page.rawValue))
                    try? await Task.sleep(for: .milliseconds(100))
                    shot("shared-preferences-\(page).png")
                }
                // The dialogs `render-panels.sh` draws as `dialog-*` (Mac parity audit): each opens, is shot, and is canceled.
                let dialogs: [(String, EditorCommand)] = [
                    ("export", .export), ("new-project", .newProject), ("new-sequence", .newSequence),
                    ("sequence-settings", .sequenceSettings), ("speed", .speedDuration), ("audio-gain", .audioGain),
                    ("project-notes", .projectNotes), ("go-to-timecode", .goToTimecode),
                    ("check-cuts", .checkCuts), ("remove-silences", .removeSilences),
                    ("tone", .newTone), ("find", .find), ("marker", .addAndEditMarker),
                    ("punch-in-cuts", .punchInCuts), ("match-loudness", .matchLoudness), ("paste-settings", .pasteAttributes),
                ]
                // Paste Settings: a video and an audio clip are copied and two others selected, so all five groups show
                // (`render-panels.sh` passes every group).
                let demoClips = c.session.activeTimeline?.tracks.flatMap(\.clips) ?? []
                let videos = demoClips.filter { $0.kind == .video }, audios = demoClips.filter { $0.kind == .audio }
                let pasteTargets = Array(videos.dropFirst().prefix(1) + audios.dropFirst().prefix(1)).map(\.id)
                // Remove Silences reads a decoded waveform and the demo media is offline: a synthetic one stands in.
                // The Mac render opens Remove Silences with the standard settings, not the ones this machine remembered.
                UserDefaults.standard.setVolatileDomain(["sq.silence.thresholdDB": -35, "sq.silence.minMs": 350, "sq.silence.padMs": 70],
                                                        forName: UserDefaults.argumentDomain)
                let realWaveform = c.shell.waveform
                c.shell.waveform = { _ in SyntheticWaveform.speech }
                defer { c.shell.waveform = realWaveform }
                let silenceClip = audios.first { $0.name == "C2156.MP4" }?.id
                for (name, command) in dialogs {
                    if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                    try? await Task.sleep(for: .milliseconds(100))
                    // Find with the timeline focused opens the caption search; the Mac shot is the Project panel's dialog.
                    if command == .find { _ = c.shell.execute(.focusPanel(.project)) }
                    c.session.select(clips: [built.selected])   // Punch-In Cuts acts on the selected clip
                    if command == .removeSilences, let silenceClip { c.session.select(clips: [silenceClip]) }
                    if command == .pasteAttributes {
                        c.session.select(clips: Set((videos.prefix(1) + audios.prefix(1)).map(\.id)))
                        _ = c.session.copySelection()
                        c.session.select(clips: Set(pasteTargets))
                    }
                    guard c.shell.execute(command) else { print("shared ui shot: \(name) not available"); continue }
                    try? await Task.sleep(for: .milliseconds(400))
                    shot("shared-dialog-\(name).png")
                }
                let windowDialogs: [(String, ShellAction)] = [
                    ("save-workspace", .saveWorkspaceAs), ("rename-workspace", .renameWorkspace),
                    ("delete-workspace", .deleteWorkspace), ("history", .history),
                    ("change-format", .changeFormat), ("new-sequence-from-template", .newSequenceFromTemplate),
                    ("save-sequence-template", .saveSequenceAsTemplate),
                ]
                for (name, action) in windowDialogs {
                    if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                    try? await Task.sleep(for: .milliseconds(100))
                    // Rename and Delete need an own workspace selected (`render-panels.sh` saves "My Layout" first).
                    if name == "rename-workspace" { _ = c.shell.dock.saveAsNew("My Layout") }
                    c.shell.perform(action)
                    try? await Task.sleep(for: .milliseconds(400))
                    shot("shared-dialog-\(name).png")
                    if name == "delete-workspace" {
                        if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                        _ = c.shell.dock.deleteCurrent()
                    }
                }
                // Collect on a project that was never saved: the Mac's "Save the project first" alert (`dialog-collect`).
                if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                try? await Task.sleep(for: .milliseconds(100))
                c.collectFiles(unsaved: true)
                try? await Task.sleep(for: .milliseconds(400))
                shot("shared-dialog-collect.png")
                // The timeline's editor sheets (`render-panels.sh` dialog-save-preset, -track-mix, -sequence-volume,
                // -color-matte, -transition-preset).
                // The demo has no transition: one Cross Dissolve on the first cut of V1 (`render-panels.sh` draws the sheet bare).
                if let v1 = c.session.activeTimeline?.tracks.first(where: { $0.kind == .video }), v1.clips.count > 1 {
                    let cut = v1.clips.sorted { $0.start < $1.start }
                    c.session.addTransition(kind: .crossDissolve, track: v1.id, point: .cut(outgoing: cut[0].id, incoming: cut[1].id), alignment: .center)
                }
                let tracks = c.session.activeTimeline?.tracks ?? []
                var editors: [(String, TimelineEditorRequest)] = [("save-preset", .saveClipPreset), ("sequence-volume", .sequenceVolume),
                                                                  ("color-matte", .newColorMatte)]
                if let a = tracks.first(where: { $0.kind == .audio }) { editors.insert(("track-mix", .trackMix(a.id)), at: 1) }
                if let t = tracks.lazy.flatMap(\.transitions).first { editors.append(("transition-preset", .saveTransitionPreset(t.id))) }
                // Create Angles Clip: the first three V1 clips selected (`render-panels.sh` dialog-create-angles).
                editors.append(("create-angles", .createAnglesClip))
                for (name, request) in editors {
                    if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                    try? await Task.sleep(for: .milliseconds(100))
                    c.session.select(clips: [built.selected])
                    if name == "create-angles", let v1 = tracks.first(where: { $0.kind == .video }) {
                        c.session.select(clips: Set(v1.clips.sorted { $0.start < $1.start }.prefix(3).map(\.id)))
                    }
                    _ = c.editorDialogs.open(request)
                    try? await Task.sleep(for: .milliseconds(400))
                    guard c.shell.dialog != nil else { print("shared ui shot: \(name) not available"); continue }
                    // The Mac render names the preset "My Look" (PresetSaveSheet defaultName).
                    if name == "save-preset" { c.shell.dialog?.form?.commitEditing(); c.shell.dialog?.form?.set("name", .text("My Look")); try? await Task.sleep(for: .milliseconds(100)) }
                    if name == "transition-preset" { c.shell.dialog?.form?.commitEditing(); c.shell.dialog?.form?.set("name", .text("My Transition")); try? await Task.sleep(for: .milliseconds(100)) }
                    shot("shared-dialog-\(name).png")
                }
                if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
                try? await Task.sleep(for: .milliseconds(100))
                await alertSweep(c, selected: built.selected, shot: shot)
                await menuSweep(c, into: dir, shot: shot)
                c.shell.showShortcuts()
                try? await Task.sleep(for: .milliseconds(200))
                shot("shared-shortcuts.png")
                exit(0)
            }
        } catch {
            print("shared ui shot: demo project: \(error)")
            exit(1)
        }
    }
}
