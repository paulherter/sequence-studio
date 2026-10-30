import Foundation
import SQCore

/// Reads the shown Program picture back as working-linear Rec. 709 samples (rows top down). The Mac captures on the
/// engine's render loop (`FrameSampler`), Windows downloads the compositor's target; both answer `done` once, later
/// than the call, nil when there is no picture.
@MainActor public protocol ProgramFrameSampling: AnyObject {
    /// About `width` pixels wide by the picture's aspect. `key` names the capture (a newer one with the same key replaces it).
    func sampleLinear(width: Int, key: String, done: @escaping @MainActor ([SIMD3<Float>]?) -> Void)
}

/// Clip > Video Options > Match Color to Clip, shared by the AppKit window and the shared window: each clip is shown on its
/// own (raw file + grade) in the Program engine for one frame capture, then the session solves and writes Exposure + Color
/// Wheels on the target as one undo step.
extension AnalysisFlows {
    public var isMatchingColor: Bool { colorMatchBusy }

    /// Display-encoded RGB (BT.709 per channel, 0...1) of linear samples: what Color Match measures.
    /// The BT.709 curve is written out here (SQRender is not part of the Windows variant of this package); it matches
    /// `TransferFunctions.bt709OETF`.
    public static func displayRGB(_ linear: [SIMD3<Float>]) -> [SIMD3<Float>] {
        func oetf(_ v: Float) -> Float {
            let l = min(max(v, 0), 1)
            let alpha: Float = 1.09929682680944, beta: Float = 0.018053968510807
            return l < beta ? 4.5 * l : alpha * powf(l, 0.45) - (alpha - 1)
        }
        return linear.map { SIMD3(oetf($0.x), oetf($0.y), oetf($0.z)) }
    }

    public func requestColorMatchToClip() {
        guard !colorMatchBusy else { return }
        switch session.colorMatchToClipPlan() {
        case .blocked(let why): ui.flash(why, 4)
        case .ready(let pair):
            guard let sampler = frameSampler else { ui.flash(Self.unavailable("Match Color to Clip"), 5); return }
            session.stopPlayback()
            colorMatchBusy = true
            colorMatchRun += 1
            let run = colorMatchRun
            // A capture that never arrives (no render) must not leave the monitor on the solo view.
            let timeout = colorMatchTimeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, colorMatchBusy, colorMatchRun == run else { return }
                colorMatchBusy = false
                colorMatchRun += 1
                session.endColorMatchSolo()
                ui.flash("Could not read the clips' frames.", 4)
            }
            sampleSolo(pair.reference, at: pair.referenceTime, with: sampler) { [weak self] ref in
                guard let self, colorMatchRun == run else { return }
                sampleSolo(pair.target, at: pair.targetTime, with: sampler) { [weak self] target in
                    guard let self, colorMatchRun == run else { return }
                    session.endColorMatchSolo()
                    colorMatchBusy = false
                    guard let ref, let target else { ui.flash("Could not read the clips' frames.", 4); return }
                    switch session.applyColorMatchToClip(pair, reference: ref, target: target) {
                    case .applied:
                        ui.flash("Matched: Exposure and Wheels & Match are set in the clip's Color effect.", 4)
                    case .alreadyMatches: ui.flash("The clip already matches.", 4)
                    case .unreadable: ui.flash("Could not read the clips' frames (black or offline).", 4)
                    }
                }
            }
        }
    }

    /// Display RGB of clip `id` alone at sequence time `at`. Captured twice: the first capture can come from a render that
    /// still waited for the decode; the second is the settled frame.
    private func sampleSolo(_ id: Clip.ID, at: Time, with sampler: any ProgramFrameSampling,
                            _ done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) {
        guard session.showColorMatchSolo(id, at: at) else { done(nil); return }
        sampler.sampleLinear(width: 96, key: "color.match.clip") { first in
            guard first != nil else { done(nil); return }
            sampler.sampleLinear(width: 96, key: "color.match.clip") { r in done(r.map(Self.displayRGB)) }
        }
    }
}
