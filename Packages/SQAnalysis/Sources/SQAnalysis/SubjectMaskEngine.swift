import CoreVideo
import Foundation
import SQCore
import Synchronization

/// The answer of the tracking model for one frame.
struct SubjectTrackOutput {
    /// `SubjectTrackRules.logitSize` squared mask logits over the whole (stretched) frame.
    var logits: [Float]
    /// The model's "object present" score (> 0: present).
    var score: Float
}

enum SubjectTrackError: Error, Equatable {
    case badFrame(String)
    case prediction(String)
    case notConditioned
    case emptyMatte
    /// The engine took the model away (memory pressure, another run's failure).
    case released
    /// A prediction did not come back in time: this model instance is abandoned.
    case stalled

    /// The model itself failed (counts toward giving it up). Not: a matte too faint to condition on, a model taken
    /// away, or anything the system's segmentation threw.
    var isModelFailure: Bool {
        switch self {
        case .prediction, .stalled, .notConditioned, .badFrame: true
        case .emptyMatte, .released: false
        }
    }
}

/// Runs blocking work one at a time on its own thread and gives up waiting after `deadline` seconds
/// (`SubjectTrackError.stalled`). After that it is abandoned: the hung work keeps its thread, every call that waits
/// behind it and every later call throws at once, so nobody queues up behind a prediction that never returns.
final class SubjectDeadlineRunner: @unchecked Sendable {
    /// Under the frame lane's stall limit, so a hung prediction ends on the system's segmentation, not as a hung read.
    static let predictionSeconds = 15.0
    /// A model's first predictions (the load's self test): the devices build their plans then, which takes far
    /// longer on a weak Mac than any later prediction. Slow there is not hung.
    static let selfTestSeconds = 120.0
    let deadline: Double
    private let queue = DispatchQueue(label: "sq.subjectmask.predict", qos: .userInitiated)
    /// Guards `abandoned`, `limit` and every box's result; signaled when a result arrives or the runner is abandoned.
    private let changed = NSCondition()
    private var abandoned = false
    private var limit: Double

    init(deadline: Double = SubjectDeadlineRunner.predictionSeconds) { self.deadline = deadline; limit = deadline }

    var isAbandoned: Bool { changed.lock(); defer { changed.unlock() }; return abandoned }

    /// Calls made inside `body` get `seconds` instead of `deadline` (the self test, before anyone else has the model).
    func withDeadline<T>(_ seconds: Double, _ body: () throws -> T) rethrows -> T {
        changed.lock(); limit = seconds; changed.unlock()
        defer { changed.lock(); limit = deadline; changed.unlock() }
        return try body()
    }

    private final class Box<T>: @unchecked Sendable {
        let work: () throws -> T
        /// Guarded by the runner's `changed`.
        var stored: Result<T, any Error>?
        init(_ work: @escaping () throws -> T) { self.work = work }
    }

    func run<T>(_ work: @escaping () throws -> T) throws -> T {
        let box = Box(work)
        changed.lock()
        if abandoned { changed.unlock(); throw SubjectTrackError.stalled }
        let end = Date(timeIntervalSinceNow: limit)
        changed.unlock()
        queue.async { [self] in
            // Queued behind work that hung: never started.
            if isAbandoned { return }
            let result = Result { try box.work() }
            changed.lock(); box.stored = result; changed.broadcast(); changed.unlock()
        }
        changed.lock()
        defer { changed.unlock() }
        while box.stored == nil, !abandoned { if !changed.wait(until: end) { break } }
        // A result that came in at the last moment counts: slow but finished is not a failure.
        if let result = box.stored { return try result.get() }
        // Its own deadline passed, or the work ahead of it hung: everyone waiting here is let go now.
        if !abandoned { abandoned = true; changed.broadcast() }
        throw SubjectTrackError.stalled
    }
}

/// Set while a frame is inside a prediction of the tracking model, and only then: not during the system's
/// segmentation (Vision) a leg also asks. A read the frame lane calls hung while it is set was hung in the model.
final class SubjectModelMark: Sendable {
    private let on = Mutex(false)
    var isSet: Bool { on.withLock { $0 } }
    /// Stays set when `body` never returns.
    func during<T>(_ body: () throws -> T) rethrows -> T {
        on.withLock { $0 = true }
        defer { on.withLock { $0 = false } }
        return try body()
    }
}

/// One track's memory on a loaded model: conditioned on one frame, then asked frame by frame in tracking order.
/// Used by one thread at a time (the frame lane); every call blocks.
protocol SubjectTrackSession: AnyObject {
    /// Conditions on a click (frame fractions), with a box around the subject when one is known. Without a box the
    /// largest candidate the model trusts is kept (`SubjectTrackRules.largestCandidate`).
    func click(_ frame: CVPixelBuffer, point: Vec2, box: SubjectTrackBox?) throws -> SubjectTrackOutput
    /// Conditions on a matte of this frame (a corrected or earlier tracked one): the model remembers it as given.
    func condition(_ frame: CVPixelBuffer, matte: SubjectMatte) throws
    /// The subject on the next frame. Not remembered until `commit`.
    func track(_ frame: CVPixelBuffer) throws -> SubjectTrackOutput
    /// Adds the frame `track` just answered to the memory of recent frames.
    func commit() throws
    /// A second look at `crop` (frame fractions) of the frame the model just tracked, prompted with `box` (the first
    /// answer's box, frame fractions) and a point inside it: the logits of the crop (`logitSize` square), or nil when
    /// this session cannot. Touches no memory.
    func refine(_ frame: CVPixelBuffer, crop: SubjectTrackBox, box: SubjectTrackBox, inside: Vec2) throws -> [Float]?
    /// The frame `track` just answered, asked again with `points` (clicks made on it) on the same memory-read
    /// features: the model's candidate masks (logits, `logitSize` square), best rated first. Empty when this session
    /// cannot. Touches no memory.
    func corrections(_ points: [MagicPoint]) throws -> [[Float]]
    /// Takes candidate `index` of the last `corrections` as the frame's answer and remembers it: `reseed` true makes
    /// it the conditioning frame (the recent frames are dropped), false adds it to the recent frames.
    func adoptCorrection(_ index: Int, reseed: Bool) throws
    /// `frame` is the one asked next: its picture work that needs no memory (the image encoder) may start now, on
    /// its own thread, while this frame is still with the model. Never blocks for long; a frame asked next that was
    /// not looked ahead is simply done in full then.
    func lookAhead(_ frame: CVPixelBuffer)
}

extension SubjectTrackSession {
    func refine(_ frame: CVPixelBuffer, crop: SubjectTrackBox, box: SubjectTrackBox, inside: Vec2) throws -> [Float]? { nil }
    func corrections(_ points: [MagicPoint]) throws -> [[Float]] { [] }
    func adoptCorrection(_ index: Int, reseed: Bool) throws {}
    func lookAhead(_ frame: CVPixelBuffer) {}
}

/// The loaded parts of the tracking model.
protocol SubjectTrackModel: AnyObject, Sendable {
    func makeSession() -> any SubjectTrackSession
}

protocol SubjectMaskLoading: Sendable {
    /// Loads (and on first use compiles for the devices: 11 to 29 s) all parts. Checks cancellation between parts.
    func load(_ parts: SubjectMaskParts, compute: SubjectTrackCompute) async throws -> any SubjectTrackModel
}

/// Owns the tracking model of the subject mask (EdgeTAM as Core ML parts) for the whole app: finds it, loads it in
/// the background the first time the mask tool asks, hands it to runs, and lets go of it when memory is short or a
/// prediction fails. Whatever goes wrong here, the subject mask works: a run without a lease tracks with the
/// system's segmentation (Vision) as before.
///
/// A run takes its lease when it begins (`leaseForRun`) and keeps that choice to its end. A load under way then (the
/// first use, or the reload after a failure) is waited for, up to `loadWaitSeconds`: the run tracks with the model
/// it asked for, not with Vision next to a model that is seconds away. A lease can be taken away (memory pressure, a
/// failed prediction of another run); the run then goes on with Vision from its last found matte.
public final class SubjectMaskEngine: Sendable {
    public enum Status: Sendable, Equatable {
        /// Nothing loaded; the next `prewarm` loads.
        case idle
        case warming
        case ready
        /// Not on this Mac or not in this install: Vision for good (the reason is in the log).
        case unavailable(String)
    }

    /// The right to use the loaded model until it is taken away.
    final class Lease: Sendable {
        private let held: Mutex<(any SubjectTrackModel)?>
        let personBox: @Sendable (CVPixelBuffer, Vec2) -> SubjectTrackBox?
        init(_ model: any SubjectTrackModel, personBox: @escaping @Sendable (CVPixelBuffer, Vec2) -> SubjectTrackBox?) {
            held = Mutex(model)
            self.personBox = { pb, p in SubjectMaskTiming.measure("person_box") { personBox(pb, p) } }
        }
        /// nil once the engine let go of the model.
        var model: (any SubjectTrackModel)? { held.withLock { $0 } }
        func revoke() { held.withLock { $0 = nil } }
    }

    private struct State {
        var status: Status = .idle
        var lease: Lease?
        var warm: Task<Void, Never>?
        var generation = 0
        var failures = 0
        var pressure: MemoryPressure = .normal
        var active = 0
        /// Runs waiting for the load that is under way (`leaseForRun`): it is not canceled under them.
        var waiters = 0
        /// The request (`generation`) the load in flight was started for, also when that load was given up since and
        /// cannot be stopped: no second one starts next to it. A load written off as hung is no longer this one.
        var loadingGeneration: Int?
        var loadingSince: ContinuousClock.Instant?
        /// When the load in flight was given up (`cancelPrewarm`, memory pressure) while it still ran.
        var givenUpAt: ContinuousClock.Instant?
        /// A run already waited in vain for the load in flight: later runs do not wait for it again, until that
        /// load ends or is written off. Leaving the tool or a memory warning does not change that while it runs.
        var waitedOut = false

        var loading: Bool { loadingGeneration != nil }
        /// The load in flight was given up a moment ago and a new one is asked for behind it: a load that ends on
        /// its cancellation is gone within this time, and the new one is worth waiting for.
        var inGrace: Bool {
            guard let loadingGeneration, loadingGeneration != generation, let givenUpAt else { return false }
            return ContinuousClock.now - givenUpAt < .seconds(SubjectMaskEngine.givenUpGraceSeconds)
        }
        /// A memory warning came while a run was on the model: it is let go when the last run ends.
        var spared = false
    }

    private let state = Mutex(State())
    private let locate: @Sendable () -> SubjectMaskLocator.Found
    private let compute: SubjectTrackCompute?
    private let loader: any SubjectMaskLoading
    private let personBox: @Sendable (CVPixelBuffer, Vec2) -> SubjectTrackBox?
    private let token = Mutex<MemoryPressureToken?>(nil)
    /// Failed loads or predictions after which the model is given up for this launch.
    let maxFailures: Int
    /// Seconds after which a load that has not ended is written off as hung: the next use loads again beside it
    /// (it counts as a failure, so at most `maxFailures` loads ever hang). Far above the slowest real first load
    /// (11 to 29 s compile plus the self test).
    static let hungLoadSeconds = 300.0
    /// Seconds a run gives a load that was just given up to end on its cancellation (`State.inGrace`). At most the
    /// time before a wait is told to the user, so it is never shown.
    static let givenUpGraceSeconds = 0.2
    let hungLoadSeconds: Double

    init(locate: @escaping @Sendable () -> SubjectMaskLocator.Found, compute: SubjectTrackCompute?,
         loader: any SubjectMaskLoading, pressure: MemoryPressureRegistry? = nil, maxFailures: Int = 2,
         hungLoadSeconds: Double = SubjectMaskEngine.hungLoadSeconds,
         personBox: @escaping @Sendable (CVPixelBuffer, Vec2) -> SubjectTrackBox? = { _, _ in nil }) {
        self.locate = locate; self.compute = compute; self.loader = loader; self.maxFailures = maxFailures
        self.hungLoadSeconds = hungLoadSeconds
        self.personBox = personBox
        if let pressure {
            let t = pressure.register("subject mask model") { [weak self] level in self?.memoryPressure(level) }
            token.withLock { $0 = t }
        }
    }

    /// The app's engine. In a test run it never finds models (tests make their own engine).
    public static let shared: SubjectMaskEngine = {
        let env = ProcessInfo.processInfo.environment
        let machine = MachineResources.current()
        var compute = SubjectTrackRules.compute(cpuBrand: cpuBrand(), isIntel: machine.isIntel, lowMemory: machine.isLowMemory)
        if let forced = env["SQ_SUBJECT_MASK_COMPUTE"] { compute = forced == "vision" ? nil : SubjectTrackCompute(rawValue: forced) ?? compute }
        let test = isTestProcess
        return SubjectMaskEngine(locate: { test ? .missing("test run") : SubjectMaskLocator.locate() }, compute: compute,
                                 loader: EdgeTAMLoader(), pressure: .shared, personBox: SubjectPersonBox.find)
    }()

    static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0) == 0 else { return "" }
        return String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil { return true }
        if ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName) { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    public var status: Status { state.withLock { $0.status } }
    /// Loads or predictions that failed so far.
    var failures: Int { state.withLock { $0.failures } }

    /// Starts loading in the background when nothing is loaded yet (the mask tool's first use; cheap to call again).
    /// Never blocks. Does nothing while memory is short.
    public func prewarm() {
        let note: String? = state.withLock { s in
            guard s.pressure == .normal else { return nil }
            let hung = s.loadingSince.map { ContinuousClock.now - $0 >= .seconds(hungLoadSeconds) } ?? false
            guard s.status == .idle || (s.status == .warming && hung) else { return nil }
            guard let compute else {
                s.status = .unavailable("this Mac runs the subject mask without the tracking model")
                return "tracking with Vision: this Mac is not in the model's range (Intel, or switched off)"
            }
            s.status = .warming
            s.generation += 1
            guard s.loading else { startLoad(&s, compute); return nil }
            // One load at a time: a load given up before (the tool was closed, memory was short) may still run,
            // Core ML's cannot be stopped. A second one next to it would hold the model twice. Its end (`warm`)
            // serves this request instead.
            guard hung else { return nil }
            // It never came back: written off (its late result is thrown away) and counted against the model, so
            // a model whose loads hang is given up instead of piling up loads.
            s.failures += 1
            guard s.failures < maxFailures else {
                s.status = .unavailable("the tracking model did not finish loading"); s.warm = nil
                return "tracking with Vision: the model did not finish loading, given up for this launch"
            }
            s.waitedOut = false
            startLoad(&s, compute)
            return "a model load did not end, loading again"
        }
        if let note { NSLog("[SubjectMask] %@", note) }
    }

    /// Stops a load that is running (the tool was closed before it got ready). The next `prewarm` starts over, or
    /// takes up the stopped load when that one could not be stopped yet. Does nothing while a run waits for that load.
    public func cancelPrewarm() {
        state.withLock { s in
            guard s.status == .warming, s.waiters == 0 else { return }
            s.warm?.cancel(); s.warm = nil
            s.generation += 1
            s.status = .idle
            Self.gaveUpLoad(&s)
        }
    }

    /// The load asked for was given up. One that still runs keeps what is known about it (`waitedOut`): it is the
    /// load the next request gets.
    private static func gaveUpLoad(_ s: inout State) {
        if s.loading { s.givenUpAt = .now } else { s.waitedOut = false }
    }

    /// Starts the one load in flight for the request `s.generation`. Called under the state lock.
    private func startLoad(_ s: inout State, _ compute: SubjectTrackCompute) {
        let generation = s.generation
        s.loadingGeneration = generation; s.loadingSince = .now; s.givenUpAt = nil
        s.warm = Task.detached(priority: .utility) { [weak self] in await self?.warm(generation, compute) }
    }

    private enum Loaded {
        case model(any SubjectTrackModel, source: String, seconds: Double)
        case missing(String)
        case canceled
        case failed(any Error)
    }

    private func load(_ compute: SubjectTrackCompute) async -> Loaded {
        switch locate() {
        case .missing(let why): return .missing(why)
        case .parts(let parts):
            do {
                let started = Date()
                let model = try await loader.load(parts, compute: compute)
                return .model(model, source: parts.source, seconds: Date().timeIntervalSince(started))
            } catch is CancellationError {
                return .canceled
            } catch {
                return .failed(error)
            }
        }
    }

    private enum Settled {
        case nothing
        case ready(source: String, seconds: Double)
        case missing(String)
        case failed(any Error, left: Int)
    }

    /// The load for request `generation`. What it brings is judged when it ends, against what is wanted then: a load
    /// that was given up and asked for again while it ran hands its model to the later request.
    private func warm(_ generation: Int, _ compute: SubjectTrackCompute) async {
        let loaded = await load(compute)
        let settled = state.withLock { s -> Settled in
            // Written off as hung meanwhile (another load took its place): whatever it brings is thrown away.
            guard s.loadingGeneration == generation else { return .nothing }
            s.loadingGeneration = nil; s.loadingSince = nil; s.givenUpAt = nil
            s.waitedOut = false
            // Given up and not asked for again: `cancelPrewarm` or memory pressure already set the state; a model
            // that came anyway is let go here.
            guard s.status == .warming else { return .nothing }
            let mine = s.generation == generation
            switch loaded {
            case .model(let model, let source, let seconds):
                s.warm = nil
                // Memory got short while it loaded: not kept.
                guard s.pressure == .normal else { s.status = .idle; return .nothing }
                s.lease = Lease(model, personBox: personBox); s.status = .ready
                return .ready(source: source, seconds: seconds)
            case .missing(let why):
                s.status = .unavailable(why); s.warm = nil
                return .missing(why)
            case .failed(let error) where mine:
                s.failures += 1; s.warm = nil
                s.status = s.failures >= maxFailures ? .unavailable("the tracking model failed to load") : .idle
                return .failed(error, left: maxFailures - s.failures)
            case .canceled where mine:
                s.status = .idle; s.warm = nil
                return .nothing
            case .canceled, .failed:
                // The load given up ended without a model, and one was asked for meanwhile: that one starts now.
                startLoad(&s, compute)
                return .nothing
            }
        }
        switch settled {
        case .nothing: break
        case .ready(let source, let seconds):
            NSLog("[SubjectMask] tracking with EdgeTAM (%@, models: %@, ready after %.1f s)", compute.rawValue, source, seconds)
        case .missing(let why):
            NSLog("[SubjectMask] tracking with Vision: %@", why)
        case .failed(let error, let left):
            NSLog("[SubjectMask] tracking with Vision: the model failed to load (%@), %@", "\(error)",
                  left > 0 ? "it is tried again on the next use" : "given up for this launch")
        }
    }

    /// The loaded model for one run, nil when it is not ready (the run then tracks with Vision).
    func lease() -> Lease? { state.withLock { $0.status == .ready ? $0.lease : nil } }

    /// A run on the model begins / ended (memory pressure spares a model in use until it is critical).
    func begin() { state.withLock { $0.active += 1 } }
    func end() {
        // Decided and done under one lock: a run that begins right after gets no lease of a model on its way out,
        // and none that just got its lease loses it to this.
        let dropped = state.withLock { s -> Lease? in
            s.active = max(0, s.active - 1)
            guard s.active == 0, s.spared else { return nil }
            s.spared = false
            return s.status == .ready ? Self.drop(&s) : nil
        }
        guard let dropped else { return }
        dropped.revoke()
        NSLog("[SubjectMask] memory is short: the tracking model is released now that its run ended")
    }

    /// Seconds a run waits for a load under way before it goes on with the system's segmentation (the load goes on
    /// and serves the next run). Covers a first load with its compile and first predictions.
    public static let loadWaitSeconds = 60.0
    /// Seconds a run waits before it says so (`preparing`): a load that ends at once (no models) says nothing.
    static let preparingAfterSeconds = 0.2

    /// The model for a run that begins now, counted as in use from here (the caller calls `end` when it got one).
    /// Starts the load when nothing is loaded and waits for one under way, at most `wait` seconds; nil when there is
    /// no model then (not available, the load failed or takes longer, memory is short): the run tracks with Vision.
    /// `preparing`: true once the wait is worth telling the user, false when it ended and the run goes on. Throws
    /// only `CancellationError` (the user's Stop while it waits).
    /// A load one run waited `wait` seconds for in vain is not waited for again (a load that never ends would cost
    /// every pick that time): later runs go on with Vision at once, and use the model once that load is done.
    func leaseForRun(wait: Double = SubjectMaskEngine.loadWaitSeconds,
                     preparing: (@Sendable (Bool) -> Void)? = nil) async throws -> Lease? {
        prewarm()
        // Taking the lease and counting the run is one step: no release decided in between takes it away.
        func look(_ s: inout State) -> (lease: Lease?, warming: Bool) {
            if s.status == .ready, let l = s.lease { s.active += 1; return (l, false) }
            return (nil, s.status == .warming && (!s.waitedOut || s.inGrace))
        }
        let first = state.withLock { s in
            let found = look(&s)
            if found.warming { s.waiters += 1 }
            return found
        }
        guard first.warming else { return first.lease }
        defer { state.withLock { $0.waiters -= 1 } }
        let clock = ContinuousClock()
        let started = clock.now
        var told = false
        while true {
            try await Task.sleep(for: .milliseconds(20))
            let now = state.withLock { look(&$0) }
            let waited = clock.now - started
            if now.lease != nil || !now.warming || waited >= .seconds(wait) {
                if now.lease == nil, now.warming {
                    state.withLock { s in if s.status == .warming { s.waitedOut = true } }
                    NSLog("[SubjectMask] this track runs with Vision: the model was not ready after %.0f s", wait)
                }
                if told { preparing?(false) }
                return now.lease
            }
            if !told, waited >= .seconds(Self.preparingAfterSeconds) { told = true; preparing?(true) }
        }
    }

    /// Lets go of the model and of a load that is running; the lease to revoke (outside the lock).
    private static func drop(_ s: inout State) -> Lease? {
        s.warm?.cancel(); s.warm = nil
        s.generation += 1
        gaveUpLoad(&s)
        if s.status == .warming || s.status == .ready { s.status = .idle }
        let l = s.lease
        s.lease = nil
        return l
    }

    /// A run on the model went through: earlier failures no longer count against it.
    func succeeded(_ lease: Lease) {
        state.withLock { s in if s.lease === lease { s.failures = 0 } }
    }

    /// A prediction of a run failed: the model is let go (every run on it goes on with Vision) and loaded again on
    /// the next use, unless it failed too often.
    func failed(_ lease: Lease, error: any Error) {
        let left = state.withLock { s -> Int? in
            guard s.lease === lease else { return nil }
            s.lease = nil; s.failures += 1
            s.status = s.failures >= maxFailures ? .unavailable("the tracking model failed") : .idle
            return maxFailures - s.failures
        }
        lease.revoke()
        if let left {
            NSLog("[SubjectMask] tracking with Vision: a prediction failed (%@), %@", "\(error)",
                  left > 0 ? "the model is loaded again on the next use" : "given up for this launch")
        }
    }

    /// Lets go of the model (and of a load that is running).
    public func release() {
        state.withLock { Self.drop(&$0) }?.revoke()
    }

    /// False while memory is short (warning or critical). Asked once, before a pick's first run
    /// (`MagicMaskTracker.decide`): the pick then tracks at the tracking size with the quick edge step, whatever
    /// `SubjectMaskQuality` says (a Quality matte is four times the memory, decoded and stored). A pick already
    /// running keeps the edge it began with; nothing is freed for it here.
    var hasRoomForQuality: Bool { state.withLock { $0.pressure == .normal } }

    /// Warning: a model nobody tracks with is let go. Critical: also one in use (its runs go on with Vision).
    func memoryPressure(_ level: MemoryPressure) {
        let dropped = state.withLock { s -> (lease: Lease?, did: Bool) in
            s.pressure = level
            // A model spared for its run is let go when the run ends (`end`), unless memory is fine again by then.
            s.spared = level == .warning && s.active > 0 && s.status == .ready
            guard s.status == .warming || s.status == .ready else { return (nil, false) }
            guard level == .critical || (level == .warning && s.active == 0) else { return (nil, false) }
            return (Self.drop(&s), true)
        }
        guard dropped.did else { return }
        dropped.lease?.revoke()
        NSLog("[SubjectMask] memory is short: the tracking model is released, tracking with Vision until it is loaded again")
    }
}

/// The five Core ML parts of the tracking model on disk.
public struct SubjectMaskParts: Sendable, Equatable {
    public static let encoder = "edgetam_encoder_fp16"
    public static let decoder = "edgetam_decoder_fp16"
    public static let decoderBox = "edgetam_decoder_box_fp16"
    public static let memoryEncoder = "edgetam_mem_encoder_fp16"
    public static let memoryAttention = "edgetam_mem_attention_fp16"
    public static let names = [encoder, decoder, decoderBox, memoryEncoder, memoryAttention]

    /// Part name -> a compiled model (`.mlmodelc`) or a package to compile (`.mlpackage`).
    public var urls: [String: URL]
    /// Where they were found (the log line).
    public var source: String
}

/// Finds the model parts. Looked at, in this order: the folder named by `SQ_SUBJECT_MASK_MODELS` (development and
/// tests: an explicit choice wins), the app bundle (`Contents/Resources/SubjectMask`), and
/// `~/Library/Application Support/Sequence Studio/Models/SubjectMask`, and in a Debug build the source checkout the app
/// was built in (`checkoutFolder(from:)`). A folder counts only with all five parts; per
/// part `<name>.mlmodelc`, `compiled/<name>.mlmodelc` or `<name>.mlpackage` (compiled into the caches on first use).
public enum SubjectMaskLocator {
    public static let environmentKey = "SQ_SUBJECT_MASK_MODELS"
    public static let folderName = "SubjectMask"

    public enum Found: Sendable, Equatable {
        case parts(SubjectMaskParts)
        case missing(String)
    }

    public static var supportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sequence Studio/Models/\(folderName)", isDirectory: true)
    }

    /// Where the spike's compiled models lie in a source checkout (not in git).
    public static let checkoutModels = "Tools/SubjectMaskSpike/work/models/compiled"

    /// The models of the source checkout an app was built in: the folders above `app` (a `.app` bundle) are searched
    /// for `checkoutModels`. A Debug app from `scripts/build.sh` carries no models (only `scripts/package.sh` copies
    /// them), so without this it tracked with Vision (Debug ~220 ms a frame, a 2 s mask took ~14 s).
    /// shortcut: only the checkout's folder is searched, upgrade when development builds copy the models into the bundle.
    public static func checkoutFolder(from app: URL?) -> URL? {
        guard let app, app.pathExtension == "app" else { return nil }
        var folder = app.deletingLastPathComponent()
        for _ in 0..<10 {
            let models = folder.appendingPathComponent(checkoutModels, isDirectory: true)
            if FileManager.default.fileExists(atPath: models.path) { return models }
            let up = folder.deletingLastPathComponent()
            if up.path == folder.path { break }
            folder = up
        }
        return nil
    }

    /// A Debug build looks in its source checkout last; a release build never does.
    public static var developmentFolder: URL? {
        #if DEBUG
        checkoutFolder(from: Bundle.main.bundleURL)
        #else
        nil
        #endif
    }

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: URL? = Bundle.main.resourceURL, support: URL? = supportFolder,
                              checkout: URL? = developmentFolder) -> Found {
        var places: [(String, URL)] = []
        if let path = environment[environmentKey], !path.isEmpty { places.append((environmentKey, URL(fileURLWithPath: path, isDirectory: true))) }
        if let bundle { places.append(("app bundle", bundle.appendingPathComponent(folderName, isDirectory: true))) }
        if let support { places.append(("Application Support", support)) }
        if let checkout { places.append(("source checkout", checkout)) }
        var notes: [String] = []
        for (name, folder) in places {
            switch parts(in: folder) {
            case .success(let urls): return .parts(SubjectMaskParts(urls: urls, source: name))
            case .failure(let gap): notes.append("\(name): \(gap.what)")
            }
        }
        return .missing("no tracking model (" + (notes.isEmpty ? "nowhere to look" : notes.joined(separator: "; ")) + ")")
    }

    struct Gap: Error { var what: String }

    static func parts(in folder: URL) -> Result<[String: URL], Gap> {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure(Gap(what: "no folder")) }
        var urls: [String: URL] = [:]
        var missing: [String] = []
        for name in SubjectMaskParts.names {
            let choices = [folder.appendingPathComponent("\(name).mlmodelc"), folder.appendingPathComponent("compiled/\(name).mlmodelc"),
                           folder.appendingPathComponent("\(name).mlpackage")]
            if let hit = choices.first(where: { fm.fileExists(atPath: $0.path) }) { urls[name] = hit } else { missing.append(name) }
        }
        return missing.isEmpty ? .success(urls) : .failure(Gap(what: "missing " + missing.joined(separator: ", ")))
    }
}
