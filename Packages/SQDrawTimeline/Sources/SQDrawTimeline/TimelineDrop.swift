import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI

/// What a drag onto the timeline carries: the part of the Mac `TimelineView.DropSource` a draw-list host drags (Project
/// list media and sequences, files from the system file manager).
public enum TimelineDropSource: Equatable, Sendable {
    case media([MediaRef.ID])
    case sequences([Timeline.ID])
    case files([URL])
}

/// The host side of a timeline drop, translated from the Mac `EditorPanels` drop wiring: the ghost items while the drag
/// runs (`dropItems(for:)`) and the session call on release (`onDropMedia`, `onDropSequences`, their ghost-row variants).
@MainActor
public enum TimelineDrop {
    /// Length and streams of what is dragged, for the ghost. Files not imported yet get the 5 s placeholder.
    public static func items(for source: TimelineDropSource, in session: EditorSession,
                             streams: SourceStreams = .both) -> [DropItem] {
        switch source {
        case .media(let ids):
            let marks = session.project.sourceMarks
            return ids.compactMap { id -> DropItem? in
                guard let ref = session.project.media(id) else { return nil }
                let total = ref.info?.duration ?? ref.duration
                guard let d = marks[id]?.range?.duration ?? total else { return nil }
                return DropItem(name: ref.name, duration: d,
                                hasVideo: (ref.info?.video != nil || ref.info == nil) && streams.includesVideo,
                                hasAudio: ref.info?.audio != nil && streams.includesAudio)
            }
        case .sequences(let ids):
            let fd = session.activeTimeline?.frameDuration ?? Time(1, 30)
            return ids.compactMap { id -> DropItem? in
                guard let t = session.project.timeline(id), let d = session.project.nestedLength(of: id, hostFrameDuration: fd) else { return nil }
                return DropItem(name: t.name, duration: d, hasVideo: true,
                                hasAudio: t.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty })
            }
        case .files(let urls):
            // Not probed yet: guess the streams from the extension (video files carry audio, stills do not). The stills
            // are SQCore's `MediaRef.imageExtensions` (SQMedia's `StillImage` list is Apple-only).
            let still: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp", "psd", "exr", "dng",
                                      "svg", "pdf"]
            let sound: Set<String> = ["wav", "aif", "aifc", "aiff", "mp3", "m4a", "aac", "flac", "caf", "ogg", "opus"]
            return urls.map { u in
                let e = u.pathExtension.lowercased()
                return DropItem(name: u.lastPathComponent, duration: Time(seconds: 5),
                                hasVideo: !sound.contains(e), hasAudio: !still.contains(e))
            }
        }
    }

    /// Places `source` where the `.dropMedia` action of `TimelinePanel.dropCommit` says (the ghost's time, track or new
    /// track, insert). Media and sequences land as one undo step; files return false (the host imports them first, then
    /// calls this with their media ids). A refused drop returns false (the session sets `lastError`).
    @discardableResult
    public static func place(_ source: TimelineDropSource, at action: TimelineAction, in session: EditorSession) -> Bool {
        guard case .dropMedia(_, let time, let track, let newTrack, let insert, let streams) = action else { return false }
        let mode: ThreePointMode = insert ? .insert : .overwrite
        switch source {
        case .media(let ids):
            return session.placeMediaAsking(ids, at: time, videoTrack: track, mode: mode, streams: streams, newTrack: newTrack)
        case .sequences(let ids):
            return session.placeSequences(ids, at: time, videoTrack: track, mode: mode, newTrack: newTrack)
        case .files: return false
        }
    }

    /// Alt (the Mac Option) held as Project media or a sequence is released over a clip: a Replace edit with the first item
    /// (`TimelineView.isReplaceDrop`, `onReplaceMedia` / `onReplaceSequence`). `matchSourceTime`: Shift with the Source
    /// monitor showing that media, its frame lines up with the playhead. Files return false (they are not imported yet).
    @discardableResult
    public static func replace(_ source: TimelineDropSource, clip: Clip.ID, matchSourceTime: Time?, in session: EditorSession) -> Bool {
        switch source {
        case .media(let ids): return !ids.isEmpty && session.replaceMedia(of: clip, withFirstOf: ids, matchSourceTime: matchSourceTime)
        case .sequences(let ids): return ids.first.map { session.replaceWithSequence(of: clip, with: $0) } ?? false
        case .files: return false
        }
    }
}
