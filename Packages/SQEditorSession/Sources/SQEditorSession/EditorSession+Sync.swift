import Foundation
import SQCore

/// Right-click on an out-of-sync clip: Move into Sync / Slip into Sync. One undo step each.
extension EditorSession {
    public func moveIntoSync(_ id: Clip.ID) { attempt("Move into Sync") { try $0.moveIntoSync(id) } }
    public func slipIntoSync(_ id: Clip.ID) { attempt("Slip into Sync") { try $0.slipIntoSync(id) } }
}

/// Audio sync with drift and timecode mode. The app reads the envelopes (SQMedia `AnglesSync.envelope`) or start
/// timecodes (`AnglesSync.startTimecode`), builds the fit with SQCore `AudioDriftFit.fit` / `.timecode`, and calls this.
extension EditorSession {
    /// Moves the clip (with its linked partners) so its recording lines up with the reference clip's and, with
    /// `retime`, corrects the drift by a constant speed: one undo step. False with `lastError` set when refused
    /// (reference retimed, locked track, no room before 0).
    /// Reference and targets of Sync Audio to Reference for the current selection (nil: fewer than two usable clips).
    public var syncAudioPlan: SyncAudioPlan? { activeTimeline?.syncAudioPlan(selection: selection) }

    static func syncAudioActionName(for method: AudioDriftFit.Method) -> String {
        switch method {
        case .sound: "Sync Audio"
        case .timecode: "Sync by Timecode"
        case .captureDate: "Sync by Capture Date"
        }
    }

    /// Warning for clips that were placed by whole-second capture dates (no shared sound, no timecode); nil when none were.
    public static func captureDateWarning(count: Int) -> String? {
        guard count > 0 else { return nil }
        let which = count == 1 ? "1 clip was" : "\(count) clips were"
        return "\(which) placed by capture date only, which is accurate to about a second. Check the sync by ear."
    }

    @discardableResult
    public func syncAudio(_ id: Clip.ID, to reference: Clip.ID, fit: AudioDriftFit.Fit, retime: Bool = true) -> Bool {
        attempt(Self.syncAudioActionName(for: fit.method)) {
            try $0.syncAudio(id, to: reference, fit: fit, retime: retime)
        }
    }
}
