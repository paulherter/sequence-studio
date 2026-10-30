import Foundation
import SQCore

/// Q-PERF2 rec 1: the display-link rate. While playing it is locked to the rate the picture changes at (sequence fps x
/// |speed|), so a 25/30 fps sequence is not shown on an uneven 60/120 Hz cadence (2:3 repeats = judder). Paused,
/// scrubbing, or faster than 120 frames/s: the interactive 60-120 Hz range. Pure.
enum FramePacing {
    struct Range: Equatable, Sendable {
        var minimum: Float
        var maximum: Float
        var preferred: Float
    }

    static let interactive = Range(minimum: 60, maximum: 120, preferred: 120)

    static func range(fps: Double, rate: PlaybackRate, scrubbing: Bool) -> Range {
        guard !rate.isPaused, !scrubbing, fps > 0 else { return interactive }
        let speed = max(1, Double(abs(Int64(rate.num))) / Double(rate.den))   // slow motion keeps the sequence rate
        let p = max(1, fps * speed)
        guard p <= 120 else { return interactive }
        let f = Float(p)
        // Up to 30 fps the system may pick an exact double (a 60 Hz panel shows 30 fps as 2:2, never 2:3).
        return Range(minimum: f, maximum: p <= 30 ? f * 2 : f, preferred: f)
    }
}

/// Frame-pacing bench stat: spread (max - min) of the intervals between presented frames while playing. 0 = one constant
/// cadence; ~16.7 ms on a 60 Hz panel = 2:3 judder.
struct PacingMeter: Sendable {
    let window: Int
    private var last: Double?
    private var intervals: [Double] = []

    init(window: Int = 120) { self.window = max(1, window) }

    mutating func record(_ seconds: Double) {
        if let l = last {
            intervals.append(seconds - l)
            if intervals.count > window { intervals.removeFirst(intervals.count - window) }
        }
        last = seconds
    }

    mutating func reset() { last = nil; intervals.removeAll() }

    var spreadMilliseconds: Double? {
        guard let lo = intervals.min(), let hi = intervals.max() else { return nil }
        return (hi - lo) * 1000
    }
}

/// Keeps the frame changes of steady play midway between display ticks. The frame a tick shows is
/// `grid(clock + offset)`; at every tick that moves one frame on, `offset` is nudged so the boundary just crossed lies
/// halfway between this tick's clock sample and the previous one (gain 1/2, whole microseconds, at most half a frame
/// either way). Without it a boundary that falls on a tick makes tick and clock jitter show one frame for 3 ticks and
/// the next for 1 (50 ms + 17 ms at 30 fps on 60 Hz). Works for any tick rate at or above the frame rate; the frames
/// shown are unchanged grid frames, only when each appears moves (a constant sub-frame shift against the audio). Pure.
struct FramePhaseLock: Sendable {
    /// Added to the clock before flooring to the frame grid.
    private(set) var offset: Time = .zero
    /// Off: `sample` returns the clock unchanged (tests, comparisons).
    var enabled = true
    private var previous: Time?

    static let quantum = Time(1, 1_000_000)

    mutating func reset() { offset = .zero; previous = nil }

    /// The position to floor to the grid for a playing tick at clock `now`.
    mutating func sample(_ now: Time, frameDuration fd: Time, reverse: Bool) -> Time {
        guard enabled, fd > .zero else { return now }
        let s = now + offset
        guard let p = previous else { previous = s; return s }
        previous = s
        let fp = p.frameIndex(frameDuration: fd), fs = s.frameIndex(frameDuration: fd)
        guard fs - fp == (reverse ? -1 : 1) else { return s }
        // Boundary just crossed; b = previous sample's distance to it, a = this sample's.
        let boundary = fd * (reverse ? fp : fs)
        let (b, a) = reverse ? (p - boundary, boundary - s) : (boundary - p, s - boundary)
        var delta = Time.scaled(reverse ? a - b : b - a, by: 1, over: 4).snapped(to: Self.quantum)
        let limit = fd.halved
        if offset + delta > limit { delta = limit - offset }
        if offset + delta < -limit { delta = -limit - offset }
        offset = offset + delta
        // The next crossing is measured in the new domain (the shown frame never steps back: |delta| <= a/4 or b/4).
        previous = s + delta
        return s
    }
}
