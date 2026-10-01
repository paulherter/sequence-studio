import Foundation
import SQCore
import Testing
@testable import SQProxy

struct FakeProber: SourceSeekProbing {
    var infos: [String: SourceSeekInfo]
    func probe(_ url: URL) async throws -> SourceSeekInfo {
        guard let i = infos[url.lastPathComponent] else { throw ProxyTranscodeError.noVideoTrack }
        return i
    }
}

@Suite struct PolicyTests {
    let policy = ProxyPolicy()

    @Test func longGOPNeedsHalfProxy() {
        #expect(policy.decide(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 15)) == .needsProxy(.proxyHalf))
        #expect(policy.decide(SourceSeekInfo(codecFourCC: "hvc1", maxSyncDistance: 9)).needsProxy)
    }
    @Test func shortGOPAtThresholdIsSkipped() {
        #expect(policy.decide(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 8)) == .skip(.shortGOP(maxDistance: 8)))
        #expect(policy.decide(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 1)) == .skip(.shortGOP(maxDistance: 1)))
    }
    @Test func intraCodecsNeverEvenWithHugeDistance() {
        for c in ["apcn", "apco", "ap4h", "AVdh", "mjpa"] {
            #expect(policy.decide(SourceSeekInfo(codecFourCC: c, maxSyncDistance: 500)) == .skip(.intraOnlyCodec))
        }
    }
    @Test func unknownGOPIsSkipped() {
        #expect(policy.decide(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: nil)) == .skip(.unknown))
    }
    @Test func customThreshold() {
        #expect(ProxyPolicy(maxSyncDistance: 30).decide(SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 15)).needsProxy == false)
    }

    @Test func autoGeneratorEnqueuesOnlyLongGOPAtBackgroundPriority() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let long = dir.appendingPathComponent("long.mp4"), intra = dir.appendingPathComponent("intra.mov")
        let broken = dir.appendingPathComponent("broken.mp4")
        try writeFile(long, bytes: 500, seed: 1); try writeFile(intra, bytes: 500, seed: 2); try writeFile(broken, bytes: 500, seed: 3)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let t = FakeTranscoder()
        let queue = ProxyQueue(cache: cache, transcoder: t)
        let prober = FakeProber(infos: [
            "long.mp4": SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 30),
            "intra.mov": SourceSeekInfo(codecFourCC: "apcn", maxSyncDistance: 1),
        ])
        let gen = ProxyAutoGenerator(queue: queue, prober: prober)
        #expect(await gen.sourceImported(long) == .needsProxy(.proxyHalf))
        #expect(await gen.sourceImported(intra) == .skip(.intraOnlyCodec))
        #expect(await gen.sourceImported(broken) == .skip(.unknown))
        let jobs = await queue.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .proxyHalf && jobs[0].priority == .background && jobs[0].source == long)
        t.release("long.mp4")
    }
}

@Suite struct ProxyUseContextTests {
    @Test func scrubbingOnlyByDefault() {
        let s = ProxySettings()
        #expect(ProxyProvider.usesProxy(context: .scrubbing, settings: s))
        #expect(!ProxyProvider.usesProxy(context: .playback, settings: s))
        #expect(!ProxyProvider.usesProxy(context: .paused, settings: s))
    }
    @Test func toggleAddsPlaybackButPausedStaysOriginal() {
        let s = ProxySettings(useProxiesForPlayback: true)
        #expect(ProxyProvider.usesProxy(context: .scrubbing, settings: s))
        #expect(ProxyProvider.usesProxy(context: .playback, settings: s))
        #expect(!ProxyProvider.usesProxy(context: .paused, settings: s))
    }
    @Test func providerFileHonorsContext() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let provider = ProxyProvider(cache: cache)
        let fp = try SourceFingerprint.compute(for: src)
        let r = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: ProxyCache.fileName(for: fp, kind: .proxyHalf),
                            dimensions: ProxyDimensions(width: 960, height: 540), createdAt: Date(), sourceDuration: Time(1, 1))
        let p = cache.partialURL(fingerprint: fp, kind: .proxyHalf)
        try Data("x".utf8).write(to: p); try cache.commit(partial: p, record: r)
        await provider.warm(src)
        let off = ProxySettings(), on = ProxySettings(useProxiesForPlayback: true)
        #expect(provider.file(for: src, context: .scrubbing, settings: off)?.kind == .proxyHalf)
        #expect(provider.file(for: src, context: .scrubbing, settings: off)?.colorInterpretation == .fromSource)
        #expect(provider.file(for: src, context: .playback, settings: off) == nil)
        #expect(provider.file(for: src, context: .playback, settings: on) != nil)
        #expect(provider.file(for: src, context: .paused, settings: on) == nil)
    }
}

@Suite struct CacheCapTests {
    func rec(_ n: Int, _ kind: ProxyKind = .proxyHalf) -> ProxyRecord {
        let fp = SourceFingerprint(size: Int64(n), modifiedMillis: 1, headHash: "aa\(n)", tailHash: "bb\(n)")
        return ProxyRecord(fingerprint: fp, kind: kind, fileName: ProxyCache.fileName(for: fp, kind: kind),
                           dimensions: ProxyDimensions(width: 2, height: 2), createdAt: Date(timeIntervalSince1970: Double(n)),
                           sourceDuration: Time(1, 1))
    }
    func add(_ c: ProxyCache, _ r: ProxyRecord, bytes: Int) throws {
        let p = c.partialURL(fingerprint: r.fingerprint, kind: r.kind)
        try Data(count: bytes).write(to: p); try c.commit(partial: p, record: r)
    }

    @Test func defaultCapIs50GB() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProxyCache(directory: dir).settings.cacheCapBytes == 50_000_000_000)
    }
    @Test func settingsPersist() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = ProxyCache(directory: dir)
        try c.updateSettings { $0.cacheCapBytes = 123; $0.useProxiesForPlayback = true }
        let c2 = ProxyCache(directory: dir)
        #expect(c2.settings == ProxySettings(cacheCapBytes: 123, useProxiesForPlayback: true))
    }
    @Test func lookupRefreshesLRUSoOlderUnusedGoesFirst() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = ProxyCache(directory: dir)
        let a = rec(1), b = rec(2), d = rec(3)
        for r in [a, b, d] { try add(c, r, bytes: 100) }
        // a is oldest by creation but was just used
        #expect(c.lookup(fingerprint: a.fingerprint, kind: .proxyHalf, now: Date(timeIntervalSince1970: 100)) != nil)
        try c.updateSettings { $0.cacheCapBytes = 200 }
        let removed = c.enforceCap()
        #expect(removed.map(\.fileName) == [b.fileName])
        #expect(c.totalSize() == 200)
    }
    @Test func evictsUntilUnderCapAndPersistsLastAccess() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = ProxyCache(directory: dir)
        for i in 1...4 { try add(c, rec(i), bytes: 100) }
        try c.updateSettings { $0.cacheCapBytes = 150 }
        let removed = c.enforceCap()
        #expect(removed.count == 3 && c.totalSize() == 100)
        #expect(c.lookup(fingerprint: rec(4).fingerprint, kind: .proxyHalf) != nil)
        c.flushIndex()
        #expect(ProxyCache(directory: dir).allRecords().count == 1)
    }
    @Test func protectedRecordSurvivesEvenAboveCap() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = ProxyCache(directory: dir)
        let only = rec(1)
        try add(c, only, bytes: 100)
        try c.updateSettings { $0.cacheCapBytes = 10 }
        #expect(c.enforceCap(protecting: [ProxyRecordID(only)]).isEmpty)
        #expect(c.lookup(fingerprint: only.fingerprint, kind: .proxyHalf) != nil)
        // unprotected it would go
        #expect(c.enforceCap().count == 1)
    }
    @Test func queueEnforcesCapAfterJobAndAtStart() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        try writeFile(a, bytes: 1000, seed: 1); try writeFile(b, bytes: 1000, seed: 2)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        try cache.updateSettings { $0.cacheCapBytes = 7 } // fake proxy is 5 bytes: only one fits
        let t = FakeTranscoder()
        let q = ProxyQueue(cache: cache, transcoder: t)
        let j1 = try await q.enqueue(a, kind: .proxyHalf)
        t.release("a.mov")
        for _ in 0..<400 { if await q.info(j1)?.isDone == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        let j2 = try await q.enqueue(b, kind: .proxyHalf)
        t.release("b.mov")
        for _ in 0..<400 { if await q.info(j2)?.isDone == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.allRecords().count == 1)
        #expect(cache.lookup(fingerprint: try SourceFingerprint.compute(for: b), kind: .proxyHalf) != nil)
        // launch: lowering the cap to 0 then start() evicts
        try cache.updateSettings { $0.cacheCapBytes = 0 }
        await q.start()
        #expect(cache.allRecords().isEmpty)
    }
    @Test func higherPriorityStartsFirst() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (i, n) in ["run.mov", "bg.mov", "user.mov"].enumerated() {
            let u = dir.appendingPathComponent(n); try writeFile(u, bytes: 500, seed: UInt8(i + 1)); urls.append(u)
        }
        let t = FakeTranscoder()
        let q = ProxyQueue(cache: ProxyCache(directory: dir.appendingPathComponent("c")), transcoder: t)
        _ = try await q.enqueue(urls[0], kind: .proxyHalf)
        _ = try await q.enqueue(urls[1], kind: .proxyHalf, priority: .background)
        _ = try await q.enqueue(urls[2], kind: .proxyHalf, priority: .userInitiated)
        t.release("run.mov")
        for _ in 0..<400 { if t.started.count >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(t.started == ["run.mov", "user.mov"])
        t.release("user.mov"); t.release("bg.mov")
    }
}
