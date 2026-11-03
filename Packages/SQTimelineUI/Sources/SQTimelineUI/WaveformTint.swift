#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SQCore
import SQUIKit

/// Waveform ink by audio role: Dialogue, Music and SFX each get a tint so a creator reads the mix at a glance.
public enum WaveformTint {
    /// The one role every clip in the row shares (clip tag, else track role); nil when none or when they differ.
    /// shortcut: one ink per track row (the row's waveforms are one blended mask); per-clip ink in a mixed row needs a mask per role.
    public static func role(of track: Track, clips: [Clip]) -> AudioTag? {
        guard let first = clips.first.map({ track.role(of: $0) }) else { return track.audioRole }
        return clips.allSatisfy({ track.role(of: $0) == first }) ? first : nil
    }

}
