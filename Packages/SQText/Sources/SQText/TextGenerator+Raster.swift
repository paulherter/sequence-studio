#if canImport(CoreVideo)
import Foundation
import CoreVideo
import Synchronization
import SQCore

/// One rendered text frame. `buffer` is linear half-float premultiplied RGBA (shared with the cache, read only).
/// Placement is the raster's top-left in sequence pixels (y down) for the untransformed, un-animated block
/// (block centered on the canvas); `width`/`height` are the raster size in sequence pixels (buffer size / scale).
/// The caller folds the animation factors into the compositor layer transform: scale and rotation (degrees)
/// about the block center, `offsetX/Y` in sequence pixels added to the position, `opacity` multiplies alpha.
public struct TextFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let x: Double, y: Double
    public let width: Double, height: Double
    public let opacity: Double
    public let scale: Double
    public let offsetX: Double, offsetY: Double
    public let rotation: Double
    /// Center of the text lines relative to the raster center (sequence px, y down): the caption pop's pivot (FB-Y).
    public let pivotX: Double, pivotY: Double
    /// The same point relative to the center of the whole raster: the pivot of a whole-box frame, to the bit.
    public let wholePivotX: Double, wholePivotY: Double
    /// The whole raster's rectangle (same space as `x/y/width/height`): equal to them unless the frame was asked for
    /// `cropped`, where `x/y/width/height` cover only the painted part. Guides, corner radius and the default pivot
    /// belong to this rectangle, whatever the crop.
    public let wholeX: Double, wholeY: Double
    public let wholeWidth: Double, wholeHeight: Double
    /// Where `buffer` lies in the whole raster, in texels from its top-left (0, 0 when it is the whole one), and the
    /// whole raster's size in texels.
    public let partX: Int, partY: Int
    public let wholePixelWidth: Int, wholePixelHeight: Int
    /// The buffer covers only a part of the whole raster.
    public var isPart: Bool {
        wholePixelWidth != CVPixelBufferGetWidth(buffer) || wholePixelHeight != CVPixelBufferGetHeight(buffer)
    }
}

extension TextFrame {
    /// The layer transform that places this raster: its center relative to the canvas center, with the animation
    /// factors (opacity, scale, offset, rotation) folded into `base` (the clip's evaluated transform).
    /// Scale and rotation happen about the center of the whole raster (not of a cropped one), or with `pivotAtText`
    /// about the center of the text lines (captions, whose raster is the whole caption box): the anchor moves there
    /// and the position with it, so at rest nothing moves.
    /// `whole`: the transform of the whole raster's rectangle instead of the buffer's, for a caller that hands the
    /// compositor a cropped buffer to draw as the whole one (`RenderLayer.contentPart`): the same numbers, to the bit, as
    /// the whole-box frame's own transform.
    public func layerTransform(base: ClipTransform, canvas: SequenceFormat, pivotAtText: Bool = false,
                               whole: Bool = false) -> ClipTransform {
        let x = whole ? wholeX : x, y = whole ? wholeY : y
        let width = whole ? wholeWidth : width, height = whole ? wholeHeight : height
        var tr = base
        let px = pivotAtText ? (whole ? wholePivotX : pivotX) : (wholeX + wholeWidth / 2) - (x + width / 2)
        let py = pivotAtText ? (whole ? wholePivotY : pivotY) : (wholeY + wholeHeight / 2) - (y + height / 2)
        tr.position = Vec2(base.position.x + x + width / 2 - Double(canvas.displayWidth) / 2 + offsetX + px,
                           base.position.y + y + height / 2 - Double(canvas.height) / 2 + offsetY + py)
        tr.anchor = Vec2(base.anchor.x + px, base.anchor.y + py)
        tr.scale = Vec2(base.scale.x * scale, base.scale.y * scale)
        tr.rotation += rotation
        tr.opacity *= opacity
        return tr
    }
}

extension TextGenerator {
    /// Nil for empty text. `localTime` is clip-local (0 = clip start). If the payload has no `AnimationSet`, the
    /// template's own single animation is used (by its anchor).
    /// `cropped`: an in-between frame of a text animator may cover only what is painted (`wholeX…` keep the whole
    /// rectangle). Only for callers that use nothing but the buffer and `layerTransform` (captions, a text clip without
    /// corner radius, effects or blend mode): those work on the layer's rectangle and need the whole one.
    /// `wait`: how long the caller may wait for an in-between frame the text lane is drawing right now (one budget for
    /// all frames of a playback tick); nil never waits (seek, scrub, export, overlays): the frame is drawn here.
    public static func frame(ref: GeneratorRef, localTime: Time, clipDuration: Time, canvas: SequenceFormat,
                             scale: Double, cropped: Bool = false, wait: RasterWait? = nil) throws -> TextFrame? {
        let (template, set) = try decode(ref)
        guard let still = try cache.raster(text: template.text, style: template.style, box: template.box,
                                            highlight: template.highlight, scale: scale) else { return nil }

        // One animation stack (SQCore `AnimationSet`): the clip's own set, else the template's animation by its anchor.
        let anims = set ?? AnimationSet(single: template.animation)
        let a = anims?.sample(clipTime: localTime, clipDuration: clipDuration) ?? .rest
        var raster = still
        // Text animators: per-character states from the cached raster's layout. All at rest (most of the clip) keeps the
        // static raster; in between, the animated raster is cached by its states (scrubbing back hits it).
        if let anims, anims.hasTextAnimator,
           let states = anims.characterStates(units: TextUnits.segment(still.layout), clipTime: localTime, clipDuration: clipDuration),
           !states.allSatisfy(\.isRest),
           let animated = try animatedCache.raster(text: template.text, style: template.style, box: template.box,
                                           highlight: template.highlight, scale: scale, states: states,
                                           cropped: cropped, wait: wait) {
            raster = animated
        }
        let s = raster.scale
        let b = raster.layout.bounds
        // Block (text bounds) centered on the canvas; the raster starts at the ink origin.
        let x = (Double(canvas.displayWidth) - b.width) / 2 + (raster.originX - b.x)
        let y = (Double(canvas.height) - b.height) / 2 + (raster.originY - b.y)
        // The whole raster's corner is computed like `x`/`y` of a whole-box frame (the same operations in the same
        // order), so a cropped frame placed as the whole one lands on the same bits.
        let wholeX = (Double(canvas.displayWidth) - b.width) / 2 + (raster.wholeOriginX - b.x)
        let wholeY = (Double(canvas.height) - b.height) / 2 + (raster.wholeOriginY - b.y)
        let pivot = CaptionLayout.pivot(of: raster), wholePivot = CaptionLayout.wholePivot(of: raster)
        return TextFrame(buffer: raster.linearBuffer, x: x, y: y,
                         width: Double(raster.pixelWidth) / s, height: Double(raster.pixelHeight) / s,
                         opacity: a.opacity, scale: a.scale, offsetX: a.offset.x, offsetY: a.offset.y, rotation: a.rotation,
                         pivotX: pivot.x, pivotY: pivot.y, wholePivotX: wholePivot.x, wholePivotY: wholePivot.y,
                         wholeX: wholeX, wholeY: wholeY,
                         wholeWidth: Double(raster.wholePixelWidth) / s, wholeHeight: Double(raster.wholePixelHeight) / s,
                         partX: Int(((raster.originX - raster.wholeOriginX) * s).rounded()),
                         partY: Int(((raster.originY - raster.wholeOriginY) * s).rounded()),
                         wholePixelWidth: raster.wholePixelWidth, wholePixelHeight: raster.wholePixelHeight)
    }

    /// Who drew the in-between frames of text animators since launch (tests, diagnostics): `callerDrawn` on the thread
    /// that asked for the frame (the render thread while playing), `callerWaited` taken from a background raster that
    /// was being drawn at that moment, `backgroundDrawn` rastered ahead on the text lane.
    public struct AnimatedRasterStats: Sendable, Equatable {
        public var callerDrawn = 0, callerWaited = 0, backgroundDrawn = 0
    }
    public static var animatedRasterStats: AnimatedRasterStats { animatedCache.stats }

    /// Counts the in-between frames the code inside `$rasterTally.withValue` had to draw itself or wait for, and the
    /// ones the text lane drew ahead because that code asked for them (`ahead`, counted when the raster is finished).
    /// Tests count with this: the process-wide stats also see every other caller, such as a test running in parallel.
    /// It also knows the rasters it asked for that are still on their way (text lane and static layouts), so a test
    /// waits for exactly its own work (`drain`), never for a process-wide count that other suites move.
    public final class RasterTally: @unchecked Sendable {
        /// Guards the counts; signaled when the last raster on its way ends.
        private let lock = NSCondition()
        private var counts = (drawn: 0, waited: 0, ahead: 0)
        private var onTheWay = 0
        public init() {}
        public var drawn: Int { lock.withLock { counts.drawn } }
        public var waited: Int { lock.withLock { counts.waited } }
        public var ahead: Int { lock.withLock { counts.ahead } }
        /// Background rasters this tally's code asked for that have not ended yet.
        public var inFlight: Int { lock.withLock { onTheWay } }
        func add(drawn: Int = 0, waited: Int = 0, ahead: Int = 0) {
            lock.withLock { counts.drawn += drawn; counts.waited += waited; counts.ahead += ahead }
        }
        /// A background raster was asked for / has ended (drawn, dropped, taken over or failed).
        func began() { lock.withLock { onTheWay += 1 } }
        func ended() {
            lock.lock()
            onTheWay -= 1
            if onTheWay == 0 { lock.broadcast() }
            lock.unlock()
        }
        /// Blocks until every background raster asked for under this tally has ended (woken by the last one, no
        /// polling). False when `limit` seconds passed first: the caller asserts on it. Blocks its thread: never call it
        /// from a task (static layouts run on the cooperative pool and need its threads), use `drained` there.
        public func drain(limit: TimeInterval = 20) -> Bool {
            let deadline = Date(timeIntervalSinceNow: limit)
            lock.lock(); defer { lock.unlock() }
            while onTheWay > 0 { if !lock.wait(until: deadline) { return onTheWay == 0 } }
            return true
        }
        /// `drain` for async code: the wait runs on a thread of its own, the task is suspended meanwhile.
        public func drained(limit: TimeInterval = 20) async -> Bool {
            if inFlight == 0 { return true }
            return await withCheckedContinuation { done in
                Thread.detachNewThread { done.resume(returning: self.drain(limit: limit)) }
            }
        }
    }
    @TaskLocal public static var rasterTally: RasterTally?

    /// The time one playback tick may spend waiting for in-between frames that are being drawn on the text lane: one
    /// deadline shared by every text frame of the tick, so many layers never add up their waits.
    /// The deadline is on a monotonic clock: a wall-clock change (time sync, the user setting the date) neither ends
    /// the budget early nor stretches it.
    public final class RasterWait: Sendable {
        let deadline: ContinuousClock.Instant
        public init(limit: TimeInterval) { deadline = ContinuousClock.now + .seconds(max(0, limit)) }
        /// Seconds left of the budget; zero or less when it is used up.
        var remaining: TimeInterval {
            let c = (deadline - ContinuousClock.now).components
            return Double(c.seconds) + Double(c.attoseconds) * 1e-18
        }
    }

    /// Drops the in-between frames of text animators and cancels the ones being rastered (critical memory pressure):
    /// they come back with the next frame that shows them.
    public static func clearAnimatedCache() { animatedCache.clear() }

    /// True when the raster for this clip's text and style (scale 1) is already cached: `frame` then returns at once.
    public static func isCached(ref: GeneratorRef) -> Bool {
        guard let (template, _) = try? decode(ref) else { return true }   // undecodable: nothing to wait for
        return cache.contains(text: template.text, style: template.style, box: template.box, highlight: template.highlight, scale: 1)
    }

    /// The footage fill of a text ref's style (nil = filled with its color, or not a text ref). The compositor layer of the
    /// clip carries it (`RenderLayer.footageFill`).
    public static func footageFill(ref: GeneratorRef) -> TextFootageFill? {
        (try? decode(ref))?.0.style.footageFill
    }

    /// The animator units of the text's cached raster (scale 1), the ones `frame` animates; nil while it is not cached.
    public static func units(ref: GeneratorRef) -> TextUnits? {
        guard let (template, _) = try? decode(ref),
              let still = cache.peek(text: template.text, style: template.style, box: template.box,
                                     highlight: template.highlight, scale: 1) else { return nil }
        return TextUnits.segment(still.layout)
    }

    /// Renders and caches the raster (scale 1) on the calling thread; call it from a background task so the render
    /// thread and the main thread never pay for the first CoreText layout. Throws what the renderer throws.
    public static func prewarm(ref: GeneratorRef) throws {
        let (template, _) = try decode(ref)
        _ = try cache.raster(text: template.text, style: template.style, box: template.box, highlight: template.highlight, scale: 1)
    }

    /// Byte cap of the raster cache (linear half-float, 8 bytes per pixel).
    public static let cacheByteLimit = 128 * 1024 * 1024
    private static let cache = RasterCache(limit: cacheByteLimit)
    /// Byte cap of the separate cache for in-between frames of text animators, so scrubbing through an animation can
    /// never evict the static rasters. Holds the frames rastered ahead of the playhead (`warmAnimatedInBackground`) of
    /// two layers on a 4K canvas.
    public static let animatedCacheByteLimit = 96 * 1024 * 1024
    private static let animatedCache = RasterCache(limit: animatedCacheByteLimit)

    /// Rasters the in-between frames of a text animator at `count` clip-local times from `localTime` on (`step` apart)
    /// on the text lane, so the frame that shows one finds it in the cache instead of drawing it on the render thread
    /// (ENGINE-NOTES "Animated captions"). Does nothing for a text without an animator, for times where every character
    /// is at rest, for frames already cached or in flight, and while the text's static raster is not cached yet (its
    /// layout is what the states are made from). Always the cropped frame (`frame(cropped: true)` finds it): a whole-box
    /// raster is too slow and too large to draw ahead (a 4K box takes longer than the look-ahead and one fills the cache).
    /// `includingEnd`: `localTime == clipDuration` counts too (the end state a caption keeps under the next one while
    /// they hand over, ENGINE-NOTES "Caption hand-over"); no ordinary frame is ever shown at that time.
    public static func warmAnimatedInBackground(ref: GeneratorRef, from localTime: Time, step: Time, count: Int = 1,
                                                clipDuration: Time, includingEnd: Bool = false) {
        guard count > 0, let (template, set) = try? decode(ref),
              let anims = set ?? AnimationSet(single: template.animation), anims.hasTextAnimator,
              let still = cache.peek(text: template.text, style: template.style, box: template.box,
                                     highlight: template.highlight, scale: 1) else { return }
        let units = TextUnits.segment(still.layout)
        var t = localTime
        for _ in 0..<count {
            defer { t = t + step }
            guard t >= .zero, t < clipDuration || (includingEnd && t == clipDuration),
                  let states = anims.characterStates(units: units, clipTime: t, clipDuration: clipDuration),
                  !states.allSatisfy(\.isRest) else { continue }
            animatedCache.warm(text: template.text, style: template.style, box: template.box, highlight: template.highlight,
                               scale: 1, states: states, cropped: true)
        }
    }

    /// Workers that raster in-between frames ahead of the playhead: Core Graphics blocks its thread for milliseconds,
    /// so the work stays off Swift's cooperative pool, and a Mac with few cores keeps most of them for decode and audio.
    static let animatedLaneWidth = ProcessInfo.processInfo.activeProcessorCount <= 8 ? 2 : 4
    private static let animatedLane = BlockingLane(label: "sq.lane.text", width: animatedLaneWidth, qos: .userInitiated)
    /// Scratch memory the background rasters may hold at once (a 4K box is 66 MB of address space, far less resident).
    static let animatedInFlightByteLimit = 64 * 1024 * 1024

    /// In-between frames being rastered in the background right now (tests, diagnostics).
    public static var animatedWarmsInFlight: Int { animatedCache.pendingCount }

    /// Bytes held by the static / animated raster caches (tests, diagnostics).
    static var staticCacheBytes: Int { cache.bytes }
    static var animatedCacheBytes: Int { animatedCache.bytes }

    /// Drops all cached rasters (memory pressure, tests).
    public static func clearCache() {
        cache.clear(); animatedCache.clear(); encodeMemo.withLock { $0.removeAll() }
        resetFailedLayouts()
    }

    final class RasterCache: @unchecked Sendable {
        struct Key: Hashable, Sendable {
            let text: String; let style: TextStyle; let box: TextBox?; let highlight: TextHighlight?; let scale: Double
            /// Animator states of an in-between frame; nil for the static raster.
            var states: [TextCharacterState]? = nil
            /// The in-between frame covers only what is painted.
            var cropped = false
        }
        private enum Stage { case queued, running }
        /// Guards everything below; signaled when a background raster ends.
        private let lock = NSCondition()
        private var entries: [Key: (raster: TextRaster?, bytes: Int, tick: UInt64)] = [:]
        /// Background rasters asked for and not finished, with the generation they were asked in.
        private var pending: [Key: (stage: Stage, generation: UInt64)] = [:]
        /// Counts `clear()`: a background raster from before it neither runs nor puts its result back.
        private var generation: UInt64 = 0
        private var inFlightBytes = 0, inFlightPeak = 0
        private var counts = AnimatedRasterStats()
        private var total = 0, tick: UInt64 = 0
        private let limit: Int
        private let inFlightLimit: Int
        /// Background rasters asked for at a time; more are asked for again on the next frame.
        private static let pendingLimit = 8
        init(limit: Int, inFlightLimit: Int = TextGenerator.animatedInFlightByteLimit) {
            self.limit = limit; self.inFlightLimit = inFlightLimit
        }
        var stats: AnimatedRasterStats { lock.withLock { counts } }
        /// Most scratch bytes the background rasters held at once (tests).
        var peakInFlightBytes: Int { lock.withLock { inFlightPeak } }

        func contains(text: String, style: TextStyle, box: TextBox?, highlight: TextHighlight?, scale: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return entries[Key(text: text, style: style, box: box, highlight: highlight, scale: max(0.01, scale))] != nil
        }

        /// The cached static raster, nil when it is not cached (nothing is rendered).
        func peek(text: String, style: TextStyle, box: TextBox?, highlight: TextHighlight?, scale: Double) -> TextRaster? {
            lock.lock(); defer { lock.unlock() }
            return entries[Key(text: text, style: style, box: box, highlight: highlight, scale: max(0.01, scale))]?.raster
        }

        /// Drops every raster and cancels the background rasters asked for so far: one that is queued never runs, one
        /// that is running does not put its result back (memory pressure must not be undone a moment later).
        func clear() {
            lock.lock()
            entries = [:]; total = 0; pending = [:]; generation &+= 1
            lock.broadcast(); lock.unlock()
        }
        var bytes: Int { lock.lock(); defer { lock.unlock() }; return total }
        var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

        func raster(text: String, style: TextStyle, box: TextBox?, highlight: TextHighlight?, scale: Double,
                    states: [TextCharacterState]? = nil, cropped: Bool = false, wait: RasterWait? = nil) throws -> TextRaster? {
            try raster(Key(text: text, style: style, box: box, highlight: highlight, scale: max(0.01, scale), states: states,
                           cropped: states != nil && cropped), wait: wait)
        }

        /// Renders the raster on the text lane unless it is cached or in flight already.
        func warm(text: String, style: TextStyle, box: TextBox?, highlight: TextHighlight?, scale: Double,
                  states: [TextCharacterState], cropped: Bool) {
            let key = Key(text: text, style: style, box: box, highlight: highlight, scale: max(0.01, scale), states: states,
                          cropped: cropped)
            let asked = lock.withLock { () -> UInt64? in
                guard entries[key] == nil, pending[key] == nil, pending.count < Self.pendingLimit else { return nil }
                pending[key] = (.queued, generation)
                return generation
            }
            guard let asked else { return }
            let tally = TextGenerator.rasterTally     // the asker's: a detached task does not inherit it
            tally?.began()
            Task.detached(priority: .userInitiated) { [self] in
                // Ended on every way out: drawn, cleared, taken over by the caller, refused, or the lane gave up.
                defer { tally?.ended() }
                try? await TextGenerator.animatedLane.run { _ in self.background(key, generation: asked, tally: tally) }
            }
        }

        /// One background raster, on a lane thread.
        private func background(_ key: Key, generation asked: UInt64, tally: RasterTally?) {
            lock.lock()
            guard let p = pending[key], p.generation == asked, p.stage == .queued else {
                lock.unlock(); return   // cleared, or the caller took it over
            }
            guard entries[key] == nil else { pending[key] = nil; lock.unlock(); return }
            pending[key] = (.running, asked)
            lock.unlock()

            var held = 0
            // Refused when the rasters in flight hold too much scratch memory already (the first is always let in): the
            // frame is asked for again on the next tick, or drawn by the caller.
            let result = Result { try draw(key) { bytes in
                self.lock.withLock {
                    guard self.inFlightBytes == 0 || self.inFlightBytes + bytes <= self.inFlightLimit else { return false }
                    self.inFlightBytes += bytes; held = bytes
                    self.inFlightPeak = max(self.inFlightPeak, self.inFlightBytes)
                    return true
                }
            } }
            lock.lock()
            inFlightBytes -= held
            if let p = pending[key], p.generation == asked, p.stage == .running {
                pending[key] = nil
                if case let .success(r) = result {
                    counts.backgroundDrawn += 1
                    tally?.add(ahead: 1)
                    _ = insert(key, r)
                }
            }
            lock.broadcast(); lock.unlock()
        }

        private func draw(_ key: Key, admit: ((Int) -> Bool)? = nil) throws -> TextRaster? {
            // A cropped in-between frame covers only what is painted: most of a caption's box is empty.
            try key.states.map {
                try TextRenderer.render(text: key.text, style: key.style, maxWidth: key.box?.width, boxHeight: key.box?.height,
                                        scale: key.scale, highlight: key.highlight, characterStates: $0, tight: key.cropped,
                                        admit: admit)
            } ?? TextRenderer.render(text: key.text, style: key.style, maxWidth: key.box?.width, boxHeight: key.box?.height,
                                     scale: key.scale, highlight: key.highlight)
        }

        /// Locked. Keeps the first raster of a key and returns the one that is kept.
        private func insert(_ key: Key, _ r: TextRaster?) -> TextRaster? {
            if let e = entries[key] { return e.raster }
            let bytes = r.map { $0.pixelWidth * $0.pixelHeight * 8 } ?? 0
            tick += 1
            entries[key] = (r, bytes, tick); total += bytes
            while total > limit, entries.count > 1,
                  let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.tick < $1.value.tick }) {
                total -= oldest.value.bytes; entries[oldest.key] = nil
            }
            return r
        }

        private func raster(_ key: Key, wait: RasterWait?) throws -> TextRaster? {
            lock.lock()
            if let e = entries[key] {
                tick += 1; entries[key]?.tick = tick
                lock.unlock(); return e.raster
            }
            // The same frame is on its way in the background. Not started yet: the caller draws it now and the queued one
            // is dropped. Being drawn: a caller with a budget (a playback tick) waits for it until the budget ends; one
            // without (seek, scrub, overlays, export) never waits and draws it here.
            if let p = pending[key] {
                if p.stage == .queued {
                    pending[key] = nil
                } else if let wait, wait.remaining > 0 {
                    // `NSCondition` only waits until a wall-clock date: what is left of the budget is measured again on
                    // the monotonic clock before every wait.
                    while pending[key]?.stage == .running, entries[key] == nil {
                        let left = wait.remaining
                        guard left > 0, lock.wait(until: Date(timeIntervalSinceNow: left)) else { break }
                    }
                    if let e = entries[key] {
                        counts.callerWaited += 1
                        TextGenerator.rasterTally?.add(waited: 1)
                        tick += 1; entries[key]?.tick = tick
                        lock.unlock(); return e.raster
                    }
                }
            }
            lock.unlock()
            let r = try draw(key)
            lock.lock(); defer { lock.unlock() }
            if key.states != nil { counts.callerDrawn += 1; TextGenerator.rasterTally?.add(drawn: 1) }
            return insert(key, r)
        }
    }
}

#endif
