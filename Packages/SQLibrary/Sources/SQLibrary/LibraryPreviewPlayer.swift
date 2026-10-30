import AVFoundation
import Foundation
import Observation

/// Plays one Library audio or video item at a time through an own AVPlayer. It never touches the timeline engine:
/// the host pauses the sequence through `onWillPlay` and calls `pause()` when sequence playback starts.
/// Unreadable or undecodable files set `errorMessage` instead of throwing.
@MainActor @Observable
public final class LibraryPreviewPlayer {
    public private(set) var currentItemID: LibraryEntryID?
    public private(set) var mode: LibraryPreviewMath.Mode?
    public private(set) var isPlaying = false
    public private(set) var seconds: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var errorMessage: String?
    /// 0...1, shared by audio and video.
    public var volume: Float = 0.8 { didSet { player?.volume = min(max(volume, 0), 1) } }
    /// Video starts muted (a clip's sound should not surprise); audio items never start muted.
    public var videoMuted = true { didSet { applyMute() } }
    public var audioMuted = false { didSet { applyMute() } }
    public var isMuted: Bool { mode == .video ? videoMuted : audioMuted }

    /// The host stops sequence playback here (called right before the preview starts).
    @ObservationIgnored public var onWillPlay: (() -> Void)?
    /// For the video viewer layer; nil for audio and images.
    @ObservationIgnored public private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init() {}

    isolated deinit { releaseCurrent() }

    public var fraction: Double { duration > 0 ? min(max(seconds / duration, 0), 1) : 0 }

    /// Selects an item: stops the previous one and (for audio and video) starts the new one.
    public func select(id: LibraryEntryID, url: URL, mode newMode: LibraryPreviewMath.Mode?) {
        if currentItemID == id, player != nil || newMode == .image { return }
        stop()
        currentItemID = id
        mode = newMode
        guard let newMode, newMode != .image else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = "Can't open this file. Check that it still exists and is readable."
            return
        }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.volume = min(max(volume, 0), 1)
        p.isMuted = isMuted
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying || self.seconds == 0 else { return }
                let s = t.seconds
                if s.isFinite { self.seconds = s }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.player?.seek(to: .zero)
                self.seconds = 0
            }
        }
        let id = id
        loadTask = Task { [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let length = (try? await asset.load(.duration).seconds) ?? 0
            guard let self, !Task.isCancelled, self.currentItemID == id else { return }
            if playable {
                self.duration = length.isFinite ? max(length, 0) : 0
            } else {
                self.releaseCurrent()
                self.isPlaying = false
                self.errorMessage = "This file can't be played."
            }
        }
        play()
    }

    public func play() {
        guard let player else { return }
        onWillPlay?()
        if duration > 0, seconds >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
    }

    public func togglePlayPause() { if isPlaying { pause() } else { play() } }

    public func seek(to t: Double) {
        let target = LibraryPreviewMath.skipTarget(position: t, delta: 0, duration: duration)
        seconds = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func scrub(toFraction f: Double) { if duration > 0 { seek(to: min(max(f, 0), 1) * duration) } }

    public func skip(by delta: Double) {
        seek(to: LibraryPreviewMath.skipTarget(position: seconds, delta: delta, duration: duration))
    }

    public func stop() {
        loadTask?.cancel(); loadTask = nil
        releaseCurrent()
        isPlaying = false
        currentItemID = nil
        mode = nil
        seconds = 0
        duration = 0
        errorMessage = nil
    }

    // MARK: private

    private func applyMute() { player?.isMuted = isMuted }

    private func releaseCurrent() {
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
