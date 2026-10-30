import AppKit
import SQCore
import SQEditorUI

/// Set while Match Color to Clip has the Program engine on a solo view (a second request waits for it).
@MainActor private enum ColorMatchToClipRun {
    static var busy = false
    /// Counts runs, so a late capture of a timed-out run is ignored.
    static var run = 0
}

/// Clip > Video Options > Match Color to Clip: each clip is shown on its own (raw file + grade) in the Program engine for one
/// frame capture, then the session solves and writes Exposure + Color Wheels on the target as one undo step.
extension AppController {
    func requestColorMatchToClip() {
        guard !ColorMatchToClipRun.busy else { return }
        switch session.colorMatchToClipPlan() {
        case .blocked(let why): shell.statusBar.flash(why, seconds: 4)
        case .ready(let pair):
            session.stopPlayback()
            ColorMatchToClipRun.busy = true
            ColorMatchToClipRun.run += 1
            let run = ColorMatchToClipRun.run
            // A capture that never arrives (no render) must not leave the monitor on the solo view.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, ColorMatchToClipRun.busy, ColorMatchToClipRun.run == run else { return }
                ColorMatchToClipRun.busy = false
                ColorMatchToClipRun.run += 1
                session.endColorMatchSolo()
                shell.statusBar.flash("Could not read the clips' frames.")
            }
            sampleSolo(pair.reference, at: pair.referenceTime) { [weak self] ref in
                guard ColorMatchToClipRun.run == run else { return }
                self?.sampleSolo(pair.target, at: pair.targetTime) { [weak self] target in
                    guard let self, ColorMatchToClipRun.run == run else { return }
                    session.endColorMatchSolo()
                    ColorMatchToClipRun.busy = false
                    guard let ref, let target else { shell.statusBar.flash("Could not read the clips' frames."); return }
                    switch session.applyColorMatchToClip(pair, reference: ref, target: target) {
                    case .applied:
                        shell.statusBar.flash("Matched: Exposure and Wheels & Match are set in the clip's Color effect.", seconds: 4)
                    case .alreadyMatches: shell.statusBar.flash("The clip already matches.")
                    case .unreadable: shell.statusBar.flash("Could not read the clips' frames (black or offline).")
                    }
                }
            }
        }
    }

    /// Display RGB of clip `id` alone at sequence time `at`. Captured twice: the first capture can come from a render that
    /// still waited for the decode; the second is the settled frame.
    private func sampleSolo(_ id: Clip.ID, at: Time, _ done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) {
        guard session.showColorMatchSolo(id, at: at) else { done(nil); return }
        let engine = session.engine
        FrameSampler.sampleScaled(engine: engine, width: 96, key: "color.match.clip") { first in
            guard first != nil else { done(nil); return }
            FrameSampler.sampleScaled(engine: engine, width: 96, key: "color.match.clip") { r in
                done(r.map { FrameSampler.displayRGB($0.linear) })
            }
        }
    }
}
