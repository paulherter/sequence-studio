import Testing
@testable import SQUIKit

@Suite struct SQAccessibilityTextTests {
    @Test func trackLabelListsStates() {
        #expect(SQAccessibilityText.track(kind: "Video", label: "V1", clipCount: 1) == "Video track V1, 1 clip")
        #expect(SQAccessibilityText.track(kind: "Audio", label: "A2", clipCount: 3, locked: true, muted: true)
            == "Audio track A2, 3 clips, locked, muted")
    }

    @Test func clipLabel() {
        #expect(SQAccessibilityText.clip(name: "Take 1", start: "00:00:01:00", length: "00:00:02:00")
            == "Take 1, from 00:00:01:00, length 00:00:02:00")
        #expect(SQAccessibilityText.clip(name: "", start: "a", length: "b", offline: true)
            == "Untitled clip, from a, length b, media offline")
    }

    @Test func monitorAndMeterValues() {
        #expect(SQAccessibilityText.monitorValue(isPlaying: true, timecode: "00:00:05:12") == "Playing, at 00:00:05:12")
        #expect(SQAccessibilityText.playState(isPlaying: false) == "Paused")
        #expect(SQAccessibilityText.meterChannel(name: "Left", dB: -12.34, clipped: false) == "Left, minus 12.3 dB")
        #expect(SQAccessibilityText.meterChannel(name: "Left", dB: nil, clipped: false) == "Left, silent")
        #expect(SQAccessibilityText.meterChannel(name: "Left", dB: -3, clipped: true) == "Left, clipped")
        #expect(SQAccessibilityText.meterValue(["a", "b"]) == "a. b")
        #expect(SQAccessibilityText.channelName("M") == "Mono")
    }
}
