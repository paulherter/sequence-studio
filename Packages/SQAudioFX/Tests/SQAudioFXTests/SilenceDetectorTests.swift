import Testing
import SQCore
@testable import SQAudioFX

@Suite struct SilenceDetectorTests {
    // 10 ms windows: 0.5 s loud, 0.6 s quiet (-60 dB), 0.3 s loud, 0.1 s quiet at the end.
    private func levels() -> [Float] {
        Array(repeating: 0.5, count: 50) + Array(repeating: 0.001, count: 60) + Array(repeating: 0.5, count: 30)
            + Array(repeating: 0.001, count: 10)
    }
    private let window = Time(1, 100)

    @Test func findsPausesAboveTheMinimumLength() {
        let r = SilenceDetector.silences(levels: levels(), window: window, thresholdDB: -40, minimumLength: Time(1, 2))
        #expect(r == [TimeRange(start: Time(5, 10), duration: Time(6, 10))])
    }

    @Test func shorterPausesAreIgnoredAndEdgePausesCount() {
        let r = SilenceDetector.silences(levels: levels(), window: window, thresholdDB: -40, minimumLength: Time(1, 20))
        #expect(r.count == 2 && r[1] == TimeRange(start: Time(14, 10), duration: Time(1, 10)))
    }

    @Test func thresholdDecidesWhatIsSilent() {
        #expect(SilenceDetector.silences(levels: levels(), window: window, thresholdDB: -80, minimumLength: Time(1, 10)).isEmpty)
        #expect(SilenceDetector.silences(levels: [], window: window, thresholdDB: -40, minimumLength: .zero).isEmpty)
    }
}
