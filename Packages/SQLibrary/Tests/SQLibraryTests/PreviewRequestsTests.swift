import Foundation
import SQCore
import Testing
@testable import SQLibrary

/// Fake provider: writes a small file; can block until opened (cancellation aware).
actor FakeProvider: PreviewProvider {
    private(set) var calls = 0
    private(set) var cancelled = 0
    private var blocking: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocking: Bool = false) { self.blocking = blocking }

    func open() {
        blocking = false
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func generate(_ request: PreviewRequest, to destination: URL) async throws {
        calls += 1
        if blocking {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { await self.markCancelledAndOpen() }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        try Data("preview".utf8).write(to: destination)
    }

    private func markCancelledAndOpen() {
        cancelled += 1
        open()
    }
}

actor CoordinatorBox {
    private(set) var value: PreviewCoordinator?
    func set(_ c: PreviewCoordinator) { value = c }
}

func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite struct PreviewCacheTests {
    let entry = LibraryEntryID(folderID: UUID(), relativePath: "a.mov")
    func req(_ hash: ContentHash, kind: PreviewKind = .thumbnail, w: Int = 160, h: Int = 90) -> PreviewRequest {
        PreviewRequest(entryID: entry, kind: kind, pixelWidth: w, pixelHeight: h, contentHash: hash)
    }

    @Test func contentHashIsStableAndSensitive() {
        let d = Date(timeIntervalSince1970: 1000)
        let base = ContentHash(path: "/a/b.mov", modified: d, size: 10)
        #expect(base == ContentHash(path: "/a/b.mov", modified: d, size: 10))
        #expect(base.key == ContentHash(path: "/a/b.mov", modified: d, size: 10).key)
        #expect(base.key != ContentHash(path: "/a/c.mov", modified: d, size: 10).key)
        #expect(base.key != ContentHash(path: "/a/b.mov", modified: d.addingTimeInterval(1), size: 10).key)
        #expect(base.key != ContentHash(path: "/a/b.mov", modified: d, size: 11).key)
        // Known value guards against accidental change of the on-disk key format.
        #expect(base.key.count == 16)
    }

    @Test func cachePathsLiveUnderInjectedDirectoryAndDiffer() {
        let root = URL(fileURLWithPath: "/tmp/caches-test")
        let cache = PreviewCache(cachesDirectory: root, disk: .unchecked)
        let h = ContentHash(path: "/a.mov", modified: .distantPast, size: 1)
        let thumb = cache.fileURL(for: req(h))
        #expect(thumb.path.hasPrefix("/tmp/caches-test/Sequence Studio/Previews/"))
        #expect(thumb != cache.fileURL(for: req(h, kind: .waveform)))
        #expect(thumb != cache.fileURL(for: req(h, w: 320, h: 180)))
        #expect(thumb == cache.fileURL(for: req(h)))
    }

    @Test func requestFromEntry() {
        let e = LibraryEntry(folderID: UUID(), relativePath: "x/y.mov", kind: .video, size: 5, modified: Date(timeIntervalSince1970: 7))
        let f = WatchedFolder(id: e.folderID, url: URL(fileURLWithPath: "/m"))
        let r = PreviewRequest(entry: e, in: f, kind: .waveform, pixelWidth: 100, pixelHeight: 20)
        #expect(r.entryID == e.id)
        #expect(r.contentHash == ContentHash(path: "/m/x/y.mov", modified: e.modified, size: 5))
    }
}

@Suite struct PreviewCoordinatorTests {
    let entry = LibraryEntryID(folderID: UUID(), relativePath: "a.mov")
    func req(size: Int64 = 1, kind: PreviewKind = .thumbnail) -> PreviewRequest {
        PreviewRequest(entryID: entry, kind: kind, pixelWidth: 160, pixelHeight: 90,
                       contentHash: ContentHash(path: "/a.mov", modified: .distantPast, size: size))
    }

    @Test func cachedResultSkipsProvider() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider()
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let a = try await coordinator.preview(for: req())
        let b = try await coordinator.preview(for: req())
        #expect(a == b)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(await provider.calls == 1)
    }

    @Test func belowDiskFloorGeneratesNothing() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider()
        let low = CacheDiskPolicy(space: { _ in (free: 1 << 30, total: 256 << 30) })
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: low), provider: provider)
        await #expect(throws: PreviewError.diskLow) { try await coordinator.preview(for: req()) }
        #expect(await provider.calls == 0)
    }

    @Test func concurrentIdenticalRequestsAreCoalesced() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider(blocking: true)
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let r = req()
        async let a = coordinator.preview(for: r)
        async let b = coordinator.preview(for: r)
        await waitUntil { let n = await coordinator.inFlightCount; let c = await provider.calls; return n == 1 && c == 1 }
        await provider.open()
        let (ua, ub) = try await (a, b)
        #expect(ua == ub)
        #expect(await provider.calls == 1)
        #expect(await coordinator.inFlightCount == 0)
    }

    @Test func cancellingTheOnlyWaiterCancelsProvider() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider(blocking: true)
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let r = req()
        let task = Task { try await coordinator.preview(for: r) }
        await waitUntil { await provider.calls == 1 }
        task.cancel()
        await waitUntil { await provider.cancelled == 1 }
        #expect(await provider.cancelled == 1)
        _ = await task.result
        await waitUntil { await coordinator.inFlightCount == 0 }
        #expect(await coordinator.inFlightCount == 0)
    }

    @Test func oneCancelledWaiterKeepsSharedWorkAlive() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider(blocking: true)
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let r = req()
        let t1 = Task { try await coordinator.preview(for: r) }
        let t2 = Task { try await coordinator.preview(for: r) }
        await waitUntil { await coordinator.waiterCount(for: r) == 2 }
        t1.cancel()
        await waitUntil { await coordinator.waiterCount(for: r) == 1 }
        await provider.open()
        let url = try await t2.value
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await provider.cancelled == 0)
    }

    @Test func fileChangeSupersedesInFlightAndRemovesOldCache() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider()
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let old = try await coordinator.preview(for: req(size: 1))
        #expect(FileManager.default.fileExists(atPath: old.path))
        let new = try await coordinator.preview(for: req(size: 2))
        #expect(new != old)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func staleInFlightRequestFails() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider(blocking: true)
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let stale = Task { try await coordinator.preview(for: req(size: 1)) }
        await waitUntil { await provider.calls == 1 }
        let fresh = Task { try await coordinator.preview(for: req(size: 2)) }
        await waitUntil { await provider.calls == 2 }
        await provider.open()
        let freshURL = try await fresh.value
        #expect(FileManager.default.fileExists(atPath: freshURL.path))
        let result = await stale.result
        if case .failure(let error) = result {
            #expect(error as? PreviewError == .stale)
        } else {
            Issue.record("stale request should fail")
        }
    }

    /// L1a: a request for older content must not supersede the newer flight or delete its files.
    @Test func olderContentRequestIsIgnoredAndKeepsNewer() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let provider = FakeProvider(blocking: true)
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: provider)
        let fresh = Task { try await coordinator.preview(for: req(size: 2)) }
        await waitUntil { await provider.calls == 1 }
        await #expect(throws: PreviewError.stale) { try await coordinator.preview(for: req(size: 1)) }
        #expect(await provider.calls == 1)
        await provider.open()
        let url = try await fresh.value
        #expect(FileManager.default.fileExists(atPath: url.path))
        // A late old request after the newer one is cached must not delete the newer file either.
        await #expect(throws: PreviewError.stale) { try await coordinator.preview(for: req(size: 1)) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// L1b: supersede lands between the staleness check and the move; the moved file must not stay behind.
    @Test func supersedeBetweenCheckAndMoveLeavesNoOrphan() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = PreviewCache(cachesDirectory: dir.url, disk: .unchecked)
        let oldReq = req(size: 1), newReq = req(size: 2)
        let box = CoordinatorBox()
        let coordinator = PreviewCoordinator(cache: cache, provider: FakeProvider(), beforeMove: { request in
            if request == oldReq, let c = await box.value { _ = await Task.detached { try? await c.preview(for: newReq) }.value }
        })
        await box.set(coordinator)
        let old = Task { try await coordinator.preview(for: oldReq) }
        _ = await old.result
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: oldReq).path))
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(for: newReq).path))
    }

    @Test func providerFailureIsPropagatedAndNotCached() async throws {
        struct Boom: Error {}
        struct Failing: PreviewProvider {
            func generate(_ request: PreviewRequest, to destination: URL) async throws { throw Boom() }
        }
        let dir = try TempDir(); defer { dir.remove() }
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: dir.url, disk: .unchecked), provider: Failing())
        await #expect(throws: Boom.self) { try await coordinator.preview(for: req()) }
        #expect(await coordinator.inFlightCount == 0)
    }
}

@Suite struct PreviewCacheLRUTests {
    private func makeCache(_ dir: TempDir, cap: Int64) -> PreviewCache {
        PreviewCache(cachesDirectory: dir.url, byteCap: cap, disk: .unchecked)
    }
    private func file(_ dir: TempDir, _ cache: PreviewCache, _ name: String, bytes: Int, age: TimeInterval) throws -> URL {
        let rel = cache.root.path.dropFirst(dir.url.path.count + 1) + "/thumbnail/\(name)"
        return try dir.write(String(rel), bytes: bytes, modified: Date().addingTimeInterval(-age))
    }

    @Test func defaultCapIsTwoGB() throws {
        let dir = try TempDir(); defer { dir.remove() }
        #expect(PreviewCache(cachesDirectory: dir.url, disk: .unchecked).byteCap == 2 * 1024 * 1024 * 1024)
    }

    @Test func evictsOldestFirstDownToCap() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 250)
        let a = try file(dir, cache, "a", bytes: 100, age: 400)
        let b = try file(dir, cache, "b", bytes: 100, age: 300)
        let c = try file(dir, cache, "c", bytes: 100, age: 200)
        let d = try file(dir, cache, "d", bytes: 100, age: 100)
        #expect(cache.totalSize() == 400)
        let removed = cache.evict()
        #expect(removed.map(\.lastPathComponent) == ["a", "b"])
        #expect(cache.totalSize() == 200)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: c.path) && FileManager.default.fileExists(atPath: d.path))
    }

    @Test func noEvictionUnderCapAndAdditionalBytesCount() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 250)
        _ = try file(dir, cache, "a", bytes: 100, age: 20)
        _ = try file(dir, cache, "b", bytes: 100, age: 10)
        #expect(cache.evict().isEmpty)
        #expect(cache.evict(toFit: 100).map(\.lastPathComponent) == ["a"])
    }

    @Test func protectedFileIsNeverRemoved() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 100)
        let a = try file(dir, cache, "a", bytes: 100, age: 400)
        let b = try file(dir, cache, "b", bytes: 100, age: 300)
        let removed = cache.evict(protecting: [a])
        #expect(removed.map(\.lastPathComponent) == ["b"])
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func touchRefreshesLRUOrder() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 100)
        let a = try file(dir, cache, "a", bytes: 100, age: 400)
        _ = try file(dir, cache, "b", bytes: 100, age: 300)
        cache.touch(a)
        #expect(cache.evict().map(\.lastPathComponent) == ["b"])
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func filesOutsideRootAreNeverTouchedOrEvicted() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 10)
        let old = Date().addingTimeInterval(-1000)
        let outside = try dir.write("elsewhere/x.png", bytes: 500, modified: old)
        _ = try file(dir, cache, "a", bytes: 100, age: 50)
        cache.touch(outside)
        let mtime = try FileManager.default.attributesOfItem(atPath: outside.path)[.modificationDate] as? Date
        #expect(mtime == old)
        _ = cache.evict()
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func coordinatorHitRefreshesAndGenerateEvictsProtectingNewFile() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let cache = makeCache(dir, cap: 10)  // provider writes 7 bytes: a second file forces eviction
        let coordinator = PreviewCoordinator(cache: cache, provider: FakeProvider())
        func req(_ n: Int64) -> PreviewRequest {
            PreviewRequest(entryID: LibraryEntryID(folderID: UUID(), relativePath: "e\(n)"), kind: .thumbnail, pixelWidth: 10, pixelHeight: 10,
                           contentHash: ContentHash(path: "/m\(n)", modified: Date(timeIntervalSince1970: 1), size: n))
        }
        let first = try await coordinator.preview(for: req(1))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-500)], ofItemAtPath: first.path)
        _ = try await coordinator.preview(for: req(1))  // hit
        let after = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        #expect(after! > Date().addingTimeInterval(-60))
        let second = try await coordinator.preview(for: req(2))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }
}
