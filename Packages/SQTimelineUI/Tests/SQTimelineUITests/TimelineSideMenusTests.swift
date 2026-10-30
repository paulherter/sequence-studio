import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@MainActor
@Suite struct TimelineSideMenusTests {
    private func titles(_ rows: [SQMenuItem]) -> [String] { rows.map { $0.kind == .separator ? "-" : $0.title } }

    @Test func volumeKeyRunsDelete() {
        var ran = 0
        let rows = TimelineSideMenus.volumeKey { ran += 1 }
        #expect(titles(rows) == ["Delete Keyframe"])
        rows[0].action?()
        #expect(ran == 1)
    }

    @Test func speedKeyAddsCurveOnlyOnRamp() {
        let plain = TimelineSideMenus.speedKey(deleteTitle: "Delete Speed Keyframe", isRamp: false, curve: {}, delete: {})
        #expect(titles(plain) == ["Delete Speed Keyframe"])
        let ramp = TimelineSideMenus.speedKey(deleteTitle: "Delete Speed Transition", isRamp: true, curve: {}, delete: {})
        #expect(titles(ramp) == ["Speed Transition Curve…", "-", "Delete Speed Transition"])
    }

    @Test func transitionOrder() {
        let rows = TimelineSideMenus.transition(setDuration: {}, saveAsPreset: {}, delete: {})
        #expect(titles(rows) == ["Set Transition Duration…", "Save as Preset…", "-", "Delete"])
    }

    @Test func trackHeaderVideoAndLocked() {
        var track = Track(kind: .video, name: "V1")
        var rows = TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {}, toggleDucking: {})
        #expect(titles(rows) == ["Add Video Track", "Add Audio Track", "Delete Track", "-", "Rename…"])
        #expect(rows[2].isEnabled)
        track.isLocked = true
        rows = TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {}, toggleDucking: {})
        #expect(!rows[2].isEnabled)
    }

    @Test func trackHeaderSelectAllClipsRow() {
        var hit = false
        var track = Track(kind: .video, name: "V1")
        func rows() -> [SQMenuItem] {
            TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {}, toggleDucking: {},
                                          selectAll: { hit = true })
        }
        #expect(rows()[0].title == "Select All Clips on Track" && !rows()[0].isEnabled)   // empty track
        let one = Time(1, 1)
        track = Track(kind: .video, clips: [Clip(name: "c", media: UUID(), kind: .video,
                      source: TimeRange(start: .zero, duration: one), start: .zero, mediaDuration: one)])
        #expect(rows()[0].isEnabled)
        rows()[0].action?()
        #expect(hit)
        track.isLocked = true
        #expect(!rows()[0].isEnabled)
    }

    @Test func trackHeaderAudioDucking() {
        var track = Track(kind: .audio, name: "A1")
        func ducking() -> SQMenuItem {
            TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {}, toggleDucking: {}).last!
        }
        #expect(ducking().title == "Live Ducking (Dialogue or Music tracks)")
        #expect(!ducking().isEnabled && !ducking().isChecked)
        track.audioRole = .music
        #expect(ducking().title == "Duck Under Dialogue")
        #expect(ducking().isEnabled && ducking().isChecked)
        track.audioRole = .dialogue
        track.isExcludedFromLiveDucking = true
        #expect(ducking().title == "Duck the Music")
        #expect(ducking().isEnabled && !ducking().isChecked)
        let rows = TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {}, toggleDucking: {})
        #expect(rows[5].title == "Volume and Pan…")
        var hit = false
        let withLevel = TimelineSideMenus.trackHeader(track: track, addVideo: {}, addAudio: {}, delete: {}, rename: {}, mix: {},
                                                      toggleDucking: {}, sequenceVolume: { hit = true })
        #expect(withLevel[6].title == "Sequence Volume…" && withLevel.last!.title == "Duck the Music")
        withLevel[6].action?()
        #expect(hit)
        let video = TimelineSideMenus.trackHeader(track: Track(kind: .video), addVideo: {}, addAudio: {}, delete: {}, rename: {},
                                                  mix: {}, toggleDucking: {}, sequenceVolume: {})
        #expect(!video.map(\.title).contains("Sequence Volume…"))
    }

    @Test func rulerRows() {
        let entries = RulerRangeEntry.entries(hasInOut: false)
        var cmds: [EditorCommand] = []
        let plain = TimelineSideMenus.ruler(hasMarkerAtPointer: false, entries: entries, addMarkerShortcut: "M",
                                            addMarker: {}, editMarker: {}, range: { cmds.append($0) }, deleteMarker: {})
        #expect(titles(plain) == ["Add Marker", "-", "Mark In", "Mark Out", "Remove In and Out"])
        #expect(plain[0].shortcut == "M")
        #expect(!plain[4].isEnabled)
        plain[2].action?()
        #expect(cmds == [.markIn])
        let onMarker = TimelineSideMenus.ruler(hasMarkerAtPointer: true, entries: entries, addMarkerShortcut: "",
                                               addMarker: {}, editMarker: {}, range: { _ in }, deleteMarker: {})
        #expect(titles(onMarker) == ["Add Marker", "Edit Marker…", "-", "Mark In", "Mark Out", "Remove In and Out", "-", "Delete Marker"])
    }
}
