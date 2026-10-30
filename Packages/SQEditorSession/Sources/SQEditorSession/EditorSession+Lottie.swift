import Foundation
import SQCore

/// Lottie clips: an animation file the user picked, placed as a generator clip (drawn by SQLottie in playback and export).
extension EditorSession {
    /// Places the Lottie animation `json` (file name `name`) at `time` (default: playhead) on `track`, else on the topmost
    /// unlocked video track that is free there, with the animation's own length. One undo step; selects the new clip.
    /// A file that is not a usable Lottie document, or a missing sequence, goes to `lastError`.
    @discardableResult
    public func addLottieClip(json: Data, name: String, at time: Time? = nil, track: Track.ID? = nil) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        guard let info = LottieInfo.parse(json) else { setError(LottieImportError.invalid.localizedDescription); return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let duration = info.duration.ceiled(to: t.frameDuration)
        guard let chosen = Self.generatorTrack(in: t, for: TimeRange(start: start, duration: duration), preferred: track) else {
            setError("There is no video track for the animation."); return nil
        }
        var newID: Clip.ID?
        do {
            try perform("Add Lottie Animation") { p in
                newID = try p.addLottieClip(json: json, name: name, in: tl, at: start, track: chosen)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Reads a Lottie file and places it (see `addLottieClip(json:name:at:track:)`). Over-size or unreadable files go to `lastError`.
    @discardableResult
    public func addLottieClip(contentsOf url: URL, at time: Time? = nil, track: Track.ID? = nil) -> Clip.ID? {
        let size = FileWalk.Values.read(url, keys: [.fileSizeKey])?.fileSize ?? 0
        guard size <= LottieLimits.maxBytes, let data = try? Data(contentsOf: url) else {
            setError(LottieImportError.invalid.localizedDescription); return nil
        }
        return addLottieClip(json: data, name: url.lastPathComponent, at: time, track: track)
    }
}
