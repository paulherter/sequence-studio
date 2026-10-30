import Foundation
import SQAnalysis
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI

/// `--magic-ui-test <folder> [verify]`: drives Magic Mask through the real window, as a user would. It selects Shot A in
/// the timeline, clicks the Mask tool in the tool strip, clicks the subject in the monitor (EdgeTAM picks it), tracks it
/// with the Effect Controls command, shoots three frames with the mask (pc-magic-ui-*.png), plays for a second and a
/// half, then corrects on another frame (an add click and a remove click on the object), saves, and checks that the
/// mattes reload from disk. `verify` (a second launch on the saved project) finds the mask's mattes on disk and shoots
/// frame 12 again. Prints "magic ui: … ok|FAIL" lines. The subject is at `--magic-point x,y` (default the MaskBench lady).
@MainActor final class WinMagicUITest {
    let app: AppController
    let folder: String
    let verify: Bool
    let url: URL
    let point: Vec2
    var failures = 0
    var shot: String?
    var done: Bool { next >= steps.count }

    /// A step returns true when done; false repeats it (every `wait` seconds) until `timeout` seconds have passed.
    private struct Step { var wait: Double; var timeout: Double; var run: @MainActor (WinMagicUITest) -> Bool }
    private var steps: [Step] = []
    private var next = 0, at = 0.0, since: Double?
    private var key = "", pickedAt = Date(), fd = Time(1, 24)
    private var matteCount = 0
    private var playStart: (shown: Int, dropped: Int, at: Date)?

    private var k: Float { max(app.screen.theme.scale, 0.01) }

    init(app: AppController, folder: String, url: URL, verify: Bool, point: Vec2) {
        self.url = url; self.app = app; self.folder = folder; self.verify = verify; self.point = point
        fd = app.timeline.frameDuration
        if verify { buildVerify() } else { buildRun() }
    }

    func tick(_ t: Double) {
        guard !done, t >= at else { return }
        let s = steps[next]
        let start = since ?? t
        since = start
        if s.run(self) { next += 1; since = nil; at = t + (next < steps.count ? steps[next].wait : 0) }
        else if t - start > s.timeout { expect(false, "step \(next) timed out after \(Int(s.timeout)) s"); next = steps.count }
        else { at = t + 0.25 }
    }

    private func add(_ wait: Double = 0.3, timeout: Double = 0, _ run: @escaping @MainActor (WinMagicUITest) -> Void) {
        steps.append(Step(wait: wait, timeout: timeout) { run($0); return true })
    }
    private func poll(timeout: Double, _ run: @escaping @MainActor (WinMagicUITest) -> Bool) {
        steps.append(Step(wait: 0.2, timeout: timeout, run: run))
    }

    private func expect(_ ok: Bool, _ what: String, _ detail: String = "") {
        if !ok { failures += 1 }
        print("magic ui: \(what) \(ok ? "ok" : "FAIL") \(detail)")
    }

    // MARK: Helpers

    private var clip: Clip? { app.timeline.tracks.first { $0.name == "V1" }?.clips.sorted { $0.start < $1.start }.first }
    private var magicMask: ClipMask? { clip?.masks.first { $0.magic != nil } }
    private var currentKey: String? { clip.flatMap { c in magicMask?.magic?.cacheKey(media: c.media) } }
    private func send(_ e: InputEvent) { app.handle(e); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    private func click(_ p: CGPoint, modifiers: InputModifiers = []) {
        let x = Float(p.x) * k, y = Float(p.y) * k
        send(.mouseMoved(x: x, y: y)); send(.mouseDown(x: x, y: y, modifiers: modifiers)); send(.mouseUp(x: x, y: y))
    }
    private func seek(frame: Int64) { app.session.seek(to: fd * frame) }
    private func monitorPoint(_ p: Vec2) -> CGPoint {
        let r = app.monitor.panel.canvasRect
        return CGPoint(x: r.minX + CGFloat(p.x) * r.width, y: r.minY + CGFloat(p.y) * r.height)
    }
    /// Centroid (0...1) of a matte.
    private func centroid(_ m: SubjectMatte) -> Vec2 {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<m.height { for x in 0..<m.width where m.values[y * m.width + x] > 0.5 { sx += Double(x); sy += Double(y); n += 1 } }
        return n > 0 ? Vec2(sx / n / Double(m.width), sy / n / Double(m.height)) : Vec2(0.5, 0.5)
    }
    private func area(_ m: SubjectMatte) -> Int { m.values.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) } }
    private var removeArea = 0, removeKey = ""
    private func matte(frame: Int64) -> SubjectMatte? {
        FrameMatteStore.shared.matte(key: currentKey ?? key, pts: Double(frame) * Double(fd.value) / Double(fd.timescale))
    }
    private func pick(_ name: String) {
        shot = folder + "\\pc-magic-ui-\(name).png"
    }

    // MARK: Run

    private func buildRun() {
        add(0.5) { t in
            guard let c = t.clip else { t.expect(false, "sample clip"); return }
            let panel = t.app.timelinePanel
            let y = panel.pixelY(bodyOf: t.app.timeline.tracks.first { $0.name == "V1" }!.id) ?? 0
            let x = panel.pixelX(for: c.start + t.fd * (c.duration.frameIndex(frameDuration: t.fd) / 2))
            t.send(.mouseDown(x: x, y: y, modifiers: [])); t.send(.mouseUp(x: x, y: y))
            t.expect(t.app.session.selection.contains(c.id), "Shot A selected")
            t.seek(frame: 0)
        }
        add(0.5) { t in
            // The Mask tool button in the tool strip (Magic is its default mode).
            guard let i = ToolStripTools.order.firstIndex(of: .mask) else { t.expect(false, "mask tool in the strip"); return }
            let r = t.app.toolStrip.slots.tools[i]
            t.click(CGPoint(x: r.midX, y: r.midY))
            t.expect(t.app.timelinePanel.toolState.tool == .mask, "Mask tool picked", "mode \(t.app.timelinePanel.toolState.maskMode), tool \(t.app.timelinePanel.toolState.tool), slot \(r), strip visible \(t.app.toolStrip.visible), contains \(t.app.toolStrip.contains(x: Float(r.midX) * t.k, y: Float(r.midY) * t.k)), scale \(t.k)")
        }
        add(0.5) { t in t.pick("tool") }
        add(0.5) { t in
            t.pickedAt = Date()
            t.click(t.monitorPoint(t.point))
        }
        poll(timeout: 90) { t in
            guard let k = t.currentKey, FrameMatteStore.shared.has(key: k) else { return false }
            t.key = k
            t.expect(true, "click picked the subject in \(String(format: "%.1f", Date().timeIntervalSince(t.pickedAt))) s (model load included)")
            if let m = t.matte(frame: 0) { t.expect(m.width > 0, "matte on frame 0", "\(m.width)x\(m.height), centroid \(t.centroid(m))") }
            return true
        }
        add(0.8) { t in t.pick("pick") }
        add(0.3) { t in
            guard let id = t.magicMask?.id else { t.expect(false, "mask in the project"); return }
            t.pickedAt = Date()
            t.app.inspector.model.onTrackMagic?(id, .run(forward: true))
        }
        poll(timeout: 60) { t in
            guard !MaskTrackActivity.shared.magic.isTracking else { return false }
            let times = FrameMatteStore.shared.times(key: t.key)
            t.matteCount = times.count
            let secs = Date().timeIntervalSince(t.pickedAt)
            t.expect(times.count >= 20, "tracked forward", String(format: "%d frames in %.2f s (%.0f ms per frame)", times.count, secs, secs / Double(max(times.count - 1, 1)) * 1000))
            return true
        }
        for f in [Int64(0), 12, 24] {
            add(0.3) { t in t.seek(frame: f) }
            add(0.8) { t in
                if let m = t.matte(frame: f) { print("magic ui: frame \(f) matte centroid \(t.centroid(m))") }
                t.pick("frame\(f)")
            }
        }
        add(0.3) { t in
            t.seek(frame: 0)
            t.playStart = (t.app.engine.shownFrames, t.app.engine.skippedFrames, Date())
            t.app.apply(.playPause)
        }
        add(1.5) { t in
            let e = t.app.engine
            if !e.rate.isPaused { t.app.apply(.playPause) }
            let secs = Date().timeIntervalSince(t.playStart?.at ?? Date())
            t.expect(e.shownFrames - (t.playStart?.shown ?? 0) > 10, "played with the mask",
                     String(format: "%d frames shown, %d dropped in %.1f s", e.shownFrames, e.skippedFrames, secs))
            t.pick("playing")
        }
        // Correction on another frame: an add click on the object keeps the frames before it.
        add(0.5) { t in
            t.seek(frame: 20)
            t.pickedAt = Date()
        }
        add(0.6) { t in
            guard let m = t.matte(frame: 20) else { t.expect(false, "matte on frame 20"); return }
            let c = t.centroid(m)
            let before = t.currentKey
            t.click(t.monitorPoint(c))
            t.key = before ?? ""
            t.pickedAt = Date()
        }
        poll(timeout: 60) { t in
            guard let k = t.currentKey, k != t.key else { return false }
            let n = FrameMatteStore.shared.times(key: k).count
            t.expect(t.magicMask?.magic?.points.count == 2 && n >= 20, "add click on frame 20 corrected the mask",
                     String(format: "%d points, %d frames carried over, %.2f s", t.magicMask?.magic?.points.count ?? 0, n, Date().timeIntervalSince(t.pickedAt)))
            t.key = k
            return true
        }
        add(0.3) { t in t.pick("corrected") }
        // Remove click (Option-click) high on the subject on frame 20: the clicked object leaves the tracked matte, or, when
        // the model's object there is the whole subject (or not in it), the mask stays untouched. Both are right; the area
        // and the key say which one happened.
        add(0.5) { t in
            guard let m = t.matte(frame: 20) else { t.expect(false, "matte on frame 20 before the remove click"); return }
            let rows = (0..<m.height).filter { y in (0..<m.width).contains { m.values[y * m.width + $0] > 0.5 } }
            guard let top = rows.first, let bottom = rows.last else { t.expect(false, "subject rows on frame 20"); return }
            let c = t.centroid(m)
            t.removeArea = t.area(m)
            t.removeKey = t.currentKey ?? ""
            t.click(t.monitorPoint(Vec2(c.x, (Double(top) + 0.12 * Double(bottom - top)) / Double(m.height))), modifiers: .option)
        }
        add(3.0) { t in
            guard let m = t.matte(frame: 20) else { t.expect(false, "matte on frame 20 after the remove click"); return }
            let now = t.area(m), changed = (t.currentKey ?? "") != t.removeKey
            let points = t.magicMask?.magic?.points.count ?? 0
            t.expect(changed ? (now < t.removeArea && points == 3) : (now == t.removeArea && points == 2),
                     changed ? "remove click cut the object out of the matte" : "remove click left the mask as it was (the object is the whole subject)",
                     "area \(t.removeArea) -> \(now), \(points) points")
            if changed { t.key = t.currentKey ?? t.key }
            t.pick("removed")
        }
        add(0.3) { t in
            // The mask is in the project, the project is saved, the mattes are flushed and read back by a fresh store.
            do { try ProjectFile.write(t.app.session.project, to: t.url) } catch { t.expect(false, "project saved", "\(error)") }
            FrameMatteStore.shared.waitForSaves()
            let dir = FrameMatteStore.shared.directory
            let fresh = FrameMatteStore(directory: dir)
            t.expect(fresh.times(key: t.key).count >= 20, "mattes reload from disk", "\(fresh.times(key: t.key).count) frames in \(dir?.path ?? "memory")")
        }
        add(0.2) { t in print("magic ui: finished (run again with verify for the reopen check)") }
    }

    // MARK: Verify (a second launch on the saved project)

    private func buildVerify() {
        add(1.0) { t in
            t.key = t.currentKey ?? ""
            t.expect(t.magicMask != nil, "mask is in the reopened project", "\(t.magicMask?.magic?.points.count ?? 0) points")
            t.expect(FrameMatteStore.shared.has(key: t.key), "mattes found on disk", "\(FrameMatteStore.shared.times(key: t.key).count) frames")
            t.seek(frame: 12)
        }
        add(1.0) { t in t.pick("reopened") }
        add(0.5) { t in
            t.expect(t.matte(frame: 12) != nil, "matte on frame 12 after reopening")
        }
    }
}
