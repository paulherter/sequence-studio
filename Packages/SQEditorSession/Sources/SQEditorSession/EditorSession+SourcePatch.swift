import Foundation
import SQCore

/// Source patching (MON-30 / TL-44): the V / A chips left of the track headers decide where Insert / Overwrite put the
/// source's video and audio. The patch belongs to its sequence (`Timeline.sourcePatch`, saved with the project from
/// v88) and each change is one undo step, so it survives a relaunch and Cmd+Z takes it back.
extension EditorSession {
    /// The active sequence's patch (default: video to V1, audio to A1, both connected).
    public var sourcePatch: SourcePatch { activeTimeline?.sourcePatch ?? SourcePatch() }

    /// Click on a patch chip: disconnects that stream, or connects it again to the same track.
    public func toggleSourcePatch(_ kind: TrackKind) {
        guard activeTimelineID != nil else { return }
        var p = sourcePatch
        p.toggleConnection(kind)
        let stream = kind == .video ? "Video" : "Audio"
        setSourcePatch(p, name: p[kind].isConnected ? "Connect Source \(stream)" : "Disconnect Source \(stream)")
    }

    /// Chip dragged onto track `track`: that stream is patched there (and connected). Another kind changes nothing.
    public func patchSource(_ kind: TrackKind, to track: Track.ID) {
        guard let t = activeTimeline else { return }
        var p = sourcePatch
        p.patch(kind, to: track, in: t)
        guard p != sourcePatch else { return }
        setSourcePatch(p, name: "Patch Source")
    }

    /// Option+click on a chip: only that stream stays connected (again: both).
    public func soloSourcePatch(_ kind: TrackKind) {
        guard activeTimelineID != nil else { return }
        var p = sourcePatch
        p.solo(kind)
        guard p != sourcePatch else { return }
        setSourcePatch(p, name: "Solo Source \(kind == .video ? "Video" : "Audio")")
    }

    /// Shift+drag of a chip: this stream goes to `track`, the other one moves by the same number of tracks.
    public func patchSourceBoth(_ kind: TrackKind, to track: Track.ID) {
        guard let t = activeTimeline else { return }
        var p = sourcePatch
        p.patchBoth(kind, to: track, in: t)
        guard p != sourcePatch else { return }
        setSourcePatch(p, name: "Patch Source")
    }

    private func setSourcePatch(_ p: SourcePatch, name: String) {
        guard attempt(name, { $0.sourcePatch = p }) else { return }
        notify(.sourcePatch)
    }
}
