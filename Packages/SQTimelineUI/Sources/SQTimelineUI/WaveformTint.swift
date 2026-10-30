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

    #if canImport(AppKit)
    @MainActor static func color(for role: AudioTag?) -> CGColor {
        switch role {
        case nil: WaveformTileCache.color
        case .dialogue: Theme.Colors.accent.withAlphaComponent(0.85).cgColor
        case .music: Theme.Colors.green.withAlphaComponent(0.75).cgColor
        case .sfx: Theme.Colors.yellow.withAlphaComponent(0.75).cgColor
        }
    }
    #endif
}
