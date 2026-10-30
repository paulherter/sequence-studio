import CoreMedia
import Foundation
import Synchronization
import Testing
import SQCore
import SQMedia
import SQPlayback
import SQProxy
@testable import SQEditorSession

// W9.9 AutoProxy wiring: monitors read proxies, export reads originals; background generation, cancel, invalidation.

private final class URLDemux: Demuxing, @unchecked Sendable {
    let url: URL
    let index: SampleIndex
    let formatDescription: CMFormatDescription
    /// Files named `EDIT*` carry an edit list: a hidden (zero-duration) sample, which a proxy never has.
    init(_ url: URL) {
        self.url = url
        let hidden = url.lastPathComponent.hasPrefix("EDIT")
        index = SampleIndex(entries: (0..<3).map { i in
            SampleIndex.Entry(pts: Time(Int64(i), 30), dts: Time(Int64(i), 30), duration: hidden && i == 0 ? .zero : Time(1, 30),
                              isSync: true, decodeOrdinal: i)
        })
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
                                       extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
    }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] { [] }
}

/// Blocks every transcode until `open()`; records starts and cancellations.
final class AutoProxyGateTranscoder: ProxyTranscoding {
    let started = Mutex<[URL]>([])
    let cancelled = Mutex(0)
    let isOpen = Mutex(false)
    func open() { isOpen.withLock { $0 = true } }
    func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        started.withLock { $0.append(source) }
        while !isOpen.withLock({ $0 }) {
            if Task.isCancelled { cancelled.withLock { $0 += 1 }; throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try Data("proxy".utf8).write(to: destination)
        return TranscodeOutput(dimensions: ProxyDimensions(width: 16, height: 16), sourceDuration: Time(1, 1))
    }
}

/// Blocks the probe until `open()`.
private final class GatedProber: SourceSeekProbing, @unchecked Sendable {
    let info: SourceSeekInfo
    let isOpen = Mutex(false)
    init(_ info: SourceSeekInfo) { self.info = info }
    func open() { isOpen.withLock { $0 = true } }
    func probe(_ url: URL) async throws -> SourceSeekInfo {
        while !isOpen.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        return info
    }
}

private struct FixedProber: SourceSeekProbing {
    var info: SourceSeekInfo
    func probe(_ url: URL) async throws -> SourceSeekInfo { info }
}

/// The busy signal (monitor playing / export running) the test can flip while the service runs.
final class BusyFlag: Sendable {
    private let state: Mutex<Bool>
    init(_ b: Bool) { state = Mutex(b) }
    var value: Bool { state.withLock { $0 } }
    func set(_ b: Bool) { state.withLock { $0 = b } }
}

/// Free disk bytes the test can change while the service runs.
final class FreeDisk: Sendable {
    let bytes: Mutex<Int64>
    init(_ b: Int64) { bytes = Mutex(b) }
    func set(_ b: Int64) { bytes.withLock { $0 = b } }
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-autoproxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func writeSource(_ u: URL, seed: UInt8) throws {
    var d = Data(count: 200_000)
    for i in 0..<d.count { d[i] = UInt8(truncatingIfNeeded: i &* 31) ^ seed }
    try d.write(to: u)
}

@MainActor private func eventually(_ what: String, _ ok: () -> Bool) async {
    // Generous ceiling: a loaded machine (parallel builds, load average > 100) can take seconds per step. The wait ends as
    // soon as the condition holds, so a healthy run is not slower.
    let deadline = ContinuousClock.now + SQTiming.budget(.seconds(120))
    while !ok(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(ok(), "\(what)")
}

@Suite(.serialized) @MainActor struct AutoProxyServiceTests {
    struct Rig {
        let dir: URL
        let source: URL
        let ref: MediaRef
        let resolver: ProjectMediaResolver
        let engine: StubProgramEngine
        let transcoder: AutoProxyGateTranscoder
        let service: AutoProxyService
        let defaultsName: String
        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: defaultsName)
        }
    }

    func rig(mode: ProxyMode = .always, codec: String = "avc1", file: String = "C0001.MP4",
             freeDisk: Int64 = 500 << 30, disk: FreeDisk? = nil, busy: BusyFlag? = nil,
             prober: (any SourceSeekProbing)? = nil) throws -> Rig {
        let dir = try tempDir()
        let source = dir.appendingPathComponent(file)
        try writeSource(source, seed: 1)
        let resolver = ProjectMediaResolver(demuxer: { u in URLDemux(u) })
        let ref = MediaRef(name: "C0001", path: source.path, fingerprint: MediaFingerprint(size: 200_000))
        resolver.update([ref])
        let name = "sq.test.autoproxy.\(UUID().uuidString)"
        let settings = ProxySettingsStore(defaults: UserDefaults(suiteName: name)!)
        settings.setMode(mode, project: nil)
        let engine = StubProgramEngine()
        let transcoder = AutoProxyGateTranscoder()
        let service = AutoProxyService(
            resolver: resolver, engines: [engine], cache: ProxyCache(directory: dir.appendingPathComponent("cache")),
            transcoder: transcoder, prober: prober ?? FixedProber(info: SourceSeekInfo(codecFourCC: codec, maxSyncDistance: 60)),
            settings: settings, machine: MachineProfile(memoryBytes: 32 << 30, cores: 12, isAppleSilicon: true),
            isBusy: { busy?.value ?? false }, busyPoll: .milliseconds(10), busyResume: .milliseconds(30),
            diskSpace: { _ in (disk?.bytes.withLock { $0 } ?? freeDisk, 1000 << 30) })
        return Rig(dir: dir, source: source, ref: ref, resolver: resolver, engine: engine, transcoder: transcoder,
                   service: service, defaultsName: name)
    }

    /// Export (and every other reader) goes through `demuxer(for:)`: always the original. Only the engines' proxy
    /// path sees the proxy file.
    @Test func monitorReadsTheProxyExportReadsTheOriginal() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        r.transcoder.open()
        await eventually("proxy ready") { r.engine.proxyChanges == [[r.ref.id]] }
        #expect(r.service.readyMedia == [r.ref.id])
        let id = r.ref.id, resolver = r.resolver
        let (export, monitor) = await Task.detached { (try? resolver.demuxer(for: id), try? resolver.proxyDemuxer(for: id)) }.value
        #expect((export as? URLDemux)?.url.path == r.source.path)
        let proxyURL = try #require((monitor as? URLDemux)?.url)
        #expect(proxyURL.path != r.source.path)
        #expect(proxyURL.path.hasPrefix(r.dir.appendingPathComponent("cache").path))
        #expect(r.engine.proxyUse == ProxyUse(scrubbing: true, playback: false))      // strong Mac: scrub only
    }

    /// Q-PERF2 rec 3: thermal "fair" / Low Power holds the queue: the job waits queued until released.
    @Test func heldServiceStartsNoJobUntilReleased() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.setHeld(true)
        let q = r.service.queue
        for _ in 0..<SQTiming.polls(500) where !(await q.isHeld) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await q.isHeld)
        r.service.sync([r.ref], projectID: nil)
        for _ in 0..<SQTiming.polls(2000) where await q.allJobs().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: SQTiming.budget(.milliseconds(50)))
        #expect(await q.allJobs().first?.state == .queued)
        r.service.setHeld(false)
        r.transcoder.open()
        await eventually("proxy ready") { r.engine.proxyChanges == [[r.ref.id]] }
    }

    /// Perf: no proxy job starts while a monitor plays or an export runs; it starts after the machine was idle again.
    @Test func busyMachineHoldsJobsUntilIdle() async throws {
        let busy = BusyFlag(true)
        let r = try rig(busy: busy)
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await eventually("held while busy") { r.service.isBusyHeld }
        let q = r.service.queue
        for _ in 0..<SQTiming.polls(2000) where await q.allJobs().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: SQTiming.budget(.milliseconds(80)))
        #expect(await q.allJobs().first?.state == .queued)
        #expect(r.transcoder.started.withLock { $0.isEmpty })
        busy.set(false)
        r.transcoder.open()
        await eventually("resumed after idle") { !r.service.isBusyHeld }
        await eventually("proxy ready") { r.engine.proxyChanges == [[r.ref.id]] }
    }

    /// A playback that starts while a decision task is still probing (no job yet) must still hold the queue.
    @Test func busyPollingContinuesWhileProbing() async throws {
        let busy = BusyFlag(false)
        let prober = GatedProber(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 60))
        let r = try rig(busy: busy, prober: prober)
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        try await Task.sleep(for: SQTiming.budget(.milliseconds(100)))     // several polls, nothing busy, no job yet
        #expect(r.service.isBusyPolling)
        busy.set(true)
        await eventually("held while probing") { r.service.isBusyHeld }
        prober.open()
    }

    /// Perf: media used in the active timeline is proxied before bin-only media, earliest position first.
    @Test func timelineMediaIsProxiedFirst() async throws {
        let busy = BusyFlag(true)
        let r = try rig(busy: busy)
        defer { r.cleanup() }
        var refs: [MediaRef] = []
        for (i, name) in ["B1", "B2", "T2", "T1"].enumerated() {      // bin order: two bin-only, then T2, T1
            let u = r.dir.appendingPathComponent(name + ".MP4")
            try writeSource(u, seed: UInt8(40 + i))
            refs.append(MediaRef(name: name, path: u.path, fingerprint: MediaFingerprint(size: 200_000)))
        }
        r.resolver.update(refs)
        func clip(_ ref: MediaRef, at s: Int64) -> Clip {
            Clip(name: ref.name, media: ref.id, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: Time(s, 1))
        }
        let tl = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip(refs[3], at: 0), clip(refs[2], at: 10)])])
        r.service.sync(refs, projectID: nil, activeTimeline: tl)
        await eventually("held") { r.service.isBusyHeld }
        let q = r.service.queue
        for _ in 0..<SQTiming.polls(3000) where await q.allJobs().count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await q.allJobs().count == 4)
        r.transcoder.open()
        busy.set(false)
        await eventually("all started") { r.transcoder.started.withLock { $0.count } == 4 }
        let names = r.transcoder.started.withLock { $0.map(\.lastPathComponent) }
        #expect(names == ["T1.MP4", "T2.MP4", "B1.MP4", "B2.MP4"])
    }

    /// Weak-Mac part 2: a full disk (below the 15 GB / 10 % reserve) starts no background proxy.
    @Test func fullDiskStartsNoProxy() async throws {
        let r = try rig(freeDisk: 10 << 30)
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await r.service.settled()
        #expect(await r.service.queue.allJobs().isEmpty)
        #expect(r.service.pendingMedia.isEmpty)
    }

    /// Queued and running proxies hold their estimate against the disk reserve: two 5.6 GB proxies with 8 GB above the
    /// 30 GB reserve start one job, not two.
    @Test func queuedJobsCountAgainstTheDiskReserve() async throws {
        let r = try rig(freeDisk: 38 << 30)
        defer { r.cleanup() }
        let video = VideoTrackInfo(width: 3840, height: 2160, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                   nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let info = MediaInfo(duration: Time(1000, 1), video: video)
        var refs: [MediaRef] = []
        for (i, name) in ["C0101", "C0102"].enumerated() {
            let u = r.dir.appendingPathComponent(name + ".MP4")
            try writeSource(u, seed: UInt8(20 + i))
            refs.append(MediaRef(name: name, path: u.path, fingerprint: MediaFingerprint(size: 200_000), info: info))
        }
        r.resolver.update(refs)
        r.service.sync(refs, projectID: nil)       // the gate keeps the accepted job running
        await eventually("one accepted, one refused") {
            r.service.diskRefusedMedia.count == 1 && r.service.pendingMedia.count == 1
        }
        let jobs = await r.service.queue.allJobs()
        #expect(jobs.count == 1)
        let reserved = r.service.reservedDiskBytes
        #expect(reserved > 5 << 30 && reserved < 6 << 30)
        r.transcoder.open()
        await eventually("reservation released when ready") { r.service.reservedDiskBytes == 0 }
    }

    /// A disk refusal is not final: after space is freed, `refresh()` tries again.
    @Test func diskRefusalIsRetriedOnRefresh() async throws {
        let disk = FreeDisk(10 << 30)
        let r = try rig(disk: disk)
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await r.service.settled()
        #expect(await r.service.queue.allJobs().isEmpty)
        #expect(r.service.diskRefusedMedia == [r.ref.id])
        disk.set(500 << 30)
        r.service.refresh()
        await eventually("transcode started after refresh") { r.transcoder.started.withLock { $0.count } == 1 }
        #expect(r.service.diskRefusedMedia.isEmpty)
    }

    @Test func removingTheMediaCancelsItsJob() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await eventually("transcode started") { r.transcoder.started.withLock { $0.count } == 1 }
        r.service.sync([], projectID: nil)
        await eventually("transcode canceled") { r.transcoder.cancelled.withLock { $0 } == 1 }
        #expect(r.engine.proxyChanges.isEmpty)
        #expect(r.service.pendingMedia.isEmpty)
        let jobs = await r.service.queue.allJobs()
        #expect(jobs.allSatisfy { $0.state == .cancelled })
    }

    @Test func modeOffCancelsAndTurnsProxyUseOff() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await eventually("transcode started") { r.transcoder.started.withLock { $0.count } == 1 }
        r.service.settings.setMode(.off, project: nil)
        r.service.refresh()
        #expect(r.engine.proxyUse == .off)
        await eventually("transcode canceled") { r.transcoder.cancelled.withLock { $0 } == 1 }
    }

    /// The per-project override beats the app setting.
    @Test func projectOverrideDisablesOneProject() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let p = UUID()
        r.service.settings.setMode(.off, project: p)
        r.service.sync([r.ref], projectID: p)
        #expect(r.engine.proxyUse == .off)
        #expect(r.service.mode == .off)
        await r.service.settled()
        #expect(r.transcoder.started.withLock { $0.isEmpty })
    }

    /// The source file changed in place (same path, new size/date): the old proxy is dropped at once (the lookup no longer
    /// finds it), and a new one is generated.
    @Test func changedSourceInvalidatesItsProxy() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        r.transcoder.open()
        await eventually("proxy ready") { r.engine.proxyChanges.count == 1 }
        var d = try Data(contentsOf: r.source); d.append(contentsOf: [1, 2, 3])
        try d.write(to: r.source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: r.source.path)
        r.service.sync([r.ref], projectID: nil)
        #expect(r.engine.proxyChanges.count == 2, "old proxy dropped immediately")
        let id = r.ref.id, resolver = r.resolver
        await eventually("new proxy ready") { r.engine.proxyChanges.count == 3 }
        #expect(r.transcoder.started.withLock { $0.count } == 2)
        let monitor = await Task.detached { try? resolver.proxyDemuxer(for: id) }.value
        #expect(monitor != nil)
    }

    /// Interlaced media with Deinterlace off gets no proxy; the switch is part of the decision, so turning it on makes
    /// the proxy and turning it off again drops it, without a reopen.
    @Test func theDeinterlaceSwitchDecidesAgain() async throws {
        let r = try rig()
        defer { r.cleanup() }
        func ref(off: Bool) -> MediaRef {
            var video = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
            video.fieldOrder = .topFirst; video.deinterlaceOff = off
            var m = r.ref; m.info = MediaInfo(duration: Time(10, 1), video: video)
            return m
        }
        r.transcoder.open()
        r.service.sync([ref(off: true)], projectID: nil)
        await r.service.settled()
        #expect(r.transcoder.started.withLock { $0.isEmpty })
        r.service.sync([ref(off: false)], projectID: nil)
        await eventually("proxy ready") { r.engine.proxyChanges.count == 1 }
        #expect(r.service.readyMedia == [r.ref.id])
        r.service.sync([ref(off: true)], projectID: nil)
        #expect(r.engine.proxyChanges.count == 2, "proxy dropped at once")
        await r.service.settled()
        #expect(r.service.readyMedia.isEmpty)
    }

    @Test func intraSourcesGetNoProxy() async throws {
        let r = try rig(codec: "apcn")
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await r.service.settled()
        #expect(r.transcoder.started.withLock { $0.isEmpty })
        #expect(r.engine.proxyChanges.isEmpty)
    }

    /// Two media items of the same file share one job (the queue dedupes by fingerprint and kind): removing one keeps it.
    @Test func removingOneOfTwoSharersKeepsTheJob() async throws {
        let r = try rig()
        defer { r.cleanup() }
        var twin = r.ref; twin.id = UUID()
        r.resolver.update([r.ref, twin])
        r.service.sync([r.ref, twin], projectID: nil)
        await eventually("both waiting on one job") { r.service.pendingMedia == [r.ref.id, twin.id] }
        await eventually("transcode started") { r.transcoder.started.withLock { $0.count } == 1 }
        r.service.sync([twin], projectID: nil)
        try await Task.sleep(for: SQTiming.budget(.milliseconds(60)))
        #expect(r.transcoder.cancelled.withLock { $0 } == 0)
        r.transcoder.open()
        await eventually("twin ready") { r.service.readyMedia == [twin.id] }
        #expect(r.transcoder.started.withLock { $0.count } == 1)
    }

    /// A proxy removed from the cache is reported: the media is no longer ready, the engines drop it, and the resolver
    /// does not hand out its old demuxer when a proxy of the same name comes back.
    @Test func removedProxyIsReportedAndItsDemuxerDropped() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        r.transcoder.open()
        await eventually("proxy ready") { r.engine.proxyChanges.count == 1 }
        let id = r.ref.id, resolver = r.resolver
        let first = try #require(await Task.detached { try? resolver.proxyDemuxer(for: id) }.value as? URLDemux)
        let fp = try SourceFingerprint.compute(for: r.source)
        r.service.cache.remove(fingerprint: fp, kind: .proxyHalf)
        await eventually("removal reported") { r.engine.proxyChanges.count == 2 && r.service.readyMedia.isEmpty }
        r.service.refresh()                                       // regenerated (same file name) on the next sync
        await eventually("proxy back") { r.engine.proxyChanges.count == 3 }
        let second = try #require(await Task.detached { try? resolver.proxyDemuxer(for: id) }.value as? URLDemux)
        #expect(second.url == first.url)
        #expect(second !== first, "a regenerated proxy is opened again")
    }

    /// Proxies in use are protected from the cache cap; once they alone fill it, no further proxies are generated
    /// (they could only evict each other in a loop).
    @Test func fullCacheOfProxiesInUseStopsGenerating() async throws {
        let r = try rig()
        defer { r.cleanup() }
        try r.service.cache.updateSettings { $0.cacheCapBytes = 1 }
        r.service.sync([r.ref], projectID: nil)
        r.transcoder.open()
        await eventually("proxy ready") { r.service.readyMedia == [r.ref.id] }
        let other = r.dir.appendingPathComponent("C0002.MP4")
        try writeSource(other, seed: 9)
        let ref2 = MediaRef(name: "C0002", path: other.path, fingerprint: MediaFingerprint(size: 200_000))
        r.resolver.update([r.ref, ref2])
        r.service.sync([r.ref, ref2], projectID: nil)
        await r.service.settled()
        #expect(r.transcoder.started.withLock { $0.count } == 1)
        #expect(r.service.readyMedia == [r.ref.id], "the proxy in use survives the cap")
        #expect(r.service.pendingMedia.isEmpty)
        let fp = try SourceFingerprint.compute(for: r.source)
        #expect(r.service.cache.lookup(fingerprint: fp, kind: .proxyHalf) != nil)
    }

    /// Settings > Media > Cache Size: lowering the cap evicts the least recently used proxy that no monitor uses, at once.
    @Test func loweringTheCacheCapEvictsLeastRecentlyUsed() async throws {
        let r = try rig(mode: .off)
        defer { r.cleanup() }
        let cache = r.service.cache
        func stage(_ name: String, seed: UInt8, lastAccess: Date) throws -> ProxyRecord {
            let src = r.dir.appendingPathComponent(name)
            try writeSource(src, seed: seed)
            let fp = try SourceFingerprint.compute(for: src)
            var rec = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: ProxyCache.fileName(for: fp, kind: .proxyHalf),
                                  dimensions: ProxyDimensions(width: 16, height: 16), createdAt: lastAccess, sourceDuration: Time(1, 1))
            rec.lastAccess = lastAccess
            let partial = cache.partialURL(fingerprint: fp, kind: .proxyHalf)
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1000).write(to: partial)
            try cache.commit(partial: partial, record: rec)
            return rec
        }
        let old = try stage("old.mp4", seed: 2, lastAccess: Date(timeIntervalSince1970: 1000))
        let recent = try stage("recent.mp4", seed: 3, lastAccess: Date(timeIntervalSince1970: 2000))
        #expect(r.service.applyCacheCap(bytes: 1500).map(\.fileName) == [old.fileName])
        #expect(cache.settings.cacheCapBytes == 1500)
        #expect(cache.allRecords().map(\.fileName) == [recent.fileName])
        #expect(r.service.applyCacheCap(bytes: 1500).isEmpty, "already within the cap")
        #expect(r.service.clearCache() == 1000)
        #expect(cache.allRecords().isEmpty)
    }

    /// A clip with an edit list has hidden samples a proxy never carries (frame counts differ, the monitor would never use
    /// it): no transcode is queued.
    @Test func editListSourcesAreNotTranscoded() async throws {
        let r = try rig(file: "EDIT0001.MP4")
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        await r.service.settled()
        #expect(r.transcoder.started.withLock { $0.isEmpty })
        #expect(r.service.pendingMedia.isEmpty)
        let hidden = URLDemux(URL(fileURLWithPath: "/EDIT.mov")).index, plain = URLDemux(URL(fileURLWithPath: "/C.mov")).index
        #expect(!AutoProxyService.proxyCanMatch(hidden))
        #expect(AutoProxyService.proxyCanMatch(plain))
        #expect(!AutoProxyService.proxyCanMatch(SampleIndex(entries: [])))
    }

    /// Changing the mode in UserDefaults (app-wide, per project, playback) applies without an explicit refresh.
    @Test func settingsChangesApplyByThemselves() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.service.sync([r.ref], projectID: nil)
        #expect(r.engine.proxyUse == ProxyUse(scrubbing: true, playback: false))
        r.service.settings.playback = .on
        await eventually("playback setting applied") { r.engine.proxyUse == ProxyUse(scrubbing: true, playback: true) }
        r.service.settings.setMode(.off, project: nil)
        await eventually("mode off applied") { r.engine.proxyUse == .off }
    }

    /// Switching to a project without media still re-reads its mode and stops the old project's jobs.
    @Test func projectSwitchResyncs() async throws {
        let r = try rig()
        defer { r.cleanup() }
        var p = EditorSession.makeUntitled(); p.media = [r.ref]
        let session = EditorSession(project: p, engine: r.engine, media: r.resolver,
                                    autosaveStore: AutosaveStore(base: r.dir.appendingPathComponent("Autosave")))
        session.autoProxy = r.service
        await eventually("transcode started") { r.transcoder.started.withLock { $0.count } == 1 }
        let empty = EditorSession.makeUntitled()
        r.service.settings.setMode(.off, project: empty.id)
        session.newProject(empty)
        #expect(r.service.projectID == empty.id)
        #expect(r.engine.proxyUse == .off)
        await eventually("old job canceled") { r.transcoder.cancelled.withLock { $0 } == 1 }
        session.close()
    }

    @Test func sessionSyncsItsMedia() async throws {
        let r = try rig()
        defer { r.cleanup() }
        var p = EditorSession.makeUntitled(); p.media = [r.ref]
        let session = EditorSession(project: p, engine: r.engine, media: r.resolver,
                                    autosaveStore: AutosaveStore(base: r.dir.appendingPathComponent("Autosave")))
        #expect(r.transcoder.started.withLock { $0.isEmpty })
        session.autoProxy = r.service
        await eventually("job queued for the project's media") { r.transcoder.started.withLock { $0.count } == 1 }
        session.close()
    }
}
