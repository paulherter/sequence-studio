import Foundation
import Synchronization

/// Diagnostics: when the frames of a playing engine really reached the glass (`MTLDrawable.presentedTime`), next to the
/// time the display link asked for. Off unless `PlaybackEngine.presentProbe` is set (EngineBench `project-play --window`):
/// the headless bench measures the engine's own cost, this measures what the viewer sees.
public final class PresentProbe: Sendable {
    public struct Sample: Sendable, Equatable {
        /// Timeline position of the presented frame, seconds.
        public var time: Double
        /// Host time the display link asked this frame to be shown at.
        public var target: Double
        /// Host time the frame reached the glass; 0 = the window server never showed it.
        public var presented: Double
        /// Host time the render tick started, and how long it took (seconds).
        public var tickStart: Double
        public var tickDuration: Double
        /// Clock position (seconds, not snapped) the tick read; nil = not recorded.
        public var clock: Double?
        /// False: a paused frame (the one a pause, seek or stop parked on). Takes no part in intervals and skips.
        public var playing: Bool

        public init(time: Double, target: Double, presented: Double, tickStart: Double = 0, tickDuration: Double = 0,
                    clock: Double? = nil, playing: Bool = true) {
            self.time = time; self.target = target; self.presented = presented
            self.tickStart = tickStart; self.tickDuration = tickDuration; self.clock = clock; self.playing = playing
        }
    }

    /// What a run of samples looked like on glass. All times in ms.
    public struct Summary: Sendable, Equatable {
        /// Frames presented, and those the window server never showed.
        public var frames = 0, neverShown = 0
        /// Sorted intervals between frames on glass.
        public var intervals: [Double] = []
        /// Intervals longer than one sequence frame plus half a frame: a frame visibly stayed too long.
        public var late = 0
        /// Sequence frames that were never presented (the playhead jumped over them).
        public var skipped = 0
        /// Sorted distance between the time on glass and the time the display link asked for (positive = later).
        public var offsets: [Double] = []
        /// Sorted picture minus sound on glass: the middle of the shown frame minus the clock position at the moment it
        /// reached the glass (clock read by the tick + time from tick start to glass, rate 1). 0 = the frame is centered
        /// on its time; negative = the picture is shown late.
        public var avOffsets: [Double] = []
        /// Sequence frames the picture stepped back when a paused frame followed the last playing one on glass (0 = the
        /// pause stayed on the frame last shown, or went forward).
        public var pauseStepBack = 0

        public func percentile(_ q: Double, of v: [Double]) -> Double {
            guard !v.isEmpty else { return 0 }
            let r = Int((q * Double(v.count)).rounded(.up)) - 1
            return v[min(max(r, 0), v.count - 1)]
        }
    }

    private let samples = Mutex<[Sample]>([])

    public init() {}

    func record(_ s: Sample) { samples.withLock { $0.append(s) } }

    /// The samples so far, in the order they reached the glass; `reset` forgets them.
    public func take(reset: Bool = true) -> [Sample] {
        samples.withLock { s in
            let out = s.sorted { ($0.presented == 0 ? $0.target : $0.presented) < ($1.presented == 0 ? $1.target : $1.presented) }
            if reset { s.removeAll() }
            return out
        }
    }

    /// `frameDuration` in seconds (the sequence frame). Frames that never reached the glass count in `neverShown` and
    /// take no part in the intervals: the frame before them simply stayed longer.
    public static func summarize(_ samples: [Sample], frameDuration: Double) -> Summary {
        var out = Summary()
        let onGlass = samples.filter { $0.presented > 0 }.sorted { $0.presented < $1.presented }
        let playing = samples.filter(\.playing)
        out.frames = playing.count
        let shown = onGlass.filter(\.playing)
        out.neverShown = playing.count - shown.count
        guard frameDuration > 0 else { return out }
        for (a, b) in zip(onGlass, onGlass.dropFirst()) where a.playing && !b.playing {
            out.pauseStepBack = max(out.pauseStepBack, Int(((a.time - b.time) / frameDuration).rounded()))
        }
        for (a, b) in zip(shown, shown.dropFirst()) {
            let dt = (b.presented - a.presented) * 1000
            out.intervals.append(dt)
            if dt > frameDuration * 1500 { out.late += 1 }
            let step = Int(((b.time - a.time) / frameDuration).rounded())
            if step > 1 { out.skipped += step - 1 }
        }
        out.intervals.sort()
        out.offsets = shown.map { ($0.presented - $0.target) * 1000 }.sorted()
        out.avOffsets = shown.compactMap { s -> Double? in
            guard let c = s.clock, s.tickStart > 0 else { return nil }
            let atGlass = c + s.presented - s.tickStart
            return (s.time + frameDuration / 2 - atGlass) * 1000
        }.sorted()
        return out
    }

    /// One drawable on its way to the glass: the tick fills in the frame, the presented handler the time; the sample is
    /// recorded when both are there. A tick that presented nothing discards it.
    final class Slot: Sendable {
        private struct State { var sample: Sample?; var presented: Double?; var done = false }
        private let state = Mutex(State())
        private let probe: PresentProbe

        init(_ probe: PresentProbe) { self.probe = probe }

        func commit(_ s: Sample) { finish { $0.sample = s } }
        func presented(at t: Double) { finish { $0.presented = t } }
        func discard() { state.withLock { $0.done = true } }

        private func finish(_ change: (inout State) -> Void) {
            let s = state.withLock { st -> Sample? in
                guard !st.done else { return nil }
                change(&st)
                guard var s = st.sample, let p = st.presented else { return nil }
                st.done = true
                s.presented = p
                return s
            }
            if let s { probe.record(s) }
        }
    }
}
