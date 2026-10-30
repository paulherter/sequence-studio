import Foundation

/// Small deterministic generator so tests can pin the idle schedule.
public struct SQMascotRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    public mutating func next(in r: ClosedRange<Double>) -> Double { r.lowerBound + next() * (r.upperBound - r.lowerBound) }
}

/// The clock-free state machine behind a mascot: key-pose steps, then rest with breathing, sway, blinks and (for
/// `rest` animations) a repeat after a random pause. Advance it with real frame deltas in milliseconds; it returns the
/// pose to draw. All times in milliseconds.
public struct SQMascotPlayer: Sendable {
    public let animation: SQMascotAnimation
    public let idle: SQMascotIdleConfig
    /// Overrides the animation's rest pause between repeats (seconds); nil keeps the design value.
    public var restPause: ClosedRange<Double>?

    public private(set) var pose: SQMascotPose
    public private(set) var resting = false
    public private(set) var clock = 0.0
    /// Clock time of the next repeat; nil none scheduled.
    public private(set) var nextAction: Double?
    public private(set) var nextBlink = 0.0
    public private(set) var blinkCount = 0

    private enum Done { case none, idle, loop, settled }
    private var queue: [SQMascotStep] = []
    private var index = 0, t = 0.0, holding = false
    private var from: SQMascotPose
    private var done = Done.none
    private var fade = 0.0
    private var blinkT = -1.0, blinkDouble = false
    private var rng: SQMascotRandom

    public var isBusy: Bool { !queue.isEmpty }

    /// `startPose` continues from a pose already on screen (a reaction taking over); nil starts at the animation's own.
    public init(animation: SQMascotAnimation, idle: SQMascotIdleConfig, seed: UInt64 = 1, startPose: SQMascotPose? = nil) {
        self.animation = animation
        self.idle = idle
        rng = SQMascotRandom(seed: seed)
        pose = startPose ?? (animation.kind == .once ? (animation.from ?? animation.rest) : animation.rest)
        from = pose
    }

    /// Begins the animation by its kind (loop: runs on; once: plays then rests; rest: plays once, then repeats).
    public mutating func start() {
        nextAction = nil
        switch animation.kind {
        case .loop: if !animation.steps.isEmpty { run(animation.steps, .loop) } else { settle() }
        case .part: settle()
        case .once:
            run([SQMascotStep(to: animation.from ?? animation.rest, duration: 320, ease: .io, hold: 520)] + animation.steps, .idle)
        case .rest:
            if animation.steps.isEmpty { settle() } else {
                run([SQMascotStep(to: animation.rest, duration: 300, ease: .io, hold: 500)] + animation.steps, .idle)
            }
        }
    }

    /// Plays the steps once from the current pose, then settles to the animation's rest (reactions: kind `part`).
    public mutating func playOnce() {
        nextAction = nil
        run(animation.steps, .idle)
    }

    private mutating func run(_ steps: [SQMascotStep], _ d: Done) {
        resting = false
        fade = 0
        blinkT = -1
        queue = steps
        index = 0; t = 0; holding = false
        from = pose
        done = d
        if steps.isEmpty { finish() }
    }

    private mutating func finish() {
        let d = done
        done = .none
        queue = []
        switch d {
        case .none: break
        case .idle: settle()
        case .loop: run(animation.steps, .loop)
        case .settled:
            resting = true
            nextBlink = clock + rng.next(in: idle.blinkEvery)
            if animation.kind == .rest, !animation.steps.isEmpty, nextAction == nil {
                nextAction = clock + rng.next(in: restPause ?? animation.pause ?? 5...9) * 1000
            }
        }
    }

    private mutating func settle() {
        run([SQMascotStep(to: animation.rest, duration: idle.settle, ease: .io, hold: 0)], .settled)
    }

    private mutating func act() {
        nextAction = nil
        run(animation.steps, .idle)
    }

    /// Advances by `dt` ms and returns the pose to draw.
    @discardableResult
    public mutating func advance(_ dt: Double) -> SQMascotPose {
        clock += dt
        if !queue.isEmpty {
            var left = dt
            while !queue.isEmpty, left > 0 {
                let s = queue[index]
                if !holding {
                    let use = min(left, s.duration - t)
                    t += use; left -= use
                    pose = SQMascotPose.mix(from, s.to, s.ease.value(t / s.duration))
                    if t >= s.duration { pose = s.to; holding = true; t = 0 }
                } else {
                    let use = min(left, s.hold - t)
                    t += use; left -= use
                    if t >= s.hold {
                        from = pose; holding = false; t = 0; index += 1
                        if index >= queue.count { finish(); if queue.isEmpty { break } }
                    }
                }
            }
            return pose
        }
        guard resting else { return pose }
        fade = min(1, fade + dt / idle.fadeIn)
        if let n = nextAction, clock >= n, blinkT < 0 { act(); return pose }
        let w = fade * fade * (3 - 2 * fade) * animation.breath
        let ph1 = clock / idle.breathPeriod * 2 * .pi, ph2 = clock / idle.swayPeriod * 2 * .pi
        var p = pose
        p[.sy] = pose[.sy] * (1 + idle.breathHeight * w * sin(ph1))
        p[.sx] = pose[.sx] * (1 - idle.breathWidth * w * sin(ph1))
        p[.rot] = pose[.rot] + idle.swayDegrees * w * sin(ph2)
        if animation.breath > 0 {
            if blinkT < 0, clock >= nextBlink {
                blinkT = 0
                blinkCount += 1
                blinkDouble = blinkCount % idle.doubleEvery == 0
            }
            if blinkT >= 0 {
                let one = idle.blinkClose + idle.blinkShut + idle.blinkOpen
                blinkT += dt
                let u = blinkDouble && blinkT >= one + idle.blinkGap ? blinkT - one - idle.blinkGap : blinkT
                p.blink = Self.blinkOpenness(u, idle)
                let end = blinkDouble ? 2 * one + idle.blinkGap : one
                if blinkT >= end { blinkT = -1; nextBlink = clock + rng.next(in: idle.blinkEvery) }
            }
        }
        return p
    }

    /// Eye openness 0...1 at `u` ms into one blink (close, shut, open).
    public static func blinkOpenness(_ u: Double, _ c: SQMascotIdleConfig) -> Double {
        let e = SQMascotEase.io
        if u < c.blinkClose { return 1 - e.value(u / c.blinkClose) }
        if u < c.blinkClose + c.blinkShut { return 0 }
        if u < c.blinkClose + c.blinkShut + c.blinkOpen { return e.value((u - c.blinkClose - c.blinkShut) / c.blinkOpen) }
        return 1
    }
}
