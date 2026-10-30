import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// F7.3: the file's pixel aspect tag and thumbnails in the shape chosen for the media item.

private func par(_ h: Any, _ v: Any) -> [String: Any] {
    [kCMFormatDescriptionExtension_PixelAspectRatio as String: [
        kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: h,
        kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: v]]
}

@Test func pixelAspectTagIsReadAndReduced() {
    #expect(PixelAspectTag.pixelAspect(extensions: par(4, 3)) == PixelAspect(4, 3))
    #expect(PixelAspectTag.pixelAspect(extensions: par(NSNumber(value: 40), NSNumber(value: 33))) == PixelAspect(40, 33))
    #expect(PixelAspectTag.pixelAspect(extensions: par(2, 2)) == .square)
}

@Test func missingOrBrokenPixelAspectTagIsSquare() {
    #expect(PixelAspectTag.pixelAspect(extensions: [:]) == .square)
    #expect(PixelAspectTag.pixelAspect(extensions: par(0, 1)) == .square)
    #expect(PixelAspectTag.pixelAspect(extensions: par(1, 0)) == .square)
    #expect(PixelAspectTag.pixelAspect(extensions: par(100, 1)) == .square)
    #expect(PixelAspectTag.pixelAspect(extensions: par("4", "3")) == .square)
}

@Test func formatDescriptionTagReachesTheTrackInfo() throws {
    var fd: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 1440, height: 1080,
                                   extensions: par(4, 3) as CFDictionary, formatDescriptionOut: &fd)
    let format = try #require(fd)
    #expect(PixelAspectTag.pixelAspect(of: format) == PixelAspect(4, 3))
    let v = try MediaImporter.videoInfo(format: format, index: SampleIndex(entries: []))
    #expect(v.pixelAspect == PixelAspect(4, 3) && v.pixelAspectOverride == nil)
    #expect(v.width == 1440 && v.displayWidth == 1920)
}

@Test func thumbnailKeySeparatesPixelAspects() {
    let id = UUID()
    let plain = ThumbnailKey(media: id, time: .zero, height: 90)
    let wide = ThumbnailKey(media: id, time: .zero, height: 90, pixelAspect: PixelAspect(2, 1))
    #expect(plain != wide)
    #expect(plain.fileName == "\(id.uuidString)_0_90.png")          // unchanged: the disk cache stays valid
    #expect(wide.fileName == "\(id.uuidString)_0_90_par2x1.png")
}

@Test func thumbnailTakesTheChosenPixelAspect() async throws {
    var s = TestClipSpec(); s.frameCount = 4   // 320x180, untagged
    let url = try await TestClipWriter.write(s)
    let t = Thumbnailer()
    let id = UUID()
    let plain = try await t.thumbnail(media: id, url: url, height: 90)
    #expect(plain.width == 160 && plain.height == 90)
    let wide = try await t.thumbnail(media: id, url: url, height: 90, pixelAspect: PixelAspect(2, 1))
    #expect(wide.width == 320 && wide.height == 90)
    let same = try await t.thumbnail(media: id, url: url, height: 90, pixelAspect: .square)
    #expect(same.width == 160)
}

/// A phone clip stored 320x180 and shown turned (180x320): 2:1 pixels make it 180x640, so at the same height the
/// thumbnail is half as wide, not twice.
@Test func rotatedSourceThumbnailNarrowsWithAWiderPixel() async throws {
    var s = TestClipSpec(); s.frameCount = 4; s.rotation = 90
    let url = try await TestClipWriter.write(s)
    let t = Thumbnailer()
    let id = UUID()
    let plain = try await t.thumbnail(media: id, url: url, height: 160)
    #expect(plain.width == 90 && plain.height == 160)
    let tall = try await t.thumbnail(media: id, url: url, height: 160, pixelAspect: PixelAspect(2, 1))
    #expect(tall.width == 45 && tall.height == 160)
    // The same shape as the engines' layer: desqueezed stored width x stored height, then the turn.
    let v = VideoTrackInfo(width: 320, height: 180, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 30),
                           isVariableFrameRate: false, rotation: 90, pixelAspectOverride: PixelAspect(2, 1))
    #expect(v.desqueezedWidth == 640 && v.displayWidth == 180 && v.displayHeight == 640)
    #expect(tall.width * v.displayHeight == tall.height * v.displayWidth)
}
