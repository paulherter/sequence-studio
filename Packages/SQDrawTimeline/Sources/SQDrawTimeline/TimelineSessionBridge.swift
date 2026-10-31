import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// Applies the panel's actions through the `EditorSession` API, the way App/EditorPanels wires the Mac `TimelineView`
/// callbacks. Editors of other panels go to the `TimelineHost`; one it does not have comes back as a status line.
@MainActor
public enum TimelineSessionBridge {
    /// Runs `a`; returns a status line for the host (a refusal, a hint, or a dialog that is not there yet).
    @discardableResult
    public static func apply(_ a: TimelineAction, to s: EditorSession, host: TimelineHost? = nil) -> String? {
        switch a {
        case .commit(let c): s.commit(c)
        case .closeGap(let g): s.closeGap(g)
        case .select(let clips, let captions): s.select(clips: clips, captions: captions)
        case .seek(let t): s.seek(to: t)
        case .beginScrub: s.beginScrub()
        case .scrub(let t): s.scrub(to: t)
        case .endScrub: s.endScrub()
        case .toggleTrack(let id, let toggle, let shift, let option):
            // The target chip: Shift / Option change several targets at once (`toggleTarget`); every other button
            // toggles one track, Shift all of its kind.
            if toggle == .target { s.toggleTarget(id, shift: shift, option: option) }
            else { s.toggleTracks(of: id, toggle, allOfKind: shift) }
        case .addTrack(let kind): s.addTrack(kind)
        case .transitionLayerCut(let id, let t, let continues):
            s.stopPlayback()
            s.moveTransitionLayerCut(id, to: t, continuesGesture: continues)
        case .transitionLayerResize(let id, let edge, let t, let symmetric, let continues):
            // The step is measured against the end as it is now (the model clamps; nothing accumulates).
            guard let r = s.activeTimeline?.resolvedTransitionLayer(id) else { break }
            let delta = t - (edge == .head ? r.span.start : r.span.end)
            guard delta != .zero else { break }
            s.stopPlayback()
            s.resizeTransitionLayer(id, edge: edge, by: delta, symmetric: symmetric, continuesGesture: continues)
        case .sourcePatchClick(let kind, let solo): if solo { s.soloSourcePatch(kind) } else { s.toggleSourcePatch(kind) }
        case .sourcePatchMove(let kind, let track, let both):
            if both { s.patchSourceBoth(kind, to: track) } else { s.patchSource(kind, to: track) }
        case .moveMarker(let id, let t): s.moveMarker(id, to: t)
        case .setMarkerDuration(let id, let d): s.setMarkerDuration(id, to: d)
        case .moveInOut(let r, let part): s.moveInOut(to: r, part: part)
        case .selectTransition(let id, let keep): s.selectTransition(id, keepClips: keep)
        case .changeTransition(let id, let c, let continues):
            s.stopPlayback()
            s.setTransition(id, duration: c.duration, alignment: c.alignment,
                            customBefore: c.alignment == .custom ? c.customBefore : nil, continuesGesture: continues)
        case .openNestedSequence(let id): s.enterNestedSequence(id)
        // The editors belong to other panels: the host opens them (a status line when it has none yet).
        case .editTransition(let id): return TimelineMenus.editTransitionDuration(id, session: s, host: host)
        case .openTrimMode(let p, let before): return request(.trimMode(p, pointerBefore: before), host)
        // The Mac selects the clip (and stops playback) before it opens the monitor's text editing or the Graphics panel.
        case .editTextClip(let id): s.stopPlayback(); s.select(clips: [id]); return request(.textClip(id), host)
        case .editToneClip(let id): s.select(clips: [id]); return request(.toneClip(id), host)
        case .openGraphicLayers(let id): s.stopPlayback(); s.select(clips: [id]); return request(.graphicLayers(id), host)
        case .openInSource(let media): return request(.source(media: media), host)
        case .editMarker(let id): return request(.marker(id), host)
        case .editClipMarker(let clip, let marker): return request(.clipMarker(clip: clip, marker: marker), host)
        case .moveClipMarker(let clip, let marker, let t): s.moveClipMarker(marker, on: clip, to: t)
        case .replaceClip(let c, let name, let continues): s.replaceClip(c, name: name, continuesGesture: continues)
        case .endGesture: s.endGesture()
        case .lineKeyClick(let ref, let extend):
            guard let ref else { s.selectLineKeys([]); return nil }
            s.selectLineKeys(extend ? s.selectedLineKeys.symmetricDifference([ref]) : [ref])
        case .speedEdit(let clip, let keys, let phase, let keep):
            s.applySpeedEdit(SpeedEdit(clip: clip, keys: keys, phase: phase, keepingKeys: keep))
        case .cancelSpeedEdit(let clip, let original): s.cancelSpeedEdit(clip: clip, restoring: original)
        case .keyLaneClick(let clip, let t, let extend): return request(.keyLaneKey(clip: clip, time: t, extend: extend), host)
        case .toggleCaptionTrackVisibility(let id):
            guard let track = s.activeTimeline?.captionTrack(id) else { return nil }
            try? s.performTimeline(track.isVisible ? "Hide Caption Track" : "Show Caption Track") { t in
                guard let i = t.captionTracks.firstIndex(where: { $0.id == id }) else { return }
                t.captionTracks[i].isVisible.toggle()
            }
        case .editCaption(let id, let word):
            if let word, host?.open?(.captionWord(word)) == true { return nil }
            return request(.captionText(id), host)
        case .skim(let t): s.skim(to: t)
        case .slipTwoUp(let two, let tl): host?.slipTwoUp?(two, tl)
        case .dropMedia(let ids, let time, let track, let kind, let insert, let streams):
            _ = s.placeMediaAsking(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite, streams: streams, newTrack: kind)
        case .dropKeystone(let k, let clip, let span):
            guard let landed = s.applyKeystone(k, to: clip, span: span) else {
                return s.lastError ?? SQL10n.format("“%@” could not be applied.", k.name)
            }
            let now = s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == clip }
            host?.editPanel { $0.setKeystoneBar(KeystoneBar(clip: clip, span: landed, name: k.name), clip: now) }
        case .restretchKeystone(let clip, let old, let new, let name):
            let ok = s.restretchKeystone(on: clip, old, to: new)
            let now = s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == clip }
            host?.editPanel { $0.setKeystoneBar(KeystoneBar(clip: clip, span: ok ? new : old, name: name), clip: now) }
            if !ok { return s.lastError }
        case .selectItems(let clip, let items):
            if s.singleSelectedClip?.id != clip { s.select(clips: [clip], captions: []) }
            host?.itemSelection?(clip, items)
        case .makeGraphic(let id):
            s.select(clips: [id], captions: [])
            s.makeGraphic()
        case .reorderItems(let clip, let ids, let index):
            s.editGraphics(clip, name: "Reorder Layer") { $0.move(ids, toIndex: index) }
        case .moveItemsOut(let clip, let ids, let dest, let copy):
            guard let landed = s.moveGraphicsLayers(ids, from: clip, to: dest, copy: copy) else { return s.lastError }
            s.select(clips: [landed.clip], captions: [])
            host?.editPanel { $0.setItemSelection(clip: landed.clip, items: Set(landed.layers)) }
            host?.itemSelection?(landed.clip, Set(landed.layers))
        case .setAttachPoint(let id, let t): return s.setAttachPoint(clip: id, at: t) ? "Attach point set." : nil
        case .contextMenu: return nil     // the host builds the menu (it needs the panel)
        case .command(let c): host?.run(c)
        case .status(let m): return m
        }
        return nil
    }

    private static func request(_ r: TimelineEditorRequest, _ host: TimelineHost?) -> String? {
        guard let host else { return r.unavailable }
        return host.open?(r) == true ? nil : r.unavailable
    }
}
