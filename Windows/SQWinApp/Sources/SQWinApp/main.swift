import CSQWinApp
import Foundation
import SQAnalysis
import SQCore
import SQDrawEditor
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQExport
import SQGPUKernels
import SQMediaFFmpeg
import Synchronization
import WinSDK

// Sequence Studio for Windows, first runnable app (the Windows port plan, "App status").
//   SQWinApp [project.sqproj]                    the editor window
//   --make-sample <media> <out.sqproj> [--title] [--layers N]  the two-shot test project for a media file
//                                                (title on V2, N picture-in-picture copies above)
//   --render-frame N --out <file>                headless: frame N of the sequence as raw RGBA (+ .png)
//   --ui-shot <file.png> [--size WxH] [--frame N] headless: the editor through D3D12 and the software renderer, diff
//   --edit-test                                  headless: select, move, razor, delete, undo, redo through the input path
//   --export-test <dir>                          headless: H.264 and a half-size PNG sequence of the sequence, timed
//   --play-test S [--play-from T] [--play-after W] window: plays S seconds (from T s, W s after launch, default 0.5),
//                                                prints shown/dropped frames, audio
//                                                stats and per-stage timings (WinPlayStats)
//   --seconds S, --shot <file.png>               window: close after S seconds, screenshot after the first second
//   --dialog-test [mta]                          window: opens the folder dialog, checks the window keeps answering,
//                                                closes it (mta: the UI thread in the multithreaded apartment)
//   --chrome-test <dir>                          window: our caption at four sizes, page switch, Workspace popup,
//                                                Maximize; pc-chrome-*.png screenshots into <dir>
_ = sq_detach_own_console()
setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
// The UI thread is a single-threaded apartment before any COM user: WASAPI's CoInitializeEx(MULTITHREADED) on this
// thread otherwise made it MTA, and the folder dialog then blocked it in a non-pumping wait ("Not responding").
let dialogTestMTA = value("--dialog-test") == "mta"
if dialogTestMTA { _ = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue)) } else { _ = sq_com_init_ui_thread() }
func fail(_ m: String) -> Never { print("error: \(m)"); exit(1) }
/// User + kernel CPU seconds of this process (all threads), for the play and export tests' CPU use.
func processCPUSeconds() -> Double {
    var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
    guard GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user) else { return 0 }
    func s(_ f: FILETIME) -> Double { Double((UInt64(f.dwHighDateTime) << 32) | UInt64(f.dwLowDateTime)) / 1e7 }
    return s(kernel) + s(user)
}

if let i = args.firstIndex(of: "--make-sample") {
    guard i + 2 < args.count else { fail("--make-sample <media> <out.sqproj>") }
    let media = args[i + 1], out = args[i + 2]
    do {
        let d = try FFmpegDemuxer(url: URL(fileURLWithPath: media))
        let info = d.trackInfo
        let size = (try FileManager.default.attributesOfItem(atPath: media)[.size] as? NSNumber)?.int64Value ?? 0
        let project = SampleProject.make(mediaPath: media, fileSize: size, width: info.width, height: info.height,
                                         frameDuration: info.nominalFrameDuration, frames: Int64(d.index.count),
                                         title: args.contains("--title") ? try SampleTitle.ref() : nil,
                                         layers: value("--layers").flatMap { Int($0) } ?? 0)
        try ProjectFile.write(project, to: URL(fileURLWithPath: out))
        print("sample project: \(out) (\(info.width)x\(info.height), \(d.index.count) frames)")
        exit(0)
    } catch { fail("make sample: \(error)") }
}

if let media = value("--magic-test") {
    // Headless, no project: Magic Mask on a clip (WinMagicBench.swift).
    let dir = value("--out") ?? "magic-test"
    let xy = (value("--point") ?? "0.5,0.5").split(separator: ",").compactMap { Double($0) }
    let ok = Mutex(false)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        ok.withLock { $0 = false }
        let r = await WinMagicBench.run(media: media, directory: dir, point: Vec2(xy.first ?? 0.5, xy.count > 1 ? xy[1] : 0.5),
                                        frames: value("--frames").flatMap(Int.init) ?? 30, from: value("--from").flatMap(Int.init) ?? 0)
        ok.withLock { $0 = r }
        done.signal()
    }
    done.wait()
    exit(ok.withLock { $0 } ? 0 : 1)
}
let projectPath = value("--project").map { ProjectFile.launchProjectPath($0) ?? $0 } ?? ProjectFile.launchProjectPath(in: Array(args.dropFirst()))
let headless = args.contains("--render-frame") || args.contains("--ui-shot") || args.contains("--edit-test")
    || args.contains("--export-test") || args.contains("--proxy-test")
if let d = value("--proxy-test") {
    // A fresh cache of its own, so generation is timed and the user's proxies stay untouched.
    let dir = URL(fileURLWithPath: d, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    WinProxies.directoryOverride = dir
    WinProxies.automatic = false
}
// Without a project the window starts on an untitled one and offers crash recovery (the Mac launch path).
let openedURL = projectPath.map { URL(fileURLWithPath: $0) }
guard openedURL != nil || !headless else { fail("no project (.sqproj) given") }
let project: Project
if let openedURL {
    do { project = try ProjectFile.read(from: openedURL) } catch { fail("open \(openedURL.path): \(error)") }
} else { project = EditorSession.makeUntitled() }
let app: AppController
do { app = try AppController(project: project, fileURL: openedURL, audio: !headless) } catch { fail("\(error)") }
// The window's drags read the keys held now (Alt mid-drag); the headless input tests keep the keys of the press.
if !headless { app.timelinePanel.liveModifiers = { keyModifiers() } }
if !headless { app.projectList.liveModifiers = { keyModifiers() } }      // Shift-scrub with Hover Scrub off
let tl = app.timeline
print("project: \(project.name), sequence \(tl.name) \(tl.format.width)x\(tl.format.height), "
      + "\(tl.tracks.count) tracks, \(tl.tracks.reduce(0) { $0 + $1.clips.count }) clips")

func settle(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// MARK: Headless: one sequence frame

if let n = value("--render-frame").flatMap(Int.init) {
    let out = value("--out") ?? "frame.rgba"
    app.session.seek(to: tl.frameDuration * Int64(n))
    guard app.engine.waitForPicture(), let p = app.engine.picture else { fail("frame \(n) not decoded: \(app.engine.lastError ?? "?")") }
    do {
        let r = try UIRenderer(hwnd: nil, width: p.width, height: p.height, device: app.engine.gpu)
        r.setPicture(p, generation: app.engine.pictureGeneration)
        var list = DrawList(width: Float(p.width), height: Float(p.height))
        list.video(DrawRect(x: 0, y: 0, w: Float(p.width), h: Float(p.height)))
        guard let img = r.render(list, atlas: app.atlas, clear: .black, readback: true) else { fail("render") }
        try Data(img.pixels).write(to: URL(fileURLWithPath: out))
        try PNGWriter.write(img, to: URL(fileURLWithPath: out + ".png"))
        print("frame \(n): \(p.width)x\(p.height) \(p.fullRange ? "full" : "video") range, adapter \(r.adapter) -> \(out)")
        // The export frame source renders the same frame on its own decoders and compositor: it must match the monitor.
        var made: Result<(WinTimelineFrameSource, NV12Picture)?, any Error>?
        Task { @MainActor in
            do {
                guard let src = try await app.engine.makeFrameSource() else { made = .success(nil); return }
                made = .success((src, try await src.rgba(at: n)))
            } catch { made = .failure(error) }
        }
        while made == nil { settle(0.01) }
        if let pair = try made!.get(), let shown = app.engine.readablePicture() {
            let (src, e) = pair
            let d = zip(e.bytes, shown.bytes).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
            print("frame \(n): export frame source \(e.width)x\(e.height), \(src.frameCount) frames, max diff to the monitor \(d)"
                  + (e.bytes.count == shown.bytes.count && d <= 1 ? "" : " FAIL"))
            // Scopes: the GPU passes on the linear composite vs the CPU binning of the 8-bit readback (the old path).
            _ = app.engine.scopeCounts(pixelStride: 2)        // first call makes the pipelines and the counts buffer
            let t0 = Date()
            if let g = app.engine.scopeCounts(pixelStride: 2) {
                let gpuMs = Date().timeIntervalSince(t0) * 1000, t1 = Date()
                let c = ScopeBinning.compute(rgba: shown.bytes, width: shown.width, height: shown.height, layout: ScopeLayout(),
                                             pixelStride: 2)
                let cpuMs = Date().timeIntervalSince(t1) * 1000
                func meanLevel(_ s: ScopeCounts) -> Double {
                    let l = s.layout
                    var sum = 0.0, n = 0.0
                    for row in 0..<l.waveformLevels {
                        for col in 0..<l.waveformWidth {
                            let k = Double(s.waveformLuma[row * l.waveformWidth + col]); sum += k * Double(l.waveformLevels - 1 - row); n += k
                        }
                    }
                    return n == 0 ? 0 : sum / n
                }
                let dl = abs(meanLevel(g) - meanLevel(c))
                print("frame \(n): scopes on the GPU \(String(format: "%.2f", gpuMs)) ms, CPU binning of the readback "
                      + "\(String(format: "%.2f", cpuMs)) ms, mean luma level diff \(String(format: "%.2f", dl)) of 256"
                      + (dl < 1.5 && g.vectorscope.reduce(0, +) == c.vectorscope.reduce(0, +) ? "" : " FAIL"))
            } else { print("frame \(n): scopes on the GPU unavailable FAIL") }
        }
    } catch { fail("\(error)") }
    exit(0)
}

// MARK: Headless: proxies (generation speed, scrubbing and playing from the original vs from proxies)

if value("--proxy-test") != nil {
    let e = app.engine, proxies = WinProxies.shared
    let end = tl.tracks.map(\.end).max() ?? .zero
    let frames = Int(end.value * Int64(tl.frameDuration.timescale) / max(1, Int64(end.timescale) * tl.frameDuration.value))
    func scrub(_ label: String, offset: Int) {
        e.beginScrub()
        var ms: [Double] = [], proxied = 0
        for k in 0..<30 {
            let f = (k * 97 + offset) % max(1, frames)
            let t0 = Date()
            e.scrub(to: tl.frameDuration * Int64(f))
            guard e.waitForPicture() else { print("proxy test: scrub frame \(f) not shown: \(e.lastError ?? "no error") FAIL"); continue }
            ms.append(Date().timeIntervalSince(t0) * 1000)
            if e.showsProxy { proxied += 1 }
        }
        e.endScrub()
        _ = e.waitForPicture()
        let mean = ms.reduce(0, +) / Double(max(1, ms.count))
        print("proxy test: scrub \(label): \(ms.count) jumps, mean \(String(format: "%.1f", mean)) ms, max "
              + "\(String(format: "%.1f", ms.max() ?? 0)) ms, \(proxied) from proxies; paused frame after the scrub "
              + (e.showsProxy ? "from a proxy FAIL" : "from the original"))
    }
    func play(_ label: String) {
        e.seek(to: .zero)
        _ = e.waitForPicture()
        let cpu0 = processCPUSeconds(), t0 = Date()
        e.play(PlaybackRate(1))
        while Date().timeIntervalSince(t0) < 6 { e.tick(); settle(1.0 / 60) }
        let shown = e.shownFrames, skipped = e.skippedFrames, proxied = e.showsProxy
        e.pause()
        let cpu = processCPUSeconds() - cpu0, wall = Date().timeIntervalSince(t0)
        print("proxy test: play \(label): \(shown) frames shown, \(skipped) dropped in 6 s, CPU "
              + "\(String(format: "%.0f", cpu / wall * 100)) % of one core" + (proxied ? ", last frame from a proxy" : ""))
    }
    // The session looked at the media when the project opened, before any frame was shown (`ProxyIntake`).
    let opened = Date()
    while !proxies.intake.pending.isEmpty, Date().timeIntervalSince(opened) < 30 { settle(0.01) }
    let seen = Set(e.mediaPaths.values).filter { proxies.decisions[$0] != nil }.count
    print("proxy test: media checked at open: \(seen) of \(Set(e.mediaPaths.values).count) files, "
          + "\(String(format: "%.2f", Date().timeIntervalSince(opened))) s after the session started")
    e.usesProxies = false
    play("original")
    scrub("original", offset: 0)
    let paths = Array(Set(e.mediaPaths.values)).sorted()
    for path in paths {
        print("proxy test: Auto rule for \(URL(fileURLWithPath: path).lastPathComponent): "
              + "\(proxies.decisions[path].map { "\($0)" } ?? "not seen") (\(ProcessInfo.processInfo.physicalMemory >> 30) GB, "
              + "\(ProcessInfo.processInfo.activeProcessorCount) cores)")
        let t0 = Date(), cpu0 = processCPUSeconds()
        var result: Result<Void, any Error>?
        Task { @MainActor in
            do { try await proxies.generate(path, kind: .proxyHalf); result = .success(()) } catch { result = .failure(error) }
        }
        while result == nil { settle(0.01) }
        if case .failure(let err) = result! { fail("proxy test: \(err)") }
        let s = Date().timeIntervalSince(t0)
        let src = try? WinMediaSource(path: path, media: UUID())
        let seconds = src.map { Double($0.frameCount) * Double($0.info.nominalFrameDuration.value) / Double($0.info.nominalFrameDuration.timescale) } ?? 0
        print("proxy test: half proxy of \(URL(fileURLWithPath: path).lastPathComponent) in \(String(format: "%.2f", s)) s "
              + "(\(String(format: "%.1f", seconds / max(s, 0.001)))x real time), CPU \(String(format: "%.2f", processCPUSeconds() - cpu0)) s")
    }
    e.usesProxies = true
    proxies.playbackOverride = false
    scrub("proxies", offset: 13)
    play("original, proxies for scrubbing only")
    proxies.playbackOverride = true
    play("proxies")
    // Preferences > Cache Folder: the proxies are copied and read from the new folder at once, without a relaunch.
    let movedTo = proxies.cache.directory.deletingLastPathComponent()
        .appendingPathComponent(proxies.cache.directory.lastPathComponent + "-moved", isDirectory: true)
    try? FileManager.default.removeItem(at: movedTo)
    let tMove = Date()
    proxies.moveCache(from: proxies.cache.directory, to: movedTo)
    while proxies.isMoving, Date().timeIntervalSince(tMove) < 60 { settle(0.01) }
    while !proxies.intake.pending.isEmpty, Date().timeIntervalSince(tMove) < 60 { settle(0.01) }
    let inNew = paths.filter {
        proxies.lookup($0, context: .scrubbing, hardwareDecode: true)?.url.deletingLastPathComponent().standardizedFileURL
            == movedTo.standardizedFileURL
    }.count
    scrub("after the cache folder moved", offset: 29)
    print("proxy test: cache folder moved in \(String(format: "%.2f", Date().timeIntervalSince(tMove))) s: \(inNew) of "
          + "\(paths.count) proxies read from the new folder" + (inNew == paths.count ? "" : " FAIL"))
    exit(0)
}

// MARK: Headless: export speed (H.264 at the sequence size, a PNG sequence at half size)

if let dir = value("--export-test") {
    let folder = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let seconds = Double(tl.duration.value) / Double(tl.duration.timescale)
    func run(_ name: String, _ settings: ExportSettings, to url: URL) -> Double? {
        var done: Result<Void, any Error>?
        let t0 = Date(), cpu0 = processCPUSeconds()
        Task { @MainActor in
            do {
                guard let make = app.shell.exportSources, let id = app.session.activeTimelineID else { throw AppError("no export") }
                let sources = try await make(id, settings)
                try await FFmpegExportEncoder().export(video: sources.video, audio: sources.audio, settings: settings, to: url) { _ in }
                done = .success(())
            } catch { done = .failure(error) }
        }
        while done == nil { settle(0.01) }
        let wall = Date().timeIntervalSince(t0)
        if case .failure(let e) = done { print("export test: \(name) FAIL \(e)"); return nil }
        let cpu = processCPUSeconds() - cpu0
        print(String(format: "export test: %@ %.2f s for %.2f s of sequence (%.2fx real time), CPU %.2f s (%.0f %% of one core)",
                     name, wall, seconds, seconds / wall, cpu, cpu / wall * 100))
        return wall
    }
    var video = ExportSettings()
    video.video.width = tl.format.width; video.video.height = tl.format.height; video.video.frameDuration = tl.frameDuration
    let h264 = run("H.264 \(tl.format.width)x\(tl.format.height)", video, to: folder.appendingPathComponent("export-test.mp4"))
    var stills = video
    stills.video.width = tl.format.width / 2; stills.video.height = tl.format.height / 2
    stills.frameOutput = .sequence(.png)
    stills.audio.enabled = false
    let pngs = folder.appendingPathComponent("export-test-png")
    try? FileManager.default.removeItem(at: pngs)
    let png = run("PNG sequence \(stills.video.width)x\(stills.video.height)", stills, to: pngs)
    // Every still has the asked size (PNG IHDR width / height).
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: pngs.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    let sized = files.prefix(3).allSatisfy { name in
        guard let d = try? Data(contentsOf: pngs.appendingPathComponent(name)), d.count > 24 else { return false }
        let be = { (o: Int) in d[o..<(o + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return be(16) == stills.video.width && be(20) == stills.video.height
    }
    print("export test: \(files.count) stills, size \(sized ? "ok" : "FAIL")")
    exit(h264 != nil && png != nil && sized && !files.isEmpty ? 0 : 1)
}

// MARK: Headless: editor screenshot, GPU vs software renderer

func diff(_ a: RGBAImage, _ b: RGBAImage) -> (mean: Double, max: Int, over2: Int) {
    var sum = 0, mx = 0, over = 0
    for i in 0..<a.pixels.count where i % 4 != 3 {
        let d = abs(Int(a.pixels[i]) - Int(b.pixels[i]))
        sum += d; mx = max(mx, d); if d > 2 { over += 1 }
    }
    return (Double(sum) / Double(a.pixels.count / 4 * 3), mx, over)
}

if let shot = value("--ui-shot") {
    let dims = (value("--size") ?? "1440x900").split(separator: "x").compactMap { Int($0) }
    let (w, h) = (dims.first ?? 1440, dims.last ?? 900)
    if let n = value("--frame").flatMap(Int.init) { app.session.seek(to: tl.frameDuration * Int64(n)) }
    if value("--page") == "color" { app.shell.dock.setPage(.color) }      // the Color page (win-app.sh SQ_UI_PAGE=color)
    _ = app.engine.waitForPicture()
    do {
        let r = try UIRenderer(hwnd: nil, width: w, height: h, device: app.engine.gpu)
        r.setPicture(app.engine.picture, generation: app.engine.pictureGeneration)
        let list = app.frame(width: w, height: h)
        for (s, img, g) in app.meters.images { r.setImage(s, img, generation: g) }
        if let t = winTimelineMedia?.thumbnailImage { r.setImage(t.0, t.1, generation: t.2) }
        if let t = app.captions.templateImage { r.setImage(t.0, t.1, generation: t.2) }
        if let t = app.effects.tileImage { r.setImage(t.0, t.1, generation: t.2) }
        guard let gpu = r.render(list, atlas: app.atlas, clear: app.screen.theme.divider, readback: true) else { fail("render") }
        try PNGWriter.write(gpu, to: URL(fileURLWithPath: shot))
        // The software reference without the picture quad's content (it has no NV12 path): compare the UI only.
        let noPicture = app.screen.draw(app.snapshot(), atlas: app.atlas, hasPicture: false)
        let gpuUI = r.render(noPicture, atlas: app.atlas, clear: app.screen.theme.divider, readback: true)!
        let cpu = SoftwareRenderer.render(noPicture, width: w, height: h, clear: app.screen.theme.divider, atlas: app.atlas)
        try PNGWriter.write(cpu, to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-cpu.png")))
        try Data(cpu.pixels).write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-cpu.rgba")))
        try Data(gpuUI.pixels).write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-gpu.rgba")))
        let d = diff(gpuUI, cpu)
        print("ui shot \(w)x\(h): \(list.quads.count) quads, adapter \(r.adapter)")
        // Redraw cost on the CPU (no GPU submit): the whole frame, and the timeline panel's draw list alone.
        let n = 30, t0 = Date()
        for _ in 0..<n { _ = app.frame(width: w, height: h) }
        let frameMs = Date().timeIntervalSince(t0) * 1000 / Double(n)
        var tlList = DrawList(width: Float(w), height: Float(h))
        let t1 = Date()
        for _ in 0..<n { tlList = DrawList(width: Float(w), height: Float(h)); app.timelinePanel.draw(into: &tlList, atlas: app.atlas) }
        let timelineMs = Date().timeIntervalSince(t1) * 1000 / Double(n)
        print(String(format: "ui redraw: frame %.2f ms, timeline %.2f ms (%d quads)", frameMs, timelineMs, tlList.quads.count))
        // The other big parts alone (laid out by the frames above), to find a slow panel.
        func partMs(_ body: (inout Canvas) -> Void) -> (Double, Int) {
            var c = Canvas(width: Float(w), height: Float(h), atlas: app.atlas, scale: app.screen.theme.scale)
            let t = Date()
            for _ in 0..<n { c = Canvas(width: Float(w), height: Float(h), atlas: app.atlas, scale: app.screen.theme.scale); body(&c) }
            return (Date().timeIntervalSince(t) * 1000 / Double(n), c.list.quads.count)
        }
        let theme = app.screen.theme
        let parts: [(String, (Double, Int))] = [
            ("dock", partMs { app.shell.dock.draw(&$0, theme: theme) }),
            ("color", partMs { app.colorPage.draw(&$0, theme: theme) }),
            ("meters+scopes", partMs { app.meters.draw(&$0, theme: theme) }),
            ("inspector", partMs { app.inspector.draw(&$0, theme: theme) }),
            ("screen", partMs { _ = app.screen.draw(app.snapshot(), atlas: app.atlas, hasPicture: false); _ = $0 }),
            ("snapshot", partMs { _ = app.snapshot(); _ = $0 }),
            ("layoutDock", partMs { _ = app.layoutDock(width: w, height: h, scale: theme.scale); _ = $0 }),
            ("colorLayout", partMs { _ in app.colorPage.layout() }),
            ("stepWindow", partMs { _ in app.colorPage.refreshStepWindow(panel: app.monitor.panel, isEditingText: app.monitor.text.isEditing) }),
            ("monitors", partMs { app.monitors.draw(&$0, card: app.screen.monitor, scale: theme.scale, isPlaying: false, theme: theme) }),
            ("project", partMs { app.projectList.draw(&$0, theme: theme) }),
            ("graphics", partMs { app.graphics.draw(&$0, theme: theme) }),
            ("captions", partMs { app.captions.draw(&$0, theme: theme) }),
            ("library", partMs { app.drawLibraryPanels(&$0, scale: theme.scale, theme: theme) }),
            ("toolStrip", partMs { app.drawToolStrip(&$0) }),
            ("bar", partMs { app.shell.drawBar(&$0, theme: theme) }),
            ("overlays", partMs { app.shell.drawOverlays(&$0, theme: theme) }),
            ("pointer", partMs { _ in WinPointer.frame(shape: app.pointerShape(), textEditing: false) })]
        print("ui parts: " + parts.map { String(format: "%@ %.2f ms (%d)", $0.0, $0.1.0, $0.1.1) }.joined(separator: ", "))
        let s = app.snapshot()
        let steps: [(String, (Double, Int))] = [
            ("cards", partMs { _ in app.cardWatcher?.poll() }),
            ("sync", partMs { _ in app.timelinePanel.sync(timeline: app.timeline, selection: app.session.selection,
                                                          captions: app.session.captionSelection, playhead: app.session.playhead,
                                                          selectedTransition: app.session.selectedTransition,
                                                          labels: app.session.project.labelResolver,
                                                          lineKeys: Set(app.session.selectedLineKeys.map(\.key))) }),
            ("meterLayout", partMs { _ in app.layoutMeters(scale: theme.scale) }),
            ("tlLayout", partMs { _ in app.timelinePanel.layout(app.layoutToolStrip(app.screen.timelineView.frame), scale: theme.scale) }),
            ("tick", partMs { _ in _ = app.timelinePanel.tick() }),
            ("inspLayout", partMs { _ in app.inspector.layout(app.screen.inspector, scale: theme.scale) }),
            ("screenLayout", partMs { _ in app.screen.layout(width: Float(w), height: Float(h), s) }),
            ("gfxLayout", partMs { _ in app.graphics.layout(app.shell.dock.contentFrame(.graphics)) }),
            ("capLayout", partMs { _ in app.captions.layout(app.shell.dock.contentFrame(.text)) }),
            ("placeholders", partMs { app.drawDockPlaceholders(&$0) }),
            ("dragLabels", partMs { app.drawLibraryDragLabels(&$0, scale: theme.scale, theme: theme) }),
            ("popover", partMs { app.inspector.drawPopover(&$0, theme: theme) }),
            ("tooltip", partMs { HostHover.shared.drawTooltip(&$0, theme: theme, now: 0) }),
            ("welcome", partMs { _ in app.presentWelcomeOnce() })]
        for chunk in stride(from: 0, to: steps.count, by: 5) {
            print("ui steps: " + steps[chunk..<min(chunk + 5, steps.count)]
                .map { String(format: "%@ %.2f", $0.0, $0.1.0) }.joined(separator: ", "))
        }
        print(String(format: "ui gpu vs software: mean %.4f, max %d, channels off by >2: %d", d.mean, d.max, d.over2))
    } catch { fail("\(error)") }
    exit(0)
}

// MARK: Headless: edits through the input path

if args.contains("--edit-test") {
    let (w, h) = (1440, 900)
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("edit: \(name) \(ok ? "ok" : "FAIL") \(detail())")
        if !ok { failures += 1 }
    }
    // Scripted presses come faster than a double-click; the panel's clock moves a second per event so none is one.
    final class StepClock: @unchecked Sendable { var t = 0.0 }
    let clock = StepClock()
    app.timelinePanel.clock = { clock.t }
    func send(_ e: InputEvent) { clock.t += 1; app.handle(e); settle(0.01) }
    func v1() -> [Clip] { app.timeline.tracks.first { $0.name == "V1" }?.clips.sorted { $0.start < $1.start } ?? [] }
    func a1() -> [Clip] { app.timeline.tracks.first { $0.name == "A1" }?.clips.sorted { $0.start < $1.start } ?? [] }
    _ = app.frame(width: w, height: h)
    let fd = tl.frameDuration
    let panel = { app.timelinePanel }
    func rowY(_ name: String) -> Float { panel().pixelY(bodyOf: app.timeline.tracks.first { $0.name == name }!.id)! }
    func xAt(_ t: Time) -> Float { panel().pixelX(for: t) }
    let original = v1()
    guard original.count == 2 else { fail("sample project expected (two clips on V1)") }
    let b = original[1]
    // Select: click Shot B.
    let yV = rowY("V1")
    let xB = xAt(b.start + fd * (b.duration.frameIndex(frameDuration: fd) / 2))
    send(.mouseDown(x: xB, y: yV, modifiers: [])); send(.mouseUp(x: xB, y: yV))
    // Linked selection (the Mac default) takes B's sound along.
    check("select", app.session.selection.contains(b.id), "\(app.session.selection.count) selected")
    // Move: drag Shot B one second later (its linked sound follows).
    let fps = Float(Double(fd.timescale) / Double(fd.value))
    let dx = xAt(fd * Int64(fps.rounded())) - xAt(.zero)
    send(.mouseDown(x: xB, y: yV, modifiers: [])); send(.mouseDragged(x: xB + dx / 2, y: yV))
    send(.mouseDragged(x: xB + dx, y: yV)); send(.mouseUp(x: xB + dx, y: yV))
    let moved = v1()[1].start, movedAudio = a1()[1].start
    check("move", moved > b.start && movedAudio == moved, "B \(TimecodeText.string(b.start, frameDuration: fd)) -> "
          + "\(TimecodeText.string(moved, frameDuration: fd)), sound \(TimecodeText.string(movedAudio, frameDuration: fd))")
    // Razor: C, click the middle of Shot A, V.
    let a = v1()[0]
    let cut = a.start + fd * (a.duration.frameIndex(frameDuration: fd) / 2)
    send(.keyDown(.character("c"), modifiers: []))
    send(.mouseDown(x: xAt(cut) + 0.5, y: yV, modifiers: [])); send(.mouseUp(x: xAt(cut) + 0.5, y: yV))
    send(.keyDown(.character("v"), modifiers: []))
    check("razor", v1().count == 3, "V1 has \(v1().count) clips")
    // Delete: select the first piece, Delete. Click its middle: a press within the edge zone of its start selects the
    // edge (trim), and how many frames that zone spans depends on the zoom the dock's timeline card gets.
    let x0 = xAt(a.start + fd * ((cut - a.start).frameIndex(frameDuration: fd) / 2))
    send(.mouseDown(x: x0, y: yV, modifiers: [])); send(.mouseUp(x: x0, y: yV))
    send(.keyDown(.delete, modifiers: []))
    check("delete", v1().count == 2 && v1()[0].start > .zero, "V1 has \(v1().count) clips")
    // Undo three times, redo once.
    send(.keyDown(.character("z"), modifiers: .command))
    check("undo delete", v1().count == 3)
    send(.keyDown(.character("z"), modifiers: .command))
    check("undo razor", v1().count == 2 && v1()[1].start == moved)
    send(.keyDown(.character("z"), modifiers: .command))
    check("undo move", v1().map(\.start) == original.map(\.start))
    send(.keyDown(.character("z"), modifiers: [.command, .shift]))
    check("redo move", v1()[1].start == moved)
    // Source monitor: the Project panel's double-click opens the clip in the Source tab; Insert puts its 1 s In-Out at
    // the playhead, through the shell command (the key map's route).
    if let m = app.session.project.media.first {
        app.projectList.onOpenMedia?(m.id)
        app.session.setSourceMarks(SourceMarks(markIn: .zero, markOut: fd * Int64(fps.rounded())), for: m.id)
        app.session.seek(to: .zero)
        _ = app.frame(width: w, height: h)
        let before = v1().count
        let ran = app.shell.execute(.insert)
        check("source insert", ran && app.source.isShown && v1().count == before + 1, "V1 has \(v1().count) clips")
        _ = app.session.undo()
        app.source.isShown = false
    }
    // Save and read back.
    let saved = openedURL!.deletingLastPathComponent().appendingPathComponent("edit-test.sqproj")
    do {
        try ProjectFile.write(app.session.project, to: saved)
        let back = try ProjectFile.read(from: saved)
        check("save + reopen", back.timelines.first?.tracks.first { $0.name == "V1" }?.clips.count == 2)
    } catch { check("save + reopen", false, "\(error)") }
    // Import: an Explorer drop of a copy of the sample lands in the bin, probed with FFmpeg (one undo step).
    // The copy must probe like the sample itself: the sample step makes 1280x720 H.264 or, with SQ_SAMPLE_10BIT,
    // 1920x1080 HEVC, so the expected width comes from probing the sample file itself.
    if let sample = app.session.project.media.first?.path {
        let expected = (try? FFmpegDemuxer(url: URL(fileURLWithPath: sample)))?.trackInfo.width ?? 0
        let copy = URL(fileURLWithPath: sample).deletingLastPathComponent().appendingPathComponent("import-test.mp4")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: copy)
        let before = app.session.project.media.count
        app.shell.importMixed([copy])
        for _ in 0..<200 where app.session.project.media.count == before { settle(0.05) }
        let item = app.session.project.media.first { $0.name == "import-test.mp4" }
        check("import", expected > 0 && item?.info?.video?.width == expected && item?.info?.audio != nil,
              "\(app.session.project.media.count - before) new, \(item?.info?.video?.width ?? 0) px of \(expected)")
    }
    print("edit test:\(failures == 0 ? "passed" : "\(failures) failed")")
    exit(failures == 0 ? 0 : 1)
}

// MARK: Window

let seconds = value("--seconds").flatMap(Double.init) ?? 0
let playTest = value("--play-test").flatMap(Double.init)
/// Play test rate (shuttle, e.g. 2, 4, -2); default 1 (Play).
let playRate = value("--play-rate").flatMap(Int32.init) ?? 1
let shotPath = value("--shot")
let window: AppWindow
let renderer: UIRenderer
do {
    window = try AppWindow(title: "Sequence Studio - \(app.session.displayName)", width: 1440, height: 900)
    app.wirePreferences(dpiScale: window.scale)
    let (w, h) = window.clientSize
    renderer = try UIRenderer(hwnd: UnsafeMutableRawPointer(window.hwnd), width: w, height: h, device: app.engine.gpu)
} catch { fail("\(error)") }
let floatingHost = WinFloatingHost(app: app, main: window, loadState: !args.dropFirst().contains { $0.hasPrefix("--") })
let filePicker = WinFilePicker(owner: window.hwnd)
app.shell.files = filePicker
app.editAPI?.sync()        // the real window only: headless runs exit before this and never bind the port
app.configureTimelinePanel()
app.session.startAutosaveTimer()
if openedURL == nil { app.shell.presentStartAtLaunch(); app.shell.spawn { await app.shell.offerRecovery() } }
else { app.shell.offerRelinkIfNeeded() }      // media beside a copied project links quietly (a Mac project on Windows)
var shownTitle = ""
print("adapter: \(renderer.adapter), scale \(window.scale), audio: \(app.engine.audioUnavailable ? "off (\(app.engine.audioError ?? "disabled"))" : app.engine.audioDevice ?? "?")")

let start = Date()
var frames = 0
var shotDone = false
var playStarted: Date?
var playCPU = 0.0
var slowFrames = 0
var lastFrameAt = Date()
var dialogTestDone = false
let chromeTest = value("--chrome-test").map { WinChromeTest(app: app, hwnd: window.hwnd, folder: $0) }
let magicUITest = value("--magic-ui-test").flatMap { folder in openedURL.map { url in
    let xy = (value("--magic-point") ?? "0.5474,0.5740").split(separator: ",").compactMap { Double($0) }
    return WinMagicUITest(app: app, folder: folder, url: url, verify: args.contains("verify"), point: Vec2(xy[0], xy[1]))
} }
let shellTest = value("--shell-test").map { WinShellTest(app: app, window: window, folder: $0) }
shellTest?.floating = floatingHost
while !window.closed {
    let (events, gestures, resized) = window.pump()
    if window.closed { break }
    if let s = resized { renderer.resize(s.0, s.1) }
    _ = window.takeDPIChange()      // the floating host sets the draw scale (largest of the windows) every frame
    for (i, e) in events.enumerated() {
        let repeating = window.repeatedEvents.contains(i)
        if let g = gestures[i] { HostGesture.shared.with(g) { app.handle(e) } }
        else { HostKeyRepeat.shared.with(repeating) { app.handle(e) } }
    }
    floatingHost.pump { e, g in
        if let g { HostGesture.shared.with(g) { app.handle(e) } } else { app.handle(e) }
    }
    for urls in window.takeDrops() { app.shell.importMixed(urls) }
    for k in window.takeKeyUps() { app.timelineKeyUp(k) }
    if window.takeFocusLost() { app.releaseHeldKeys() }
    if window.takeAltTaps() > 0, app.shell.dialog == nil { app.shell.menuBar.altTapped() }
    let playing = playStarted != nil, stats = WinPlayStats.shared
    var stageStart = DispatchTime.now().uptimeNanoseconds
    func lap(_ s: WinPlayStats.Stage) {
        let now = DispatchTime.now().uptimeNanoseconds
        if playing { stats.add(s, Double(now - stageStart) / 1e6) }
        stageStart = now
    }
    RunLoop.main.run(until: Date())        // decode results and session work queued on the main actor
    lap(.runloop)
    app.engine.tick()
    lap(.tick)
    let t = Date().timeIntervalSince(start)
    if let p = playTest, playStarted == nil, t > (value("--play-after").flatMap(Double.init) ?? 0.5) {
        if let from = value("--play-from").flatMap(Double.init) {   // seconds into the sequence
            let fd = tl.frameDuration
            app.session.seek(to: fd * Int64((from * Double(fd.timescale) / Double(fd.value)).rounded()))
        }
        app.apply(playRate == 1 ? .playPause : .shuttle(.setRate(PlaybackRate(playRate))))
        playStarted = Date()
        playCPU = processCPUSeconds()
        slowFrames = 0; frames = 0
        print(String(format: "play test: playing \(p) s (at %.3f s)", Double(DispatchTime.now().uptimeNanoseconds % 1_000_000_000_000) / 1e9))
        if let m = value("--play-marker") { _ = FileManager.default.createFile(atPath: m, contents: Data()) }   // GPU load sampling
    }
    if args.contains("--dialog-test"), !dialogTestDone, t > 0.5 { dialogTestDone = true; runDialogTest(window.hwnd) }
    if let c = chromeTest, t > 1.0 { c.tick(t); if c.done { window.close() } }
    if let c = shellTest, t > 1.0 { c.tick(t); if c.done { window.close() } }
    if let c = magicUITest, t > 1.0 { c.tick(t); if c.done { window.close() } }
    stageStart = DispatchTime.now().uptimeNanoseconds
    let drawW = ShellFloating.drawSize(renderer.width, window: window.scale, draw: floatingHost.draw)
    let drawH = ShellFloating.drawSize(renderer.height, window: window.scale, draw: floatingHost.draw)
    renderer.viewScale = floatingHost.mainRatio
    let list = floatingHost.mainPart(of: app.frame(width: drawW, height: drawH), width: drawW, height: drawH)
    lap(.ui)
    renderer.setPicture(app.shownPicture.picture, generation: app.shownPicture.generation)
    for (s, img, g) in app.meters.images { renderer.setImage(s, img, generation: g) }
    if let t = winTimelineMedia?.thumbnailImage { renderer.setImage(t.0, t.1, generation: t.2) }
    if let t = app.captions.templateImage { renderer.setImage(t.0, t.1, generation: t.2) }
    if let t = app.effects.tileImage { renderer.setImage(t.0, t.1, generation: t.2) }
    if let t = app.shell.exportPreviewImage { renderer.setImage(t.0, t.1, generation: t.2) }     // the Export sheet's picture
    if app.shell.windowTitle != shownTitle { shownTitle = app.shell.windowTitle; window.setTitle(shownTitle) }
    var shot = false
    if let path = shotPath, !shotDone, t > (value("--shot-after").flatMap(Double.init) ?? 1.0) { shot = true; shotDone = true; _ = path }
    let chromeShot = chromeTest?.shot ?? shellTest?.shot ?? magicUITest?.shot
    magicUITest?.shot = nil
    chromeTest?.shot = nil
    shellTest?.shot = nil
    if chromeShot != nil { shot = true }
    if playStarted != nil, app.engine.isWaitingForFrame { WinPlayStats.shared.waited() }
    let presentStart = DispatchTime.now().uptimeNanoseconds
    let presented = renderer.render(list, atlas: app.atlas, clear: app.screen.theme.divider, readback: shot)
    if playStarted != nil, !shot { WinPlayStats.shared.add(.present, Double(DispatchTime.now().uptimeNanoseconds - presentStart) / 1e6) }
    floatingHost.render { r in
        r.setPicture(app.shownPicture.picture, generation: app.shownPicture.generation)
        for (s, img, g) in app.meters.images { r.setImage(s, img, generation: g) }
        if let t = winTimelineMedia?.thumbnailImage { r.setImage(t.0, t.1, generation: t.2) }
        if let t = app.captions.templateImage { r.setImage(t.0, t.1, generation: t.2) }
        if let t = app.effects.tileImage { r.setImage(t.0, t.1, generation: t.2) }
        if let t = app.shell.exportPreviewImage { r.setImage(t.0, t.1, generation: t.2) }
    }
    if let img = presented, let path = chromeShot ?? shotPath {
        do { try PNGWriter.write(img, to: URL(fileURLWithPath: path)); print("screenshot: \(path) \(img.width)x\(img.height)") }
        catch { print("screenshot failed: \(error)") }
    }
    if chromeShot != nil { shellTest?.screenshotTaken() }     // readback + PNG: not the app's frame time
    let now = Date()
    if playStarted != nil, now.timeIntervalSince(lastFrameAt) > 1.5 / 60 { slowFrames += 1 }
    lastFrameAt = now
    frames += 1
    if let p = playTest, let ps = playStarted, now.timeIntervalSince(ps) >= p {
        let e = app.engine
        let played = now.timeIntervalSince(ps)
        // Read the numbers first, and pause only while playing: at the sequence end the engine has stopped by itself,
        // and Play there restarts from the start (resetting the counters).
        let shown = e.shownFrames, dropped = e.skippedFrames, playhead = app.session.playhead, span = e.playedSpan
        if !e.rate.isPaused { app.apply(.playPause) }
        let cpu = processCPUSeconds() - playCPU
        if let m = value("--play-marker") { try? FileManager.default.removeItem(atPath: m) }
        print(String(format: "play test: %.2f s, %d window frames, %d slow window frames, CPU %.2f s (%.0f %% of one core)",
                     played, frames, slowFrames, cpu, cpu / played * 100))
        print("play test: \(shown) sequence frames shown, \(dropped) dropped, playhead "
              + "\(TimecodeText.string(playhead, frameDuration: tl.frameDuration)), "
              + (span.map { "frames \($0.from)...\($0.to), " } ?? "")
              + "audio \(e.audioUnavailable ? "off" : "on, \(e.audioUnderruns) underruns")")
        print(String(format: "play test: compose %.2f ms per frame (CPU), up to %d GPU frames in flight",
                     e.meanComposeMilliseconds, e.framesInFlightMax))
        for line in WinPlayStats.shared.report() { print("play test: \(line)") }
        if let err = e.lastError { print("play test: last engine error: \(err)") }
        window.close()
    }
    if seconds > 0, t > seconds { window.close() }
}
floatingHost.flush()
app.editAPI?.stop()        // closes the port and removes the discovery file
FrameMatteStore.shared.waitForSaves()      // Magic mattes tracked in this run
print("closed after \(frames) frames, media: \(app.session.missingMedia.count) offline of \(app.session.project.media.count)"
      + ", Project panel: \(app.projectModel.health.missing) missing of \(app.projectModel.project.media.count)")
if args.contains("--dialog-test") && !dialogTestPassed { exit(1) }
if let c = chromeTest, c.failures > 0 || !c.done { exit(1) }
if let c = shellTest, c.failures > 0 || !c.done { exit(1) }
if let c = magicUITest, c.failures > 0 || !c.done { exit(1) }
exit(0)
