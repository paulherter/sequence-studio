import Foundation
import SQCore
import SQFrame
#if canImport(CoreVideo)
import CoreVideo
import SQFrameCoreVideo
#endif

/// One decoded frame: the neutral `SQFrame` (its presentation time is `pts`) plus the media and display duration.
/// On the Mac the frame wraps an IOSurface-backed, Metal compatible CVPixelBuffer (`pixelBuffer`), immutable after creation.
public struct DecodedFrame: Sendable {
    public let media: UUID, duration: Time
    public let frame: SQFrame
    public var pts: Time { frame.presentationTime }
    public init(media: UUID, duration: Time, frame: SQFrame) {
        self.media = media; self.duration = duration; self.frame = frame
    }
}

#if canImport(CoreVideo)
public extension DecodedFrame {
    /// The wrapped CVPixelBuffer (no copy).
    var pixelBuffer: CVPixelBuffer { frame.pixelBuffer }
    var byteCost: Int {
        let pixelBuffer = self.pixelBuffer
        let total = CVPixelBufferGetDataSize(pixelBuffer)
        if total > 0 { return total }
        var sum = 0
        for p in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            sum += CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, p) * CVPixelBufferGetHeightOfPlane(pixelBuffer, p)
        }
        return sum > 0 ? sum : CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
    }
    init(media: UUID, pts: Time, duration: Time, pixelBuffer: CVPixelBuffer) {
        self.init(media: media, duration: duration, frame: SQFrame(pixelBuffer: pixelBuffer, presentationTime: pts))
    }
}
#else
public extension DecodedFrame {
    /// Bytes the frame holds, from its size and pixel format (GPU textures included: they count against the same budget).
    var byteCost: Int {
        let px = frame.width * frame.height
        switch frame.pixelFormat {
        case .nv12, .nv12FullRange: return px * 3 / 2
        case .p010, .p010FullRange: return px * 3
        case .p210: return px * 4
        case .bgra8, .rgba8: return px * 4
        case .rgba16f, .ayuv16: return px * 8
        case .rgba32f: return px * 16
        case .other: return px * 4
        }
    }
}
#endif

public protocol VideoDecoding: Sendable {
    var info: VideoTrackInfo { get }
    var isHardware: Bool { get }
    /// Decodes presentation frames `range` and returns them in PTS order (entries with zero duration, which the edit
    /// list does not show, are left out). Continues from the previous call without
    /// reseeking when `range` starts right after the last decoded frame (forward playback). Cancellable (Task).
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame]
    /// Same as `decode(_:)`, and additionally hands each frame of `range` to `deliver` as soon as it is decoded (decode
    /// order, on any thread), so a caller can show the target of a long GOP before the job ends. The returned array
    /// holds only the frames that were not delivered early (carried over from a previous call, or a decoder without early
    /// delivery): a delivered frame belongs to the caller and is not held until the job ends (a long GOP of 4K frames).
    /// Default: nothing is delivered early.
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame]
    /// Seek hint, see the extension. Default: `decode(_:deliver:)`.
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame]
    func invalidate()
}

public extension VideoDecoding {
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try await decode(range)
    }
    /// As `decode(_:deliver:)`; frames of `range` before `neededFrom` may be left out (a seek: a decoder that can skips
    /// pictures nothing references before the target, so the target arrives sooner). Default: ignores the hint.
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try await decode(range, deliver: deliver)
    }
}

/// H.264 access units in AVCC form (length-prefixed NAL units).
public enum H264NAL {
    /// True when the sample has at least one coded slice and no slice is used for reference (`nal_ref_idc` 0 on every
    /// slice NAL, types 1-5): no other picture depends on it, decoding can skip it. Anything malformed: false.
    public static func isDisposable<C: RandomAccessCollection>(_ bytes: C, lengthSize: Int) -> Bool where C.Element == UInt8, C.Index == Int {
        guard (1...4).contains(lengthSize) else { return false }
        var i = bytes.startIndex
        var slices = 0
        while i < bytes.endIndex {
            guard bytes.endIndex - i >= lengthSize + 1 else { return false }
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(bytes[i + k]) }
            let h = bytes[i + lengthSize]
            guard len >= 1, bytes.endIndex - (i + lengthSize) >= len else { return false }
            let type = h & 0x1F
            if (1...5).contains(type) {
                if h & 0x60 != 0 { return false }
                slices += 1
            }
            i += lengthSize + len
        }
        return slices > 0
    }
}

/// VT destination size divisor (Program monitor quality popup).
public enum DecodeScale: Sendable, Hashable {
    case full, half, quarter
    var divisor: Int { self == .full ? 1 : self == .half ? 2 : 4 }
}
