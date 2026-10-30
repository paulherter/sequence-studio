import Foundation
import SQCore
import Testing
@testable import SQProxy

@Suite struct ProviderTests {
    func commit(_ cache: ProxyCache, _ src: URL, _ kind: ProxyKind, build: Int = ProxyRecord.currentBuild) throws {
        let fp = try SourceFingerprint.compute(for: src)
        let r = ProxyRecord(fingerprint: fp, kind: kind, fileName: ProxyCache.fileName(for: fp, kind: kind),
                            dimensions: ProxyDimensions(width: 1920, height: 1080).scaled(divisor: kind.scaleDivisor),
                            createdAt: Date(), sourceDuration: Time(5, 1), build: build)
        let p = cache.partialURL(fingerprint: fp, kind: kind)
        try Data("x".utf8).write(to: p)
        try cache.commit(partial: p, record: r)
    }

    /// The build is part of a record's identity (the cache's "still the record I read" checks must see `markCurrent`),
    /// and `removeOutdated` leaves a record that became current.
    @Test func aRecordMarkedCurrentIsNotTheOldOne() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let fp = SourceFingerprint(size: 1, modifiedMillis: 2, headHash: "a", tailHash: "b")
        let old = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: ProxyCache.fileName(for: fp, kind: .proxyHalf),
                              dimensions: ProxyDimensions(width: 2, height: 2), createdAt: Date(timeIntervalSince1970: 10),
                              sourceDuration: Time(5, 1), build: 0)
        var new = old; new.build = ProxyRecord.currentBuild
        #expect(old != new)
        let partial = cache.partialURL(fingerprint: fp, kind: .proxyHalf)
        try Data("x".utf8).write(to: partial)
        try cache.commit(partial: partial, record: old)
        cache.markCurrent(fingerprint: fp, kind: .proxyHalf)
        cache.removeOutdated(fingerprint: fp, kind: .proxyHalf)
        let kept = try #require(cache.currentLookup(fingerprint: fp, kind: .proxyHalf))
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(for: kept).path))
    }

    /// A record written before `build` existed reads as build 0; a new one carries the current build through the index.
    @Test func recordsWithoutABuildAreOld() throws {
        let fp = SourceFingerprint(size: 1, modifiedMillis: 2, headHash: "a", tailHash: "b")
        let new = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: "f", dimensions: ProxyDimensions(width: 2, height: 2),
                              createdAt: Date(timeIntervalSince1970: 10), sourceDuration: Time(5, 1))
        #expect(new.isCurrent)
        let data = try JSONEncoder.proxy.encode(new)
        #expect(try JSONDecoder.proxy.decode(ProxyRecord.self, from: data).isCurrent)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["build"] = nil
        let old = try JSONDecoder.proxy.decode(ProxyRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.build == 0 && !old.isCurrent)
    }

    /// Proxies from before interlaced sources were deinterlaced are woven: the one of an interlaced source is deleted
    /// (and so made again), the one of a progressive source is kept and handed out. Neither is handed out unchecked.
    @Test func oldProxiesOfInterlacedSourcesAreDropped() async throws {
        for fields in [true, false] {
            let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
            let cacheDir = dir.appendingPathComponent("c")
            let cache = ProxyCache(directory: cacheDir)
            try commit(cache, src, .proxyHalf, build: 0)
            try commit(cache, src, .optimized)
            let fp = try SourceFingerprint.compute(for: src)
            #expect(cache.outdatedKinds(for: fp) == [.proxyHalf])
            #expect(cache.currentLookup(fingerprint: fp, kind: .proxyHalf) == nil)
            let provider = ProxyProvider(cache: cache) { _ in fields }
            #expect(provider.cachedLookup(for: src, preferring: [.proxyHalf]) == nil)
            await provider.warm(src)
            let half = provider.cachedLookup(for: src, preferring: [.proxyHalf])
            #expect((half == nil) == fields, "fields \(fields)")
            #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(ProxyCache.fileName(for: fp, kind: .proxyHalf)).path) == !fields)
            #expect(provider.cachedLookup(for: src, preferring: [.optimized])?.kind == .optimized, "a new proxy is untouched")
            #expect(cache.outdatedKinds(for: fp).isEmpty)
            // The verdict is stored: the next launch does not ask again.
            let again = ProxyProvider(cache: ProxyCache(directory: cacheDir)) { _ in Issue.record("asked twice"); return true }
            #expect((await again.optimizedFile(for: src, preferring: [.proxyHalf]) == nil) == fields)
        }
    }

    @Test func prefersInOrderAndSkipsMissing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let provider = ProxyProvider(cache: cache)
        #expect(await provider.optimizedFile(for: src, preferring: [.optimized]) == nil)
        try commit(cache, src, .proxyQuarter)
        let l = try #require(await provider.optimizedFile(for: src, preferring: [.optimized, .proxyHalf, .proxyQuarter]))
        #expect(l.kind == .proxyQuarter && l.scaleDivisor == 4)
        #expect(l.dimensions == ProxyDimensions(width: 480, height: 270))
        #expect(FileManager.default.fileExists(atPath: l.url.path))
        try commit(cache, src, .proxyHalf)
        #expect(await provider.optimizedFile(for: src, preferring: [.proxyHalf, .proxyQuarter])?.kind == .proxyHalf)
        #expect(await provider.optimizedFile(for: src, preferring: [])  == nil)
    }

    @Test func syncVariantNeedsWarmFingerprint() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let provider = ProxyProvider(cache: cache)
        try commit(cache, src, .proxyHalf)
        #expect(provider.cachedLookup(for: src, preferring: [.proxyHalf]) == nil) // cold: never reads content
        _ = await provider.optimizedFile(for: src, preferring: [.proxyHalf])
        #expect(provider.cachedLookup(for: src, preferring: [.proxyHalf])?.kind == .proxyHalf)
        // file modified -> stat mismatch -> cold again
        try writeFile(src, bytes: 600)
        #expect(provider.cachedLookup(for: src, preferring: [.proxyHalf]) == nil)
    }

    @Test func survivesRenameOfSource() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let provider = ProxyProvider(cache: cache)
        try commit(cache, src, .proxyHalf)
        let moved = dir.appendingPathComponent("moved.mov")
        try FileManager.default.moveItem(at: src, to: moved)
        #expect(await provider.optimizedFile(for: moved, preferring: [.proxyHalf]) != nil)
    }

    @Test func readyEvents() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov"); try writeFile(src, bytes: 500)
        let cache = ProxyCache(directory: dir.appendingPathComponent("c"))
        let provider = ProxyProvider(cache: cache)
        var it = provider.readyEvents().makeAsyncIterator()
        try commit(cache, src, .optimized)
        let ev = await it.next()
        #expect(ev?.kind == .optimized)
        #expect(ev?.fingerprint == (try SourceFingerprint.compute(for: src)))
    }
}
