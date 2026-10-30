import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@MainActor @Suite struct WaveformTintTests {
    private func clip(_ tag: AudioTag? = nil) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        c.audioTag = tag
        return c
    }

    @Test func untaggedRowIsNeutral() {
        let t = Track(kind: .audio)
        #expect(WaveformTint.role(of: t, clips: [clip(), clip()]) == nil)
    }

    @Test func trackRoleAppliesToUntaggedClips() {
        var t = Track(kind: .audio)
        t.audioRole = .music
        #expect(WaveformTint.role(of: t, clips: [clip(), clip()]) == .music)
    }

    @Test func clipTagOverridesAndMixedRowsStayNeutral() {
        var t = Track(kind: .audio)
        t.audioRole = .music
        #expect(WaveformTint.role(of: t, clips: [clip(.sfx), clip(.sfx)]) == .sfx)
        #expect(WaveformTint.role(of: t, clips: [clip(.sfx), clip()]) == nil)
    }

    @Test func eachRoleHasItsOwnInk() {
        let inks = AudioTag.allCases.map { WaveformTint.color(for: $0) }
        #expect(inks[0] != inks[1] && inks[1] != inks[2] && inks[0] != inks[2])
        #expect(WaveformTint.color(for: nil) == WaveformTileCache.color)
    }
}
