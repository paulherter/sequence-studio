import AppKit
import SQCore
import Testing
@testable import SQTimelineUI

/// One rule for "this track does not contribute": hidden video and muted audio dim their clips.
@MainActor @Suite struct InactiveTrackDimTests {
    @Test func activeTracksAreNotDimmed() {
        #expect(TimelineView.clipFade(clipEnabled: true, track: Track(kind: .video), selected: false) == nil)
        #expect(TimelineView.clipFade(clipEnabled: true, track: Track(kind: .audio), selected: false) == nil)
    }

    @Test func hiddenVideoDimsAndMutedAudioDims() {
        var v = Track(kind: .video); v.isVisible = false
        var a = Track(kind: .audio); a.isMuted = true
        #expect(TimelineView.clipFade(clipEnabled: true, track: v, selected: false) == TimelineView.inactiveTrackFade)
        #expect(TimelineView.clipFade(clipEnabled: true, track: a, selected: false) == TimelineView.inactiveTrackFade)
    }

    @Test func selectedClipKeepsAReadableOutline() {
        var v = Track(kind: .video); v.isVisible = false
        let f = TimelineView.clipFade(clipEnabled: true, track: v, selected: true)
        #expect(f == TimelineView.inactiveTrackSelectedFade)
        #expect(f! < TimelineView.inactiveTrackFade)
    }

    @Test func mutedVideoAndHiddenAudioFlagsDoNotDim() {
        var v = Track(kind: .video); v.isMuted = true
        var a = Track(kind: .audio); a.isVisible = false
        #expect(TimelineView.clipFade(clipEnabled: true, track: v, selected: false) == nil)
        #expect(TimelineView.clipFade(clipEnabled: true, track: a, selected: false) == nil)
    }

    @Test func disabledClipStillFades() {
        #expect(TimelineView.clipFade(clipEnabled: false, track: Track(kind: .video), selected: false) == TimelineView.disabledClipFade)
    }
}
