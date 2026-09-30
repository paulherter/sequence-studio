import AVFoundation
import CoreVideo
import Foundation
import SSMediaTestSupport
import Testing
@testable import SSMedia

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

@Test func missingFileThrows() async {
    let t = Thumbnailer()
    await #expect(throws: (any Error).self) {
        _ = try await t.firstFrame(media: UUID(), url: URL(fileURLWithPath: "/nonexistent.mov"), height: 90)
    }
}
