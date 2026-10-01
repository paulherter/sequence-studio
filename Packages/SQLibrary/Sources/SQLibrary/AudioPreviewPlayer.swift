import AVFoundation
import Foundation
import Observation
import SQCore

/// Plays one library audio item at a time. Starting another item stops the current one.
/// Call `stop()` when the Library panel hides. Space in the panel maps to `togglePlayPause()`.
@MainActor @Observable
public final class AudioPreviewPlayer {
    public enum LoadError: Error { case unreadable }

    public private(set) var currentItemID: String?
    public private(set) var isPlaying = false
    public private(set) var position: Time = .zero
    public private(set) var duration: Time = .zero
    public private(set) var range = PreviewRange(duration: .zero)

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    public init() {}

    public var fraction: Double { PreviewTimeMap.fraction(time: position, duration: duration) }

    /// Loads the item (stopping any other) and starts playing from the in point.
    public func play(itemID: String, url: URL) throws {
        if currentItemID != itemID { try load(itemID: itemID, url: url) }
        guard let player else { return }
        if position >= range.outPoint || position < range.inPoint { seek(to: range.inPoint) }
        player.play()
        isPlaying = true
        startTimer()
    }

    public func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause(); isPlaying = false; stopTimer()
        } else {
            if position >= range.outPoint { seek(to: range.inPoint) }
            player.play(); isPlaying = true; startTimer()
        }
    }

    public func scrub(toFraction f: Double) {
        seek(to: PreviewTimeMap.time(fraction: f, duration: duration))
    }

    public func seek(to t: Time) {
        let c = min(max(t, .zero), duration)
        position = c
        player?.currentTime = seconds(c)
    }

    public func setIn(_ t: Time) { range.setIn(t) }
    public func setOut(_ t: Time) { range.setOut(t) }

    /// Range to attach to a drag of the current item; nil if nothing loaded or selection empty.
    public var dragRange: TimeRange? { currentItemID == nil ? nil : range.timeRange }

    public func stop() {
        player?.stop()
        player = nil
        stopTimer()
        isPlaying = false
        currentItemID = nil
        position = .zero
        duration = .zero
        range = PreviewRange(duration: .zero)
    }

    // MARK: private

    private func load(itemID: String, url: URL) throws {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { throw LoadError.unreadable }
        p.prepareToPlay()
        player = p
        currentItemID = itemID
        duration = Time(Int64((p.duration * 1000).rounded()), 1000)
        range = PreviewRange(duration: duration)
        position = .zero
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let player else { return }
        let t = Time(Int64((player.currentTime * 1000).rounded()), 1000)
        position = min(t, duration)
        if !player.isPlaying || t >= range.outPoint {
            player.pause()
            isPlaying = false
            stopTimer()
            position = min(t, range.outPoint)
        }
    }

    private func seconds(_ t: Time) -> TimeInterval { Double(t.value) / Double(t.timescale) }
}
