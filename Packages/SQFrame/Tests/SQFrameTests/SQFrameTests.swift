import Testing
import SQCore
import SQFrame

/// A platform-free storage for the portable tests (Windows later plugs in a D3D texture / FFmpeg frame the same way).
private final class TestStorage: SQFrameStorage {
    let tag: Int
    init(_ tag: Int) { self.tag = tag }
}

@Suite struct SQFrameTests {
    @Test func holdsSizeFormatColorTimeAndStorage() {
        let s = TestStorage(7)
        let f = SQFrame(width: 1920, height: 1080, pixelFormat: .nv12, colorSpace: .rec709,
                        presentationTime: Time(1001, 30000), storage: s)
        #expect(f.width == 1920 && f.height == 1080)
        #expect(f.pixelFormat == .nv12)
        #expect(f.colorSpace == .rec709)
        #expect(f.presentationTime == Time(1001, 30000))
        #expect((f.storage as? TestStorage) === s)
    }

    @Test func defaultsAreUnspecifiedColorAndTimeZero() {
        let f = SQFrame(width: 2, height: 2, pixelFormat: .bgra8, storage: TestStorage(0))
        #expect(f.colorSpace == .unspecified)
        #expect(f.presentationTime == .zero)
    }

    @Test func copiesShareTheSameStorage() {
        let s = TestStorage(1)
        let a = SQFrame(width: 4, height: 4, pixelFormat: .rgba16f, storage: s)
        var b = a
        b.colorSpace = .linearRec709
        #expect((b.storage as? TestStorage) === s)
        #expect(a.colorSpace == .unspecified)
    }

    @Test func retimingKeepsPixels() {
        let s = TestStorage(2)
        let a = SQFrame(width: 8, height: 6, pixelFormat: .p010, presentationTime: Time(1, 25), storage: s)
        let b = a.withPresentationTime(Time(2, 25))
        #expect(b.presentationTime == Time(2, 25))
        #expect(b.width == 8 && b.height == 6 && b.pixelFormat == .p010)
        #expect((b.storage as? TestStorage) === s)
    }

    @Test func pixelFormatTraits() {
        #expect(SQFramePixelFormat.nv12.planeCount == 2 && SQFramePixelFormat.nv12.isYCbCr)
        #expect(SQFramePixelFormat.p010FullRange.planeCount == 2 && SQFramePixelFormat.p010FullRange.isFullRange)
        #expect(!SQFramePixelFormat.nv12.isFullRange)
        #expect(SQFramePixelFormat.bgra8.planeCount == 1 && !SQFramePixelFormat.bgra8.isYCbCr)
        #expect(SQFramePixelFormat.rgba16f.planeCount == 1 && !SQFramePixelFormat.rgba16f.isYCbCr)
        #expect(SQFramePixelFormat.p010.bitsPerComponent == 10 && SQFramePixelFormat.nv12.bitsPerComponent == 8)
        #expect(SQFramePixelFormat.rgba16f.bitsPerComponent == 16 && SQFramePixelFormat.rgba32f.bitsPerComponent == 32)
        #expect(SQFramePixelFormat.other(0x2676_7630).planeCount == nil)
    }
}
