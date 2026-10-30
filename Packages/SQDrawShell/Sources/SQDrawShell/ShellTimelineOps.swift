import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// The timeline operations of the Mac `executeTimelineOp` and `execute` that need only the session (clipboard, link,
/// markers, targets, nudge, slide, slip, Fast Cut rows, tags), so their menu rows and keys work in the shell too.
/// Same calls and status lines as the Mac; a row the session refuses says why.
extension ShellCommands {
    // Rows that read the timeline view (edge trims, Select Left/Right Edge, Toggle Trim Type, Snapping, Linked
    // Selection, track heights) are the host panel's (`TimelinePanel.runViewCommand`, chained before the shell).
    // shortcut: rows that read the Project selection (Append to Main Track) or Effect Controls (Add Keyframe) stay
    // with the host's panels; upgrade when those panels hand their selection to the shell.
    static func runTimelineOp(_ c: EditorCommand, session s: EditorSession) -> String? {
        func step(_ verb: String, _ n: Int) -> String { StepStatus.line(verb, frames: n) }
        func fastCut(_ run: () -> String) -> String {
            guard s.fastCutCommandEnabled(c) else {
                return s.activeTimeline?.editMode == .magnetic ? "Select the right clips first." : "Switch the sequence to Fast Cut first (Shift+G)."
            }
            return run()
        }
        switch c {
        case .copy: if !s.copySelection() { return "Select clips to copy." }
        case .cut:
            if s.selection.isEmpty { return "Select clips to cut." }
            s.cutSelection()
        case .paste, .pasteInsert, .pasteToTargets:
            if c == .paste, s.builtInClipboard != nil {
                if !s.pasteAttributes() { return "Select a clip of the same kind to paste the copied effect onto." }
            } else if c == .paste, let clip = s.effectClipboard {
                if !s.pasteEffectClipboard() {
                    return clip.isAudio ? "Select an audio clip (or its linked video clip) that can take the copied effect."
                                        : "Select a video clip that can take the copied effect."
                }
            } else if s.clipboard == nil {
                return "Nothing to paste. Copy clips first."
            } else {
                s.pasteClipboard(insert: c == .pasteInsert, toTargets: c == .pasteToTargets)
            }
        case .pasteAttached:
            guard s.fastCutCommandEnabled(c) else {
                return s.activeTimeline?.editMode == .magnetic ? "Nothing to paste. Copy clips first." : "Switch the sequence to Fast Cut first (Shift+G)."
            }
            s.pasteClipboard(attached: true)
        case .selectAll: s.selectAllClips()
        case .deselectAll: s.select(clips: [], captions: [])
        case .selectClipAtPlayhead: s.selectClipAtPlayhead()
        case .selectNextClip, .selectPreviousClip:
            if !s.selectAdjacentClip(forward: c == .selectNextClip) {
                return s.selection.isEmpty ? "Select a clip first." : "No further clip on this track."
            }
        case .goToSelectedClipStart, .goToSelectedClipEnd:
            if !s.goToSelectedClipEdge(end: c == .goToSelectedClipEnd) { return "Select a clip first." }
        case .nextEditPointAnyTrack: s.goToEditPointOnAnyTrack(forward: true)
        case .previousEditPointAnyTrack: s.goToEditPointOnAnyTrack(forward: false)
        case .link: s.toggleLinkSelection()
        case .unlink: if !s.unlinkSelection() { return "Select linked clips first." }
        case .solo: if s.soloSelectedTracks() == nil { return "Select clips with audio first." }
        case .muteTracks: if s.muteSelectedTracks() == nil { return "Select clips with audio first." }
        case .detachAudio: if !s.detachAudioSelection() { return "Select video clips with linked audio first." }
        case .trimToRange:
            if s.activeTimeline?.inOut == nil { return "Mark In and Out first." }
            if s.selection.isEmpty { return "Select clips to trim first." }
            if s.trimSelectionToRange() == 0 { return "The selection already lies inside In and Out." }
        case .nextKeyframe, .previousKeyframe:
            if !s.goToKeyframe(forward: c == .nextKeyframe) { return "No more keyframes that way." }
        case .addVideoTrack: s.addTrack(.video)
        case .addAudioTrack: s.addTrack(.audio)
        case .removeEmptyTracks: s.removeEmptyTracks()
        case .deleteTrack: s.deleteTargetedTracks()
        case .insertSpacer: return fastCut { s.insertSpacer() }
        case .liftOffMainTrack: return fastCut { s.liftOffMainTrack() }
        case .putOnMainTrack: return fastCut { s.putOnMainTrack() }
        case .createStoryline: return fastCut { s.createStoryline() }
        case .storylineRippleDelete: return fastCut { s.storylineRippleDelete() }
        case .moveClipLeft: return fastCut { s.moveSelectedMainClips(-1) }
        case .moveClipRight: return fastCut { s.moveSelectedMainClips(1) }
        case .deleteSelectionOnly: return fastCut { s.deleteSelectionOnly() }
        case .setAttachPoint: return fastCut { s.setAttachPoint() }
        case .markSelection: s.markSelection()
        case .addMarker, .addAndEditMarker: _ = s.markAtPlayhead()   // shortcut: no marker dialog in the shell yet
        case .nextMarker: s.goToNextMarker()
        case .previousMarker: s.goToPreviousMarker()
        case .markOverhang:
            if !s.canMarkOverhang { return "No split edit under the playhead." }
            s.markOverhang()
        case .nextSplitPoint: s.goToNextSplitPoint()
        case .previousSplitPoint: s.goToPreviousSplitPoint()
        case .clearMarker: if !s.clearMarkerAtPlayhead() { return "No marker at the playhead." }
        case .clearAllMarkers: if s.clearAllMarkers() == 0 { return "There are no markers to clear." }
        case .keywordAtPlayhead: if !s.addKeywordAtPlayhead() { return s.lastError ?? "" }
        case .slideLeft, .slideRight, .slideLeft5, .slideRight5:
            if s.selection.isEmpty { return "Select clips to slide." }
            let n = (c == .slideLeft || c == .slideLeft5 ? -1 : 1) * (c == .slideLeft5 || c == .slideRight5 ? StepStatus.large : StepStatus.small)
            s.slideSelection(frames: n)
            return step("Slide", n)
        case .slipLeft, .slipRight, .slipLeft5, .slipRight5:
            if s.selection.isEmpty { return "Select clips to slip." }
            let n = (c == .slipLeft || c == .slipLeft5 ? -1 : 1) * (c == .slipLeft5 || c == .slipRight5 ? StepStatus.large : StepStatus.small)
            s.slipSelection(frames: n)
            return step("Slip", n)
        case .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .nudgeLeft10, .nudgeRight10:
            let n = (c == .nudgeLeft || c == .nudgeLeft5 || c == .nudgeLeft10 ? -1 : 1) * (c == .nudgeLeft || c == .nudgeRight ? StepStatus.small : StepStatus.large)
            s.nudgeSelection(frames: n)
            return step("Nudge", n)
        case .toggleAllTargets: s.toggleAllTargets()
        case .toggleTrackTarget(let kind, let n):
            if !s.toggleTrackTarget(kind, n) { return "There is no \(kind == .video ? "video" : "audio") track \(n)." }
        case .toggleLockOfTargets: if !s.toggleLockOfTargets() { return "Target a track first." }
        case .toggleVideoTargets: s.toggleTargets(of: .video)
        case .toggleAudioTargets: s.toggleTargets(of: .audio)
        case .rollTrimPrevious: s.trimToPlayhead(.head, mode: .roll)
        case .rollTrimNext: s.trimToPlayhead(.tail, mode: .roll)
        case .trimPrevious: s.trimToPlayhead(.head, mode: .plain)
        case .trimNext: s.trimToPlayhead(.tail, mode: .plain)
        case .enableClip:
            if s.selection.isEmpty { return "Select clips to enable or disable." }
            s.toggleEnabledSelection()
        case .group:
            if s.selection.isEmpty { return "Select clips to group." }
            s.groupSelection()
        case .ungroup: s.ungroupSelection()
        case .bundle: if !s.bundleSelection() { return "Select two or more clips to bundle." }
        case .unbundle: if !s.unbundleSelection() { return "Select a bundled clip to unbundle." }
        case .joinCuts:
            let n = s.joinCutsInSelection()
            return n == 0 ? "No through edits to join." : n == 1 ? "Joined 1 cut." : "Joined \(n) cuts."
        case .extendToSequenceEnd:
            if s.selectedAdjustmentLayers.isEmpty { return "Select Adjustment Layers to extend." }
            s.toggleExtendToSequenceEndSelection()
        case .duplicate:
            if s.selection.isEmpty { return "Select clips to duplicate." }
            s.duplicateSelection()
        case .moveSelectionUp, .moveSelectionDown:
            if s.selection.isEmpty { return "Select clips to move." }
            if !s.moveSelectionLane(up: c == .moveSelectionUp) {
                return c == .moveSelectionUp ? "The clips cannot go further up." : "The clips cannot go further down."
            }
        case .jumpCutAlternate:
            if let reason = s.jumpCutRefusal { return reason }
            _ = s.jumpCutAlternate()
        case .tagDialogue: if !s.toggleAudioTag(.dialogue) { return "Select an audio clip first." }
        case .tagMusic: if !s.toggleAudioTag(.music) { return "Select an audio clip first." }
        case .tagSFX: if !s.toggleAudioTag(.sfx) { return "Select an audio clip first." }
        default: return nil
        }
        return ""
    }
}
