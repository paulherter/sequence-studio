import Testing
import CoreVideo
import SSCore
@testable import SSExport

@Suite struct FrameSourceTests {
    @Test func testPatternProducesBGRAFrames() async throws {
        let src = TestPatternSource(width: 64, height: 112, frameCount: 5, frameDuration: Time(1, 30))
        #expect(src.frameCount == 5)
        #expect(src.frameDuration == Time(1, 30))
        let f = try await src.frame(at: 2)
        #expect(CVPixelBufferGetWidth(f) == 64 && CVPixelBufferGetHeight(f) == 112)
        #expect(CVPixelBufferGetPixelFormatType(f) == kCVPixelFormatType_32BGRA)
    }
    @Test func outOfRangeThrows() async {
        let src = TestPatternSource(width: 64, height: 112, frameCount: 2, frameDuration: Time(1, 30))
        await #expect(throws: FrameSourceError.self) { _ = try await src.frame(at: 2) }
    }
    @Test func framesDiffer() async throws {
        let src = TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30))
        func bytes(_ b: CVPixelBuffer) -> [UInt8] {
            CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            let n = CVPixelBufferGetBytesPerRow(b) * CVPixelBufferGetHeight(b)
            return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), count: n))
        }
        let a = bytes(try await src.frame(at: 0)), b = bytes(try await src.frame(at: 1))
        #expect(a != b)
    }
    @Test func sineAudioChunks() async throws {
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 2), frequency: 440)
        #expect(a.totalFrames == 24_000)
        var total = 0
        var pos = 0
        while let chunk = try await a.nextChunk(maxFrames: 10_000) {
            #expect(chunk.channels == 2)
            #expect(chunk.samples.count == chunk.frameCount * 2)
            total += chunk.frameCount; pos += 1
        }
        #expect(total == 24_000)
        #expect(pos == 3)
    }
}
