import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

private func stamp(of image: CGImage) -> Int? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(pb, [])
    return FrameStamp.read(pb)
}

private func clip() async throws -> URL {
    var s = TestClipSpec(); s.frameCount = 60   // 320x180 @30
    return try await TestClipWriter.write(s)
}

private func solid(_ n: Int) -> CGImage {
    CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

@Test func lruEvictsOldestAndRespectsCap() {
    var lru = ThumbnailLRU(capacity: 3 * 100 * 100 * 4)
    let id = UUID()
    let k = (0..<4).map { ThumbnailKey(media: id, time: CMTime(value: Int64($0), timescale: 1), height: 100) }
    lru.put(k[0], solid(100)); lru.put(k[1], solid(100)); lru.put(k[2], solid(100))
    _ = lru.get(k[0])               // k1 is now oldest
    lru.put(k[3], solid(100))
    #expect(lru.get(k[1]) == nil && lru.get(k[0]) != nil && lru.count == 3)
    #expect(lru.bytes <= lru.capacity)
    lru.put(ThumbnailKey(media: id, time: .zero, height: 9), solid(200))   // larger than cap: not stored
    #expect(lru.bytes <= lru.capacity)
}

@Test func lruShrinksUnderMemoryPressureAndGrowsBack() {
    let one = 100 * 100 * 4
    var lru = ThumbnailLRU(capacity: 4 * one)
    let id = UUID()
    let k = (0..<6).map { ThumbnailKey(media: id, time: CMTime(value: Int64($0), timescale: 1), height: 100) }
    for i in 0..<4 { lru.put(k[i], solid(100)) }
    _ = lru.get(k[0])                     // k1 is the oldest now
    lru.apply(.warning)                   // half: 2 thumbnails, the newest
    #expect(lru.count == 2 && lru.bytes <= 2 * one)
    #expect(lru.get(k[0]) != nil && lru.get(k[3]) != nil)
    lru.put(k[4], solid(100))             // the cap holds while the warning lasts
    #expect(lru.count == 2)
    lru.apply(.critical)                  // a quarter: 1
    #expect(lru.count == 1)
    lru.apply(.normal)
    lru.put(k[5], solid(100)); lru.put(k[1], solid(100)); lru.put(k[2], solid(100))
    #expect(lru.count == 4)
}

@Test func thumbnailerFollowsTheRegistry() async throws {
    let reg = MemoryPressureRegistry()
    let t = Thumbnailer(memoryBytes: 1 << 20, pressure: reg)
    reg.post(.critical)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await t.memoryCap == (1 << 20) / 4)
    reg.post(.normal)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await t.memoryCap == 1 << 20)
}

/// Audit: each level hops to the actor in its own task, so a warning's task can run after a later normal's. The stale
/// one must not win: the LRU follows the registry's current level, not the order the hops arrive in.
@Test func thumbnailerIgnoresAStaleLevelArrivingLast() async throws {
    let reg = MemoryPressureRegistry()
    let t = Thumbnailer(memoryBytes: 1 << 20, pressure: reg)
    reg.post(.warning)
    reg.post(.normal)
    try await Task.sleep(for: .milliseconds(100))
    await t.memoryPressureDelivered(.warning)          // the warning's hop, arriving after the normal one
    #expect(await t.memoryCap == 1 << 20)
}

@Test func keyQuantisesEqualRationalTimes() {
    let id = UUID()
    #expect(ThumbnailKey(media: id, time: CMTime(value: 1, timescale: 2), height: 10)
            == ThumbnailKey(media: id, time: CMTime(value: 600, timescale: 1200), height: 10))
}

@Test func firstFrameIsStampedZeroAtFullSize() async throws {
    let url = try await clip()
    let t = Thumbnailer()
    let img = try await t.firstFrame(media: UUID(), url: url, height: 180)
    #expect(img.height == 180 && img.width == 320)
    #expect(stamp(of: img) == 0)
}

@Test func atTimeExactAndScaledToHeight() async throws {
    let url = try await clip()
    let t = Thumbnailer()
    let id = UUID()
    let full = try await t.thumbnail(media: id, url: url, at: CMTime(value: 1, timescale: 1), height: 180)
    #expect(stamp(of: full) == 30)
    let small = try await t.thumbnail(media: id, url: url, at: .zero, height: 90)
    #expect(small.height == 90 && small.width == 160)
}

@Test func concurrentRequestsCoalesceAndHitCache() async throws {
    let url = try await clip()
    let t = Thumbnailer()
    let id = UUID()
    try await withThrowingTaskGroup(of: Int.self) { g in
        for _ in 0..<5 { g.addTask { try await t.firstFrame(media: id, url: url, height: 90).width } }
        for try await w in g { #expect(w == 160) }
    }
    _ = try await t.firstFrame(media: id, url: url, height: 90)
    #expect(await t.generationCount == 1)
    #expect(await t.cachedBytes > 0)
}

@Test func cancellationThrowsAndLaterRequestWorks() async throws {
    let url = try await clip()
    let t = Thumbnailer()
    let id = UUID()
    let task = Task { try await t.firstFrame(media: id, url: url, height: 90) }
    task.cancel()
    do { _ = try await task.value } catch { /* expected or already finished */ }
    let img = try await t.firstFrame(media: id, url: url, height: 90)
    #expect(img.height == 90)
}

/// Holds every slot of `limiter` until the returned task is canceled.
private func occupy(_ limiter: AsyncLimiter) async throws -> Task<Void, Error> {
    let holder = Task { try await limiter.run { try await Task.sleep(for: .seconds(120)) } }
    while limiter.freeSlots > 0 { try await Task.sleep(for: .milliseconds(2)) }
    return holder
}

/// Hover scrub has its own slot: it is served while every poster slot is busy.
@Test func interactiveLaneDoesNotWaitBehindPosters() async throws {
    let url = try await clip()
    let posters = AsyncLimiter(width: 1)
    let t = Thumbnailer(limiter: posters, interactiveLimiter: AsyncLimiter(width: 1))
    let holder = try await occupy(posters)
    defer { holder.cancel() }
    let img = try await t.thumbnail(media: UUID(), url: url, height: 90, exact: false, lane: .interactive)
    #expect(img.height == 90)
    #expect(posters.freeSlots == 0)
}

/// A request canceled while waiting for a decode slot never decodes and is not counted.
@Test func requestCancelledBeforeDecodingIsNotCounted() async throws {
    let url = try await clip()
    let posters = AsyncLimiter(width: 1)
    let t = Thumbnailer(limiter: posters)
    let holder = try await occupy(posters)
    let req = Task { try await t.firstFrame(media: UUID(), url: url, height: 90) }
    while posters.waiting == 0 { try await Task.sleep(for: .milliseconds(2)) }
    req.cancel()
    _ = try? await req.value
    while posters.waiting > 0 { try await Task.sleep(for: .milliseconds(2)) }
    holder.cancel()
    _ = try? await holder.value
    #expect(await t.generationCount == 0)
}

@Test func diskCacheServesNewInstance() async throws {
    let url = try await clip()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    _ = try await Thumbnailer(diskDirectory: dir).firstFrame(media: id, url: url, height: 180)
    let t2 = Thumbnailer(diskDirectory: dir)
    let img = try await t2.firstFrame(media: id, url: URL(fileURLWithPath: "/nonexistent.mov"), height: 180)
    #expect(stamp(of: img) == 0)
    #expect(await t2.generationCount == 0)
    await t2.invalidate(media: id)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
}

// MARK: Batches (several times of one file in one generator call; docs/PLAYBACK-PERF.md "Import: posters, per variant")

private let batchTimes = [CMTime.zero, CMTime(value: 1, timescale: 1), CMTime(value: 3, timescale: 2)]

/// A batch gives each time the frame a single request gives, under the same cache keys, in one generator run.
@Test func batchEqualsSingleRequestsAndSharesTheirCache() async throws {
    let url = try await clip()
    let t = Thumbnailer(pressure: nil)
    let id = UUID()
    let got = await t.thumbnails(media: id, url: url, at: batchTimes, height: 180)
    let stamps = try got.map { stamp(of: try $0.get()) }
    #expect(stamps == [0, 30, 45])
    #expect(await t.generationCount == 1)
    let single = Thumbnailer(pressure: nil)
    for (i, time) in batchTimes.enumerated() {
        #expect(stamp(of: try await single.thumbnail(media: id, url: url, at: time, height: 180)) == stamps[i])
        let cached = try await t.thumbnail(media: id, url: URL(fileURLWithPath: "/nonexistent.mov"), at: time, height: 180)
        #expect(cached.height == 180 && cached.width == 320)
    }
    #expect(await t.generationCount == 1)                    // every single request above was a cache hit
}

/// A time the file cannot give fails on its own; the other times of the batch still arrive.
@Test func oneFailedTimeDoesNotFailTheBatch() async throws {
    let url = try await clip()
    let t = Thumbnailer(pressure: nil)
    let got = await t.thumbnails(media: UUID(), url: url, at: [.zero, CMTime(value: 1000, timescale: 1)], height: 180)
    #expect(stamp(of: try got[0].get()) == 0)
    #expect((try? got[1].get()) == nil)
}

/// One requester of a batch leaving does not cancel it while another still waits for one of its frames.
@Test func batchSurvivesWhileAnyRequesterStays() async throws {
    let url = try await clip()
    let posters = AsyncLimiter(width: 1)
    let t = Thumbnailer(limiter: posters, pressure: nil)
    let id = UUID()
    let holder = try await occupy(posters)
    let a = Task { await t.thumbnails(media: id, url: url, at: batchTimes, height: 180) }
    while posters.waiting == 0 { try await Task.sleep(for: .milliseconds(2)) }
    let b = Task { try await t.thumbnail(media: id, url: url, at: batchTimes[1], height: 180) }
    while await t.waiterCount(ThumbnailKey(media: id, time: batchTimes[1], height: 180)) < 2 {
        try await Task.sleep(for: .milliseconds(2))
    }
    a.cancel()
    holder.cancel()
    #expect(stamp(of: try await b.value) == 30)
    #expect(await a.value.allSatisfy { (try? $0.get()) == nil })
    #expect(await t.generationCount == 1)
}

/// When every requester of a batch has left, it never decodes.
@Test func batchCanceledByAllRequestersIsNotDecoded() async throws {
    let url = try await clip()
    let posters = AsyncLimiter(width: 1)
    let t = Thumbnailer(limiter: posters, pressure: nil)
    let holder = try await occupy(posters)
    let a = Task { await t.thumbnails(media: UUID(), url: url, at: batchTimes, height: 90) }
    while posters.waiting == 0 { try await Task.sleep(for: .milliseconds(2)) }
    a.cancel()
    while posters.waiting > 0 { try await Task.sleep(for: .milliseconds(2)) }
    holder.cancel()
    _ = try? await holder.value
    #expect(await a.value.allSatisfy { (try? $0.get()) == nil })
    #expect(await t.generationCount == 0)
}

@Test func missingFileThrows() async {
    let t = Thumbnailer()
    await #expect(throws: (any Error).self) {
        _ = try await t.firstFrame(media: UUID(), url: URL(fileURLWithPath: "/nonexistent.mov"), height: 90)
    }
}
