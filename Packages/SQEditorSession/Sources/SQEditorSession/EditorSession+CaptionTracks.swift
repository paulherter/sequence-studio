import Foundation
import SQCore

/// Caption tracks like Premiere's: created with the first caption, named "Captions N", one look per track, the
/// Captions panel follows the selection and shows the sequence's captions automatically.
extension EditorSession {
    /// The track the Look tab edits: the track of the first selected caption, else the focused track, else the first one.
    public var currentCaptionTrack: CaptionTrack? {
        guard let tl = activeTimeline else { return nil }
        for id in captionSelection {
            if let tid = tl.captionTrackID(containing: id), let t = tl.captionTrack(tid) { return t }
        }
        if let f = captionTrackFocus, let t = tl.captionTrack(f) { return t }
        return tl.captionTracks.first
    }

    /// Picks the caption track the Look tab (scope All Captions) edits and new captions go to.
    public func focusCaptionTrack(_ id: CaptionTrack.ID?) {
        guard captionTrackFocus != id else { return }
        captionTrackFocus = id
        notify(.selection)
    }

    /// Adds an empty caption track ("Captions N") and focuses it; new captions go there (`captionTrackFocus`).
    @discardableResult
    public func addCaptionTrack() -> CaptionTrack.ID? {
        var made: CaptionTrack.ID?
        guard attempt("Add Caption Track", { made = $0.addCaptionTrack() }), let made else { return nil }
        captionTrackFocus = made
        notify(.selection)
        return made
    }

    /// True when any selected caption deviates from its track look (style, animation or position).
    public var selectedCaptionsHaveOverrides: Bool {
        let ids = captionSelection
        return captionItems.contains { ids.contains($0.id) && ($0.styleOverridden || $0.position != nil) }
    }

    /// "Reset to Track Look": the selected captions follow their track again (style, animation, position).
    @discardableResult
    public func resetSelectedCaptionsToTrackLook() -> Bool {
        guard !captionSelection.isEmpty, let tlID = activeTimelineID else { return false }
        let ids = captionSelection
        let before = history.current
        do {
            try perform("Reset to Track Look") { p in
                try p.edit(tlID) { try $0.resetCaptionItemsToTrackLook(ids) }
                CaptionStyleEdit.pruneOwnLooks(&p)
            }
        } catch { setError(Self.message(for: error)); return false }
        return history.current != before
    }
}
