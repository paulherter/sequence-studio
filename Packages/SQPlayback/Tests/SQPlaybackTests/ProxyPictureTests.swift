import Testing
import SQCore
import SQMedia
@testable import SQPlayback

@Suite struct ProxyPictureTests {
    private func index(_ n: Int, start: Int64 = 0) -> SampleIndex {
        SampleIndex(entries: (0..<n).map { i in
            let t = Time(start + Int64(i), 30)
            return SampleIndex.Entry(pts: t, dts: t, duration: Time(1, 30), isSync: true, decodeOrdinal: i)
        })
    }

    @Test func proxyWithSameFrameTimesStandsIn() {
        #expect(ProxyPicture.hasOriginalFrameTimes(proxy: index(10), original: index(10)))
    }

    @Test func differentCountOrEmptyKeepsTheOriginal() {
        #expect(!ProxyPicture.hasOriginalFrameTimes(proxy: index(9), original: index(10)))
        #expect(!ProxyPicture.hasOriginalFrameTimes(proxy: index(0), original: index(0)))
    }
}
