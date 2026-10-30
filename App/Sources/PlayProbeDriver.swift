import AppKit
import ObjectiveC
import SQCore
import SQPlayback

/// Developer aid for docs/PLAYBACK-PERF.md "Seek in the real app": `SQ_PLAY_PROBE=1 SQ_PLAY_PROBE_SCRIPT=seek20` opens the
/// project (`SQ_PLAY_PROBE_PROJECT=<.prproj|.sqproj>`, default: the newest .prproj under ~/Documents/Videos like the
/// benches), jumps 20 times far through the ruler's own closures (press, scrub, release: the path a click takes), waits
/// for each frame on the glass, plays 10 s with sound, logs the `PlayProbe` summary and quits. `jump20` uses
/// `EditorSession.seek` (jump-to-cut keys, markers) instead of the ruler. Without `SQ_PLAY_PROBE=1` nothing runs.
@MainActor
enum PlayProbeDriver {
    static func runIfRequested(_ c: AppController) {
        let env = ProcessInfo.processInfo.environment
        guard PlayProbe.enabled, let script = env["SQ_PLAY_PROBE_SCRIPT"] else { return }
        PlayProbe.watchMainRunLoop()
        if env["SQ_PLAY_PROBE_NO_FLUSH"] == "1" { disableWindowStateFlush() }
        Task { @MainActor in await run(c, script: script, env: env) }
    }

    /// Experiment only (`SQ_PLAY_PROBE_NO_FLUSH=1`): AppKit's window-state flush (`NSPersistentUIFlushScheduler`) runs on main a few
    /// seconds after window changes and costs 15-20 ms (docs/PLAYBACK-PERF.md "main-thread stalls"). This turns its timer off to
    /// show that it, and nothing else, is the stall near +7.5 s. Private class, probe builds only.
    private static func disableWindowStateFlush() {
        guard let cls = NSClassFromString("NSPersistentUIFlushScheduler") else { NSLog("PLAYPROBE no NSPersistentUIFlushScheduler"); return }
        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        for name in ["scheduleTimer", "_performFlush"] {
            if let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) { method_setImplementation(m, imp_implementationWithBlock(noop)) }
        }
        NSLog("PLAYPROBE window-state flush disabled")
    }

    /// The probe summary at quit also covers hand-driven sessions (`SQ_PLAY_PROBE=1` alone).
    static func installQuitReport() {
        guard PlayProbe.enabled else { return }
        PlayProbe.watchMainRunLoop()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            PlayProbe.shared.logReport()
        }
    }

    private static func newestProject() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Videos")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (URL, Date)?
        for case let u as URL in e where u.pathExtension == "prproj" && !u.path.contains("Auto-Save") {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best.map({ d > $0.1 }) ?? true { best = (u, d) }
        }
        return best?.0
    }

    private static func run(_ c: AppController, script: String, env: [String: String]) async {
        guard script == "seek20" || script == "jump20" || script == "play10" else { NSLog("PLAYPROBE unknown script \(script)"); exit(2) }
        guard let engine = c.session.engine as? PlaybackEngine else { NSLog("PLAYPROBE stub engine, no Metal"); exit(1) }
        guard let url = env["SQ_PLAY_PROBE_PROJECT"].map({ URL(fileURLWithPath: $0) }) ?? newestProject() else {
            NSLog("PLAYPROBE no project"); exit(3)
        }
        try? await Task.sleep(for: .seconds(1.5))
        let opened = ContinuousClock.now
        if url.pathExtension.lowercased() == "prproj" { await c.importPremiereProject(at: url) } else { await c.openProject(at: url) }
        guard let tl = c.session.activeTimeline, tl.duration > .zero else { NSLog("PLAYPROBE project has no timeline"); exit(4) }
        NSLog("PLAYPROBE opened \(url.lastPathComponent) in \(opened.duration(to: .now)), \(Double(tl.duration.value) / Double(tl.duration.timescale)) s, "
              + "\(Int(tl.format.width))x\(Int(tl.format.height)); load \(loadAverage())")
        NSApp.activate(ignoringOtherApps: true)      // an occluded window gets no display-link ticks
        c.window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(Double(env["SQ_PLAY_PROBE_SETTLE"] ?? "") ?? 6))
        let probe = PlayProbe.shared
        probe.reset()
        NSLog("PLAYPROBE window visible=\(c.window.isVisible) occlusion=\(c.window.occlusionState.rawValue) key=\(c.window.isKeyWindow) "
              + "viewer.window=\(c.panels.viewer.window != nil) presented=\(engine.stats.presentedFrames) screen=\(String(describing: c.window.screen?.localizedName))")

        NSLog("PLAYPROBE windows: " + NSApp.windows.map { "\(type(of: $0)) restorable=\($0.isRestorable) visible=\($0.isVisible)" }.joined(separator: "; "))
        let fd = tl.format.frameDuration
        let frames = Int64(tl.duration.value) * Int64(fd.timescale) / (Int64(tl.duration.timescale) * Int64(fd.value))
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        var last = Int64(0)
        let view = c.panels.timelineView
        for i in 0..<(script == "play10" ? 0 : 20) {
            // Far jumps: at least a quarter of the sequence from the previous position, deterministic.
            var f: Int64
            repeat {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                f = Int64(rng >> 33) % max(frames - 1, 1)
            } while abs(f - last) < frames / 4 && frames > 8
            last = f
            let t = fd * f
            if script == "seek20" {
                probe.begin("ruler \(i + 1)")
                view.onScrubBegan?(); view.onScrub?(t); view.onScrubEnded?()
            } else {
                probe.begin("jump \(i + 1)")
                c.session.seek(to: t)
            }
            if !(await waitFor(seconds: 4) { probe.completedCount == i + 1 }) { NSLog("PLAYPROBE jump \(i + 1) never reached the glass: \(probe.pendingText)") }
            try? await Task.sleep(for: .milliseconds(400))
        }
        for l in probe.report().prefix(while: { !$0.contains("publish->apply") }) { NSLog("%@", l) }
        NSLog("PLAYPROBE seek phase load \(loadAverage())")

        // Playback: 10 s with sound from the middle, on-glass timing next to the main-thread numbers.
        probe.reset()
        let present = PresentProbe()
        engine.presentProbe = present
        var startFrame = frames / 3
        if let sec = env["SQ_PLAY_PROBE_START"].flatMap(Double.init) { startFrame = Int64(sec * Double(fd.timescale) / Double(fd.value)) }
        let startTime = fd * startFrame
        c.session.seek(to: startTime)
        // Edit points in the 10 s window (offset from play start): a stall at a cut is a clip change, not the page scroll.
        let sec = { (t: Time) in Double(t.value) / Double(t.timescale) }
        let cuts = tl.editPoints().filter { $0 >= startTime && sec($0) - sec(startTime) < 10 }.map { String(format: "+%.0f", (sec($0) - sec(startTime)) * 1000) }
        NSLog("PLAYPROBE start \(String(format: "%.1f", sec(startTime))) s; edit points (ms after play start): \(cuts.joined(separator: " ")); "
              + "playhead x \(view.geometry.x(for: startTime)) view width \(view.bounds.width) scrollX \(view.geometry.scrollX)")
        try? await Task.sleep(for: .seconds(1.5))
        _ = present.take()
        PlayProbe.shared.markPlayStart()
        if let n = env["SQ_PLAY_PROBE_SAMPLE_PID_FILE"] { try? "go".write(toFile: n, atomically: true, encoding: .utf8) }
        c.session.playPause()
        // `SQ_PLAY_PROBE_SCROLL=1`: the timeline is scrolled back and forth at 120 Hz (12 pt, 1 s each way) while it plays.
        let scrolls = env["SQ_PLAY_PROBE_SCROLL"] == "1"
        let end = ContinuousClock.now + .seconds(10)
        var n = 0
        while ContinuousClock.now < end {
            if scrolls { n += 1; view.scroll(byX: n % 240 < 120 ? 12 : -12, y: 0) }
            try? await Task.sleep(for: .milliseconds(8))
        }
        c.session.playPause()
        engine.presentProbe = nil
        let s = PresentProbe.summarize(present.take(), frameDuration: Double(fd.value) / Double(fd.timescale))
        func p(_ v: [Double], _ q: Double) -> Double { s.percentile(q, of: v) }
        NSLog("PLAYPROBE engine stats after play: presented \(engine.stats.presentedFrames) dropped \(engine.stats.droppedFrames)")
        NSLog("PLAYPROBE play 10 s: frames \(s.frames) late \(s.late) skipped \(s.skipped) neverShown \(s.neverShown) "
              + String(format: "interval p50 %.1f p95 %.1f p99 %.1f worst %.1f ms; load %@", p(s.intervals, 0.5), p(s.intervals, 0.95),
                       p(s.intervals, 0.99), s.intervals.last ?? 0, loadAverage()))
        for l in probe.report().suffix(3) { NSLog("%@", l) }
        exit(0)
    }

    private static func waitFor(seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }

    private static func loadAverage() -> String {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return String(format: "%.1f", l[0])
    }
}
