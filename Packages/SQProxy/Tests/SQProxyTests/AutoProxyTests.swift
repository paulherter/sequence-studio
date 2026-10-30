import Foundation
import SQCore
import Testing
@testable import SQProxy

// W9.9 AutoProxy: which sources get a background proxy (mode x source x machine) and where the setting lives.

private let longGOP = SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 60)
private let shortGOP = SourceSeekInfo(codecFourCC: "avc1", maxSyncDistance: 1)
private let prores = SourceSeekInfo(codecFourCC: "apcn", maxSyncDistance: 1)
private let fps = Time(1001, 30000)

private func video(_ w: Int, _ h: Int, bits: Int = 8, chroma: String = "4:2:0") -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: bits, chroma: chroma, nominalFrameDuration: fps, isVariableFrameRate: false)
}

private let strong = MachineProfile(memoryBytes: 32 << 30, cores: 12, isAppleSilicon: true)
private let weak = MachineProfile(memoryBytes: 8 << 30, cores: 8, isAppleSilicon: true)

@Suite struct AutoProxyRuleTests {
    /// Deinterlace off: the fields are wanted, a proxy has none and playback never reads it, so none is made.
    @Test func interlacedWithDeinterlaceOffGetsNoProxy() {
        var v = video(3840, 2160, bits: 10, chroma: "4:2:2")
        v.fieldOrder = .topFirst
        #expect(AutoProxyRule.decide(seek: longGOP, video: v, mode: .always, machine: strong).needsProxy)
        v.deinterlaceOff = true
        #expect(AutoProxyRule.decide(seek: longGOP, video: v, mode: .always, machine: strong) == .skip(.keepsFields))
        #expect(AutoProxyRule.decide(seek: longGOP, video: v, mode: .auto, machine: strong) == .skip(.keepsFields))
        #expect(AutoProxyRule.decide(seek: longGOP, video: v, mode: .off, machine: strong) == .skip(.disabled))
        v.fieldOrder = nil      // the switch means nothing on progressive media
        #expect(AutoProxyRule.decide(seek: longGOP, video: v, mode: .always, machine: strong).needsProxy)
    }

    /// The Sony case that missed the 50 ms scrub target: 4K long-GOP 10-bit 4:2:2.
    @Test func sony4K10Bit422GetsAHalfProxyOnEveryMac() {
        let sony = video(3840, 2160, bits: 10, chroma: "4:2:2")
        #expect(AutoProxyRule.decide(seek: longGOP, video: sony, mode: .auto, machine: strong) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: sony, mode: .auto, machine: weak) == .needsProxy(.proxyHalf))
    }

    @Test func light8Bit420SourcesOnlyOnAWeakMac() {
        let uhd8 = video(3840, 2160)
        #expect(AutoProxyRule.decide(seek: longGOP, video: uhd8, mode: .auto, machine: strong) == .skip(.lightSource))
        #expect(AutoProxyRule.decide(seek: longGOP, video: uhd8, mode: .auto, machine: weak) == .needsProxy(.proxyHalf))
        let hd = video(1920, 1080)
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .auto, machine: weak) == .skip(.lightSource))
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .auto, machine: strong) == .skip(.lightSource))
    }

    /// No hardware decoder for the source on this Mac (e.g. H.264 / HEVC on an Intel Mac without that engine): a 4K
    /// software H.264 frame costs ~28 ms on one core (M1 Max, decode-hw bench), so from 1080p on a long GOP gets a proxy
    /// on every Mac; below 1080p and short GOPs stay as before.
    @Test func softwareDecodedLongGOPFrom1080pGetsAProxy() {
        let hd = video(1920, 1080), uhd8 = video(3840, 2160)
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .auto, machine: strong, softwareDecode: true) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: uhd8, mode: .auto, machine: strong, softwareDecode: true) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: video(1280, 720), mode: .auto, machine: strong, softwareDecode: true) == .skip(.lightSource))
        #expect(!AutoProxyRule.decide(seek: shortGOP, video: hd, mode: .auto, machine: strong, softwareDecode: true).needsProxy)
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .off, machine: strong, softwareDecode: true) == .skip(.disabled))
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .auto, machine: strong, softwareDecode: false) == .skip(.lightSource))
    }

    /// Software-decoded media go to the front of the proxy queue (they are the slowest to scrub), in their timeline order.
    @Test func softwareDecodedMediaRankFirst() {
        #expect(AutoProxyRule.rank(3, softwareDecode: true, mediaCount: 10) < AutoProxyRule.rank(0, softwareDecode: false, mediaCount: 10))
        #expect(AutoProxyRule.rank(1, softwareDecode: true, mediaCount: 10) < AutoProxyRule.rank(3, softwareDecode: true, mediaCount: 10))
        #expect(AutoProxyRule.rank(4, softwareDecode: false, mediaCount: 10) == 4)
        #expect(AutoProxyRule.rank(.max, softwareDecode: true, mediaCount: 10) == .max)   // unranked stays last
    }

    @Test func eightKGetsAQuarterProxy() {
        #expect(AutoProxyRule.decide(seek: longGOP, video: video(7680, 4320), mode: .auto, machine: strong) == .needsProxy(.proxyQuarter))
    }

    @Test func intraAndShortGOPNeverNeedOne() {
        let big = video(3840, 2160, bits: 10, chroma: "4:2:2")
        for mode in ProxyMode.allCases {
            #expect(!AutoProxyRule.decide(seek: prores, video: big, mode: mode, machine: weak).needsProxy)
            #expect(!AutoProxyRule.decide(seek: shortGOP, video: big, mode: mode, machine: weak).needsProxy)
        }
    }

    @Test func alwaysProxiesEveryLongGOPSourceAndOffNone() {
        let hd = video(1920, 1080)
        #expect(AutoProxyRule.decide(seek: longGOP, video: hd, mode: .always, machine: strong) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: nil, mode: .always, machine: strong) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: video(3840, 2160, bits: 10), mode: .off, machine: weak) == .skip(.disabled))
    }

    /// Without probed track info Auto stays conservative (only the GOP is known).
    @Test func unknownTrackInfoIsSkippedInAuto() {
        #expect(AutoProxyRule.decide(seek: longGOP, video: nil, mode: .auto, machine: weak) == .skip(.unknown))
    }

    @Test func machineWeakness() {
        #expect(!strong.isWeak)
        #expect(weak.isWeak)
        #expect(MachineProfile(memoryBytes: 64 << 30, cores: 16, isAppleSilicon: false).isWeak)
        #expect(MachineProfile(memoryBytes: 16 << 30, cores: 4, isAppleSilicon: true).isWeak)
        let c = MachineProfile.current
        #expect(c.cores > 0 && c.memoryBytes > 0)
    }

    /// Weak-Mac part 2: on 8 GB a 1440p 10-bit or 4:2:2 long-GOP source is proxied too (its GOPs do not fit the 1/6 frame
    /// cache at Full); a 16 GB weak Mac and 8-bit 1440p stay on the original.
    @Test func lowMemoryMacsAlsoProxyRichQHD() {
        let qhd10 = video(2560, 1440, bits: 10, chroma: "4:2:2")
        let mid = MachineProfile(memoryBytes: 16 << 30, cores: 4, isAppleSilicon: true)
        #expect(weak.isLowMemory && !mid.isLowMemory)
        #expect(AutoProxyRule.decide(seek: longGOP, video: qhd10, mode: .auto, machine: weak) == .needsProxy(.proxyHalf))
        #expect(AutoProxyRule.decide(seek: longGOP, video: qhd10, mode: .auto, machine: mid) == .skip(.lightSource))
        #expect(AutoProxyRule.decide(seek: longGOP, video: video(2560, 1440), mode: .auto, machine: weak) == .skip(.lightSource))
        #expect(AutoProxyRule.decide(seek: longGOP, video: video(1920, 1080, bits: 10, chroma: "4:2:2"), mode: .auto, machine: weak) == .skip(.lightSource))
    }

    /// `SQ_RAM_GB=8` makes this Mac an 8 GB one for the rule as well (it was the real RAM only).
    @Test func simulatedSmallMacIsWeak() {
        let m = MachineProfile.current(environment: ["SQ_RAM_GB": "8"], physicalMemory: 32 << 30, cores: 10, isAppleSilicon: true)
        #expect(m.memoryBytes == 8 << 30 && m.isWeak && m.isLowMemory)
        let real = MachineProfile.current(environment: [:], physicalMemory: 32 << 30, cores: 10, isAppleSilicon: true)
        #expect(!real.isWeak)
    }

    /// A background proxy never eats the disk: the volume keeps max(15 GB, 10 % up to 30 GB) free after the estimated proxy.
    @Test func diskReserveBlocksAutoProxies() {
        let g: Int64 = 1 << 30
        #expect(ProxyDiskGuard.allows(estimatedBytes: 5 * g, freeBytes: 100 * g, volumeBytes: 256 * g))
        #expect(!ProxyDiskGuard.allows(estimatedBytes: 5 * g, freeBytes: 30 * g, volumeBytes: 256 * g))   // 25.6 GB reserve
        #expect(!ProxyDiskGuard.allows(estimatedBytes: 1 * g, freeBytes: 15 * g, volumeBytes: 128 * g))   // 15 GB floor
        #expect(ProxyDiskGuard.allows(estimatedBytes: 1 * g, freeBytes: 17 * g, volumeBytes: 128 * g))
        #expect(ProxyDiskGuard.allows(estimatedBytes: 1 * g, freeBytes: 40 * g, volumeBytes: 2048 * g))  // reserve capped at 30 GB
        #expect(ProxyDiskGuard.allows(estimatedBytes: 1 * g, freeBytes: nil, volumeBytes: nil))         // unknown: allowed
    }

    /// ProRes 422 Proxy at 1080p30 is about 45 Mbit/s; the estimate scales with pixels and frame rate.
    @Test func proxySizeEstimate() {
        let hour = Time(3600, 1)
        let uhd30 = ProxySizeEstimate.bytes(kind: .proxyHalf, width: 3840, height: 2160, frameDuration: Time(1, 30), duration: hour)
        let expected: Double = 45e6 / 8 * 3600
        let err: Double = abs(Double(uhd30) - expected) / expected
        #expect(err < 0.01)
        let uhd60 = ProxySizeEstimate.bytes(kind: .proxyHalf, width: 3840, height: 2160, frameDuration: Time(1, 60), duration: hour)
        let ratio60: Double = Double(uhd60) / Double(uhd30)
        #expect(abs(ratio60 - 2) < 0.01)
        let q = ProxySizeEstimate.bytes(kind: .proxyQuarter, width: 7680, height: 4320, frameDuration: Time(1, 30), duration: hour)
        let ratioQ: Double = Double(q) / Double(uhd30)
        #expect(abs(ratioQ - 1) < 0.01)
    }

    @Test func playbackProxiesFollowTheMachineInAuto() {
        #expect(AutoProxyRule.usesProxiesForPlayback(.auto, machine: weak))
        #expect(!AutoProxyRule.usesProxiesForPlayback(.auto, machine: strong))
        #expect(AutoProxyRule.usesProxiesForPlayback(.on, machine: strong))
        #expect(!AutoProxyRule.usesProxiesForPlayback(.off, machine: weak))
    }
}

@Suite struct ProxySettingsStoreTests {
    private func store() -> (ProxySettingsStore, UserDefaults, String) {
        let name = "sq.test.proxy.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (ProxySettingsStore(defaults: d), d, name)
    }

    @Test func proxiesForExportIsOffUntilSwitchedOn() {
        let (s, d, name) = store(); defer { UserDefaults().removePersistentDomain(forName: name) }
        #expect(s.useProxiesForExport == false)
        s.useProxiesForExport = true
        #expect(s.useProxiesForExport && d.bool(forKey: "sq.proxy.export"))
    }

    @Test func defaultsToAuto() {
        let (s, _, name) = store(); defer { UserDefaults().removePersistentDomain(forName: name) }
        #expect(s.mode(project: nil) == .auto)
        #expect(s.mode(project: UUID()) == .auto)
        #expect(s.playback == .auto)
    }

    @Test func projectOverrideWinsOverTheAppSetting() {
        let (s, d, name) = store(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let p = UUID(), other = UUID()
        s.setMode(.off, project: nil)
        #expect(d.string(forKey: "sq.proxy.mode") == "off")
        s.setMode(.always, project: p)
        #expect(d.string(forKey: "sq.proxy.mode.\(p.uuidString)") == "always")
        #expect(s.mode(project: p) == .always)
        #expect(s.mode(project: other) == .off)
        s.setMode(nil, project: p)           // back to the app setting
        #expect(s.mode(project: p) == .off)
        s.playback = .on
        #expect(d.string(forKey: "sq.proxy.playback") == "on")
        #expect(s.playback == .on)
    }

    @Test func garbageValuesReadAsAuto() {
        let (s, d, name) = store(); defer { UserDefaults().removePersistentDomain(forName: name) }
        d.set("sometimes", forKey: "sq.proxy.mode")
        d.set(42, forKey: "sq.proxy.playback")
        #expect(s.mode(project: nil) == .auto)
        #expect(s.playback == .auto)
    }
}

/// W9.9 review: proxies the monitors use survive the cache cap, and every removal is reported.
@Suite struct CacheProtectionTests {
    private func record(_ id: String, created: Double) -> ProxyRecord {
        let f = SourceFingerprint(size: 10, modifiedMillis: 5, headHash: id, tailHash: id)
        return ProxyRecord(fingerprint: f, kind: .proxyHalf, fileName: ProxyCache.fileName(for: f, kind: .proxyHalf),
                           dimensions: ProxyDimensions(width: 960, height: 540), createdAt: Date(timeIntervalSince1970: created),
                           sourceDuration: Time(5, 1))
    }
    private func commit(_ cache: ProxyCache, _ r: ProxyRecord, bytes: Int = 100) throws {
        let p = cache.partialURL(fingerprint: r.fingerprint, kind: r.kind)
        try writeFile(p, bytes: bytes)
        try cache.commit(partial: p, record: r)
    }

    @Test func protectedRecordsAreNeverEvicted() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let inUse = record("aa", created: 1), other = record("bb", created: 2), newest = record("cc", created: 3)
        for r in [inUse, other, newest] { try commit(cache, r) }
        cache.setProtected([ProxyRecordID(inUse)])
        // The in-use proxy is the least recently used one (its lastAccess is stale), yet it stays.
        let removed = cache.evict(toFit: 200, protecting: [ProxyRecordID(newest)])
        #expect(removed == [other])
        #expect(cache.lookup(fingerprint: inUse.fingerprint, kind: .proxyHalf) != nil)
        #expect(cache.protectedBytes() == 100)
    }

    @Test func removalsAreBroadcast() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let a = record("aa", created: 1), b = record("bb", created: 2)
        try commit(cache, a); try commit(cache, b)
        var it = cache.removedRecords().makeAsyncIterator()
        _ = cache.evict(toFit: 100)
        #expect(await it.next() == a)
        cache.remove(fingerprint: b.fingerprint, kind: .proxyHalf)
        #expect(await it.next() == b)
    }

    @Test func lookupCarriesTheRecordID() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mov")
        try writeFile(src, bytes: 300_000)
        let fp = try SourceFingerprint.compute(for: src)
        let cache = ProxyCache(directory: dir.appendingPathComponent("cache"))
        let r = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: ProxyCache.fileName(for: fp, kind: .proxyHalf),
                            dimensions: ProxyDimensions(width: 960, height: 540), createdAt: Date(), sourceDuration: Time(5, 1))
        try commit(cache, r)
        let hit = await ProxyProvider(cache: cache).optimizedFile(for: src, preferring: ProxyProvider.scrubPreference)
        #expect(hit?.record == ProxyRecordID(r))
    }
}
