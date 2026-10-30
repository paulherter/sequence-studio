import SQCore

/// The "This clip does not match the sequence settings" question for hosts whose dialogs are asynchronous (the shared
/// draw-list shell). `confirmFormatChange` answers at once and serves the AppKit host; this one is awaited.
extension EditorSession {
    /// `placeMedia`, asking the format question first when the media would change an empty, never configured sequence.
    /// With no `askFormatChange` hook (or no mismatch) it is `placeMedia` at once. Otherwise it returns true and places once
    /// the answer is in (true: adopt the clip's format, false: keep the sequence settings); `finished` gets the result
    /// then, and `lastError` holds the reason when it is false.
    @discardableResult
    public func placeMediaAsking(_ ids: [MediaRef.ID], at time: Time? = nil, videoTrack: Track.ID? = nil,
                                 mode: ThreePointMode = .overwrite, streams: SourceStreams = .both, newTrack: TrackKind? = nil,
                                 finished: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        guard let ask = askFormatChange, let t = activeTimeline, !t.formatLocked, t.tracks.allSatisfy({ $0.clips.isEmpty }),
              let proposed = formatMismatch(placing: ids) else {
            let ok = placeMedia(ids, at: time, videoTrack: videoTrack, mode: mode, streams: streams, newTrack: newTrack)
            finished?(ok)
            return ok
        }
        let current = t.format
        Task { @MainActor [weak self] in
            let adopt = await ask(current, proposed)
            let ok = self?.placeMedia(ids, at: time, videoTrack: videoTrack, mode: mode, adoptFormat: adopt, streams: streams,
                                      newTrack: newTrack) ?? false
            finished?(ok)
        }
        return true
    }
}
