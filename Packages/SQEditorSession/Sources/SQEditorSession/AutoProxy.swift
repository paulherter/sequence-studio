import Foundation
#if canImport(os)
import os
#endif
import SQCore
import SQMedia
import SQPlayback
import SQProxy

/// W9.9 AutoProxy: generates proxies of heavy long-GOP sources in the background (one at a time, background priority)
/// and points the monitors at them (scrubbing; playback too on a weak Mac or when `sq.proxy.playback` is on). Paused
/// frames and export always read the originals: proxies are only reachable through `ProjectMediaResolver.proxyDemuxer`,
/// which only the playback engines call. Mode and playback setting live in UserDefaults (`ProxySettingsStore`), so the
/// project file is unchanged.
@MainActor
public final class AutoProxyService {
    public let cache: ProxyCache
    public let queue: ProxyQueue
    public let provider: ProxyProvider
    public let settings: ProxySettingsStore
    public let machine: MachineProfile
    private let resolver: ProjectMediaResolver
    private let prober: any SourceSeekProbing
    /// Free and total bytes of the proxy cache's volume (`ProxyDiskGuard`); injected by tests.
    private let diskSpace: @Sendable (URL) -> (free: Int64?, total: Int64?)
    private var engines: [WeakEngine] = []
    /// True while a monitor plays or an export runs (injected; the app reads the engines and the export queue).
    private let isBusy: @MainActor () -> Bool
    private let busyPoll: Duration
    /// How long the machine must be idle before held jobs resume (a pause between two plays does not restart a transcode).
    private let busyResume: Duration
    private var busyHeld = false
    private var idleSince: ContinuousClock.Instant?
    private var busyTask: Task<Void, Never>?
    /// Queue start order per media (timeline-first, `ProxyOrdering`).
    private var ranks: [UUID: Int] = [:]

    private final class WeakEngine { weak var engine: (any ProgramEngine)?; init(_ e: any ProgramEngine) { engine = e } }

    /// What a proxy decision was made for; a different path, size or modification date starts over, and so does the
    /// item's Deinterlace switch (`keepsFields`: interlaced with Deinterlace off, which gets and uses no proxy).
    private struct FileState: Equatable { var path: String; var size: Int64; var modified: Date?; var keepsFields = false }
    private struct Tracked {
        var file: FileState
        var task: Task<Void, Never>?
        /// The decision task has not returned yet (probe, warm, disk read, enqueue, or waiting on its job).
        var taskLive = false
        var job: ProxyJobID?
        var ready = false
        /// The cache record in use once ready (protected from eviction).
        var record: ProxyRecordID?
        /// Not generated because proxies in use fill the cache cap; retried by `refresh()`.
        var capped = false
        /// Not generated because the disk reserve would be broken (`ProxyDiskGuard`); retried by `refresh()`.
        var diskRefused = false
        /// Estimated bytes of this media's queued or running proxy, held against the disk reserve until it is ready.
        var reservedBytes: Int64 = 0
        /// No hardware decoder for the source on this Mac: its job runs ahead of the others (`AutoProxyRule.rank`).
        var software = false
    }
    private var tracked: [UUID: Tracked] = [:]
    /// Last free/total disk reading of the cache volume (read off the main actor, reused for `diskSampleTTL`).
    private var diskSample: (at: ContinuousClock.Instant, free: Int64?, total: Int64?)?
    static let diskSampleTTL: Duration = .seconds(5)
    private var lastMedia: [MediaRef] = []
    private var lastProject: UUID?
    private var lastTimeline: Timeline?
    public private(set) var mode: ProxyMode = .auto
    /// The playback setting last applied (with `mode`), to tell a real settings change from any other defaults write.
    private var appliedPlayback: ProxyPlaybackMode = .auto
    private var settingsDebounce: Task<Void, Never>?
    private var observers: [Observer] = []
    nonisolated private static let log = Logger(subsystem: "SequenceStudio", category: "proxy")

    private final class Observer: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ t: any NSObjectProtocol) { token = t }
        deinit { NotificationCenter.default.removeObserver(token) }
    }

    public init(resolver: ProjectMediaResolver, engines: [any ProgramEngine], cache: ProxyCache = ProxyCache(),
                transcoder: any ProxyTranscoding = ProxyTranscoder(), prober: any SourceSeekProbing = AVSourceSeekProber(),
                settings: ProxySettingsStore = ProxySettingsStore(), machine: MachineProfile = .current,
                limits: WorkLimits = .current,
                isBusy: @escaping @MainActor () -> Bool = { false },
                busyPoll: Duration = .milliseconds(500), busyResume: Duration = .seconds(2),
                diskSpace: @escaping @Sendable (URL) -> (free: Int64?, total: Int64?) = { ProxyDiskGuard.volume(of: $0) }) {
        self.resolver = resolver; self.cache = cache; self.prober = prober; self.settings = settings; self.machine = machine
        self.diskSpace = diskSpace
        self.isBusy = isBusy; self.busyPoll = busyPoll; self.busyResume = busyResume
        queue = ProxyQueue(cache: cache, transcoder: transcoder, concurrency: limits.proxyTranscodes)
        let provider = ProxyProvider(cache: cache)
        self.provider = provider
        self.engines = engines.map(WeakEngine.init)
        // Stat-only: a source whose size or date changed has no proxy until its new fingerprint is computed (`warm`).
        resolver.setProxyLookup { _, path in
            provider.cachedLookup(for: URL(fileURLWithPath: path), preferring: ProxyProvider.scrubPreference)?.url
        }
        let queue = self.queue
        Task { await queue.start() }        // stale partials, cache cap
        let removals = cache.removedRecords()
        Task { [weak self] in for await r in removals { self?.removed(r) } }
        // Mode (app-wide or per project) or playback changed in UserDefaults: re-applied, debounced.
        observers.append(Observer(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsChanged() }
            }))
    }

    /// Q-PERF2 rec 3: thermal pressure or Low Power Mode: no new proxy job starts (a running one finishes).
    public private(set) var isHeld = false
    public func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        applyHold()
    }

    /// The app's service: the proxy cache sits in `directory` (`AppSettings.proxyCacheDirectory`).
    public static func make(resolver: ProjectMediaResolver, engines: [any ProgramEngine], directory: URL,
                            isBusy: @escaping @MainActor () -> Bool) -> AutoProxyService {
        AutoProxyService(resolver: resolver, engines: engines, cache: ProxyCache(directory: directory), isBusy: isBusy)
    }

    /// Settings > Media > Cache Size: sets the proxy cache cap and evicts least-recently-used proxies down to it at once.
    /// Proxies in use by a monitor are never evicted (the cap may then stay exceeded). Returns the evicted records.
    @discardableResult
    public func applyCacheCap(bytes: Int64) -> [ProxyRecord] {
        let capped = max(bytes, 0)
        if cache.settings.cacheCapBytes != capped { try? cache.updateSettings { $0.cacheCapBytes = capped } }
        let removed = cache.enforceCap()
        refresh()
        return removed
    }

    /// Settings > Media > Delete Cache: removes every proxy that no monitor is using, returns the bytes freed.
    @discardableResult
    public func clearCache() -> Int64 {
        let before = cache.totalSize()
        _ = cache.evict(toFit: 0)
        return before - cache.totalSize()
    }

    /// The queue is held for thermal pressure / Low Power Mode, or while a monitor plays or an export runs.
    private var queueHeld = false
    private func applyHold() {
        let hold = isHeld || busyHeld
        guard hold != queueHeld else { return }
        queueHeld = hold
        let q = queue
        Task { await q.setHeld(hold) }
    }

    /// True while jobs wait for playback or export to end (tests, debug HUD).
    public var isBusyHeld: Bool { busyHeld }

    /// One reading of the busy signal: busy holds at once; idle releases after `busyResume` without interruption.
    /// A running transcode always finishes (same rule as the thermal hold). Internal for tests.
    func pollBusy() {
        if isBusy() {
            idleSince = nil
            if !busyHeld { busyHeld = true; applyHold() }
        } else if busyHeld {
            let now = ContinuousClock.now
            let since = idleSince ?? now
            idleSince = since
            if now - since >= busyResume { busyHeld = false; idleSince = nil; applyHold() }
        }
    }

    /// Polls while jobs are pending or held; stops when there is nothing to pause.
    private func ensureBusyPolling() {
        pollBusy()                     // a job decided while busy is held before it can start
        guard busyTask == nil else { return }
        busyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollBusy()
                if !self.needsBusyPolling && !self.busyHeld { self.busyTask = nil; return }
                try? await Task.sleep(for: self.busyPoll)
            }
        }
    }

    /// Any tracked media still has a live decision task or a queued/running job: a playback or export that starts
    /// now must still be seen (probe, warm and enqueue happen before `job` is set).
    var needsBusyPolling: Bool { tracked.values.contains { !$0.ready && ($0.taskLive || $0.job != nil) } }
    /// True while the busy poll task runs (tests).
    var isBusyPolling: Bool { busyTask != nil }

    /// Media IDs with a ready proxy (tests, debug HUD).
    public var readyMedia: Set<UUID> { Set(tracked.filter { $0.value.ready }.keys) }
    /// Media with a proxy job queued or running.
    public var pendingMedia: Set<UUID> { Set(tracked.filter { !$0.value.ready && $0.value.job != nil }.keys) }
    /// Media not generated because of the disk reserve (until `refresh()`).
    public var diskRefusedMedia: Set<UUID> { Set(tracked.filter { $0.value.diskRefused }.keys) }
    /// Bytes held against the disk reserve by queued and running proxies.
    var reservedDiskBytes: Int64 { tracked.values.reduce(0) { $0 + ($1.ready ? 0 : $1.reservedBytes) } }

    /// Free and total bytes of the cache volume, read off the main actor (a volume query can block), cached briefly.
    private func diskNow() async -> (free: Int64?, total: Int64?) {
        if let d = diskSample, ContinuousClock.now - d.at < Self.diskSampleTTL { return (d.free, d.total) }
        let read = diskSpace, dir = cache.directory
        let v = await Task.detached(priority: .utility) { read(dir) }.value
        diskSample = (ContinuousClock.now, v.free, v.total)
        return v
    }

    /// Reserves `estimate` for `id` if the volume keeps its reserve after it and every queued or running proxy.
    /// Synchronous on the main actor, so two decisions can never both pass on the same free space.
    private func reserveDisk(_ id: UUID, file: FileState, estimate: Int64, disk: (free: Int64?, total: Int64?)) -> Bool {
        guard tracked[id]?.file == file else { return false }
        guard ProxyDiskGuard.allows(estimatedBytes: estimate + reservedDiskBytes, freeBytes: disk.free, volumeBytes: disk.total) else {
            tracked[id]?.diskRefused = true
            return false
        }
        tracked[id]?.reservedBytes = estimate
        return true
    }
    /// Waits until every tracked media's decision task has finished (tests: a deterministic "nothing was queued" check).
    /// Only for states where no job is running: a task waiting on a running job finishes with it.
    func settled() async {
        for t in tracked.values.compactMap(\.task) { await t.value }
    }
    /// The project last synced.
    public var projectID: UUID? { lastProject }

    /// Called with the project's media after every change (and on open). New or changed video sources are probed and,
    /// when the rule says so, queued; removed ones are canceled; a changed source drops its old proxy at once.
    public func sync(_ media: [MediaRef], projectID: UUID?, activeTimeline: Timeline? = nil) {
        lastMedia = media; lastProject = projectID; lastTimeline = activeTimeline
        mode = settings.mode(project: projectID)
        appliedPlayback = settings.playback
        let use = mode == .off ? ProxyUse.off
            : ProxyUse(scrubbing: true, playback: AutoProxyRule.usesProxiesForPlayback(appliedPlayback, machine: machine))
        for e in liveEngines() where e.proxyUse != use { e.proxyUse = use }
        var invalid: Set<UUID> = []
        let wanted = mode == .off ? [] : media.filter { $0.info?.isStill != true && ($0.info == nil || $0.info?.video != nil) }
        let keep = Set(wanted.map(\.id))
        for (id, t) in tracked where !keep.contains(id) {
            stop(id, t)
            if t.ready { invalid.insert(id) }
        }
        // Timeline-first: media the active timeline uses (earliest position first), then bin-only media.
        let ordered = ProxyOrdering.sorted(wanted.map(\.id), firstUse: ProxyOrdering.firstUse(in: activeTimeline))
        ranks = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        let byID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, t) in tracked {
            if let job = t.job, !t.ready, let r = ranks[id] {
                let q = queue, rank = AutoProxyRule.rank(r, softwareDecode: t.software, mediaCount: ranks.count)
                Task { await q.setRank(job, rank) }
            }
        }
        for ref in ordered.compactMap({ byID[$0] }) {
            var file = Self.fileState(ref.path)
            if let v = ref.info?.video { file.keepsFields = v.isInterlaced && v.deinterlaceOff }
            if let t = tracked[ref.id] {
                if t.file == file { continue }
                stop(ref.id, t)
                if t.ready { invalid.insert(ref.id) }
            }
            guard file.size > 0 else { continue }          // offline: decided when it comes back (next sync)
            tracked[ref.id] = Tracked(file: file)
            start(ref, file)
        }
        if !invalid.isEmpty { notify(invalid) }
    }

    /// Re-reads the settings (mode, playback) and applies them to the last synced media.
    public func refresh() {
        diskSample = nil                      // space may have been freed: read the disk again
        for (id, t) in tracked where t.capped || t.diskRefused { tracked[id] = nil }
        sync(lastMedia, projectID: lastProject, activeTimeline: lastTimeline)
    }

    private func defaultsChanged() {
        settingsDebounce?.cancel()
        settingsDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            if self.settings.mode(project: self.lastProject) != self.mode || self.settings.playback != self.appliedPlayback {
                self.refresh()
            }
        }
    }

    private func stop(_ id: UUID, _ t: Tracked) {
        t.task?.cancel()
        tracked[id] = nil
        if let job = t.job, !t.ready { release(job) }
        if t.ready { updateProtected() }
    }

    /// Cancels `job` unless another tracked media still waits on it (the queue hands the same job to every media of the
    /// same file and kind).
    private func release(_ job: ProxyJobID) {
        guard !tracked.values.contains(where: { $0.job == job }) else { return }
        let q = queue
        Task { await q.cancel(job) }
    }

    /// A proxy can only be used when its frames are the original's: no hidden (edit-list, zero-duration) samples, which a
    /// transcode never carries, so the counts would differ and the monitor would ignore the proxy (`RenderLoop.proxy(for:)`).
    public nonisolated static func proxyCanMatch(_ index: SampleIndex) -> Bool {
        !index.entries.isEmpty && !index.entries.contains { $0.duration <= .zero }
    }

    /// The ready proxies fill the cache cap on their own: generating more would only evict proxies in use.
    private var cacheFullOfProxiesInUse: Bool { cache.protectedBytes() >= cache.settings.cacheCapBytes }

    private func start(_ ref: MediaRef, _ file: FileState) {
        let id = ref.id, url = URL(fileURLWithPath: ref.path), video = ref.info?.video, duration = ref.info?.duration ?? .zero
        let prober = self.prober, provider = self.provider, queue = self.queue, mode = self.mode, machine = self.machine
        let resolver = self.resolver
        let task = Task(priority: .background) { [weak self] in
            defer { if self?.tracked[id]?.file == file { self?.tracked[id]?.taskLive = false } }
            guard let seek = try? await prober.probe(url), !Task.isCancelled else { return }
            var decision = AutoProxyRule.decide(seek: seek, video: video, mode: mode, machine: machine)
            var software = false
            if case .skip(.lightSource) = decision {
                // Long-GOP but light: still worth a proxy when this Mac decodes it in software (PLAYBACK-PERF "Hardware decode").
                guard let original = await resolver.openedDemuxer(for: id), !Task.isCancelled else { return }
                software = !HardwareDecode.isHardware(original.formatDescription)
                if software { decision = AutoProxyRule.decide(seek: seek, video: video, mode: mode, machine: machine, softwareDecode: true) }
            }
            guard case .needsProxy(let kind) = decision else { return }
            guard let original = await resolver.openedDemuxer(for: id), !Task.isCancelled else { return }
            guard Self.proxyCanMatch(original.index) else {
                Self.log.info("no proxy for \(url.lastPathComponent, privacy: .public): edit list (hidden samples)")
                return
            }
            await provider.warm(url)           // fingerprint of the current file, for the stat-only lookup
            if let hit = provider.cachedLookup(for: url, preferring: ProxyProvider.scrubPreference) {
                self?.became(ready: id, file: file, record: hit.record); return
            }
            guard let self, !Task.isCancelled else { return }
            if self.cacheFullOfProxiesInUse {
                Self.log.info("no proxy for \(url.lastPathComponent, privacy: .public): cache cap reached by proxies in use")
                if self.tracked[id]?.file == file { self.tracked[id]?.capped = true }
                return
            }
            let estimate = ProxySizeEstimate.bytes(kind: kind, width: video?.width ?? 0, height: video?.height ?? 0,
                                                   frameDuration: video?.nominalFrameDuration ?? Time(1, 30), duration: duration)
            let disk = await self.diskNow()
            guard !Task.isCancelled else { return }
            guard self.reserveDisk(id, file: file, estimate: estimate, disk: disk) else {
                Self.log.info("no proxy for \(url.lastPathComponent, privacy: .public): disk reserve (free \(disk.free ?? -1) bytes, \(self.reservedDiskBytes) reserved)")
                return
            }
            if software, self.tracked[id]?.file == file { self.tracked[id]?.software = true }
            let rank = AutoProxyRule.rank(self.ranks[id] ?? .max, softwareDecode: software, mediaCount: self.ranks.count)
            guard let job = try? await queue.enqueue(url, kind: kind, priority: .background, rank: rank) else {
                if self.tracked[id]?.file == file { self.tracked[id]?.reservedBytes = 0 }
                return
            }
            guard self.tracked[id]?.file == file, !Task.isCancelled else { self.release(job); return }
            self.tracked[id]?.job = job
            for await info in await queue.updates(for: job) {
                if Task.isCancelled { break }
                if info.isDone {
                    await provider.warm(url)
                    let hit = provider.cachedLookup(for: url, preferring: ProxyProvider.scrubPreference)
                    self.became(ready: id, file: file, record: hit?.record)
                }
            }
            // Failed or canceled: the reservation goes (a ready proxy no longer counts anyway).
            if self.tracked[id]?.file == file, self.tracked[id]?.ready == false { self.tracked[id]?.reservedBytes = 0 }
        }
        tracked[id]?.task = task
        tracked[id]?.taskLive = true
        ensureBusyPolling()
    }

    private func became(ready id: UUID, file: FileState, record: ProxyRecordID?) {
        guard tracked[id]?.file == file, tracked[id]?.ready == false else { return }
        tracked[id]?.ready = true; tracked[id]?.record = record
        updateProtected()
        notify([id])
        guard cacheFullOfProxiesInUse else { return }
        // Jobs still waiting would only push proxies in use out of the cache: stop them (`refresh()` tries again).
        let waiting = tracked.filter { !$0.value.ready && $0.value.job != nil }
        if !waiting.isEmpty { Self.log.info("cache cap reached by proxies in use: \(waiting.count) proxy jobs stopped") }
        for (mid, t) in waiting {
            stop(mid, t)
            var kept = Tracked(file: t.file); kept.capped = true
            tracked[mid] = kept
        }
    }

    /// Proxies the monitors use are never evicted.
    private func updateProtected() {
        cache.setProtected(Set(tracked.values.compactMap { $0.ready ? $0.record : nil }))
    }

    /// A proxy left the cache (evicted, deleted): its media is no longer ready and the engines and the resolver drop it.
    /// It is generated again only by a later sync (no regeneration loop against the cap).
    private func removed(_ r: ProxyRecord) {
        let rid = ProxyRecordID(r)
        let hit = tracked.filter { $0.value.ready && $0.value.record == rid }
        guard !hit.isEmpty else { return }
        for id in hit.keys { tracked[id] = nil }
        updateProtected()
        notify(Set(hit.keys))
    }

    /// The proxies of these media changed or went away: the resolver reopens them, the engines drop frames and decoders.
    private func notify(_ ids: Set<UUID>) {
        resolver.dropProxies(ids)
        for e in liveEngines() { e.proxiesChanged(ids) }
    }

    /// Another monitor that decodes the project's media (the Trim monitor's engines) follows proxy changes too.
    public func addEngine(_ e: any ProgramEngine) {
        guard !engines.contains(where: { $0.engine === e }) else { return }
        engines.append(WeakEngine(e))
    }

    private func liveEngines() -> [any ProgramEngine] {
        engines.removeAll { $0.engine == nil }
        return engines.compactMap(\.engine)
    }

    private static func fileState(_ path: String) -> FileState {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return FileState(path: path, size: (a?[.size] as? NSNumber)?.int64Value ?? 0, modified: a?[.modificationDate] as? Date)
    }
}
