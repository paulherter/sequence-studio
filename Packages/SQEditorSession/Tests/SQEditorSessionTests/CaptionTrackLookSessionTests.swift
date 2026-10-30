import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

@MainActor private func makeSession(_ items: [CaptionItem]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    s.replaceCaptions(items)
    return s
}

private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(b, 1)), styleRef: "default")
}

/// Captions as a Premiere-like caption track: the Look edits the track, a selected caption overrides only itself.
@MainActor @Suite(.serialized) struct CaptionTrackLookSessionTests {
    private func tracks(_ s: EditorSession) -> [CaptionTrack] { s.activeTimeline?.captionTracks ?? [] }

    @Test func creatingCaptionsMakesTrackNamedCaptions1() {
        let s = makeSession([])
        #expect(s.addCaptions([item("a", 0, 2)]))
        #expect(tracks(s).map(\.name) == ["Captions 1"])
        #expect(s.currentCaptionTrack?.name == "Captions 1")
    }

    @Test func trackLookEditChangesEveryCaptionOfTheTrack() {
        let s = makeSession([item("a", 0, 2), item("b", 2, 4)])
        #expect(s.editCaptionStyle(.size(88), scope: .all))
        let refs = Set(tracks(s)[0].items.map(\.styleRef))
        #expect(refs.count == 1)
        #expect(s.captionStyleState(scope: .all)?.style.size == 88)
    }

    @Test func selectedEditOverridesOnlyThatCaptionAndResetHandsItBack() throws {
        let s = makeSession([item("a", 0, 2), item("b", 2, 4)])
        let b = try #require(tracks(s)[0].items.last?.id)
        let a = try #require(tracks(s)[0].items.first?.id)
        s.select(clips: [], captions: [b])
        #expect(s.editCaptionStyle(.size(120), scope: .selected))
        let items = tracks(s)[0].items
        #expect(items.first { $0.id == b }?.styleOverridden == true)
        #expect(items.first { $0.id == a }?.styleOverridden == false)
        #expect(s.selectedCaptionsHaveOverrides)
        #expect(s.resetSelectedCaptionsToTrackLook())
        let after = tracks(s)[0].items
        #expect(after.allSatisfy { !$0.styleOverridden })
        #expect(after.first { $0.id == b }?.styleRef == after.first { $0.id == a }?.styleRef)
        #expect(!s.selectedCaptionsHaveOverrides)
        #expect(s.undo())
        #expect(tracks(s)[0].items.first { $0.id == b }?.styleOverridden == true)
    }

    @Test func secondTrackHasItsOwnLookAndLeavesTheFirstAlone() throws {
        let s = makeSession([item("a", 0, 2)])
        let second = try #require(s.addCaptionTrack())
        #expect(tracks(s).map(\.name) == ["Captions 1", "Captions 2"])
        #expect(s.currentCaptionTrack?.id == second)
        let c = try #require(s.addCaptionAtPlayhead())
        #expect(tracks(s)[1].items.map(\.id) == [c])           // the new caption went to the focused track
        s.select(clips: [], captions: [])
        let firstBefore = tracks(s)[0].items.map(\.styleRef)
        #expect(s.editCaptionStyle(.size(99), scope: .all))
        #expect(tracks(s)[0].items.map(\.styleRef) == firstBefore)
        #expect(tracks(s)[1].styleRef.contains("own-trk-"))
        #expect(tracks(s)[1].items.allSatisfy { $0.styleRef == tracks(s)[1].styleRef })
        s.focusCaptionTrack(tracks(s)[0].id)
        #expect(s.currentCaptionTrack?.name == "Captions 1")
        #expect(s.captionStyleState(scope: .all)?.style.size != 99)
    }

    @Test func selectingACaptionSwitchesTheLookToItsTrack() throws {
        let s = makeSession([item("a", 0, 2)])
        _ = s.addCaptionTrack()
        _ = s.addCaptionAtPlayhead()
        let first = try #require(tracks(s)[0].items.first?.id)
        s.select(clips: [], captions: [first])
        #expect(s.currentCaptionTrack?.name == "Captions 1")
    }
}
