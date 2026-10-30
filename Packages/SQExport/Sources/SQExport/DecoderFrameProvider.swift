import CoreVideo
import Dispatch
import Foundation
import SQCore
import SQMedia
import SQPlayback

/// Runs blocking AVAssetReader / VideoToolbox work on a dedicated serial queue instead of the cooperative pool.
final class QueueExecutor: TaskExecutor, @unchecked Sendable {
    let queue: DispatchQueue
    init(label: String, qos: DispatchQoS = .userInitiated) { queue = DispatchQueue(label: label, qos: qos) }
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Limits shared by the decode providers of one export (all its parallel segments): open decoder sessions and bytes of
/// decoded frames kept. A provider over a limit releases its least recently used media first (never the one it is
/// decoding); the frame being returned is always kept.
public final class DecoderBudget: @unchecked Sendable {
    public let maxDecoders: Int
    public let maxBytes: Int
    /// Open software (non-hardware) sessions at most (weak Macs; `WorkLimits.softwareDecoderSessions`). Default: no extra cap.
    /// Soft: only idle software sessions are closed for it, never layers in use (no close-reopen thrash).
    public let maxSoftwareDecoders: Int
    /// Whether an opened decoder counts against `maxSoftwareDecoders` (default: it is not a hardware session; tests inject).
    let countsAsSoftware: @Sendable (any VideoDecoding) -> Bool
    private let lock = NSLock()
    private var decoders = 0, bytes = 0, opening = 0, software = 0

    /// Defaults: 8 VT sessions and 768 MB of frames over the whole export (a 4K 10-bit frame is ~25 MB).
    public init(maxDecoders: Int = 8, maxBytes: Int = 768 << 20, maxSoftwareDecoders: Int = .max) {
        self.maxDecoders = max(1, maxDecoders); self.maxBytes = max(0, maxBytes)
        self.maxSoftwareDecoders = max(1, maxSoftwareDecoders)
        countsAsSoftware = { !$0.isHardware }
    }

    init(maxDecoders: Int, maxBytes: Int, maxSoftwareDecoders: Int, countsAsSoftware: @escaping @Sendable (any VideoDecoding) -> Bool) {
        self.maxDecoders = max(1, maxDecoders); self.maxBytes = max(0, maxBytes)
        self.maxSoftwareDecoders = max(1, maxSoftwareDecoders); self.countsAsSoftware = countsAsSoftware
    }

    /// The preview's budget on this Mac: software sessions and frame bytes from `WorkLimits` (lower on weak Macs; the
    /// 8 sessions / 768 MB defaults from 16 GB Apple silicon up).
    public static func preview(_ limits: WorkLimits = .current) -> DecoderBudget {
        DecoderBudget(maxDecoders: 8, maxBytes: limits.previewDecoderFrameBytes, maxSoftwareDecoders: limits.softwareDecoderSessions)
    }

    func add(software d: Int) { lock.withLock { software += d } }
    var overSoftware: Bool { lock.withLock { software > maxSoftwareDecoders } }
    /// Open software sessions right now (tests / diagnostics).
    public var softwareSessions: Int { lock.withLock { software } }

    /// `opening`: sessions of opens still in flight (counted in `decoders` too).
    func add(decoders d: Int, bytes b: Int, opening o: Int = 0) { lock.withLock { decoders += d; bytes += b; opening += o } }
    /// Adds `b` bytes only if they stay within the limit (check and add are one step across providers).
    func reserve(bytes b: Int) -> Bool {
        lock.withLock {
            guard bytes + b <= maxBytes else { return false }
            bytes += b
            return true
        }
    }
    var overDecoders: Bool { lock.withLock { decoders > maxDecoders } }
    var overBytes: Bool { lock.withLock { bytes > maxBytes } }
    /// Counted sessions and how many of them are opens still in flight, read in one step.
    var sessions: (all: Int, opening: Int) { lock.withLock { (decoders, opening) } }
    /// Open sessions and kept frame bytes right now (tests / diagnostics).
    public var usage: (decoders: Int, bytes: Int) { lock.withLock { (decoders, bytes) } }
}

/// A decode that failed (damaged media, decoder error). The export renderer adds the clip and timeline time.
public struct FrameDecodeError: Error, Sendable, CustomStringConvertible {
    public var media: UUID
    public var sourceTime: Time
    public var reason: String
    public var description: String { reason }
}

/// Export-side `FrameProvider`: one `VTVideoDecoder` per media, decoding forward without reseeking for consecutive frames
/// (the decoder continues when a request starts right after the last decoded frame) and reseeking on jumps.
/// The last decoded frame is kept, so a repeated source frame (slow motion, frame-rate conversion) costs nothing.
/// Decoding and opening run on a dedicated queue per media (never on the cooperative pool or the actor). Media the resolver cannot open are
/// reported as offline (`nil`); a decode that fails throws `FrameDecodeError`.
/// Sessions and frames are bounded: `release(media:)` drops media the export has moved past, and the shared
/// `DecoderBudget` caps sessions and frame bytes across all providers of one export (least recently used goes first).
/// Decode ahead (export speed): after a request that moves forward, the next `lookAhead` frames at the same step are
/// decoded in the background (the media's own queue), so the next requests find them while the export composites and
/// encodes. Only one decode per media runs at a time (a request waits for the look-ahead first, and cancels it when the
/// request itself is canceled). Moving frame by frame it decodes runs of `aheadBatch` frames (one decoder call each; a
/// frame of a long-GOP 4K source costs about half as much in a run of 6-8 as alone), reserves a run's bytes in the budget
/// before decoding it (a run that does not fit is cut) and keeps each frame when the decoder hands it out, so a request
/// takes it before the run has ended. A released media's look-ahead is canceled and its session stays counted until it
/// has ended.
/// Lanes (export decode-ahead across cuts): `prefetch(media:at:)` decodes a clip start the export will reach soon. When
/// the media's decoder is busy with another point of it (a jump cut ahead, a dissolve), the prefetch opens a further
/// session for it (a lane, up to `lanesPerMedia`, only while the shared session budget keeps room), so neither point
/// seeks on the render path. A request takes the lane that holds, is decoding or decodes on to its frame; else the
/// media's first lane (it seeks, as without lanes). A lane left idle while another serves its media closes. Every lane
/// decodes the same samples from the same sync sample, so the frames are those of a single decoder.
public actor DecoderFrameProvider: FrameProvider {
    private struct Entry {
        var decoder: any VideoDecoding
        var isSoftware = false
        var index: SampleIndex
        var executor: QueueExecutor
        var lastIndex: Int?
        var lastFrame: DecodedFrame?
        /// A few recent frames by index (Frame Blending asks for a frame and its successor alternately).
        var recent: [Int: DecodedFrame] = [:]
        var lastUse = 0
        /// Track info to report instead of the decoder's (a proxy's frames carry the original's geometry and color).
        var infoOverride: VideoTrackInfo?
        /// The background decode of the frames after `lastIndex` (nil = none running).
        var ahead: Task<Void, Never>?
        /// Tells a reopened media's entry from the one a look-ahead was started for.
        var generation = 0
        /// A request has used it. Opens in flight never close an unused entry (its waiter has not run yet).
        var used = false
        /// Frames the running look-ahead or prefetch (`ahead`) will keep.
        var aheadTargets: Set<Int> = []
        /// Source frames between the last two forward requests that started or checked the look-ahead (nil = none yet).
        var step: Int?
        /// Requests waiting for the running look-ahead (no further run is chained meanwhile: a request elsewhere would
        /// wait for it too).
        var waiting = 0
        /// The last frame the lane's decoder decoded (a look-ahead run that starts at or before it seeks back).
        var decodedTo: Int?
        /// A request is decoding on it (no look-ahead or prefetch starts meanwhile: decodes never overlap).
        var busy = false

        /// Bytes of the frames this entry keeps (`lastFrame` is normally also in `recent`: counted once).
        var bytes: Int {
            var seen = Set<ObjectIdentifier>(), n = 0
            for f in Array(recent.values) + (lastFrame.map { [$0] } ?? []) where seen.insert(ObjectIdentifier(f.pixelBuffer)).inserted {
                n += CVPixelBufferGetDataSize(f.pixelBuffer)
            }
            return n
        }
    }
    private let resolver: any MediaResolver
    /// "Use proxies for export": decode a ready proxy with the original's frame times instead of the original.
    private let useProxies: Bool
    private let scale: DecodeScale
    private let budget: DecoderBudget
    private var entries: [UUID: Entry] = [:]
    private var failed: Set<UUID> = []
    /// Still-image media (decoded once by the resolver) and media known not to be stills.
    private var stills: [UUID: StillFrame] = [:]
    private var notStill: Set<UUID> = []
    private var clock = 0
    /// Sessions and bytes this provider has reported to `budget` (given back on release and deinit).
    private var reportedBytes = 0
    /// Bytes reserved in `budget` for look-ahead frames being decoded.
    private var reservedBytes = 0
    /// Look-aheads of released media still ending, by generation: their sessions stay counted in `budget` until then.
    private var draining: [Int: Task<Void, Never>] = [:]
    /// Media being opened (off the actor), with a token that tells a current open from one `invalidate` discarded.
    private var opening: [UUID: (token: Int, task: Task<Entry?, Never>)] = [:]
    private var openToken = 0
    /// Opens in flight: their sessions are already counted in `budget`.
    private var openingSessions = 0

    /// Per media lane, whatever the window: 384 MB = 12 frames of 4K 10-bit 4:2:2 (~33 MB each), so there the
    /// look-ahead stops 11 ahead of the last request (`aheadWindow`); smaller frames are bounded by the window's count
    /// (`3 + lookAhead`). A larger limit measured no faster.
    private let recentByteLimit: Int
    /// Requests (and opens) of this provider without using a software session before it counts as idle for the software
    /// cap: covers every layer of a frame up to ~16 software layers.
    static let softwareIdleRequests = 16
    /// Frames decoded ahead of a forward request (0 = off).
    private let lookAhead: Int
    /// Frames one look-ahead decoder call decodes at step 1 (half the window: one run decodes while the other is used;
    /// a run starts when that many frames of the window are missing).
    private let aheadBatch: Int
    /// 12 frames ahead in runs of 6 (16/8 was as fast on one 4K stream, slower on a cut-heavy template).
    /// `SQ_EXPORT_LOOKAHEAD=4 SQ_EXPORT_AHEAD_BATCH=1`: the look-ahead before 2026-10-06
    /// (A/B bench only).
    public static var defaultLookAhead: Int {
        ProcessInfo.processInfo.environment["SQ_EXPORT_LOOKAHEAD"].flatMap(Int.init) ?? (deliversEarlyByDefault ? 12 : 8)
    }
    /// `SQ_EXPORT_AHEAD_DELIVER=0`: the provider before 2026-10-09 (A/B bench only): 8 frames ahead in runs of 4, kept
    /// only when their decoder call returns; a run that does not fit the budget is refused, a request that finds
    /// nothing decodes its frame alone, and the next run starts with the next request.
    public static let deliversEarlyByDefault = ProcessInfo.processInfo.environment["SQ_EXPORT_AHEAD_DELIVER"] != "0"
    private let deliversEarly: Bool
    /// Look-ahead runs that started at or before the last frame their decoder had decoded (a seek back; tests: 0 when
    /// moving forward).
    public private(set) var aheadReseeks = 0
    /// Requests waiting for a frame of the running look-ahead, by entry generation: resumed whenever frames of it are
    /// kept and when it ends (so no wait outlives the look-ahead).
    private var aheadWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// Look-ahead runs cut short to fit the byte budget (diagnostics).
    public private(set) var aheadShortened = 0
    /// Decodes on the request path (the request had to wait for the decoder; tests / diagnostics).
    public private(set) var requestDecodes = 0
    /// Requests that started over because their media was closed (and maybe reopened) while they waited (tests).
    public private(set) var requestRestarts = 0
    /// Decoder calls the look-ahead made (each decodes a run of frames; tests / diagnostics).
    public private(set) var aheadDecodeCalls = 0
    /// Frames a look-ahead decode returned that were not the one it asked for (tests: must stay 0).
    private(set) var aheadUnwanted = 0
    /// Media closed because the budget was over (diagnostics), look-ahead runs refused by the byte budget, recent frames trimmed.
    public private(set) var budgetDrops = 0, aheadRefused = 0, trimmed = 0
    /// Media opens and their summed duration on the decode queues (diagnostics; they overlap when media open at once).
    public private(set) var opens = 0, openTime: Duration = .zero
    /// Prefetches started (clip starts decoded ahead) and further lanes opened for them (diagnostics).
    public private(set) var prefetches = 0, lanesOpened = 0

    /// Further lanes: lane key -> media (a media's first lane is keyed by the media id itself and is not listed).
    private var laneMedia: [UUID: UUID] = [:]
    /// Decoder sessions per media at most (its first lane included); 1 = prefetch only into the first lane.
    private let lanesPerMedia: Int
    /// Requests of this provider after which a used lane counts as idle (closed when its media has another lane, or
    /// reused by a prefetch). Lanes opened by a prefetch and not used yet wait `8 x` as long (the lead).
    private let laneIdleRequests: Int
    /// Frames a prefetch decodes from the clip start (the first alone, then the rest: the request finds the first early).
    static let prefetchFrames = 3
    /// Prefetches opening their lane (tests: `settle`).
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    private var prefetchToken = 0
    /// Open decoder sessions of this provider, every lane counted (tests / diagnostics).
    public var sessionCount: Int { entries.count }

    /// The media changed (relinked, proxy switched): forget its decoder, cached frames and still.
    public func invalidate(media: UUID) {
        dropLanes(of: media)
        drop(media); stills[media] = nil; failed.remove(media); notStill.remove(media); opening[media] = nil
    }

    /// QoS of the decode queues: userInitiated for an export the user waits for, utility for the background render cache.
    let qos: DispatchQoS

    /// - Parameter budget: shared by every provider of one export (parallel segments); a private one by default.
    /// - Parameter lookAhead: frames decoded ahead of a forward request (0 = off).
    /// - Parameter lanesPerMedia: decoder sessions per media at most (prefetch lanes; 1 = none beyond the first).
    /// - Parameter laneIdleRequests: requests after which a used lane counts as idle.
    /// - Parameter recentByteLimit: decoded frames kept per media lane, in bytes.
    /// - Parameter deliversEarly: false = the look-ahead before 2026-10-09 (see `deliversEarlyByDefault`).
    public init(resolver: any MediaResolver, scale: DecodeScale = .full, budget: DecoderBudget = DecoderBudget(),
                lookAhead: Int = DecoderFrameProvider.defaultLookAhead, lanesPerMedia: Int = 3, laneIdleRequests: Int = 64,
                recentByteLimit: Int = 384 << 20, deliversEarly: Bool = DecoderFrameProvider.deliversEarlyByDefault,
                useProxies: Bool = false, qos: DispatchQoS = .userInitiated) {
        self.useProxies = useProxies; self.qos = qos
        self.resolver = resolver; self.scale = scale; self.budget = budget; self.lookAhead = max(0, lookAhead)
        self.recentByteLimit = recentByteLimit; self.deliversEarly = deliversEarly
        aheadBatch = ProcessInfo.processInfo.environment["SQ_EXPORT_AHEAD_BATCH"].flatMap(Int.init) ?? max(1, lookAhead / 2)
        self.lanesPerMedia = max(1, lanesPerMedia); self.laneIdleRequests = max(1, laneIdleRequests)
    }

    /// Waits for every running look-ahead and prefetch (tests).
    func settle() async {
        while true {
            let running = entries.values.compactMap(\.ahead) + Array(draining.values) + Array(prefetchTasks.values)
            if running.isEmpty { return }
            for t in running { await t.value }
        }
    }

    deinit {
        budget.add(decoders: -entries.count - draining.count - openingSessions, bytes: -reportedBytes - reservedBytes,
                   opening: -openingSessions)
        budget.add(software: -entries.values.filter(\.isSoftware).count)
    }

    /// Wraps every decoder this provider opens (tests: a decoder whose calls return late).
    private var decoderWrap: (@Sendable (any VideoDecoding) -> any VideoDecoding)?
    func setDecoderWrap(_ wrap: (@Sendable (any VideoDecoding) -> any VideoDecoding)?) { decoderWrap = wrap }
    /// Kept frames of a media's first lane and its last requested frame (tests).
    func kept(_ media: UUID) -> (last: Int?, frames: [Int]) { (entries[media]?.lastIndex, (entries[media]?.recent.keys.sorted()) ?? []) }
    /// Bytes still reserved for look-ahead frames and requests waiting for one (tests: both 0 once nothing runs).
    /// Requests of a media's first lane waiting for its look-ahead, and canceled look-aheads still ending (tests).
    func waiting(_ media: UUID) -> Int { entries[media]?.waiting ?? 0 }
    var drainingCount: Int { draining.count }
    var aheadPending: (reserved: Int, waiters: Int) { (reservedBytes, aheadWaiters.values.reduce(0) { $0 + $1.count }) }

    /// Runs in `entry(for:)` right after an open was awaited, before its entry is looked up (tests: lets another open
    /// finish in between).
    private var afterOpenWait: (@Sendable (UUID) async -> Void)?
    func setAfterOpenWait(_ hook: (@Sendable (UUID) async -> Void)?) { afterOpenWait = hook }

    /// Decoder reseeks over the open media (tests / diagnostics; released media no longer count).
    public var reseeks: Int { entries.values.reduce(0) { $0 + (($1.decoder as? VTVideoDecoder)?.reseekCount ?? 0) } }
    /// H.264 samples seeks skipped over the open media (tests / diagnostics; released media no longer count).
    public var seekSkips: Int { entries.values.reduce(0) { $0 + (($1.decoder as? VTVideoDecoder)?.skippedSampleCount ?? 0) } }
    /// Media with an open decoder session (tests / diagnostics).
    public var openMedia: Set<UUID> { Set(entries.keys.map(mediaOf)) }

    /// The export has moved past these media: close their sessions and drop their frames (stills stay: they are the
    /// resolver's, decoded once). A later request opens the media again.
    public func release(media: Set<UUID>) async {
        for m in media { dropLanes(of: m); drop(m) }
        await endDraining()
    }

    /// Closes the further lanes of `media` and discards their opens in flight (the first lane is the caller's).
    private func dropLanes(of media: UUID) {
        for (k, m) in laneMedia where m == media {
            if entries[k] != nil { drop(k) } else if opening[k] != nil { opening[k] = nil }
        }
    }

    private func mediaOf(_ key: UUID) -> UUID { laneMedia[key] ?? key }

    /// Open lanes of `media`, its first lane first.
    private func lanes(of media: UUID) -> [UUID] {
        (entries[media] != nil ? [media] : []) + laneMedia.compactMap { $0.value == media && entries[$0.key] != nil ? $0.key : nil }
    }

    /// Lanes of `media` still opening.
    private func openingLanes(of media: UUID) -> [UUID] {
        (opening[media] != nil ? [media] : []) + laneMedia.compactMap { $0.value == media && opening[$0.key] != nil ? $0.key : nil }
    }

    /// Frame presented at `t`, clamped to the media (a clip may run past its last frame).
    private static func frameIndex(_ index: SampleIndex, _ t: Time) -> Int {
        let all = index.entries
        return index.frame(at: t) ?? (t < all[0].pts ? 0 : all.count - 1)
    }

    /// How a lane gets to frame `idx`: 0 holds it, 1 is decoding it, 2 decodes on to it (a few frames forward); nil = seek.
    private static func reach(_ e: Entry, _ idx: Int) -> Int? {
        if e.recent[idx] != nil || e.lastIndex == idx { return 0 }
        if e.aheadTargets.contains(idx) { return 1 }
        if let l = e.lastIndex, idx > l, idx - l <= 8 { return 2 }
        return nil
    }

    /// The lane a request for `media` at `sourceTime` uses. With only the first lane (or none) that one, as without lanes.
    /// Else the lane that reaches the frame best (most recently used first); else the first lane (it seeks; opened when
    /// needed), or with that one closed, the least recently used lane.
    private func lane(for media: UUID, at sourceTime: Time) async -> UUID {
        var keys = lanes(of: media)
        if keys.isEmpty, let o = openingLanes(of: media).first(where: { $0 != media }) {
            // A prefetch is opening a lane of this media: it will serve, rather than another session.
            _ = await opening[o]?.task.value
            keys = lanes(of: media)
        }
        guard !keys.isEmpty, keys != [media], let first = entries[keys[0]] else { return media }
        let idx = Self.frameIndex(first.index, sourceTime)
        var best: (reach: Int, lastUse: Int, key: UUID)?
        for k in keys {
            guard let e = entries[k], let r = Self.reach(e, idx) else { continue }
            if best.map({ (r, -e.lastUse) < ($0.reach, -$0.lastUse) }) ?? true { best = (r, e.lastUse, k) }
        }
        if let best { return best.key }
        if entries[media] != nil || opening[media] != nil { return media }
        return keys.min { (entries[$0]?.lastUse ?? 0) < (entries[$1]?.lastUse ?? 0) } ?? media
    }

    /// Closes lanes of `media` left idle while it has another lane: used ones after `laneIdleRequests`, prefetched ones
    /// never used after 8 x that.
    private func retireIdleLanes(of media: UUID) {
        for k in lanes(of: media) {
            guard lanes(of: media).count > 1, let e = entries[k], e.ahead == nil else { continue }
            if clock - e.lastUse >= (e.used ? laneIdleRequests : laneIdleRequests * 8) { drop(k) }
        }
    }

    /// Room for a prefetch session: one more still leaves a session free for the render's own opens, and frames fit.
    private var prefetchRoom: Bool { budget.sessions.all + 2 <= budget.maxDecoders && !budget.overBytes }

    /// Decodes the frame of `media` at `sourceTime` (a clip start the export reaches soon) and the next few in the
    /// background, so the request finds them. Nothing when a lane already holds, decodes or decodes on to it. The media's
    /// only lane is used when it is idle (or none is open: its first lane opens); else a further lane opens while the
    /// media has fewer than `lanesPerMedia` and the session budget has room. Returns at once (the work runs on the
    /// lane's decode queue).
    public func prefetch(media: UUID, at sourceTime: Time) async {
        guard !failed.contains(media), still(for: media) == nil else { return }
        let keys = lanes(of: media), pending = openingLanes(of: media)
        let key: UUID
        if keys.isEmpty {
            guard pending.isEmpty, prefetchRoom else { return }
            key = media
        } else {
            guard let first = entries[keys[0]] else { return }
            let idx = Self.frameIndex(first.index, sourceTime)
            if keys.contains(where: { entries[$0].flatMap { Self.reach($0, idx) } != nil }) { return }
            let idle = keys.filter { k in
                entries[k].map { $0.ahead == nil && !$0.busy && $0.used && clock - $0.lastUse >= laneIdleRequests } ?? false
            }.min { (entries[$0]?.lastUse ?? 0) < (entries[$1]?.lastUse ?? 0) }
            if let idle {
                // Its point is done: forget its frames (they are behind or elsewhere) and seek it in the background.
                entries[idle]?.recent = [:]; entries[idle]?.lastIndex = nil; entries[idle]?.lastFrame = nil
                syncBytes()
                key = idle
            } else {
                guard keys.count + pending.count < lanesPerMedia, prefetchRoom else { return }
                key = UUID()
                laneMedia[key] = media
                lanesOpened += 1
            }
        }
        prefetches += 1
        if entries[key] != nil { startPrefetch(key, at: sourceTime); return }
        let open = startOpen(key)
        prefetchToken += 1
        let token = prefetchToken
        prefetchTasks[token] = Task {
            if await open.value != nil { self.startPrefetch(key, at: sourceTime) }
            self.prefetchTasks[token] = nil
        }
    }

    /// Only on a lane no request has positioned (new, or an idle one just reset): never seeks a lane in use.
    private func startPrefetch(_ key: UUID, at sourceTime: Time) {
        guard let e = entries[key], e.ahead == nil, !e.busy, e.lastIndex == nil else { return }
        let idx = Self.frameIndex(e.index, sourceTime), count = e.index.entries.count
        let targets = (idx..<min(count, idx + Self.prefetchFrames)).filter { e.recent[$0] == nil }
        guard let lo = targets.first, let hi = targets.last else { return }
        // Bytes per frame from another lane of the media (none yet: the first frame is counted once it is kept).
        let estimate = lanes(of: mediaOf(key)).lazy.compactMap { self.entries[$0]?.lastFrame ?? self.entries[$0]?.recent.values.first }
            .first.map { CVPixelBufferGetDataSize($0.pixelBuffer) } ?? 0
        runAhead(key, runs: hi > lo && targets.count == hi - lo + 1 ? [lo...lo, (lo + 1)...hi] : targets.map { $0...$0 },
                 estimate: estimate)
    }

    private func drop(_ media: UUID) {
        guard let e = entries.removeValue(forKey: media) else { return }
        laneMedia[media] = nil
        if e.isSoftware { budget.add(software: -1) }
        if let ahead = e.ahead {
            // Its decoder lives until the canceled look-ahead has ended: still counted until `aheadEnded`.
            ahead.cancel()
            draining[e.generation] = ahead
        } else {
            budget.add(decoders: -1, bytes: 0)
        }
        syncBytes()
    }

    /// Reports this provider's current frame bytes to the budget, giving back `released` reserved bytes in the same step.
    private func syncBytes(releasing released: Int = 0) {
        let now = entries.values.reduce(0) { $0 + $1.bytes }
        budget.add(decoders: 0, bytes: now - reportedBytes - released)
        reportedBytes = now
    }

    /// Bounded by count and by bytes (4K frames are large). Frames behind the last request go first (oldest first),
    /// then frames ahead (farthest first): evicting a look-ahead frame would make the decoder seek back for it. The
    /// last requested frame always stays.
    private func trim(_ media: UUID) {
        guard let last = entries[media]?.lastIndex else { return }
        func rank(_ k: Int) -> Int { k < last ? (1 << 40) + (last - k) : k - last }
        while let r = entries[media]?.recent, r.count > 1,
              r.count > 3 + lookAhead || r.values.reduce(0, { $0 + CVPixelBufferGetDataSize($1.pixelBuffer) }) > recentByteLimit,
              let far = r.keys.filter({ $0 != last }).max(by: { rank($0) < rank($1) }) {
            entries[media]?.recent.removeValue(forKey: far)
            trimmed += 1        }
    }

    /// Drops every kept frame before its media's last request (they only serve a step back, e.g. Frame Blending).
    private func shedBehind() {
        for (m, e) in entries {
            guard let last = e.lastIndex, e.recent.keys.contains(where: { $0 < last }) else { continue }
            entries[m]?.recent = e.recent.filter { $0.key >= last }
        }
        syncBytes()
    }

    /// Reserves look-ahead bytes; when they do not fit, frames behind the export are given up first and it tries again.
    private func reserveAhead(_ bytes: Int) -> Bool {
        if budget.reserve(bytes: bytes) { return true }
        shedBehind()
        if budget.reserve(bytes: bytes) { return true }
        aheadRefused += 1
        return false
    }

    /// Over the shared limits: release least recently used media other than `keep`; then trim `keep`'s recent frames
    /// down to its last one.
    /// Opens in flight count as sessions, but only used media are closed to make room for them: an unused entry (just
    /// opened, its waiter not run yet) is closed only when the sessions already open are over the limit, so in-flight
    /// opens never thrash media just opened, and open sessions never exceed `maxDecoders`.
    private func enforceBudget(keep: UUID) {
        // Frames already behind the export are the cheapest to give up (no reseek), so they go before any media.
        if budget.overBytes { shedBehind() }
        // Sessions of canceled look-aheads still count in the budget but are already on their way out.
        func lru(used: Bool) -> UUID? {
            entries.filter { $0.key != keep && (!used || $0.value.used) }.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
        }
        /// Least recently used software session idle for `softwareIdleRequests` (never one in recent use: those are layers
        /// of the frames being rendered, e.g. picture in picture or a dissolve; closing them reopened demuxer + decoder
        /// and reseeked on every frame).
        func idleSoftware() -> UUID? {
            entries.filter { $0.key != keep && $0.value.isSoftware && clock - $0.value.lastUse >= Self.softwareIdleRequests }
                .min(by: { $0.value.lastUse < $1.value.lastUse })?.key
        }
        while true {
            let s = budget.sessions
            let counted = s.all - draining.count, open = counted - s.opening
            var victim: UUID?
            // Software sessions beyond their own cap go first, idle ones only (weak Macs). The cap is soft: when a frame
            // needs more software layers than it allows (or another segment holds the excess), sessions stay open over it
            // instead of thrashing; they close once idle.
            if budget.overSoftware, let v = idleSoftware() { victim = v }
            else if counted > budget.maxDecoders || budget.overBytes, let u = lru(used: true) { victim = u }
            else if open > budget.maxDecoders || budget.overBytes { victim = lru(used: false) }
            else { victim = nil }
            guard let v = victim else { break }
            drop(v)
            budgetDrops += 1
        }
        if budget.overBytes, var e = entries[keep], let last = e.lastIndex, e.recent.count > 1 {
            e.recent = e.recent.filter { $0.key == last }
            entries[keep] = e
            syncBytes()
        }
    }

    /// The open media's entry, opening it when needed. Opening (demuxer + VT session, which can block for a long time on
    /// a cold file) runs on the media's own decode queue, never on the actor: other media open at the same time and
    /// requests for media already open are answered meanwhile. Concurrent requests for one media share its open.
    /// The open itself is not canceled with a request (others may wait for it; the session is kept for the next one);
    /// the request checks for cancellation once it has its entry.
    private func entry(for media: UUID) async -> Entry? {
        while true {
            if let e = entries[media] { return e }
            if failed.contains(mediaOf(media)) { return nil }
            let task = opening[media]?.task ?? startOpen(media)
            // nil: failed (next turn returns nil) or invalidated while opening (next turn opens again). Opened: the
            // entry may have been closed meanwhile (budget, invalidate) — only the current one is returned, else open again.
            if await task.value != nil {
                await afterOpenWait?(media)
                if let e = entries[media] { return e }
            }
        }
    }

    private enum OpenError: Error { case noFrames }

    /// Starts opening `media` on a new decode queue. Its session is counted in the budget from the start (an open in
    /// flight will be a session), so `enforceBudget` closes idle media for it; a failed or discarded open gives it back.
    private func startOpen(_ key: UUID) -> Task<Entry?, Never> {
        let media = mediaOf(key)
        let ex = QueueExecutor(label: "export.decode.\(media.uuidString.prefix(8))", qos: qos)
        let resolver = self.resolver, scale = self.scale, useProxies = self.useProxies
        openToken += 1
        let token = openToken
        openingSessions += 1
        budget.add(decoders: 1, bytes: 0, opening: 1)
        let task = Task<Entry?, Never> {
            let (opened, took): (Result<OpenedMedia, any Error>, Duration) = await withCheckedContinuation { c in
                ex.queue.async {
                    let t0 = ContinuousClock.now
                    let r = Result {
                        // The resolver reuses an import's demuxer (DemuxerHandoff) for a just-imported file.
                        let original = try resolver.demuxer(for: media)
                        var d = original
                        guard original.index.count > 0 else { throw OpenError.noFrames }
                        var proxied = false
                        if useProxies, resolver.colorResolver?.info(of: media)?.video?.deinterlaceFieldOrder == nil,
                           let p = try? resolver.proxyDemuxer(for: media),
                           ProxyPicture.hasOriginalFrameTimes(proxy: p.index, original: original.index) { proxied = true; d = p }
                        // Interlaced media leaves the decoder progressive, as in playback (export reads originals only).
                        let fields = resolver.colorResolver?.info(of: media)?.video?.deinterlaceFieldOrder
                        let decoder = try makeVideoDecoder(demuxer: d, media: media, scale: scale, deinterlace: fields)
                        return OpenedMedia(decoder: decoder, index: original.index,
                                           infoOverride: proxied ? ProxyPicture.info(of: decoder.info, original: original) : nil)
                    }
                    c.resume(returning: (r, ContinuousClock.now - t0))
                }
            }
            self.opens += 1; self.openTime += took
            return self.finishOpen(key, token: token, executor: ex, opened)
        }
        opening[key] = (token, task)
        return task
    }

    private struct OpenedMedia: Sendable {
        var decoder: any VideoDecoding
        var index: SampleIndex
        var infoOverride: VideoTrackInfo?
    }

    /// `media`: the lane key (the media id for its first lane).
    private func finishOpen(_ media: UUID, token: Int, executor: QueueExecutor, _ opened: Result<OpenedMedia, any Error>) -> Entry? {
        openingSessions -= 1
        // Invalidated (relinked, proxy switched) or released while opening: the session belongs to the old file.
        guard opening[media]?.token == token else {
            budget.add(decoders: -1, bytes: 0, opening: -1)
            if media != mediaOf(media), opening[media] == nil, entries[media] == nil { laneMedia[media] = nil }
            return nil
        }
        opening[media] = nil
        switch opened {
        case .failure:
            budget.add(decoders: -1, bytes: 0, opening: -1)
            failed.insert(mediaOf(media))
            laneMedia[media] = nil
            return nil
        case .success(let o):
            budget.add(decoders: 0, bytes: 0, opening: -1)
            clock += 1
            var e = Entry(decoder: decoderWrap?(o.decoder) ?? o.decoder, index: o.index, executor: executor, lastUse: clock, generation: clock)
            e.infoOverride = o.infoOverride
            e.isSoftware = budget.countsAsSoftware(o.decoder)
            if e.isSoftware { budget.add(software: 1) }
            entries[media] = e
            enforceBudget(keep: media)
            return e
        }
    }

    private func still(for media: UUID) -> StillFrame? {
        if let s = stills[media] { return s }
        if notStill.contains(media) || failed.contains(media) { return nil }
        if let s = try? resolver.stillFrame(for: media) { stills[media] = s; return s }
        notStill.insert(media)
        return nil
    }

    public func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        do {
            let f = try await decodedFrame(media: media, at: sourceTime)
            await endDraining()
            return f
        } catch {
            await endDraining()
            throw error
        }
    }

    /// Waits for canceled look-aheads of released media (at most the one frame each was decoding), so their sessions
    /// are closed and uncounted before the request returns.
    private func endDraining() async {
        while let t = draining.values.first { await t.value }
    }

    private func decodedFrame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        if let s = still(for: media) { return ProvidedFrame(buffer: s.buffer, info: s.info, sampleIndex: 0) }
        // The lane serving this frame: `media` itself (its first lane) unless prefetch opened further lanes. A further
        // lane is returned open; the first lane opens here when needed.
        let lane = await lane(for: media, at: sourceTime)
        let k: UUID, e: Entry
        if let open = entries[lane] { k = lane; e = open } else {
            guard let opened = await entry(for: media) else { return nil }
            k = media; e = opened
        }
        defer { if !laneMedia.isEmpty { retireIdleLanes(of: media) } }
        try Task.checkCancellation()
        clock += 1
        entries[k]?.lastUse = clock
        entries[k]?.used = true
        let all = e.index.entries
        let idx = Self.frameIndex(e.index, sourceTime)
        func provided(_ f: DecodedFrame) -> ProvidedFrame {
            ProvidedFrame(buffer: f.pixelBuffer, info: e.infoOverride ?? e.decoder.info, start: all[idx].pts, duration: all[idx].duration, sampleIndex: idx)
        }
        let previous = e.lastIndex
        if let hit = e.recent[idx] ?? (e.lastIndex == idx ? e.lastFrame : nil) {
            entries[k]?.lastIndex = idx; entries[k]?.lastFrame = hit
            enforceBudget(keep: k)
            startAhead(k, after: idx, previous: previous)
            return provided(hit)
        }
        // The next frame is missing and nothing decodes it: it becomes the head of a run (a frame decoded alone costs
        // about twice a frame of a run), and the request takes it as soon as the decoder hands it out.
        if deliversEarly, lookAhead > 0, let p = previous, idx == p + 1, entries[k]?.ahead == nil, entries[k]?.busy == false {
            let estimate = e.lastFrame.map { CVPixelBufferGetDataSize($0.pixelBuffer) } ?? 0
            let n = min(aheadBatch, aheadWindow(estimate))
            var hi = idx
            while hi + 1 < all.count, hi + 1 < idx + n, e.recent[hi + 1] == nil { hi += 1 }
            runAhead(k, runs: [idx...hi], estimate: estimate)
        }
        // One decode per lane at a time: a running look-ahead finishes first (it may hold this very frame). A frame
        // it is decoding is taken when it arrives, not when its run ends.
        // Every pass works on the entry this request opened (`e.generation`): when the budget dropped the media while
        // the request waited (and maybe another request reopened it), the request starts over on the current entry, so
        // it never counts as waiting on, marks busy, or decodes with a session that is not its own.
        while entries[k]?.generation == e.generation, let ahead = entries[k]?.ahead {
            entries[k]?.waiting += 1
            if deliversEarly, let now = entries[k], now.aheadTargets.contains(idx) {
                await waitForAhead(generation: now.generation, ahead)
            } else {
                await withTaskCancellationHandler { await ahead.value } onCancel: { ahead.cancel() }
            }
            if entries[k]?.generation == e.generation { entries[k]?.waiting -= 1 }
            try Task.checkCancellation()
            if let hit = entries[k]?.recent[idx] {
                entries[k]?.lastIndex = idx; entries[k]?.lastFrame = hit
                enforceBudget(keep: k)
                startAhead(k, after: idx, previous: previous)
                return provided(hit)
            }
        }
        guard entries[k]?.generation == e.generation else {
            requestRestarts += 1
            return try await decodedFrame(media: media, at: sourceTime)
        }
        requestDecodes += 1
        let dec = e.decoder
        let frames: [DecodedFrame]
        entries[k]?.busy = true
        func done() { if entries[k]?.generation == e.generation { entries[k]?.busy = false } }
        do {
            if entries[k]?.generation == e.generation { entries[k]?.decodedTo = idx }
            frames = try await withTaskExecutorPreference(e.executor) { try await Self.decode(dec, idx...idx) }
            done()
        } catch let c as CancellationError {
            done()
            throw c
        } catch {
            done()
            if Task.isCancelled { throw CancellationError() }
            throw FrameDecodeError(media: media, sourceTime: sourceTime, reason: String(describing: error))
        }
        guard let f = frames.first else {
            throw FrameDecodeError(media: media, sourceTime: sourceTime, reason: "the decoder returned no picture for source frame \(idx)")
        }
        // Released or reopened while decoding (actor re-entrancy: another request went over the budget, or the media was
        // invalidated and opened again): return without keeping it — it belongs to a decoder that is gone.
        guard entries[k]?.generation == e.generation else { return provided(f) }
        entries[k]?.lastIndex = idx
        entries[k]?.lastFrame = f
        entries[k]?.recent[idx] = f
        trim(k)
        syncBytes()
        enforceBudget(keep: k)
        startAhead(k, after: idx, previous: previous)
        return provided(f)
    }

    /// Suspends until the look-ahead of `generation` has kept more frames or has ended. A canceled request cancels the
    /// look-ahead (as when it waits for all of it), which ends it and so this wait.
    private func waitForAhead(generation: Int, _ ahead: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in aheadWaiters[generation, default: []].append(c) }
        } onCancel: { ahead.cancel() }
    }

    private func wakeAheadWaiters(_ generation: Int) {
        for c in aheadWaiters.removeValue(forKey: generation) ?? [] { c.resume() }
    }

    /// `SQ_EXPORT_SEEK_SKIP=0` decodes every picture before a seek target (A/B bench only).
    static let seekSkip = ProcessInfo.processInfo.environment["SQ_EXPORT_SEEK_SKIP"] != "0"

    /// Frames handed out early by a seek decode (VT callback thread).
    private final class EarlyFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DecodedFrame] = []
        func add(_ f: DecodedFrame) { lock.withLock { frames.append(f) } }
        func take() -> [DecodedFrame] { lock.withLock { frames } }
    }

    /// Decodes `range` with its first frame as the seek target: a fresh start skips H.264 pictures nothing references
    /// before it (frames from the target on are bit-identical; PLAYBACK-PERF "Export: seeks skip unreferenced frames").
    /// Frames come back in presentation order, those the decoder handed out early included.
    static func decode(_ dec: any VideoDecoding, _ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        guard seekSkip else { return try await dec.decode(range) }
        let early = EarlyFrames()
        let rest = try await dec.decode(range, neededFrom: range.lowerBound, deliver: { early.add($0) })
        let delivered = early.take()
        return delivered.isEmpty ? rest : (delivered + rest).sorted { $0.pts < $1.pts }
    }

    /// After a forward request (step 1...8 source frames since the previous one, or the first), decodes the next
    /// `lookAhead` frames at that step in the background unless one is running or they are all kept already.
    /// Each run of consecutive wanted frames is one decode (at step 1 the whole span; at larger steps one frame, so only
    /// wanted frames come back), its bytes reserved in the budget first; stops when the budget is full, a decode fails
    /// or the task is canceled (the decoder also checks between frames).
    private func startAhead(_ media: UUID, after idx: Int, previous: Int?) {
        guard lookAhead > 0, let e = entries[media] else { return }
        let step = previous.map { idx - $0 } ?? 1
        entries[media]?.step = step
        guard e.ahead == nil, step >= 1, step <= 8 else { return }
        let count = e.index.entries.count
        let estimate = e.lastFrame.map { CVPixelBufferGetDataSize($0.pixelBuffer) } ?? 0
        let window = aheadWindow(estimate)
        var targets = (1...window).map { idx + $0 * step }.filter { $0 < count && e.recent[$0] == nil }
        guard !targets.isEmpty else { return }
        // Runs, not single frames (a 4K long-GOP frame decoded alone costs ~9 ms, in a run of 4 ~6, of 8 ~5, of 16 ~5): at step 1
        // wait until `aheadBatch` frames are missing, unless the next one is or the media ends sooner; one run at a time.
        if step == 1 {
            let batch = min(aheadBatch, window)
            let tail = idx + window >= count
            guard targets.count >= batch || targets[0] == idx + 1 || tail else { return }
            targets = Array(targets.prefix(batch))
        }
        var runs: [ClosedRange<Int>] = []
        for i in targets {
            if let r = runs.last, r.upperBound + 1 == i { runs[runs.count - 1] = r.lowerBound...i } else { runs.append(i...i) }
        }
        runAhead(media, runs: runs, estimate: estimate)
    }

    /// Frames ahead of the last request the look-ahead decodes: `lookAhead`, fewer when the last and that many frames
    /// of `estimate` bytes would not fit `recentByteLimit` (trimming would evict the farthest right after it arrived,
    /// and the next run would seek back for it).
    private func aheadWindow(_ estimate: Int) -> Int {
        guard estimate > 0 else { return lookAhead }
        return max(1, min(lookAhead, recentByteLimit / estimate - 1))
    }

    /// Frames of one look-ahead run on their way from the decoder (its callback thread) to the provider, and what is
    /// left of the run's byte reservation.
    private final class AheadRun: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DecodedFrame] = []
        private var reserved: Int, stored = 0
        init(reserved: Int) { self.reserved = reserved }
        func add(_ f: [DecodedFrame]) { lock.withLock { frames += f } }
        func take() -> [DecodedFrame] { lock.withLock { let f = frames; frames = []; return f } }
        /// `kept` more frames are stored: the part of the reservation they stood for (at most what is left).
        func release(kept: Int, each: Int) -> Int {
            lock.withLock { let n = min(reserved, kept * each); reserved -= n; stored += kept; return n }
        }
        /// The rest of the reservation and the frames stored over the whole run.
        func end() -> (reserved: Int, stored: Int) { lock.withLock { let r = reserved; reserved = 0; return (r, stored) } }
    }

    /// Reserves the bytes of `run` in the budget (frames behind the export are given up first). With early delivery a
    /// run that does not fit is cut to its first half, quarter ... frame; nil = not even one frame fits.
    private func reserveRun(_ run: ClosedRange<Int>, estimate: Int) -> ClosedRange<Int>? {
        guard deliversEarly else { return reserveAhead(estimate * run.count) ? run : nil }
        if budget.reserve(bytes: estimate * run.count) { return run }
        shedBehind()
        var n = run.count
        while n >= 1 {
            if budget.reserve(bytes: estimate * n) {
                if n < run.count { aheadShortened += 1 }
                return run.lowerBound...(run.lowerBound + n - 1)
            }
            n /= 2
        }
        aheadRefused += 1
        return nil
    }

    /// Decodes `runs` in the background on the lane's decoder (`ahead`), each run's bytes reserved in the budget first;
    /// stops when the budget is full (a run cut short is the last), a decode fails or the task is canceled (the decoder
    /// also checks between frames). Each frame is kept when the decoder hands it out (`absorb`), so a request finds it
    /// before the run has ended; the reservation shrinks with every frame kept.
    private func runAhead(_ media: UUID, runs: [ClosedRange<Int>], estimate: Int) {
        guard let e = entries[media], e.ahead == nil, !e.busy, !runs.isEmpty else { return }
        let dec = e.decoder, ex = e.executor, gen = e.generation
        entries[media]?.aheadTargets = Set(runs.flatMap { Array($0) })
        let early = deliversEarly, skip = Self.seekSkip
        entries[media]?.ahead = Task {
            var complete = false
            for wanted in runs {
                guard !Task.isCancelled, let run = self.reserveRun(wanted, estimate: estimate) else { break }
                let state = AheadRun(reserved: estimate * run.count)
                self.reservedBytes += estimate * run.count
                self.aheadDecodeCalls += 1
                self.noteRun(media, generation: gen, run)
                let rest: [DecodedFrame]? = try? await withTaskExecutorPreference(ex) {
                    guard skip else { return try await dec.decode(run) }
                    // The run's first frame is the seek target (see `decode`).
                    return try await dec.decode(run, neededFrom: run.lowerBound, deliver: { f in
                        state.add([f])
                        if early { Task { await self.absorb(media, generation: gen, run: run, state, each: estimate) } }
                    })
                }
                state.add(rest ?? [])
                guard self.endRun(media, generation: gen, run: run, state, each: estimate), run == wanted else { break }
                complete = wanted == runs.last
            }
            self.aheadEnded(media, generation: gen, complete: complete)
        }
    }

    /// Keeps the frames of `run` the decoder has handed out so far, gives back their share of the reservation and
    /// resumes the requests waiting for them. Frames of a media released or reopened meanwhile are dropped (they belong
    /// to a decoder that is gone).
    private func absorb(_ media: UUID, generation: Int, run: ClosedRange<Int>, _ state: AheadRun, each: Int) {
        let frames = state.take()
        guard !frames.isEmpty, let e = entries[media], e.generation == generation else { return }
        var stored = 0
        for f in frames {
            guard let i = e.index.frame(at: f.pts), run.contains(i) else { aheadUnwanted += 1; continue }
            if entries[media]?.recent[i] == nil { entries[media]?.recent[i] = f }
            stored += 1
        }
        let released = state.release(kept: stored, each: each)
        reservedBytes -= released
        trim(media)
        syncBytes(releasing: released)
        enforceBudget(keep: media)
        wakeAheadWaiters(generation)
    }

    /// The decoder call of `run` has returned: keeps what is left and gives back the rest of the reservation; false
    /// when the look-ahead should stop (frames missing, or the media was released or reopened).
    private func endRun(_ media: UUID, generation: Int, run: ClosedRange<Int>, _ state: AheadRun, each: Int) -> Bool {
        absorb(media, generation: generation, run: run, state, each: each)
        let end = state.end()
        reservedBytes -= end.reserved
        budget.add(decoders: 0, bytes: -end.reserved)
        return end.stored == run.count && entries[media]?.generation == generation
    }

    /// Counts a run that seeks back (`aheadReseeks`) and moves the lane's decoder position past it.
    private func noteRun(_ media: UUID, generation: Int, _ run: ClosedRange<Int>) {
        guard let e = entries[media], e.generation == generation else { return }
        if let to = e.decodedTo, run.lowerBound <= to { aheadReseeks += 1 }
        entries[media]?.decodedTo = run.upperBound
    }

    /// `complete`: every run was decoded in full (not canceled, cut or failed). Then, moving forward frame by frame,
    /// the next run starts here when the window has room for it, instead of with the next request: the decoder does
    /// not stand idle in between.
    private func aheadEnded(_ media: UUID, generation: Int, complete: Bool) {
        wakeAheadWaiters(generation)
        if draining.removeValue(forKey: generation) != nil {
            budget.add(decoders: -1, bytes: 0)
        } else if let e = entries[media], e.generation == generation {
            entries[media]?.ahead = nil
            entries[media]?.aheadTargets = []
            if complete, deliversEarly, e.step == 1, e.waiting == 0, let last = e.lastIndex {
                startAhead(media, after: last, previous: last - 1)
            }
        }
    }
}
