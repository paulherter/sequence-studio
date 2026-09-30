import Foundation
import SSCore
import Testing
@testable import SSProxy

func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ssproxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func writeFile(_ url: URL, bytes: Int, seed: UInt8 = 1) throws {
    var data = Data(count: bytes)
    for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
    try data.write(to: url)
}

@Suite struct ProxyKindTests {
    @Test func scaleAndCodec() {
        #expect(ProxyKind.optimized.scaleDivisor == 1)
        #expect(ProxyKind.proxyHalf.scaleDivisor == 2)
        #expect(ProxyKind.proxyQuarter.scaleDivisor == 4)
        #expect(ProxyKind.optimized.codecFourCC == "apcn")
        #expect(ProxyKind.proxyHalf.codecFourCC == "apco")
        #expect(ProxyKind.proxyQuarter.codecFourCC == "apco")
    }
    @Test func scaledDimensionsAreEven() {
        let d = ProxyDimensions(width: 3840, height: 2160).scaled(divisor: 4)
        #expect(d == ProxyDimensions(width: 960, height: 540))
        let odd = ProxyDimensions(width: 1922, height: 1082).scaled(divisor: 4)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
    }
}

@Suite struct FingerprintTests {
    @Test func movedFileKeepsFingerprint() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        try writeFile(a, bytes: 300_000)
        let f1 = try SourceFingerprint.compute(for: a)
        let b = dir.appendingPathComponent("renamed.bin")
        try FileManager.default.moveItem(at: a, to: b)
        #expect(try SourceFingerprint.compute(for: b) == f1)
    }
    @Test func headTailAndSizeChangeFingerprint() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        try writeFile(a, bytes: 300_000)
        let date = try #require(FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date)
        let base = try SourceFingerprint.compute(for: a)
        func mutate(_ offset: Int) throws -> SourceFingerprint {
            var d = try Data(contentsOf: a); d[offset] ^= 0xFF; try d.write(to: a)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
            defer { d[offset] ^= 0xFF; try? d.write(to: a); try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path) }
            return try SourceFingerprint.compute(for: a)
        }
        #expect(try mutate(10) != base)
        #expect(try mutate(299_990) != base)
        // documented limitation: middle edit with same size+mtime is not detected
        #expect(try mutate(150_000) == base)
        var d = try Data(contentsOf: a); d.append(0); try d.write(to: a)
        #expect(try SourceFingerprint.compute(for: a) != base)
    }
    @Test func smallFileAndCodable() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("s.bin")
        try writeFile(a, bytes: 100)
        let f = try SourceFingerprint.compute(for: a)
        let back = try JSONDecoder().decode(SourceFingerprint.self, from: JSONEncoder().encode(f))
        #expect(back == f)
        #expect(!f.id.isEmpty && !f.id.contains("/"))
    }
    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) { try SourceFingerprint.compute(for: URL(fileURLWithPath: "/nonexistent/x.mov")) }
    }
}

@Suite struct CacheTests {
    let fp = SourceFingerprint(size: 10, modifiedMillis: 5, headHash: "aa", tailHash: "bb")
    func record(_ kind: ProxyKind = .proxyHalf, fp: SourceFingerprint? = nil, created: Date = Date(timeIntervalSince1970: 1000)) -> ProxyRecord {
        let f = fp ?? self.fp
        return ProxyRecord(fingerprint: f, kind: kind, fileName: ProxyCache.fileName(for: f, kind: kind),
                           dimensions: ProxyDimensions(width: 1920, height: 1080), createdAt: created,
                           sourceDuration: Time(5, 1))
    }
    func stage(_ cache: ProxyCache, _ r: ProxyRecord, bytes: Int = 100) throws -> URL {
        let p = cache.partialURL(fingerprint: r.fingerprint, kind: r.kind)
        try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFile(p, bytes: bytes)
        return p
    }

    @Test func commitLookupAndPersist() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let r = record()
        #expect(cache.lookup(fingerprint: fp, kind: .proxyHalf) == nil)
        let p = try stage(cache, r)
        try cache.commit(partial: p, record: r)
        #expect(!FileManager.default.fileExists(atPath: p.path))
        #expect(cache.lookup(fingerprint: fp, kind: .proxyHalf) == r)
        #expect(cache.lookup(fingerprint: fp, kind: .optimized) == nil)
        let reopened = ProxyCache(directory: dir)
        #expect(reopened.lookup(fingerprint: fp, kind: .proxyHalf) == r)
        #expect(FileManager.default.fileExists(atPath: reopened.fileURL(for: r).path))
    }
    @Test func missingFileDropsEntry() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let r = record()
        try cache.commit(partial: try stage(cache, r), record: r)
        try FileManager.default.removeItem(at: cache.fileURL(for: r))
        #expect(cache.lookup(fingerprint: fp, kind: .proxyHalf) == nil)
        #expect(cache.allRecords().isEmpty)
    }
    @Test func partialsAreNotReady() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let r = record()
        _ = try stage(cache, r)
        #expect(cache.lookup(fingerprint: fp, kind: .proxyHalf) == nil)
        #expect(cache.purgePartials() == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.partialURL(fingerprint: fp, kind: .proxyHalf).path))
    }
    @Test func removeAndSize() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let r1 = record(.proxyHalf), r2 = record(.proxyQuarter)
        try cache.commit(partial: try stage(cache, r1, bytes: 100), record: r1)
        try cache.commit(partial: try stage(cache, r2, bytes: 50), record: r2)
        #expect(cache.totalSize() == 150)
        cache.remove(fingerprint: fp, kind: .proxyHalf)
        #expect(cache.totalSize() == 50)
        cache.removeAll(for: fp)
        #expect(cache.allRecords().isEmpty && cache.totalSize() == 0)
    }
    @Test func evictOldestFirst() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        let f2 = SourceFingerprint(size: 11, modifiedMillis: 5, headHash: "cc", tailHash: "dd")
        let old = record(.proxyHalf, created: Date(timeIntervalSince1970: 1))
        let new = record(.proxyHalf, fp: f2, created: Date(timeIntervalSince1970: 2))
        try cache.commit(partial: try stage(cache, old, bytes: 100), record: old)
        try cache.commit(partial: try stage(cache, new, bytes: 100), record: new)
        let removed = cache.evict(toFit: 100)
        #expect(removed == [old])
        #expect(cache.lookup(fingerprint: f2, kind: .proxyHalf) != nil)
    }
    @Test func commitBroadcastsChange() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ProxyCache(directory: dir)
        var it = cache.readyRecords().makeAsyncIterator()
        let r = record()
        try cache.commit(partial: try stage(cache, r), record: r)
        #expect(await it.next() == r)
    }
}
