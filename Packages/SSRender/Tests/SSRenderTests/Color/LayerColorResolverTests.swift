import Foundation
import Testing
import SSCore
@testable import SSRender

@Suite struct LayerColorResolverTests {
    let slogID = UUID(), rec709ID = UUID()

    func make(provider: StubProvider? = nil) -> LayerColorResolver {
        let slog = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine)
        let plain = MediaInfo(duration: Time(1, 1), detectedColorSpace: .rec709)
        let (s, r) = (slogID, rec709ID)
        return LayerColorResolver(lutProvider: provider) { $0 == s ? slog : ($0 == r ? plain : nil) }
    }

    @Test func identityRec709TakesFastPath() {
        let r = make()
        #expect(r.pipeline(for: .default, media: rec709ID) == nil)
        #expect(r.pipeline(for: .default, media: UUID()) == nil)          // unknown media = Rec.709
        var c = ClipColor.default; c.correction.exposure = 1
        #expect(r.pipeline(for: c, media: rec709ID) != nil)
        c = .default; c.bypassCorrection = true; c.correction.exposure = 1
        #expect(r.pipeline(for: c, media: rec709ID) == nil)               // bypassed correction is identity
    }

    @Test func slog3GetsPipelineAndCachesIt() {
        let r = make()
        let p = r.pipeline(for: .default, media: slogID)
        #expect(p?.source == .sLog3SGamut3Cine)
        #expect(r.cachedCount == 1)
        _ = r.pipeline(for: .default, media: slogID)
        #expect(r.cachedCount == 1)
        var c = ClipColor.default; c.correction.tint = 10
        _ = r.pipeline(for: c, media: slogID)
        #expect(r.cachedCount == 2)
        r.invalidate()
        #expect(r.cachedCount == 0)
    }

    @Test func sourceOverrideToRec709IsIdentity() {
        let r = make()
        var c = ClipColor.default; c.source = .rec709
        #expect(r.pipeline(for: c, media: slogID) == nil)
        c.source = .hlgBT2020
        #expect(r.pipeline(for: c, media: rec709ID)?.source == .hlgBT2020)
    }
}
