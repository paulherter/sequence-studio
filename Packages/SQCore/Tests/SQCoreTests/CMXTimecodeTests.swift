import Testing
@testable import SQCore

@Suite struct CMXTimecodeTests {
    @Test func nonDropRoundTrip() {
        let tc = CMXTimecode(nominalRate: 25)
        #expect(tc.frames("01:00:00:00") == 90_000)
        #expect(tc.string(frames: 90_000) == "01:00:00:00")
        #expect(tc.frames("00:00:01:12") == 37)
        #expect(tc.string(frames: 37) == "00:00:01:12")
        #expect(tc.frames("garbage") == nil)
    }

    @Test func dropFrameKnownValues() {
        let tc = CMXTimecode(nominalRate: 30, dropFrame: true)
        // One hour of 29.97 drop frame is 107_892 frames.
        #expect(tc.frames("01:00:00;00") == 107_892)
        #expect(tc.string(frames: 107_892) == "01:00:00;00")
        // Frame numbers 00 and 01 do not exist at 00:01:00 (except every tenth minute).
        #expect(tc.frames("00:01:00;02") == 1800)
        #expect(tc.string(frames: 1800) == "00:01:00;02")
        #expect(tc.string(frames: 1799) == "00:00:59;29")
        #expect(tc.frames("00:10:00;00") == 17_982)
        for n in stride(from: Int64(0), to: 200_000, by: 997) {
            #expect(tc.frames(tc.string(frames: n)) == n)
        }
    }

    @Test func rateFromFrameDuration() {
        let ntsc = CMXTimecode(frameDuration: Time(1001, 30_000))
        #expect(ntsc.nominalRate == 30 && ntsc.dropFrame)
        let film = CMXTimecode(frameDuration: Time(1001, 24_000))
        #expect(film.nominalRate == 24 && !film.dropFrame)
        let pal = CMXTimecode(frameDuration: Time(1, 25))
        #expect(pal.nominalRate == 25 && !pal.dropFrame)
        #expect(CMXTimecode(frameDuration: Time(1001, 60_000)).nominalRate == 60)
    }
}
