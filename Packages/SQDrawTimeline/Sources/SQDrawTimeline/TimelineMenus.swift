import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI
import SQUIKit

extension TimelinePanel {
    /// A right press (`InputModifiers.secondary`) selects what is under the pointer like the Mac `contextSelect`; the
    /// host then builds the menu with `TimelineMenus.items(at:panel:session:host:)`.
    public mutating func contextSelect(at p: CGPoint) -> [TimelineAction] {
        cancelGesture()
        feedInteraction()
        interaction.contextSelect(at: p)
        return refreshFromInteraction()
    }
}

/// The timeline's right-click menus, translated from App/Sources/EditorPanels.swift `timelineMenu(at:)` and its
/// helpers (+TrackMenu, +Markers, +Transitions, +Captions, +ClipMarkers, +Sync, +Angles): the same SQTimelineUI menu
/// specs (`TimelineContextMenu`, `TimelineSideMenus`), the same session calls; only the dialogs go through the host.
@MainActor
public enum TimelineMenus {
    /// The menu for a right press at `p` (panel points); nil = no menu there. Selects like the Mac view first.
    public static func items(at p: CGPoint, panel: inout TimelinePanel, session s: EditorSession,
                             host: TimelineHost) -> [SQMenuItem]? {
        if let f = panel.fadeHandleHit(at: p) { return fadeCurveItems(clip: f.clip, handle: f.handle, current: f.curve, session: s) }
        if let k = panel.volumeKey(at: p) { return volumeKeyItems(clip: k.clip, key: k.key, session: s) }
        if let k = panel.speedKeyHit(at: p) { return speedKeyItems(clip: k.clip, hit: k.key, at: p, session: s, host: host) }
        if let c = panel.speedSegmentClip(at: p) {
            let pointer = panel.geometry.time(atX: p.x)
            return speedPointItems(clip: c, at: pointer, session: s)
        }
        if let m = transitionItems(at: p, panel: &panel, session: s, host: host) { return m }
        if let h = ClipMarkerFlags.hit(at: p, in: panel.timeline, geometry: panel.geometry) { return clipMarkerItems(h, session: s, host: host) }
        for a in panel.contextSelect(at: p) { TimelineSessionBridge.apply(a, to: s, host: host) }
        if panel.selection.isEmpty, !panel.captionSelection.isEmpty {
            let words = captionWordItems(at: p, panel: panel, session: s, host: host)
            return words + (words.isEmpty ? [] : [.separator]) + captionMenu(panel: panel, session: s, host: host)
        }
        let hasClipboard = s.clipboard != nil
        let items: [TimelineMenuItem]
        switch panel.geometry.hitTest(p, in: panel.timeline) {
        case .clip, .caption:
            items = TimelineContextMenu.items(timeline: panel.timeline, selection: panel.selection,
                                              captionSelection: panel.captionSelection, clipboardHasClips: hasClipboard,
                                              groups: Set(s.project.timelines.filter(\.isGroup).map(\.id)))
        case .gap where panel.interaction.gapSelection != nil:
            items = TimelineContextMenu.gapItems(clipboardHasClips: hasClipboard)
        case .gap, .captionGap:
            items = TimelineContextMenu.emptyItems(clipboardHasClips: hasClipboard,
                                                   placeSequencesAsClips: panel.toolState.placeSequencesAsClips)
        case .header(let id):
            return trackHeaderItems(for: id, session: s, host: host)
        case .ruler:
            return rulerItems(at: p, panel: panel, session: s, host: host)
        default:
            return nil
        }
        let resolver = s.project.labelResolver
        let all = panel.timeline.tracks.flatMap(\.clips)
        let shared = Set(s.selection.compactMap { id in all.first { $0.id == id }.map(resolver.label(for:)) })
        let pointer = panel.geometry.time(atX: p.x)
        let timeline = panel.timeline
        let clipSelection = panel.selection
        var rows = TimelineContextMenu.makeSQItems(items: items, labelHandler: { [weak s] l in s?.setLabel(l) },
                                                   currentLabel: shared.count == 1 ? shared.first : nil) { [weak s] action in
            guard let s else { return }
            perform(action, session: s, host: host, timeline: timeline, selection: clipSelection, pointer: pointer)
        }
        // Sync, angle and edit-point entries go on top of the clip menu.
        rows.insert(contentsOf: syncItems(at: p, panel: panel, session: s) + angleItems(at: p, panel: panel, session: s, host: host)
                    + editPointItems(at: p, panel: panel, session: s), at: 0)
        if s.selection.count == 1, s.singleSelectedClip?.acceptsColor == true {
            rows.append(SQMenuItem(title: "Grade From Previous Clip") { [weak s] in _ = s?.gradeFromPreviousClip(back: 1) })
            rows.append(SQMenuItem(title: "Grade From Clip Before Previous") { [weak s] in _ = s?.gradeFromPreviousClip(back: 2) })
            rows.append(SQMenuItem(title: "Grade All From This Camera") { [weak s] in
                guard let s else { return }
                let n = s.gradeAllFromCamera()
                if n > 0 { host.status?(SQL10n.format("Graded %d clips from this camera.", n)) }
            })
        }
        return rows
    }

    /// EditorPanels+Volume.swift `volumeKeyItems`: "Delete Keyframe" on a volume key.
    static func volumeKeyItems(clip: Clip.ID, key: UUID, session s: EditorSession) -> [SQMenuItem] {
        TimelineSideMenus.volumeKey { [weak s] in
            guard let s, var c = s.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            c.removeVolumeKey(key)
            s.replaceClip(c, name: "Delete Keyframe", continuesGesture: false)
        }
    }

    /// EditorPanels+Volume.swift `fadeCurveItems`: the curve shapes on a fade handle.
    static func fadeCurveItems(clip: Clip.ID, handle: FadeHandle, current: FadeCurve?, session s: EditorSession) -> [SQMenuItem] {
        TimelineSideMenus.fadeCurve(current: current) { [weak s] curve in
            guard let s, var c = s.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            c.setAudioFadeCurve(curve, head: handle == .head)
            s.replaceClip(c, name: "Fade Curve", continuesGesture: false)
        }
    }

    /// EditorPanels+SpeedBand.swift `speedKeyItems`: a span and its center handle both answer as `.ramp`.
    static func speedKeyItems(clip: Clip.ID, hit: SpeedBandKeyHit, at p: CGPoint, session s: EditorSession,
                              host: TimelineHost) -> [SQMenuItem] {
        var isRamp = false, segment = 0
        if case .ramp(let i) = hit.hit { isRamp = true; segment = i }
        return TimelineSideMenus.speedKey(deleteTitle: hit.title, isRamp: isRamp,
                                          curve: { host.request(.speedCurve(clip: clip, segment: segment, at: p)) },
                                          delete: { [weak s] in _ = s?.deleteSpeedKey(clip: clip, hit: hit) })
    }

    /// `speedPointItems`: "Add Speed Point" at the clicked time.
    static func speedPointItems(clip: Clip.ID, at time: Time, session s: EditorSession) -> [SQMenuItem] {
        TimelineSideMenus.speedPoint { [weak s] in
            guard let s, let c = s.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            _ = s.addSpeedKey(clip: clip, atLocal: time - c.start)
        }
    }

    /// One clip menu row (`timelineMenu`'s action switch).
    static func perform(_ action: TimelineMenuAction, session s: EditorSession, host: TimelineHost, timeline: Timeline,
                        selection: Set<Clip.ID>, pointer: Time) {
        switch action {
        case .cut: host.run(.cut)
        case .copy: host.run(.copy)
        case .paste: host.run(.paste)
        case .pasteInsert: host.run(.pasteInsert)
        case .pasteAttributes: host.run(.pasteAttributes)
        case .delete: host.run(.delete)
        case .rippleDelete: host.run(.rippleDelete)
        case .enable: host.run(.enableClip)
        case .useTake: s.useSelectedTakeForRange()
        case .link, .unlink: host.run(.link)
        case .nest: nest(session: s, host: host)
        case .unnest: s.unnestSelection()
        case .group: host.run(.group)
        case .ungroup: host.run(.ungroup)
        case .bundle: host.run(.bundle)
        case .unbundle: host.run(.unbundle)
        case .editOriginal: host.run(.editOriginal)
        case .revealInProject: if let id = s.mediaOfSelection.first { host.request(.revealInProject(media: id)) }
        case .extendToSequenceEnd: host.run(.extendToSequenceEnd)
        case .speed: host.run(.speedDuration)
        case .reverse: host.run(.reverseClip)
        case .audioGain: host.run(.audioGain)
        case .removeSilences: host.run(.removeSilences)
        case .removeFillerWords: host.run(.removeFillerWords)
        case .punchInCuts: host.run(.punchInCuts)
        case .fitMusicToLength: host.run(.fitMusicToLength)
        case .timeRemapping: host.run(.toggleTimeRemapping)
        case .setToFrameSize: _ = s.setToFrameSize()
        case .setToFillFrame: _ = s.setToFillFrame()
        case .rename: renameSelectedClip(session: s, host: host)
        case .addClipMarker:
            guard let id = selection.first else { return }
            let clip = timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }
            let at = clip.map { $0.timeline.contains(pointer) ? pointer : s.playhead } ?? pointer
            if let m = s.addClipMarker(to: id, at: at) { host.request(.clipMarker(clip: id, marker: m)) }
        case .saveAsPreset: host.request(.saveClipPreset)
        case .makeGraphic: s.makeGraphic()
        case .newColorMatte:
            guard s.activeTimeline != nil else { host.status?("Open a sequence first."); return }
            host.request(.newColorMatte)
        case .togglePlaceSequencesAsClips: host.editPanel { $0.toolState.placeSequencesAsClips.toggle() }
        case .saveTitleBlock: host.request(.saveTitleBlock)
        case .saveTemplate: host.request(.saveTemplate)
        case .toggleZones: toggleZones(session: s, host: host)
        case .speedRamp(let p, let onBeat): host.run(.speedRampPreset(p, onBeat: onBeat))
        case .label, .editCaption, .splitCaption, .mergeCaptions: break   // captions have their own menu (`captionMenu`)
        }
    }

    // MARK: Dialog flows (the Mac SQDialog sheets, as host prompts)

    /// `requestNest`: Combine… names the new sequence (`NestSheet` rules), then nests the selection.
    static func nest(session s: EditorSession, host: TimelineHost) {
        guard !s.selection.isEmpty else { return }
        let names = s.project.timelines.map(\.name)
        host.ask(TimelinePrompt(title: "Combine", message: "Name of the new sequence:", text: NestSheet.defaultName(existing: names)),
                 missing: "Combine is not available here yet") { [weak s] name in
            _ = s?.nestSelection(name: NestSheet.resolvedName(name, existing: names))
        }
    }

    /// `renameSelectedClip`.
    static func renameSelectedClip(session s: EditorSession, host: TimelineHost) {
        guard let clip = s.singleSelectedClip, s.selection.count == 1 else { return }
        host.ask(TimelinePrompt(title: "Rename Clip", text: clip.name), missing: "Rename is not available here yet") { [weak s] name in
            s?.renameSelectedClip(to: name)
        }
    }

    /// `renameTrack`.
    static func renameTrack(_ track: Track, session s: EditorSession, host: TimelineHost) {
        host.ask(TimelinePrompt(title: "Rename Track", text: track.name, placeholder: track.kind == .video ? "Video" : "Audio"),
                 missing: "Rename is not available here yet") { [weak s] name in
            s?.renameTrack(track.id, to: name)
        }
    }

    /// `setTransitionDuration`: the host's own dialog when it has one, else a timecode prompt.
    @discardableResult
    static func editTransitionDuration(_ id: Transition.ID, session s: EditorSession, host: TimelineHost?) -> String? {
        guard let host else { return TimelineEditorRequest.editTransitionDuration(id).unavailable }
        if host.open?(.editTransitionDuration(id)) == true { return nil }
        guard host.prompt != nil, let info = s.transitionInfo(id), let fd = s.activeTimeline?.frameDuration else {
            return host.request(.editTransitionDuration(id))
        }
        let current = info.resolved?.duration ?? info.transition.duration
        host.ask(TimelinePrompt(title: "Set Transition Duration", message: info.transition.kind.name,
                                text: MarkersPanelModel.timecode(current, frameDuration: fd), placeholder: "00:00:00:00"),
                 missing: "") { [weak s] text in
            guard let d = MarkersPanelModel.parseTimecode(text, frameDuration: fd), d > .zero else { return }
            s?.setTransition(id, duration: d)
        }
        return nil
    }

    /// `toggleZonesOfSelection`.
    static func toggleZones(session s: EditorSession, host: TimelineHost) {
        let clips = s.selectedZoneClips
        guard !clips.isEmpty else { host.status?("Select a title clip first."); return }
        let on = clips.contains { $0.zones == nil }
        for c in clips where !s.setZonesEnabled(on, clip: c.id) { host.status?(s.lastError ?? "Zones could not be changed."); return }
    }

    // MARK: Side menus

    /// `transitionItems`: right-click on a transition box (selects it).
    static func transitionItems(at p: CGPoint, panel: inout TimelinePanel, session s: EditorSession, host: TimelineHost) -> [SQMenuItem]? {
        guard let hit = TransitionLayout.hitTest(p, in: panel.timeline, geometry: panel.geometry) else { return nil }
        panel.cancelGesture()
        panel.selectedTransition = hit.id
        s.selectTransition(hit.id)
        return TimelineSideMenus.transition(
            setDuration: { [weak s] in if let s { editTransitionDuration(hit.id, session: s, host: host) } },
            saveAsPreset: { [weak s] in
                s?.selectTransition(hit.id)
                host.request(.saveTransitionPreset(hit.id))
            },
            delete: { [weak s] in s?.removeTransition(hit.id) })
    }

    /// `clipMarkerItems`.
    static func clipMarkerItems(_ h: ClipMarkerFlags.Hit, session s: EditorSession, host: TimelineHost) -> [SQMenuItem] {
        [SQMenuItem(title: "Edit Clip Marker…", action: { host.request(.clipMarker(clip: h.clip, marker: h.marker)) }),
         .separator,
         SQMenuItem(title: "Delete Clip Marker", action: { [weak s] in s?.deleteClipMarker(h.marker, on: h.clip) })]
    }

    /// `captionWordMenuItems`: the word and caption items above the caption menu (none on a locked track).
    static func captionWordItems(at p: CGPoint, panel: TimelinePanel, session s: EditorSession, host: TimelineHost) -> [SQMenuItem] {
        guard case .caption(let id, _) = panel.geometry.hitTest(p, in: panel.timeline),
              let (row, _) = CaptionWordLayout.locate(id, in: panel.timeline, geometry: panel.geometry),
              let track = panel.timeline.captionTrack(row.track), !track.isLocked else { return [] }
        /// Runs a panel edit and hands its actions to the session.
        func run(_ edit: @escaping (inout TimelinePanel) -> [TimelineAction]?) -> @MainActor () -> Void {
            { [weak s] in
                guard let s else { return }
                var out: [TimelineAction] = []
                host.editPanel { out = edit(&$0) ?? [] }
                for a in out { TimelineSessionBridge.apply(a, to: s, host: host) }
            }
        }
        var items: [SQMenuItem] = []
        if let hit = CaptionWordLayout.hit(p, caption: id, in: panel.timeline, geometry: panel.geometry) {
            let ref = hit.ref
            items += [
                SQMenuItem(title: "Edit Word", action: run { $0.beginWordEditing(ref) }),
                SQMenuItem(title: "Insert Word Before", action: run { $0.beginWordInsert(in: id, at: ref.index) }),
                SQMenuItem(title: "Insert Word After", action: run { $0.beginWordInsert(in: id, at: ref.index + 1) }),
                SQMenuItem(title: "Delete Word", action: run { $0.deleteWord(ref) }),
                .separator,
                SQMenuItem(title: "Split Caption Before This Word", isEnabled: ref.index > 0,
                           action: run { $0.splitCaption(id, beforeWord: ref.index) }),
            ]
        }
        let i = track.items.firstIndex { $0.id == id } ?? 0
        items += [
            SQMenuItem(title: "Join with Previous Caption", isEnabled: i > 0, action: run { $0.joinCaption(id, with: .previous) }),
            SQMenuItem(title: "Join with Next Caption", isEnabled: i + 1 < track.items.count, action: run { $0.joinCaption(id, with: .next) }),
            .separator,
            SQMenuItem(title: "Find and Replace in Captions\u{2026}", action: { host.request(.captionFindReplace) }),
        ]
        return items
    }

    /// `captionMenu`.
    static func captionMenu(panel: TimelinePanel, session s: EditorSession, host: TimelineHost) -> [SQMenuItem] {
        let items = TimelineContextMenu.captionItems(timeline: panel.timeline, captionSelection: panel.captionSelection,
                                                     playhead: s.playhead)
        return TimelineContextMenu.makeSQItems(items: items) { [weak s] action in
            guard let s else { return }
            switch action {
            case .editCaption: if let id = s.captionSelection.first { host.request(.captionText(id)) }
            case .splitCaption: s.splitCaption()
            case .mergeCaptions: s.mergeSelectedCaptions()
            case .delete: s.deleteSelectedCaptions()
            default: break
            }
        }
    }

    /// `trackHeaderItems`: Add / Delete / Rename / Move, mix, ducking, Select All, the header toggles.
    static func trackHeaderItems(for id: Track.ID, session s: EditorSession, host: TimelineHost) -> [SQMenuItem]? {
        guard let track = s.activeTimeline?.track(id) else { return nil }
        return TimelineSideMenus.trackHeader(
            track: track,
            addVideo: { [weak s] in s?.addTrack(.video) },
            addAudio: { [weak s] in s?.addTrack(.audio) },
            delete: { [weak s] in s?.deleteTrack(id) },
            rename: { [weak s] in if let s { renameTrack(track, session: s, host: host) } },
            moveUp: { [weak s] in s?.moveTrack(id, up: true) },
            moveDown: { [weak s] in s?.moveTrack(id, up: false) },
            mix: { host.request(.trackMix(id)) },
            toggleDucking: { [weak s] in s?.setTrackExcludedFromLiveDucking(id, !track.isExcludedFromLiveDucking) },
            sequenceVolume: { host.request(.sequenceVolume) },
            selectAll: { [weak s] in s?.selectAllClips(on: id) },
            toggle: { [weak s] t in if let s { TimelineSessionBridge.apply(.toggleTrack(id, t, shift: false, option: false), to: s, host: host) } })
    }

    /// `rulerItems`: marker commands at the pointer, the In/Out entries, Delete Marker, Beat Snap.
    static func rulerItems(at p: CGPoint, panel: TimelinePanel, session s: EditorSession, host: TimelineHost) -> [SQMenuItem] {
        let t = panel.geometry.time(atX: p.x)
        let marker = panel.markerID(at: p)
        let eq = CommandMap.current.binding(for: .addMarker).flatMap(TimelineMenuItem.portableKeyEquivalent)
        let level = panel.beatLevel
        func levelItem(_ l: BeatSnapLevel, _ title: String) -> SQMenuItem {
            SQMenuItem(title: title, isChecked: level == l) {
                host.editPanel { $0.beatLevel = l }
                l.store()
            }
        }
        let beatSnap = SQMenuItem(title: "Beat Snap", submenu: [levelItem(.everyBeat, "Every Beat"), levelItem(.barsOnly, "Bars Only")])
        return TimelineSideMenus.ruler(
            hasMarkerAtPointer: marker != nil,
            entries: RulerRangeEntry.entries(hasInOut: s.activeTimeline?.inOut != nil),
            addMarkerShortcut: eq.map { SQMenuShortcut.glyphs(key: $0.key, keyModifiers: $0.modifiers) } ?? "",
            addMarker: { [weak s] in
                guard let s else { return }
                s.seek(to: t)
                if let r = s.markAtPlayhead(), r.openEdit { host.request(.marker(r.id)) }
            },
            editMarker: { if let marker { host.request(.marker(marker)) } },
            range: { [weak s] command in
                guard let s else { return }
                switch command {
                case .markIn: s.markIn()
                case .markOut: s.markOut()
                default: s.clearInOut()
                }
            },
            deleteMarker: { [weak s] in if let marker { s?.deleteMarker(marker) } }) + [.separator, beatSnap]
    }

    // MARK: Rows on top of the clip menu

    /// `syncMenuItems`.
    static func syncItems(at p: CGPoint, panel: TimelinePanel, session s: EditorSession) -> [SQMenuItem] {
        guard case .clip(let id, _) = panel.geometry.hitTest(p, in: panel.timeline), panel.timeline.syncOffsets()[id] != nil else { return [] }
        return [SQMenuItem(title: "Move into Sync") { [weak s] in s?.moveIntoSync(id) },
                SQMenuItem(title: "Slip into Sync") { [weak s] in s?.slipIntoSync(id) },
                .separator]
    }

    /// `angleMenuItems`.
    static func angleItems(at p: CGPoint, panel: TimelinePanel, session s: EditorSession, host: TimelineHost) -> [SQMenuItem] {
        guard case .clip(let id, _) = panel.geometry.hitTest(p, in: panel.timeline) else { return [] }
        var rows: [SQMenuItem] = []
        if let st = s.angleMenuState(for: id) {
            let angles = st.names.enumerated().map { i, name in
                let key = !st.isAudio && i < 9
                    ? CommandMap.current.binding(for: .switchAngle(i + 1)).flatMap(TimelineMenuItem.portableKeyEquivalent)
                        .map { SQMenuShortcut.glyphs(key: $0.key, keyModifiers: $0.modifiers) } ?? ""
                    : ""
                return SQMenuItem(title: "\(i + 1)  \(name)", shortcut: key, isChecked: i == st.active) { [weak s] in s?.setAngle(i, on: id) }
            }
            rows.append(SQMenuItem(title: st.isAudio ? "Sound Angle" : "Angle", submenu: angles))
            rows.append(SQMenuItem(title: "Flatten Angles Clip") { [weak s] in s?.flattenAngles(clip: id) })
            if let follows = st.followsVideo {
                rows.append(SQMenuItem(title: "Audio Follows Video", isChecked: follows) { [weak s] in s?.setAudioFollowsVideo(!follows, on: id) })
            }
        }
        if s.selection.contains(id), s.angleCandidatesOfSelection.count >= 2 {
            rows.append(SQMenuItem(title: "Create Angles Clip…") { host.request(.createAnglesClip) })
        }
        return rows.isEmpty ? [] : rows + [.separator]
    }

    /// `editPointItems`: Apply Default Transitions at the edit under the pointer.
    static func editPointItems(at p: CGPoint, panel: TimelinePanel, session s: EditorSession) -> [SQMenuItem] {
        guard case .clip(let id, let zone) = panel.geometry.hitTest(p, in: panel.timeline), zone != .body,
              let track = panel.timeline.tracks.first(where: { $0.clips.contains { $0.id == id } }), !track.isLocked else { return [] }
        let ref = EdgeRef(clip: id, edge: zone == .head ? .head : .tail)
        let scope: EditorSession.TransitionScope = track.kind == .video ? .video : .audio
        return [SQMenuItem(title: "Apply Default Transitions") { [weak s] in
            s?.applyDefaultTransitions(scope: scope, edges: EdgeSelection(edges: [ref]))
        }, .separator]
    }
}
