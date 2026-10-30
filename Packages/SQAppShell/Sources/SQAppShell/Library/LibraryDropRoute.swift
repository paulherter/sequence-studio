import Foundation
import SQCore
import SQDrawKit
import SQDrawLibrary
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQLibrary
import SQText
import SQTimelineUI

/// Drags from the Library and Effects panels onto the timeline, translated from the Mac `TimelineView` drop handlers and
/// their `EditorPanels` wiring (`onDropFiles`, `onDropTextTemplate`, `onDropTitleBlock`, `onDropPreset`, `onDropEffect`,
/// `commitTransitionDrop`). Files show the Project drop ghost and land where it showed after the import; templates and
/// titles show a 5 s ghost; effects, effect presets and transitions land on the clip or edit under the pointer.
/// shortcut: no hover highlight for effects, presets and transitions (the Mac box over the target edit or clip); upgrade
/// when TimelinePanel draws a transition drop target.
public enum LibraryDropRoute {
    /// What is dragged: a Library cell or Effects panel rows (effect kinds, `preset.<uuid>`, transition ids).
    public enum Payload: Equatable, Sendable {
        case library(LibraryDragPayload)
        case effects([String])
    }

    /// The Library's saved presets (title blocks, effect presets) and the file import of the Project panel.
    public struct Context {
        public var presets: [PresetItem]
        /// Imports the files, then places them where `action` (the `.dropMedia` of the ghost) says.
        public var importAndPlace: @MainActor ([URL], TimelineAction) -> Void
        public var status: @MainActor (String) -> Void
        public init(presets: [PresetItem], importAndPlace: @escaping @MainActor ([URL], TimelineAction) -> Void,
                    status: @escaping @MainActor (String) -> Void) {
            self.presets = presets; self.importAndPlace = importAndPlace; self.status = status
        }
    }

    /// One drag step at window pixels `x, y`. True when the release changed the timeline (or started the import).
    @MainActor @discardableResult
    public static func drag(_ payload: Payload, phase: TimelineDropRoute.Phase, x: Float, y: Float, modifiers mods: InputModifiers,
                            panel: inout TimelinePanel, session: EditorSession, context: Context) -> Bool {
        let over = panel.contains(x: x, y: y)
        let insert = mods.contains(.command)
        guard phase != .canceled else { panel.dropExit(); return false }
        switch payload {
        case .library(.files(let urls)):
            guard phase == .ended else {
                if over { panel.dropHover(items: TimelineDrop.items(for: .files(urls), in: session), x: x, y: y, insert: insert) }
                else { panel.dropExit() }
                return false
            }
            guard over, let a = panel.dropCommit(media: [], x: x, y: y, insert: insert).first else { panel.dropExit(); return false }
            context.importAndPlace(urls, a)
            return true
        case .library(.textTemplate(let id)):
            return ghostDrop(name: TextTemplateCatalog.entry(id: id)?.name ?? "", phase: phase, over: over, x: x, y: y, panel: &panel) { time, track in
                guard let entry = TextTemplateCatalog.entry(id: id) else { return }
                if entry.isCTA { session.addCTAEndCard(at: time, track: track); return }
                if let g = entry.graphicPresetID { session.addGraphicPreset(g, at: time, track: track); return }
                session.addTextClip(template: entry.template, at: time, track: track)
            }
        case .library(.titleBlock(let id)):
            guard let item = context.presets.first(where: { $0.id == id }) else { panel.dropExit(); return false }
            return ghostDrop(name: item.name, phase: phase, over: over, x: x, y: y, panel: &panel) { time, _ in
                context.status(TextTemplatePlacement.insertTitle(item, at: time, session: session))
            }
        case .library(.effectPreset(let id)):
            guard phase == .ended, over, let clip = panel.clipID(x: x, y: y),
                  let item = context.presets.first(where: { $0.id == id }) else { return false }
            if !session.applyPreset(item, to: [clip], mode: PresetApplyModeSetting.load()) {
                context.status(session.lastError ?? SQL10n.string("The preset could not be applied."))
            }
            return true
        case .effects(let ids):
            guard phase == .ended, over, let id = ids.first else { return false }
            if let kind = EffectDragPayload.transitionKind(forID: id) {
                return dropTransition(kind, at: panel.point(x: x, y: y), panel: panel, session: session)
            }
            guard let clip = panel.clipID(x: x, y: y) else { return false }
            if id.hasPrefix(presetPrefix), let uuid = UUID(uuidString: String(id.dropFirst(presetPrefix.count))),
               let item = context.presets.first(where: { $0.id == uuid }) {
                if !session.applyPreset(item, to: [clip], mode: PresetApplyModeSetting.load()) {
                    context.status(session.lastError ?? SQL10n.string("The preset could not be applied."))
                }
                return true
            }
            let targets = session.effectDropTargets(hit: clip)
            for kind in ids where !session.addEffect(kind: kind, to: targets) {
                context.status(SQL10n.format("%@ needs %@.", SQL10n.string(EffectsApply.title(kind)), SQL10n.string(EffectsApply.targetNoun(kind))))
            }
            return true
        }
    }

    static let presetPrefix = "preset."

    /// Templates and titles: a one-item ghost on the existing tracks, then `place` with its time and track.
    @MainActor
    static func ghostDrop(name: String, phase: TimelineDropRoute.Phase, over: Bool, x: Float, y: Float, panel: inout TimelinePanel,
                          place: (Time, Track.ID?) -> Void) -> Bool {
        let ghost = [DropItem(name: name, duration: Time(seconds: 5), hasVideo: true, hasAudio: false)]
        guard phase == .ended else {
            if over { panel.dropHover(items: ghost, x: x, y: y, insert: false, canCreateTracks: false) } else { panel.dropExit() }
            return false
        }
        guard over else { panel.dropExit(); return false }
        panel.dropHover(items: ghost, x: x, y: y, insert: false, canCreateTracks: false)
        guard case .dropMedia(_, let time, let track, _, _, _)? = panel.dropCommit(media: [], x: x, y: y, insert: false).first else {
            return false
        }
        place(time, track)
        return true
    }

    /// A transition on the cut or clip end under `p` (panel points), else a transition layer on an empty video spot
    /// (`TimelineView.commitTransitionDrop`).
    @MainActor
    static func dropTransition(_ kind: TransitionKind, at p: CGPoint, panel: TimelinePanel, session: EditorSession) -> Bool {
        let timeline = panel.timeline, geometry = panel.geometry
        guard let t = TransitionLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry) else {
            let d = session.transitionLayerDuration(kind)
            guard let l = TransitionLayerLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry, playhead: panel.playhead,
                                                           duration: d) else { return false }
            _ = session.addTransitionLayer(kind: kind, track: l.track, start: l.start, duration: l.duration, cut: l.cut)
            return true
        }
        if kind.isElement {
            switch t.point {
            case .head(let c): _ = session.addElementTransition(kind: kind, track: t.track, clip: c, edges: t.bothEnds ? [.head, .tail] : [.head])
            case .tail(let c): _ = session.addElementTransition(kind: kind, track: t.track, clip: c, edges: [.tail])
            case .cut: return false
            }
            return true
        }
        _ = session.addTransition(kind: kind, track: t.track, point: t.point, alignment: t.alignment)
        return true
    }
}

/// Double-click in the Effects panel (the Mac `EditorPanels` `effectsView.onApply`): built-in stack presets, saved
/// presets, transitions on the selected edit (else at the playhead), effects on the selected clips.
public enum EffectsApply {
    public static func targetNoun(_ kind: String) -> String {
        TextPresetCatalog.isTextPresetID(kind) ? "a text layer" : ClipEffect.isAudioKind(kind) ? "an audio clip" : "a video clip"
    }

    public static func title(_ kind: String) -> String {
        TextPresetCatalog.look(id: kind)?.name ?? TextPresetCatalog.motion(id: kind)?.name ?? EffectCatalog.title(for: kind)
    }

    @MainActor
    public static func apply(_ id: String, session: EditorSession, presets: [PresetItem], edges: EdgeSelection?,
                             status: (String) -> Void) {
        if id.hasPrefix(EditorSession.builtInPresetPrefix) {
            if !session.applyStackPreset(String(id.dropFirst(EditorSession.builtInPresetPrefix.count))) {
                status(session.lastError ?? SQL10n.string("The preset could not be applied."))
            }
            return
        }
        if id.hasPrefix(LibraryDropRoute.presetPrefix), let uuid = UUID(uuidString: String(id.dropFirst(LibraryDropRoute.presetPrefix.count))),
           let preset = presets.first(where: { $0.id == uuid }) {
            let ok = preset.kind == .transition
                ? session.applyTransitionPreset(preset, edges: edges)
                : session.applyPreset(preset, mode: PresetApplyModeSetting.load())
            if !ok { status(session.lastError ?? SQL10n.string("The preset could not be applied.")) }
            return
        }
        if let kind = EffectDragPayload.transitionKind(forID: id) {
            session.applyDefaultTransitions(scope: kind.trackKind == .video ? .video : .audio, edges: edges, kind: kind)
            return
        }
        session.flushFollowSelection()
        if !session.addEffect(kind: id, to: session.selection) {
            status(SQL10n.format("Select %@ first, then double-click %@.", SQL10n.string(targetNoun(id)), SQL10n.string(title(id))))
        }
    }
}
