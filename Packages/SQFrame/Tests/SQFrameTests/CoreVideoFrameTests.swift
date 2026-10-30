#if canImport(CoreVideo)
import CoreVideo
import Testing
import SQCore
import SQFrame
import SQFrameCoreVideo

private func makeBuffer(_ format: OSType, _ w: Int = 16, _ h: Int = 8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(nil, w, h, format, attrs, &pb)
    return pb!
}

private final class ForeignStorage: SQFrameStorage {}

@Suite struct CoreVideoFrameTests {
    @Test func wrapAndUnwrapIsTheSameBufferWithoutCopy() {
        let pb = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32)
        let f = SQFrame(pixelBuffer: pb, presentationTime: Time(3, 30))
        #expect(f.pixelBuffer === pb)
        #expect(f.coreVideoBuffer === pb)
        #expect(f.width == 64 && f.height == 32)
        #expect(f.pixelFormat == .nv12)
        #expect(f.presentationTime == Time(3, 30))
        #expect(f.colorSpace == .unspecified)
    }

    /// The storage is one reference: it sits in the existential's inline buffer, so wrapping allocates nothing.
    @Test func storageFitsTheExistentialInlineBuffer() {
        #expect(MemoryLayout<CoreVideoFrameStorage>.size <= 3 * MemoryLayout<Int>.size)
        #expect(MemoryLayout<CoreVideoFrameStorage>.alignment <= MemoryLayout<Int>.alignment)
    }

    @Test func foreignStorageHasNoCoreVideoBuffer() {
        let f = SQFrame(width: 2, height: 2, pixelFormat: .bgra8, storage: ForeignStorage())
        #expect(f.coreVideoBuffer == nil)
    }

    @Test func coreVideoFormatMapping() {
        let cases: [(OSType, SQFramePixelFormat)] = [
            (kCVPixelFormatType_32BGRA, .bgra8),
            (kCVPixelFormatType_32RGBA, .rgba8),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .nv12),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .nv12FullRange),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .p010),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, .p010FullRange),
            (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, .p210),
            (kCVPixelFormatType_64RGBAHalf, .rgba16f),
            (kCVPixelFormatType_128RGBAFloat, .rgba32f),
            (kCVPixelFormatType_4444AYpCbCr16, .ayuv16),
        ]
        for (code, format) in cases {
            #expect(SQFramePixelFormat(coreVideo: code) == format)
            #expect(format.coreVideoFormat == code)
        }
        let compressed: OSType = 0x2638_7630 // "&8v0", Apple's lossless-compressed NV12
        #expect(SQFramePixelFormat(coreVideo: compressed) == .other(compressed))
        #expect(SQFramePixelFormat.other(compressed).coreVideoFormat == compressed)
    }

    @Test func wrappingReadsTheBufferFormat() {
        let pb = makeBuffer(kCVPixelFormatType_64RGBAHalf, 10, 6)
        let f = SQFrame(pixelBuffer: pb, colorSpace: .linearRec709)
        #expect(f.pixelFormat == .rgba16f && f.width == 10 && f.height == 6 && f.colorSpace == .linearRec709)
    }
}
#endif
