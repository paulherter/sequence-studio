import Foundation

// Text animators: in/out animations that play per character, word or line with a stagger between the units.
//
// Timing is rational (`Time`) throughout: unit i of n starts at `rank(i) * stagger` (template-local) and plays for
// `duration`. Only the progress inside one unit's window becomes a Double fraction (0...1), never a time.
// An animator rides on a `KeyframeTemplate` (`textAnimator`), so it travels wherever a template does: a text clip's
// `AnimationSet` (in = start-anchored, out = end-anchored), a `TextTemplate`, a caption look's animation.
// Pure model (W7.3, moved from SQText): timing, per-unit states and segmentation by UTF-16 line ranges. Layout and
// rasterizing stay in SQText (`TextUnits.segment(_: TextLayoutResult)`, `TextRenderer.render(characterStates:)`).

/// What one animator step moves: a grapheme (whitespace excluded), a whitespace-separated word, or a laid-out line.
public enum TextAnimatorUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case character, word, line
}

public enum TextAnimatorEffect: String, Sendable, Hashable, Codable, CaseIterable {
    /// Opacity 0 -> 1.
    case fade
    /// Scale 0 -> 1 about the unit center (use `.overshoot` easing for a bounce), opacity follows quickly.
    case pop
    /// Moves in from `distance` pixels against `direction`, fading in.
    case slide
    /// Each unit appears at once at its start (duration is ignored).
    case typewriter
    /// Blur `blurRadius` -> 0, fading in.
    case blur
    /// Loop: each unit bobs up by `distance` and back, `loops` times (rests at both ends).
    case wave
    /// Loop: each unit swells to 1.25x and back, `loops` times.
    case pulse

    public var isLoop: Bool { self == .wave || self == .pulse }
}

/// Which unit goes first.
public enum TextAnimatorOrder: String, Sendable, Hashable, Codable, CaseIterable {
    case forward, reverse
    /// Middle unit(s) first, then outward.
    case center
}

/// Direction the units travel while sliding in (up = they start below and rise). Out mirrors it (up = leave upward).
public enum TextSlideDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case up, down, left, right
}

/// Look of one unit at one time. At `.rest` the unit is drawn exactly as the static text.
public struct TextUnitState: Sendable, Hashable {
    public var opacity: Double
    /// About the unit center.
    public var scale: Double
    /// Sequence pixels, y down.
    public var offsetX: Double, offsetY: Double
    /// Blur radius in sequence pixels.
    public var blur: Double

    public init(opacity: Double = 1, scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, blur: Double = 0) {
        self.opacity = opacity; self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY; self.blur = blur
    }
    public static let rest = TextUnitState()
    public var isRest: Bool { self == .rest }
}

public struct TextAnimator: Sendable, Hashable, Codable {
    public var effect: TextAnimatorEffect
    public var unit: TextAnimatorUnit
    public var order: TextAnimatorOrder
    public var easing: SegmentShape
    /// Length of one unit's animation.
    public var duration: Time
    /// Delay between two consecutive units (by rank).
    public var stagger: Time
    /// Slide distance in sequence pixels.
    public var distance: Double
    public var direction: TextSlideDirection
    /// Start blur of the blur effect, sequence pixels.
    public var blurRadius: Double
    /// Cycles of a loop effect (wave, pulse) inside one unit's window; the window is `duration * loops`. 1 for the rest.
    public var loops: Int

    public init(effect: TextAnimatorEffect, unit: TextAnimatorUnit, order: TextAnimatorOrder = .forward,
                easing: SegmentShape = .easeOut, duration: Time, stagger: Time, distance: Double = 40,
                direction: TextSlideDirection = .up, blurRadius: Double = 12, loops: Int = 1) {
        self.loops = min(max(loops, 1), 50)
        self.effect = effect; self.unit = unit; self.order = order; self.easing = easing
        self.duration = Self.sanitized(duration); self.stagger = Self.sanitized(stagger)
        self.distance = distance; self.direction = direction; self.blurRadius = max(0, blurRadius)
    }

    private enum CodingKeys: String, CodingKey { case effect, unit, order, easing, duration, stagger, distance, direction, blurRadius, loops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(effect: try c.decode(TextAnimatorEffect.self, forKey: .effect),
                  unit: try c.decode(TextAnimatorUnit.self, forKey: .unit),
                  order: try c.decodeIfPresent(TextAnimatorOrder.self, forKey: .order) ?? .forward,
                  easing: try c.decodeIfPresent(SegmentShape.self, forKey: .easing) ?? .easeOut,
                  duration: try c.decode(Time.self, forKey: .duration),
                  stagger: try c.decode(Time.self, forKey: .stagger),
                  distance: try c.decodeIfPresent(Double.self, forKey: .distance) ?? 40,
                  direction: try c.decodeIfPresent(TextSlideDirection.self, forKey: .direction) ?? .up,
                  blurRadius: try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 12,
                  loops: try c.decodeIfPresent(Int.self, forKey: .loops) ?? 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(effect, forKey: .effect); try c.encode(unit, forKey: .unit); try c.encode(order, forKey: .order)
        try c.encode(easing, forKey: .easing); try c.encode(duration, forKey: .duration); try c.encode(stagger, forKey: .stagger)
        try c.encode(distance, forKey: .distance); try c.encode(direction, forKey: .direction)
        try c.encode(blurRadius, forKey: .blurRadius)
        if loops > 1 { try c.encode(loops, forKey: .loops) }
    }

    // MARK: Timing (rational)

    /// Position of unit `i` (0-based, reading order) in the play order.
    public func rank(ofUnit i: Int, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        switch order {
        case .forward: return i
        case .reverse: return n - 1 - i
        case .center: return abs(2 * i - (n - 1)) / 2
        }
    }

    private func maxRank(count n: Int) -> Int {
        guard n > 0 else { return 0 }
        return order == .center ? (n - 1) / 2 : n - 1
    }

    /// Upper bound of `duration` and `stagger` (also applied when decoding).
    public static let maxTime = Time(60, 1)

    /// Clamps to 0...`maxTime`; a timescale above 1 MHz (unreduced, pathological fractions) is moved to the nearest
    /// microsecond, so `rank * stagger` and sums with clip times stay far from Int64 overflow. Normal timescales stay exact.
    public static func sanitized(_ t: Time) -> Time {
        guard t > .zero else { return .zero }
        guard t < maxTime else { return maxTime }
        guard t.timescale > 1_000_000 else { return t }
        let us = (Int128(t.value) * 2_000_000 + Int128(t.timescale)) / (Int128(t.timescale) * 2)
        return Time(Int64(us), 1_000_000)
    }

    private var safeStagger: Time { Self.sanitized(stagger) }
    /// Typewriter ignores the duration: every unit is a step, so the out side ends exactly at the clip end.
    private var effectiveDuration: Time {
        if effect == .typewriter { return .zero }
        let d = Self.sanitized(duration)
        guard effect.isLoop, loops > 1 else { return d }
        return Self.sanitized(Time(d.value * Int64(loops), d.timescale))
    }

    /// `stagger * rank`, clamped instead of overflowing (stagger is at most 60 s on a <= 1 MHz grid).
    private func staggered(_ rank: Int) -> Time {
        let s = safeStagger
        let v = Int128(s.value) * Int128(max(0, rank))
        return Time(Int64(min(v, Int128(Int64.max / 4))), s.timescale)
    }

    /// Template-local start of unit `i`.
    public func start(ofUnit i: Int, count n: Int) -> Time { staggered(rank(ofUnit: i, count: n)) }

    /// From the first unit's start to the last unit's end; zero without units.
    public func totalDuration(count n: Int) -> Time {
        guard n > 0 else { return .zero }
        return staggered(maxRank(count: n)) + effectiveDuration
    }

    /// Linear progress of unit `i` at template-local `t`: 0 before its start, 1 from its end on. Typewriter and a zero
    /// duration are a step at the start.
    public func progress(ofUnit i: Int, count n: Int, at t: Time) -> Double {
        let s = start(ofUnit: i, count: n)
        if t < s { return 0 }
        let d = effectiveDuration
        if d <= .zero { return 1 }
        if t >= s + d { return 1 }
        return Self.ratio(t - s, d)
    }

    /// State of unit `i` while it animates in (template-local time, 0 = clip start).
    public func inState(ofUnit i: Int, count n: Int, at t: Time) -> TextUnitState {
        let p = progress(ofUnit: i, count: n, at: t)
        return state(visible: p, eased: effect == .typewriter ? p : Self.ease(p, easing), leaving: false)
    }

    /// Clip time at which unit `i` starts leaving (the last one is gone exactly at the clip end).
    public func outStart(ofUnit i: Int, count n: Int, clipDuration: Time) -> Time {
        clipDuration - totalDuration(count: n) + start(ofUnit: i, count: n)
    }

    /// State of unit `i` while it animates out; at the clip end every unit is gone.
    public func outState(ofUnit i: Int, count n: Int, clipTime: Time, clipDuration: Time) -> TextUnitState {
        let local = clipTime - (clipDuration - totalDuration(count: n))
        let q = progress(ofUnit: i, count: n, at: local)
        return state(visible: 1 - q, eased: 1 - (effect == .typewriter ? q : Self.ease(q, easing)), leaving: true)
    }

    /// `visible`: linear 0 (hidden) ... 1 (rest); `eased`: the eased amount (may overshoot past 1 or below 0).
    private func state(visible v: Double, eased e: Double, leaving: Bool) -> TextUnitState {
        if v >= 1 && e == 1 { return .rest }
        let clamped = min(1, max(0, e))
        if effect.isLoop {
            // Easing does not apply: a sine per cycle, 0 at both ends of every cycle.
            let phase = (leaving ? 1 - v : v) * Double(loops)
            let wave = sin(.pi * (phase - phase.rounded(.down)))
            if effect == .wave { return TextUnitState(offsetY: -distance * wave) }
            return TextUnitState(scale: 1 + 0.25 * wave)
        }
        switch effect {
        case .fade, .typewriter:
            return TextUnitState(opacity: clamped)
        case .pop:
            return TextUnitState(opacity: min(1, max(0, 2 * v)), scale: max(0, e))
        case .slide:
            let d = (1 - e) * distance * (leaving ? -1 : 1)
            switch direction {
            case .up: return TextUnitState(opacity: clamped, offsetY: d)
            case .down: return TextUnitState(opacity: clamped, offsetY: -d)
            case .left: return TextUnitState(opacity: clamped, offsetX: d)
            case .right: return TextUnitState(opacity: clamped, offsetX: -d)
            }
        case .blur:
            return TextUnitState(opacity: clamped, blur: (1 - clamped) * blurRadius)
        case .wave, .pulse:
            return .rest
        }
    }

    // MARK: Math

    /// a / b for b > 0 via exact Int128 cross-multiplication (only the result is a Double).
    static func ratio(_ a: Time, _ b: Time) -> Double {
        let num = Int128(a.value) * Int128(b.timescale)
        let den = Int128(a.timescale) * Int128(b.value)
        return Double(num) / Double(den)
    }

    /// Eased progress for linear progress `p` in 0...1, using the same handles as keyframe segments.
    public static func ease(_ p: Double, _ shape: SegmentShape) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        switch shape.interpolation {
        case .linear: return p
        case .hold: return 0
        case .holdAhead: return 1
        case .bezier:
            let h = shape.handles
            let x1 = min(max(h.out.dx, 0), 1), x2 = 1 - min(max(h.in.dx, 0), 1)
            let s = solve(p, x1, x2)
            return bezier(s, h.out.dy, 1 - h.in.dy)
        }
    }

    private static func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }

    /// Solves x(s) = t on the monotonic x curve by bisection (x1, x2 in 0...1).
    private static func solve(_ t: Double, _ x1: Double, _ x2: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let m = (lo + hi) / 2
            if bezier(m, x1, x2) < t { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }
}

// MARK: - Units

/// The animatable units of a laid-out text: every non-whitespace grapheme with the word and line it belongs to.
public struct TextUnits: Sendable, Hashable {
    public struct Character: Sendable, Hashable {
        /// Index among all characters (whitespace excluded), reading order.
        public let index: Int
        public let word: Int
        public let line: Int
        /// UTF-16 range in the laid-out (display) text.
        public let range: NSRange
    }
    public let characters: [Character]
    public let wordCount: Int
    public let lineCount: Int

    public func count(of unit: TextAnimatorUnit) -> Int {
        switch unit {
        case .character: characters.count
        case .word: wordCount
        case .line: lineCount
        }
    }

    public func index(of c: Character, unit: TextAnimatorUnit) -> Int {
        switch unit {
        case .character: c.index
        case .word: c.word
        case .line: c.line
        }
    }

    /// `lines`: UTF-16 ranges of the laid-out lines in `text` (a character outside every line is dropped). Words follow
    /// `WordSegmentation` (whitespace and CJK characters separate); a word the wrap breaks keeps one index. Lines without a character still count.
    public static func segment(text: String, lines: [NSRange]) -> TextUnits {
        var chars: [Character] = []
        var offset = 0
        let all = Array(text)
        var wordOf = [Int?](repeating: nil, count: all.count)
        let spans = WordSegmentation.spans(all)
        for (w, span) in spans.enumerated() { for i in span { wordOf[i] = w } }
        let word = spans.count - 1
        for (i, ch) in all.enumerated() {
            let len = ch.utf16.count
            defer { offset += len }
            guard let wordIndex = wordOf[i] else { continue }
            guard let line = lines.firstIndex(where: { offset >= $0.location && offset < $0.location + $0.length }) else { continue }
            chars.append(Character(index: chars.count, word: wordIndex, line: line, range: NSRange(location: offset, length: len)))
        }
        return TextUnits(characters: chars, wordCount: word + 1, lineCount: lines.count)
    }
}

/// One character's look: the in- and out-animator states of the units it belongs to (each about its own unit's center).
public struct TextCharacterState: Sendable, Hashable {
    public var `in`: TextUnitState
    public var out: TextUnitState
    /// Unit whose center the in-state scales about (nil without an in-animator).
    public var inUnit: TextAnimatorUnit?
    public var outUnit: TextAnimatorUnit?
    public init(in inState: TextUnitState, out outState: TextUnitState, inUnit: TextAnimatorUnit? = nil,
                outUnit: TextAnimatorUnit? = nil) {
        self.in = inState; self.out = outState; self.inUnit = inUnit; self.outUnit = outUnit
    }
    public var opacity: Double { self.in.opacity * out.opacity }
    public var isRest: Bool { self.in.isRest && out.isRest }
}

extension KeyframeTemplate {
    /// A template that only carries a text animator (no property tracks).
    public init(textAnimator: TextAnimator, anchor: AnimationAnchor = .start) {
        self.init(tracks: [], duration: .zero, anchor: anchor, textAnimator: textAnimator)
    }
}

extension AnimationSet {
    public var hasTextAnimator: Bool { animationIn?.textAnimator != nil || animationOut?.textAnimator != nil }

    /// Per-character states at clip time `clipTime`; nil when neither side has a text animator. In and out compose
    /// (opacities multiply, each scales about its own unit), so a clip shorter than both animations still ends hidden.
    public func characterStates(units: TextUnits, clipTime: Time, clipDuration: Time) -> [TextCharacterState]? {
        let a = animationIn?.textAnimator, b = animationOut?.textAnimator
        guard a != nil || b != nil else { return nil }
        let nIn = a.map { units.count(of: $0.unit) } ?? 0, nOut = b.map { units.count(of: $0.unit) } ?? 0
        return units.characters.map { c in
            TextCharacterState(
                in: a.map { $0.inState(ofUnit: units.index(of: c, unit: $0.unit), count: nIn, at: clipTime) } ?? .rest,
                out: b.map { $0.outState(ofUnit: units.index(of: c, unit: $0.unit), count: nOut, clipTime: clipTime,
                                         clipDuration: clipDuration) } ?? .rest,
                inUnit: a?.unit, outUnit: b?.unit)
        }
    }
}
