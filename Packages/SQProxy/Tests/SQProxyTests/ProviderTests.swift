import Foundation
import SQCore
import Testing
@testable import SQProxy

@Suite struct ProviderTests {
    func commit(_ cache: ProxyCache, _ src: URL, _ kind: ProxyKind) throws {
        let fp = try SourceFingerprint.compute(for: src)
        let r = ProxyRecord(fingerprint: fp, kind: kind, fileName: ProxyCache.fileName(for: fp, kind: kind),
                            dimensions: ProxyDimensions(width: 1920, height: 1080).scaled(divisor: kind.scaleDivisor),
                            createdAt: Date(), sourceDuration: Time(5, 1))
        let p = cache.partialURL(fingerprint: fp, kind: kind)
        try Data("x".utf8).write(to: p)
        try cache.commit(partial: p, record: r)
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
