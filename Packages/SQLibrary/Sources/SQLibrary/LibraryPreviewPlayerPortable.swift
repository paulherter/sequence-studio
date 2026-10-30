#if !canImport(AVFoundation)
import Foundation
import Observation

/// Windows stand-in for the AVFoundation `LibraryPreviewPlayer` (same API, so `LibraryPanelModel` builds unchanged).
/// shortcut: no audio or video preview playback on Windows; selecting an item only records it. Upgrade when the
/// Windows media backend (Media Foundation / FFmpeg) offers a small preview player.
@MainActor @Observable
public final class LibraryPreviewPlayer {
    public private(set) var currentItemID: LibraryEntryID?
    public private(set) var mode: LibraryPreviewMath.Mode?
    public private(set) var isPlaying = false
    public private(set) var seconds: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var errorMessage: String?
    public var volume: Float = 0.8
    public var videoMuted = true
    public var audioMuted = false
    public var isMuted: Bool { mode == .video ? videoMuted : audioMuted }
    @ObservationIgnored public var onWillPlay: (() -> Void)?

    public init() {}

    public var fraction: Double { duration > 0 ? min(max(seconds / duration, 0), 1) : 0 }

    public func select(id: LibraryEntryID, url: URL, mode newMode: LibraryPreviewMath.Mode?) {
        currentItemID = id
        mode = newMode
    }

    public func play() {}
    public func pause() { isPlaying = false }
    public func togglePlayPause() {}
    public func seek(to t: Double) { seconds = LibraryPreviewMath.skipTarget(position: t, delta: 0, duration: duration) }
    public func scrub(toFraction f: Double) { if duration > 0 { seek(to: min(max(f, 0), 1) * duration) } }
    public func skip(by delta: Double) { seek(to: LibraryPreviewMath.skipTarget(position: seconds, delta: delta, duration: duration)) }

    public func stop() {
        isPlaying = false; currentItemID = nil; mode = nil; seconds = 0; duration = 0; errorMessage = nil
    }
}
#endif
