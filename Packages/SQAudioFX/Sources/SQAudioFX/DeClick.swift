import Foundation
import Synchronization

/// Automatic de-click fades: a few milliseconds of linear gain ramp at every audio clip boundary (head from silence,
/// tail to silence), so a hard cut never jumps in the waveform. A pure per-sample function of the absolute frame, so any
/// split of the timeline into render blocks gives identical samples (playback, scrub and export share it).
public enum AudioDeClick {
    /// UserDefaults key of the on/off setting (default on).
    public static let defaultsKey = "sq.audio.autoDeClick"
    public static let fadeMilliseconds = 3.0

    /// The setting; absent means on.
    public static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// The setting read from `defaults` (injectable for tests); absent means on.
    public static func isEnabled(in defaults: UserDefaults) -> Bool { defaults.object(forKey: defaultsKey) as? Bool ?? true }

    /// Fade length in frames at `sampleRate`, or 0 when the setting is off. Playback and export both take it from here.
    public static func currentFadeFrames(sampleRate: Int = 48_000, defaults: UserDefaults = .standard) -> Int {
        isEnabled(in: defaults) ? fadeFrames(sampleRate: sampleRate) : 0
    }

    public static func fadeFrames(sampleRate: Int) -> Int { max(1, Int((fadeMilliseconds / 1000 * Double(sampleRate)).rounded())) }

    /// Effective fade of a segment `[start, end)`: shrinks to half the segment for very short ones.
    @inline(__always)
    static func effectiveFade(_ fade: Int, start: Int64, end: Int64) -> Int64 {
        Int64(min(fade, max(1, Int((end - start) / 2))))
    }

    /// Gain at absolute `frame` of a segment covering `[start, end)`.
    @inline(__always)
    public static func edgeGain(frame: Int64, start: Int64, end: Int64, fade: Int) -> Float {
        guard fade > 0 else { return 1 }
        let f = effectiveFade(fade, start: start, end: end)
        let k = min(frame - start, end - 1 - frame)
        return k >= f ? 1 : Float(max(k, 0)) / Float(f)
    }

    /// Multiplies `samples` (frames `firstFrame..<firstFrame+count` of the segment `[start, end)`) by the edge gain.
    public static func apply(_ samples: UnsafeMutablePointer<Float>, count: Int, firstFrame: Int64, start: Int64, end: Int64, fade: Int) {
        guard fade > 0, count > 0 else { return }
        let f = effectiveFade(fade, start: start, end: end)
        let headEnd = max(0, min(Int64(count), start + f - firstFrame))          // block indices < headEnd are in the head fade
        let tailBegin = min(Int64(count), max(0, end - f - firstFrame))          // indices >= tailBegin are in the tail fade
        for i in 0..<Int(headEnd) { samples[i] *= edgeGain(frame: firstFrame + Int64(i), start: start, end: end, fade: fade) }
        for i in Int(max(tailBegin, headEnd))..<count { samples[i] *= edgeGain(frame: firstFrame + Int64(i), start: start, end: end, fade: fade) }
    }
}

/// Re-reads the de-click setting whenever `defaults` changes and reports the new fade length, so playback follows the
/// Preferences toggle live (no restart). `onChange` fires only when the value actually changed, on the thread that wrote
/// the default; keep it to an atomic store. Dropping the observer stops it.
public final class AudioDeClickObserver: @unchecked Sendable {
    private let defaults: UserDefaults
    private let sampleRate: Int
    private let onChange: @Sendable (Int) -> Void
    private let last: Mutex<Int>
    private var token: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard, sampleRate: Int = 48_000, onChange: @escaping @Sendable (Int) -> Void) {
        self.defaults = defaults; self.sampleRate = sampleRate; self.onChange = onChange
        last = Mutex(AudioDeClick.currentFadeFrames(sampleRate: sampleRate, defaults: defaults))
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    /// Applies the current value if it differs from the last reported one.
    public func refresh() {
        let now = AudioDeClick.currentFadeFrames(sampleRate: sampleRate, defaults: defaults)
        let changed = last.withLock { old -> Bool in
            defer { old = now }
            return old != now
        }
        if changed { onChange(now) }
    }
}
