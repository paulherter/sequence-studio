import Foundation
import SQCore
import SQMedia
import SQProxy

/// What the platform probe learns about one source file (demuxer index, track facts, decoder).
public struct ProxySourceProbe: Sendable {
    public var seek: SourceSeekInfo
    public var video: VideoTrackInfo?
    /// The GPU decodes the source (a long-GOP but light source still gets a proxy when it does not).
    public var hardwareDecode: Bool
    /// The proxy's frames can be the original's (`ProxyIntake.proxyCanMatch` on the source index).
    public var canMatch: Bool
    public init(seek: SourceSeekInfo, video: VideoTrackInfo?, hardwareDecode: Bool, canMatch: Bool) {
        self.seek = seek; self.video = video; self.hardwareDecode = hardwareDecode; self.canMatch = canMatch
    }
}

/// Proxies at import and open where `AutoProxyService` (Apple-only: AVFoundation prober, ProjectMediaResolver) is not
/// built: the session hands over the project's media after every change (`SessionProxyServing.sync`), as on the Mac.
/// Each new or changed video file (path, size, modification date) is probed once off the main actor, warmed in the
/// provider (so lookups find its ready proxy) and, when `AutoProxyRule` asks for one, queued at background priority in
/// timeline-first order (`ProxyOrdering`). Removed files cancel their queued job. Mode `sq.proxy.mode` (per project,
/// else the app setting) as the Mac reads it; Off queues nothing.
@MainActor
public final class ProxyIntake {
    public typealias Probe = @Sendable (URL) async -> ProxySourceProbe?

    /// Replaced together by `retarget` (Preferences > Cache Folder).
    public private(set) var provider: ProxyProvider
    public private(set) var queue: ProxyQueue
    private let settings: ProxySettingsStore
    private let probe: Probe
    private let machine: @Sendable (_ hardwareDecode: Bool) -> MachineProfile
    /// Off: files are probed and warmed but nothing is queued (headless checks time their own generation).
    public var automatic: Bool
    /// Called after a file was warmed or its proxy job ended (the monitors redraw).
    public var onChange: (@MainActor () -> Void)?

    public private(set) var projectID: UUID?
    /// The Auto rule's answer per path.
    public private(set) var decisions: [String: ProxyDecision] = [:]

    private struct FileKey: Hashable { var path: String; var size: Int64; var modified: Date? }
    private var seen: [String: FileKey] = [:]
    private var jobs: [String: ProxyJobID] = [:]
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// The last `sync`, looked at again after `retarget`.
    private var lastMedia: [MediaRef] = []
    private var lastTimeline: Timeline?

    public init(provider: ProxyProvider, queue: ProxyQueue, settings: ProxySettingsStore = ProxySettingsStore(),
                automatic: Bool = true, machine: @escaping @Sendable (Bool) -> MachineProfile, probe: @escaping Probe) {
        self.provider = provider; self.queue = queue; self.settings = settings
        self.automatic = automatic; self.machine = machine; self.probe = probe
    }

    /// A proxy can only be used when its frames are the original's: no hidden (edit-list, zero-duration) samples, which a
    /// transcode never carries.
    public nonisolated static func proxyCanMatch(_ index: SampleIndex) -> Bool {
        !index.entries.isEmpty && !index.entries.contains { $0.duration <= .zero }
    }

    /// Paths with a probe or a proxy job still running.
    public var pending: Set<String> { Set(tasks.keys) }

    /// Waits until every probe and queued job started so far has ended (tests, headless checks).
    public func settle() async {
        while let t = tasks.values.first { await t.task.value }
    }

    public func sync(_ media: [MediaRef], projectID: UUID?, activeTimeline: Timeline?) {
        self.projectID = projectID
        lastMedia = media; lastTimeline = activeTimeline
        let mode = settings.mode(project: projectID)
        let wanted = media.filter { $0.info?.isStill != true && ($0.info == nil || $0.info?.video != nil) }
        let paths = Set(wanted.map(\.path))
        for (path, job) in jobs where !paths.contains(path) {
            jobs[path] = nil
            let q = queue
            Task { await q.cancel(job) }
        }
        for path in seen.keys where !paths.contains(path) { seen[path] = nil; tasks[path]?.task.cancel(); tasks[path] = nil }
        let firstUse = ProxyOrdering.firstUse(in: activeTimeline)
        let byID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in ProxyOrdering.sorted(wanted.map(\.id), firstUse: firstUse) {
            guard let ref = byID[id] else { continue }
            let key = Self.key(ref.path)
            guard seen[ref.path] != key else { continue }
            seen[ref.path] = key
            tasks[ref.path]?.task.cancel()
            if let old = jobs.removeValue(forKey: ref.path) { let q = queue; Task { await q.cancel(old) } }
            start(ref.path, mode: mode)
        }
    }

    private func start(_ path: String, mode: ProxyMode) {
        let url = URL(fileURLWithPath: path)
        let probe = self.probe, machine = self.machine, provider = self.provider, queue = self.queue
        let token = UUID()
        let task = Task { [weak self] in
            defer { if let self { if self.tasks[path]?.token == token { self.tasks[path] = nil }; self.onChange?() } }
            guard let p = await probe(url), !Task.isCancelled else { return }
            let decision = AutoProxyRule.decide(seek: p.seek, video: p.video, mode: mode, machine: machine(p.hardwareDecode),
                                                softwareDecode: !p.hardwareDecode)
            self?.decisions[path] = decision
            await provider.warm(url)
            guard !Task.isCancelled, self?.automatic == true, p.canMatch, case .needsProxy(let kind) = decision else { return }
            if provider.cachedLookup(for: url, preferring: [kind]) != nil { return }
            guard let id = try? await queue.enqueue(url, kind: kind, priority: .background) else { return }
            guard !Task.isCancelled else { await queue.cancel(id); return }      // retargeted while it was queued
            self?.jobs[path] = id
            for await info in await queue.updates(for: id) where info.state.isTerminal { break }
            if self?.jobs[path] == id { self?.jobs[path] = nil }
            await provider.warm(url)
        }
        tasks[path] = (token, task)
    }

    /// Preferences > Cache Folder moved: proxies come from `provider` and are made by `queue` from now on. Every probe and
    /// job of the old pair is canceled (the old queue is left held, its files stay), and the media of the last sync is
    /// probed, warmed and queued again against the new folder.
    public func retarget(provider: ProxyProvider, queue: ProxyQueue) {
        guard provider !== self.provider else { return }
        for t in tasks.values { t.task.cancel() }
        tasks = [:]; jobs = [:]; seen = [:]
        let old = self.queue
        Task { await old.setHeld(true); await old.cancelAll() }
        self.provider = provider; self.queue = queue
        sync(lastMedia, projectID: projectID, activeTimeline: lastTimeline)
        onChange?()
    }

    private static func key(_ path: String) -> FileKey {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return FileKey(path: path, size: (a?[.size] as? NSNumber)?.int64Value ?? -1, modified: a?[.modificationDate] as? Date)
    }
}

extension ProxyIntake: SessionProxyServing {
    /// The engines look proxies up themselves (the Windows Program engine through its proxy service).
    public func addEngine(_ e: any ProgramEngine) {}
}
