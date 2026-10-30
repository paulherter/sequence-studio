import Foundation
import SQCore

/// Display lead: a display-link tick runs some time before its frame reaches the glass (about 83 ms for 30 fps on a
/// 120 Hz panel). The clock is read at tick time, so the frame for that position would be shown that much after its
/// sound. While playing, the tick therefore picks the frame for `clock + (presentAt - host now) x rate`: the position
/// the clock will have when the frame is shown.
///
/// Only the picked video frame leads. The position reported to the host (playhead, timecode) and the audio stay on the
/// clock. A pause parks on the last frame handed to the display (`RenderLoop.park`).
///
/// - The lead is this tick's real presentation target, clamped to 0...`maximumSeconds`, in whole microseconds, times
///   the rate. A late tick (target already passed) or a bad timestamp reuses the last lead.
/// - Paused (seek, scrub, step, start gate) or without a timestamp (headless ticks): no lead, the exact frame at the clock.
/// - Play start on a display: the clock is started one lead after play (`PlayStart`), so the lead is full from the first
///   playing tick (`prime`) and every frame from the start position is shown in order.
/// - Without that (headless, a direction change while playing) the applied lead follows the wanted one by at most
///   1/`rampDivisor` of the distance the clock moved since the last tick, both ways: the picture catches up in single
///   frames, and when the rate drops (shuttle 2x to 1x) it slows down instead of stepping back. Once the applied lead
///   has reached the wanted one it is exactly that: nothing accumulates.
/// - A seek while playing (loop wrap) keeps the lead.
/// - `bounds`: the picture never leads out of the play range it is still inside (the host stops there). With `loops`
///   it does: the caller wraps the led position into the range (`wrapped`), so the frames after the wrap are shown.
///
/// Pure; export and offline rendering never come through here (they have no display).
struct DisplayLead: Sendable {
    /// Longest host-time lead taken from a presentation timestamp: a bad timestamp cannot jump the picture.
    static let maximumSeconds = 0.150
    /// The applied lead changes by 1/`rampDivisor` of the distance played.
    static let rampDivisor: Int64 = 8
    static let quantum = Time(1, 1_000_000)
    /// `SQ_DISPLAY_LEAD=0` turns the lead off (A/B in EngineBench `project-play --window`).
    static let enabledByDefault = ProcessInfo.processInfo.environment["SQ_DISPLAY_LEAD"] != "0"
    /// The floor holds the picture for a clock at most this many frames behind, for at most this many ticks.
    static let floorFrames: Int64 = 6
    static let floorTicksLimit = 30

    var enabled = DisplayLead.enabledByDefault
    var bounds: TimeRange?
    /// The engine wraps playback inside `bounds`: the led position is not held at its ends.
    var loops = false
    /// Clock position of the previous playing tick (nil: not playing yet).
    private var previous: Time?
    /// Lead in use, timeline time, as a distance (never negative).
    private var applied = Time.zero
    private var reverse = false
    /// The last usable host lead.
    private var hostLead = Time.zero
    /// The next playing tick starts with the full lead (`prime`).
    private var primed = false
    /// The picture does not go behind this position (the last frame the play start showed) until the clock is past it.
    private var floor: Time?
    private var floorTicks = 0

    mutating func reset() { previous = nil; applied = .zero; hostLead = .zero; primed = false; floor = nil; floorTicks = 0 }

    /// A play start laid out on the display ends (the clock runs now): the lead is full from the first tick, and the
    /// picture stays on `floor`, the last position the play start showed, while a clock that started late is behind it.
    mutating func prime(floor: Time?, hostLead: Time) {
        reset()
        primed = true
        self.floor = floor
        self.hostLead = hostLead
    }

    /// Host time from now until the frame is shown, clamped to 0...`maximumSeconds`, whole microseconds. Zero without a
    /// usable timestamp or when that time has passed.
    static func hostLead(presentAt: Double?, hostNow: Double) -> Time {
        guard let presentAt, presentAt.isFinite, hostNow.isFinite else { return .zero }
        let d = presentAt - hostNow
        guard d > 0 else { return .zero }
        return Time(Int64((min(d, maximumSeconds) * 1_000_000).rounded()), 1_000_000)
    }

    /// Where a pause parks: the newest frame handed to the display (`handed`), which is ahead of the clock frame
    /// `clock` by the lead. Unless the clock ran on from it in play direction by more than the largest lead (the
    /// picture was held for a cold layer while sound and playhead went on): then the clock frame, so neither jumps
    /// back; the picture goes forward to it. `loop`: the picture is past the wrap before the clock is.
    static func parkPosition(handed: Time?, clock: Time, rate: PlaybackRate, loop: TimeRange?) -> Time {
        guard let handed, !rate.isPaused else { return handed ?? clock }
        var past = rate.isReverse ? handed - clock : clock - handed
        if let loop {
            let length = loop.end - loop.start
            if past + past > length { past = past - length }
        }
        let most = scaled(Time(Int64(maximumSeconds * 1_000_000), 1_000_000), by: rate)
        return past > (most.isNegative ? -most : most) ? clock : handed
    }

    /// `t` inside the loop `r`: a position past its end continues from its start, one before its start from its end.
    static func wrapped(_ t: Time, in r: TimeRange) -> Time {
        let length = r.end - r.start
        if t >= r.end {
            let over = t - r.end
            return over < length ? r.start + over : r.start
        }
        if t < r.start {
            let under = r.start - t
            return under < length ? r.end - under : r.start
        }
        return t
    }

    /// `p` (a led position for the clock at `now`) held inside `bounds`; unchanged when looping.
    func held(_ p: Time, clock now: Time, reverse: Bool, frameDuration fd: Time) -> Time {
        guard !loops, let b = bounds else { return p }
        if reverse { return now >= b.start && p < b.start ? b.start : p }
        return now < b.end && p >= b.end ? max(now, b.end - fd) : p
    }

    /// The position whose frame a tick at clock `now` shows. `hostLead`: nil = the tick has no presentation time (no
    /// lead); zero = late or unusable (the last lead is used again).
    mutating func position(clock now: Time, rate: PlaybackRate, hostLead lead: Time?, frameDuration fd: Time) -> Time {
        guard !rate.isPaused else { reset(); return now }
        guard enabled, let lead else { return now }
        if lead > .zero { hostLead = lead }
        let full = scaled(hostLead, by: rate)                       // signed, exact
        let wanted = rate.isReverse ? -full : full
        if previous == nil || reverse != rate.isReverse {
            applied = primed && previous == nil ? wanted : .zero
            previous = now; reverse = rate.isReverse
        }
        primed = false
        let moved = now - (previous ?? now)
        previous = now
        if applied != wanted {
            let step = Time.scaled(moved.isNegative ? -moved : moved, by: 1, over: Self.rampDivisor).snapped(to: Self.quantum)
            applied = applied < wanted ? min(wanted, applied + step) : max(wanted, applied - step)
        }
        var p = held(reverse ? now - applied : now + applied, clock: now, reverse: reverse, frameDuration: fd)
        if let f = floor {
            floorTicks += 1
            let behind = reverse ? p - f : f - p
            // Far behind is not a late clock: a seek or a loop wrap moved it.
            if behind <= .zero || behind > fd * Self.floorFrames || floorTicks > Self.floorTicksLimit { floor = nil } else { p = f }
        }
        return p
    }
}

/// Play start on a display. Leading the picture right away skipped the first frames (the picture jumped a lead ahead of
/// the start position), and ramping the lead in left picture and sound apart for the first seconds. Instead the clock
/// stays parked on the start position while the display link lays the start out: once the link ticks steadily, the
/// start is placed in host time so that every tick's presentation time falls in the middle of a frame (the same phase
/// on every play start), and the frames from the start position are picked for their presentation times, one after
/// the other. The main actor starts the clock at that host time (`hostStart`), about one lead after play; from then on
/// `DisplayLead` runs with its full lead and picks the same frames.
///
/// Host times are seconds on the display link's time base. Pure.
struct PlayStart: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// Not laid out yet: the start frame stays.
        case hold
        /// The position whose frame this tick shows; `anchored`: this tick laid the start out (`hostStart` is set).
        case led(Time, anchored: Bool)
        /// No display time (headless, a bad timestamp): start the clock now, at the start position.
        case startNow
    }

    /// The start is laid out by this tick at the latest, steady link or not.
    static let anchorByTick = 4
    /// A measured tick interval within this share of the expected one counts as steady.
    static let intervalTolerance = 0.2
    /// The clock start lies at least this far after the tick that lays it out (the main actor needs to get there).
    static let startMargin = 0.004

    let start: Time
    let rate: PlaybackRate
    let token: UInt64
    /// Host time at which the clock starts at `start`.
    private(set) var hostStart: Double?
    /// The last led position handed out, and the host lead of the last tick.
    private(set) var lastLed: Time?
    private(set) var lastHostLead = Time.zero
    /// No display time: the clock starts at once.
    private(set) var immediate = false
    private var ticks = 0
    private var lastPresentAt: Double?

    init(start: Time, rate: PlaybackRate, token: UInt64) {
        self.start = start; self.rate = rate; self.token = token
    }

    var isLaidOut: Bool { hostStart != nil }

    private var speed: Double { rate.den == 0 ? 1 : max(Double(abs(rate.num)) / Double(rate.den), 0.0001) }

    private func run(_ hostSeconds: Double) -> Time {
        scaled(Time(Int64((hostSeconds * 1_000_000).rounded()), 1_000_000), by: rate)
    }

    /// Where the clock is started at host time `h`: the start position until the laid-out start time, then on from it.
    func clockPosition(atHost h: Double) -> Time {
        guard let hs = hostStart, h > hs else { return start }
        return start + run(h - hs)
    }

    /// The clock as laid out, also before its start (diagnostics: the picture against the clock that will run).
    func virtualClock(atHost h: Double) -> Time {
        guard let hs = hostStart else { return start }
        return start + run(h - hs)
    }

    mutating func tick(presentAt: Double?, hostNow: Double, frameDuration fd: Time, linkInterval: Double) -> Step {
        guard let presentAt, presentAt.isFinite, hostNow.isFinite, presentAt > hostNow, fd.value > 0 else {
            immediate = true
            return .startNow
        }
        lastHostLead = DisplayLead.hostLead(presentAt: presentAt, hostNow: hostNow)
        if let hs = hostStart {
            let v = start + run(max(0, presentAt - hs))
            lastLed = v
            return .led(v, anchored: false)
        }
        ticks += 1
        defer { lastPresentAt = presentAt }
        // The link's interval as it runs now: the expected one, or twice as fast (a 60 Hz floor for 30 fps).
        var interval: Double?
        if let last = lastPresentAt, linkInterval > 0 {
            let measured = presentAt - last
            for e in [linkInterval, linkInterval / 2] where abs(measured - e) <= e * Self.intervalTolerance { interval = e; break }
        }
        guard interval != nil || ticks >= Self.anchorByTick else { return .hold }
        let frame = Double(fd.value) / Double(fd.timescale)
        // Ticks fall in the middle of a frame (or of the part of it one tick shows).
        let half = min((interval ?? (linkInterval > 0 ? linkInterval : frame / speed)) * speed, frame) / 2
        // Forward the start frame is on the glass already: this tick shows the next one when the clock start that
        // implies is still ahead. In reverse the frame before the start position begins right at it.
        var distance = half
        if rate.isForward, presentAt - (frame + half) / speed >= hostNow + Self.startMargin { distance = frame + half }
        let hs = presentAt - distance / speed
        hostStart = hs
        let v = start + run(presentAt - hs)
        lastLed = v
        return .led(v, anchored: true)
    }
}
