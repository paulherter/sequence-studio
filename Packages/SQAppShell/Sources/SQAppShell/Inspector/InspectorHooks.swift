import Foundation
import SQCore
import SQDrawShell
import SQEditorSession
import SQInspectorUI

/// The session-side hooks of Effect Controls that the Mac AppKit window sets in `EditorPanels.wireEffectControls`,
/// `wireEffectDefaults`, `wireColorMatch` and `AppController.wireStabilizeEffect`: notices, "Use as Default" and the
/// user's defaults, Convert to Keyframes, Match Color's reference and match, the Stabilizer's Analyze row and the jump to
/// the Color page's Pro grade. Without them those rows and menu items did nothing in the shared window.
@MainActor
enum InspectorHooks {
    /// `libraryChanged` runs after the user's defaults changed from outside (Preferences), so the panel redraws.
    static func connect(model: EffectControlsModel, session: EditorSession, shell: ShellHost, libraryChanged: @escaping @MainActor () -> Void) {
        model.onNotice = { [weak shell] m in shell?.onStatus?(m) }
        connectDefaults(model: model, session: session, shell: shell, libraryChanged: libraryChanged)
        model.canConvert = { [weak session] clip, effect in session?.canConvertToKeyframes(effect: effect, in: clip) ?? false }
        model.onConvertToKeyframes = { [weak session, weak shell] clip, effect in
            guard let session else { return }
            if !session.convertToKeyframes(effect: effect, in: clip) { shell?.onStatus?(session.lastError ?? "The effect could not be converted.") }
        }
        model.onReopenAsEffect = { [weak session, weak shell] clip in
            guard let session else { return }
            if !session.reopenAsEffect(in: clip) { shell?.onStatus?(session.lastError ?? "The effect could not be re-opened.") }
        }
        model.colorSourceOf = { [weak session] clip in session?.colorSource(of: clip) ?? clip.color.source ?? .rec709 }
        model.onColorMatch = { [weak model, weak session, weak shell] effect, request in
            guard let model, let session, let shell else { return }
            switch request {
            case .setReference: setColorMatchReference(effect, model: model, session: session, shell: shell)
            case .match: applyColorMatch(effect, model: model, shell: shell)
            }
        }
        model.onOpenColorPro = { [weak shell] in shell?.dock.setPage(.color) }
        connectStabilizer(model: model, session: session, shell: shell)
    }

    // MARK: Defaults

    private static func connectDefaults(model: EffectControlsModel, session: EditorSession, shell: ShellHost,
                                        libraryChanged: @escaping @MainActor () -> Void) {
        guard let lib = shell.effectDefaultsLibrary else { return }
        session.effectDefaults = lib.defaults
        model.effectDefaults = lib.defaults
        let store: (EffectDefaults) -> Void = { [weak model, weak session, weak shell] d in
            if !lib.replace(with: d) {
                shell?.onStatus?("Your defaults could not be saved.")
                if let model, let session { apply(lib.defaults, model, session) }
                libraryChanged()
            }
        }
        session.onEffectDefaultsChange = store
        model.onEffectDefaultsChange = store
        // Every change, also from Preferences, comes back to the session and the panel.
        NotificationCenter.default.addObserver(forName: EffectDefaultsLibrary.didChange, object: lib, queue: .main) { [weak model, weak session] _ in
            MainActor.assumeIsolated {
                guard let model, let session else { return }
                apply(lib.defaults, model, session)
                libraryChanged()
            }
        }
    }

    static func apply(_ d: EffectDefaults, _ model: EffectControlsModel, _ session: EditorSession) {
        session.effectDefaults = d
        if model.effectDefaults != d { model.effectDefaults = d }
    }

    // MARK: Match Color

    private static func setColorMatchReference(_ effect: ClipEffect.ID, model: EffectControlsModel, session: EditorSession, shell: ShellHost) {
        guard let sampler = shell.frameSampler else { shell.onStatus?("Match Color cannot read the picture on this computer yet."); return }
        let at = session.playhead
        let shot = session.activeTimeline.flatMap { tl in
            tl.tracks.reversed().first { $0.kind == .video && $0.clips.contains { $0.timeline.contains(at) } }?
                .clips.first { $0.timeline.contains(at) }
        }
        let fd = session.activeTimeline?.frameDuration ?? Time(1, 30)
        let tc = TimecodeFormat(frameDuration: fd).string(for: at, frameDuration: fd)
        sampler.sampleLinear(width: 96, key: "color.match.reference") { [weak model] linear in
            guard let linear, let stats = ColorMatchStats.measure(AnalysisFlows.displayRGB(linear)) else { return }
            model?.setColorMatchReference(effect, ColorMatchReference(clip: shot?.id, time: at, label: "\(shot?.name ?? "Frame") \(tc)", stats: stats))
        }
    }

    private static func applyColorMatch(_ effect: ClipEffect.ID, model: EffectControlsModel, shell: ShellHost) {
        if let reason = model.colorMatchBlock(effect) { shell.onStatus?(reason); return }
        guard let sampler = shell.frameSampler else { shell.onStatus?("Match Color cannot read the picture on this computer yet."); return }
        sampler.sampleLinear(width: 96, key: "color.match") { [weak model, weak shell] linear in
            guard let model, let linear else { return }
            if !model.applyColorMatch(effect, display: AnalysisFlows.displayRGB(linear)) {
                shell?.onStatus?("The clip already matches the reference.")
            }
        }
    }

    // MARK: Stabilizer

    private static func connectStabilizer(model: EffectControlsModel, session: EditorSession, shell: ShellHost) {
        let analysis = shell.analysis
        model.onStabilizeAnalyze = { [weak analysis] id in analysis?.analyzeStabilizers([id]) }
        model.onStabilizeCancel = { [weak analysis] in analysis?.cancelStabilizerRun() }
        analysis.onStabilizeProgress = { [weak model] clips, p in
            model?.stabilizeRun = p.map { StabilizeRunState(clips: clips, progress: $0) }
        }
        // Rolling Shutter switched on, a Stabilizer dropped onto a clip: the session asks for the analysis.
        session.onStabilizerNeedsAnalysis = { [weak analysis] tid, ids in analysis?.analyzeStabilizers(ids, in: tid) }
    }
}
