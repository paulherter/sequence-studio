import Testing
@testable import SQCore

@Suite struct CoverFrameTests {
    private let fd = Time(1, 30)

    @Test func findsMarkerNamedCover() {
        let ms = [Marker(time: Time(1, 1), name: "Intro"), Marker(time: Time(5, 1), name: "Cover")]
        #expect(CoverFrame.time(markers: ms) == Time(5, 1))
    }
    @Test func nameMatchIgnoresCaseAndSpaces() {
        let ms = [Marker(time: Time(2, 1), name: "  cover ")]
        #expect(CoverFrame.time(markers: ms) == Time(2, 1))
    }
    @Test func earliestCoverWins() {
        let ms = [Marker(time: Time(9, 1), name: "Cover"), Marker(time: Time(3, 1), name: "Cover")]
        #expect(CoverFrame.time(markers: ms) == Time(3, 1))
    }
    @Test func noCoverMarkerGivesNil() {
        #expect(CoverFrame.time(markers: [Marker(time: Time(1, 1), name: "Cover art")]) == nil)
        #expect(CoverFrame.time(markers: []) == nil)
    }
    @Test func indexIsRelativeToRangeStart() {
        // Cover at 5 s, export range starts at 2 s: frame 90.
        #expect(CoverFrame.frameIndex(time: Time(5, 1), rangeStart: Time(2, 1), frameDuration: fd, frameCount: 1000) == 90)
    }
    @Test func indexFallsBackToFirstFrame() {
        #expect(CoverFrame.frameIndex(time: nil, rangeStart: .zero, frameDuration: fd, frameCount: 100) == 0)
    }
    @Test func indexClampsIntoTheExportedRange() {
        #expect(CoverFrame.frameIndex(time: Time(1, 1), rangeStart: Time(2, 1), frameDuration: fd, frameCount: 100) == 0)
        #expect(CoverFrame.frameIndex(time: Time(60, 1), rangeStart: .zero, frameDuration: fd, frameCount: 100) == 99)
        #expect(CoverFrame.frameIndex(time: Time(1, 1), rangeStart: .zero, frameDuration: fd, frameCount: 0) == 0)
    }
    @Test func coverFileNameSharesTheVideoStem() {
        #expect(CoverFrame.fileName(videoStem: "Trip", ext: "png") == "Trip Cover.png")
        #expect(CoverFrame.fileName(videoStem: "Trip", ext: "jpg") == "Trip Cover.jpg")
    }
}
