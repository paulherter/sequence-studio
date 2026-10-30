import CoreVideo
import Foundation
import SQCore

/// Color bars plus a frame-counter bar, BGRA.
public struct TestPatternSource: FrameSource {
    public let width: Int, height: Int
    public let frameCount: Int
    public let frameDuration: Time

    public init(width: Int, height: Int, frameCount: Int, frameDuration: Time) {
        self.width = width; self.height = height; self.frameCount = frameCount; self.frameDuration = frameDuration
    }

    public func frame(at index: Int) async throws -> CVPixelBuffer {
        guard index >= 0, index < frameCount else { throw FrameSourceError.indexOutOfRange(index) }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { throw FrameSourceError.bufferCreationFailed(st) }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        // 7 bars (BGRA order), bottom 12% is a counter bar whose fill grows with the index.
        let bars: [(UInt8, UInt8, UInt8)] = [(235,235,235),(16,235,235),(235,235,16),(16,235,16),(235,16,235),(16,16,235),(235,16,16)]
        let counterTop = height - max(1, height / 8)
        let fill = frameCount > 0 ? width * (index + 1) / frameCount : 0
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let (b, g, r): (UInt8, UInt8, UInt8)
                if y >= counterTop { (b, g, r) = x < fill ? (255, 255, 255) : (20, 20, 20) }
                else { (b, g, r) = bars[min(6, x * 7 / max(1, width))] }
                let p = row + x * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        return buf
    }
}
