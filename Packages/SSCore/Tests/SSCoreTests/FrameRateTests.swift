import Testing
@testable import SSCore

@Suite struct FrameRateTests {
    @Test func cfrSnapsToStandard() {
        // 300 frames over 10.01 s = 29.97 fps
        #expect(FrameRate.sequenceFrameDuration(frameCount: 300, duration: Time(1001, 100)) == Time(1001, 30000))
        #expect(FrameRate.sequenceFrameDuration(frameCount: 240, duration: Time(10, 1)) == Time(1, 24))
        #expect(FrameRate.sequenceFrameDuration(frameCount: 1800, duration: Time(30, 1)) == Time(1, 60))
    }

    @Test func nearStandardWithinOnePercentSnaps() {
        // 29.8 fps is within 1 % of 29.97
        #expect(FrameRate.sequenceFrameDuration(frameCount: 298, duration: Time(10, 1)) == Time(1001, 30000))
        // 23.9 fps is within 1 % of 23.976
        #expect(FrameRate.sequenceFrameDuration(frameCount: 239, duration: Time(10, 1)) == Time(1001, 24000))
    }

    @Test func farFromStandardUsesFramesOverDuration() {
        // iPhone-like VFR clip: 27.12 fps, between 25 and 29.97 and more than 1 % from both
        let fd = FrameRate.sequenceFrameDuration(frameCount: 2712, duration: Time(100, 1))
        #expect(fd == Time(100, 2712))
        let fps = Double(fd.timescale) / Double(fd.value)
        #expect(abs(fps - 27.12) < 0.001)
    }

    @Test func degenerateInputFallsBackTo30() {
        #expect(FrameRate.sequenceFrameDuration(frameCount: 0, duration: Time(1, 1)) == Time(1, 30))
        #expect(FrameRate.sequenceFrameDuration(frameCount: 10, duration: .zero) == Time(1, 30))
    }
}
