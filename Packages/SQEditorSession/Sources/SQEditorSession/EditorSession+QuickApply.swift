import Foundation
import SQCore
import SQLibrary

/// What the host still has to do after `applyQuickApply` (the session part is done).
public enum QuickApplyOutcome: Equatable, Sendable {
    /// Done (or refused): show this line in the status bar for `seconds`; nil = nothing to say.
    case status(String?, seconds: Double)
    /// Run a menu command through the host (its panels, dialogs).
    case command(EditorCommand)
    /// "Save Effect Stack as Preset…": the host's preset sheet.
    case saveStackAsPreset
    /// An ordered list of other rows applied as one undo step (`QuickApplyMacro`).
    case macro(QuickApplyMacro)
}

/// The Option+Space palette's apply step, shared by the AppKit window and the shared window (Mac and Windows).
extension EditorSession {
    /// The selected clips the highlighted transition row can go to: video clips for a video transition, audio clips for an
    /// audio one. The start/end question only appears when there are any.
    public func quickApplyTransitionClips(for item: QuickApplyItem?) -> Set<Clip.ID> {
        guard let item, case .transition(let kind) = item.action else { return [] }
        return Set(commandClipsForMenu(kind: kind.trackKind).map(\.id)).intersection(selection)
    }

    /// Applies one palette row to the selection. `presets` are the Library's presets, `timelineEdges` the timeline's selected
    /// edit points (used when no start/end was chosen).
    public func applyQuickApply(_ item: QuickApplyItem, end: TransitionEnd? = nil, presets: [PresetItem],
                                timelineEdges: EdgeSelection?, applyMode: EffectPreset.ApplyMode = PresetApplyModeSetting.load()) -> QuickApplyOutcome {
        flushFollowSelection()           // while playing the selection is not followed: catch up first
        let videoIDs = Set(commandClipsForMenu(kind: .video).map(\.id)).intersection(selection)
        let audioTargets = audioEffectTargets(for: Set(commandClipsForMenu(kind: .video).map(\.id)
            + commandClipsForMenu(kind: .audio).map(\.id)).intersection(selection))
        func failure() -> QuickApplyOutcome { .status(lastError.flatMap { $0.isEmpty ? nil : $0 }, seconds: 4) }
        func applied(_ name: String) -> QuickApplyOutcome { .status(SQL10n.format("%@ applied.", SQL10n.string(name)), seconds: 2) }
        switch QuickApplyTarget.resolve(item, selectedVideoClips: videoIDs, audioTargets: audioTargets) {
        case .effect(let kind, let clips):
            _ = addEffect(kind: kind, to: clips)
            return failure()
        case .transition(let kind):
            stopPlayback()
            let clips = quickApplyTransitionClips(for: item)
            let edges = end.map { QuickApplyTarget.edges(for: clips, end: $0) } ?? timelineEdges
            let n = applyDefaultTransitions(scope: kind.trackKind == .video ? .video : .audio, edges: edges, kind: kind)
            return n > 0 ? applied(kind.name) : .status(lastError, seconds: 4)
        case .preset(let id, let kind):
            guard let preset = presets.first(where: { $0.id == id }) else { return .status(nil, seconds: 0) }
            stopPlayback()
            let ok = kind == .transition ? applyTransitionPreset(preset, edges: timelineEdges) : applyPreset(preset, mode: applyMode)
            return ok ? applied(preset.name) : failure()
        case .builtInPreset(let id):
            stopPlayback()
            return applyStackPreset(id) ? applied(item.title) : failure()
        case .command(let c): return .command(c)
        case .saveStackAsPreset: return .saveStackAsPreset
        case .macro(let macro): return .macro(macro)
        case .refused(let message): return .status(message, seconds: 3)
        }
    }
}
