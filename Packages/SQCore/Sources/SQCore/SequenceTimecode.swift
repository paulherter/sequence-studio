import Foundation

// v81: per-sequence timecode start / display and preview quality. Each is stored only when not the default, so untouched
// sequences encode as before; a sequence with any of them makes the file v81 (ProjectFile+V81.swift).

/// How positions of a sequence are shown: as timecode (HH:MM:SS:FF) or as a plain frame count.
public enum TimecodeDisplay: String, Codable, Sendable, CaseIterable {
    case timecode, frames
}

/// Preview resolution a sequence asks for when it becomes active. nil on the sequence = follow the app setting (Auto).
public enum SequencePreviewQuality: String, Codable, Sendable, CaseIterable {
    case full, half, quarter
}

extension Timeline {
    /// Timecode of the first frame (default 0): shifts the shown positions only; clips, markers and export keep their times.
    /// Never negative, kept on a whole frame.
    public var timecodeStart: Time {
        get { timecodeStartStore ?? .zero }
        set {
            let t = newValue < .zero ? Time.zero : newValue.snapped(to: frameDuration)
            timecodeStartStore = t == .zero ? nil : t
        }
    }
    public var timecodeDisplay: TimecodeDisplay {
        get { timecodeDisplayStore ?? .timecode }
        set { timecodeDisplayStore = newValue == .timecode ? nil : newValue }
    }
    /// nil = follow the app setting.
    public var previewQuality: SequencePreviewQuality? {
        get { previewQualityStore }
        set { previewQualityStore = newValue }
    }
}
