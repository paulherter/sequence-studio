import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession

/// Drags onto the timeline from the shared panels (the Project list's items, the Source monitor's clip), translated from
/// the Mac `EditorPanels` drop wiring: the ghost while over the timeline, Cmd inserts, Alt on release over a clip is a
/// Replace edit (Shift with the Source showing that media lines its frame up with the playhead).
public enum TimelineDropRoute {
    public enum Phase: Sendable, Equatable { case moved, ended, canceled }

    /// Media win over sequences in a mixed selection (the Mac list drags one kind at a time).
    public static func source(_ refs: [BinItemRef]) -> TimelineDropSource? {
        let media = refs.compactMap { if case .media(let id) = $0 { id } else { nil } }
        if !media.isEmpty { return .media(media) }
        let seqs = refs.compactMap { if case .sequence(let id) = $0 { id } else { nil } }
        return seqs.isEmpty ? nil : .sequences(seqs)
    }

    /// One drag step at window pixels `x, y`. `sourceTime`: the Source monitor's frame when it shows that media (Shift
    /// replace). Returns true when the release placed or replaced something (the app refreshes its media tables); a
    /// failed edit's message goes to `status`.
    @MainActor @discardableResult
    public static func drag(_ item: TimelineDropSource, streams: SourceStreams = .both, phase: Phase, x: Float, y: Float,
                            modifiers mods: InputModifiers, panel: inout TimelinePanel, session: EditorSession,
                            sourceTime: (MediaRef.ID) -> Time? = { _ in nil }, status: (String) -> Void) -> Bool {
        let over = panel.contains(x: x, y: y), insert = mods.contains(.command)
        switch phase {
        case .moved:
            if over {
                panel.dropHover(items: TimelineDrop.items(for: item, in: session, streams: streams), x: x, y: y,
                                insert: insert, streams: streams)
            } else { panel.dropExit() }
            return false
        case .ended:
            if over, mods.contains(.option), let clip = panel.clipID(x: x, y: y) {
                panel.dropExit()
                var match: Time?
                if mods.contains(.shift), case .media(let ids) = item, let id = ids.first { match = sourceTime(id) }
                if !TimelineDrop.replace(item, clip: clip, matchSourceTime: match, in: session), let e = session.lastError { status(e) }
                return true
            }
            guard over, let a = panel.dropCommit(media: [], x: x, y: y, insert: insert).first else {
                panel.dropExit(); return false
            }
            if !TimelineDrop.place(item, at: a, in: session), let e = session.lastError { status(e) }
            return true
        case .canceled:
            panel.dropExit()
            return false
        }
    }
}
