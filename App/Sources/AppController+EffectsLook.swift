import AppKit
import SQCore
import SQEditorSession
import SQEditorUI

/// Clip look commands: Fade In / Fade Out (video), Frame Hold, Paste Attributes. Kept apart from the main switch.
extension AppController {
    /// True when the command was handled here.
    func executeEffectsLookOp(_ c: EditorCommand) -> Bool {
        // Fades, frame holds, Dynamic Zoom, blurred fill, split screen, punch-in, subject mask: one shared implementation.
        if let line = EditorLookCommands.run(c, session: session) {
            if !line.isEmpty { shell.statusBar.flash(line, seconds: 3) }
            return true
        }
        switch c {
        case .autoReframe: requestAutoReframe()
        case .anonymize: requestAnonymize()
        case .editDynamicZoom:
            if !panels.toggleDynamicZoomEdit() { shell.statusBar.flash("Select a video clip and put the playhead on it to edit its zoom.") }
        case .stabilize: requestStabilize()
        case .findSceneChanges: requestFindSceneChanges()
        case .matchColorToClip: requestColorMatchToClip()
        case .speedRampPreset(let preset, let onBeat): applySpeedPreset(preset, onBeat: onBeat)
        case .replaceMode(let mode): replaceClipWithMode(mode)
        case .cutToBeats: requestBeatEdit(cut: true)
        case .snapToBeats: requestBeatEdit(cut: false)
        case .fitMusicToLength: requestFitMusic()
        case .pasteAttributes:
            if session.clipboard == nil { shell.statusBar.flash("Copy a clip first, then select the clips to paste its attributes onto.") }
            else if !session.canPasteAttributes { shell.statusBar.flash("Select clips of the same kind as the copied clip.") }
            else if let pick = PasteAttributesDialog.run(choices: session.pasteAttributeChoices) {
                session.pasteAttributes(groups: pick.groups, scaleTimes: pick.scaleTimes)     // a refused paste reports through the session error
            }
        default: return false
        }
        return true
    }

    /// Menu enabling for these commands; nil = not one of them.
    func effectsLookEnabled(_ c: EditorCommand) -> Bool? {
        if let on = EditorLookCommands.enabled(c, session: session) { return on }
        switch c {
        case .speedRampPreset(_, let onBeat): return session.canApplySpeedPreset && (!onBeat || session.hasBeatMarkers)
        case .replaceMode: return replaceModesEnabled
        case .cutToBeats, .snapToBeats: return session.canEditToBeats
        case .fitMusicToLength: return session.canFitMusic
        case .pasteAttributes: return session.canPasteAttributes
        case .editDynamicZoom: return panels.isEditingDynamicZoom || !session.reframeTargets.isEmpty
        case .autoReframe: return isReframing || !session.reframeTargets.isEmpty
        case .anonymize: return isAnonymizing || session.anonymizeTarget != nil
        case .stabilize: return isStabilizing || !session.stabilizeTargets.isEmpty
        case .findSceneChanges: return isFindingSceneChanges || !session.sceneChangeTargets.isEmpty
        case .matchColorToClip: return session.hasColorMatchTarget
        default: return nil
        }
    }
}
