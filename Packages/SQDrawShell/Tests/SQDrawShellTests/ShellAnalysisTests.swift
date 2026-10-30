import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellAnalysisTests {
    private func host() -> ShellHost {
        let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1))
        let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var v = Track(kind: .video)
        try! v.overwrite(c)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [v, Track(kind: .audio)])
        return ShellHost(session: EditorSession(project: Project(name: "P", media: [m], timelines: [tl])), map: .premiereDefault)
    }

    private struct Cuts: AnalysisBackend {
        func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? { [Time(2, 1)] }
    }

    @Test func theAnalysisCommandsLeaveTheNotYetSharedList() {
        for c in [EditorCommand.findSceneChanges, .stabilize, .autoReframe, .matchColorToClip, .nextWeakTracking, .quickApply] { #expect(!ShellHost.notYetShared.contains(c)) }
    }

    @Test func sceneChangesAnswerWithoutABackendInsteadOfFlashingNotYetShared() {
        let h = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        #expect(h.enabled(.findSceneChanges))
        #expect(h.execute(.findSceneChanges))
        #expect(lines == ["Find Scene Changes is not available on this computer yet."])
    }

    @Test func sceneChangesRunThroughTheBackendWithAJobLineThatClears() async throws {
        let h = host()
        h.analysisBackend = Cuts()
        var jobs: [String?] = []
        h.onJob = { jobs.append($0) }
        #expect(h.execute(.findSceneChanges))
        #expect(h.menuState().titles[.findSceneChanges] == "Cancel Find Scene Changes")
        for _ in 0..<500 where h.analysis.isFindingSceneChanges { try await Task.sleep(for: .milliseconds(4)) }
        #expect(jobs.first == "Find Scene Changes: reading “c”…")
        #expect(jobs.last! == nil)
        #expect(h.session.activeTimeline!.proposedCuts.count == 1)
    }

    @Test func withoutTargetsTheAnalysisCommandsAreDisabled() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        #expect(!h.enabled(.findSceneChanges) && !h.enabled(.autoReframe) && !h.enabled(.stabilize))
    }

    // MARK: Match Color, Weak Tracking, Quick Apply

    @Test func matchColorWithoutAClipToMatchSaysWhy() {
        let h = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        h.frameSampler = nil
        #expect(h.enabled(.matchColorToClip))
        #expect(h.execute(.matchColorToClip))
        #expect(lines == [SQL10n.string(EditorSession.colorMatchNoReference)])
    }

    @Test func nextWeakTrackingSaysWhenThereIsNoTrackedMask() {
        let h = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        #expect(h.execute(.nextWeakTracking))
        h.magicHealth = MagicTrackHealthCache(samples: { _ in [] })
        #expect(h.execute(.nextWeakTracking))
        #expect(lines == ["No tracked Magic mask in this sequence.", "No tracked Magic mask in this sequence."])
    }

    @Test func quickApplyOpensSearchesAndAppliesAnEffectToTheSelectedClip() throws {
        let h = host()
        h.quickApplyItems = {
            QuickApplyCatalog.items(effects: [(ClipEffect.gaussianBlurKind, "Gaussian Blur")], builtInPresets: [], presets: [])
        }
        h.size = CGSize(width: 1280, height: 800)
        let id = h.session.activeTimeline!.tracks[0].clips[0].id
        h.session.select(clips: [id], captions: [])
        #expect(h.execute(.quickApply))
        let popup = try #require(h.quickApply)
        #expect(popup.frame.width == QuickApplyPopup.width && popup.frame.midX == 640)
        for ch in "gblur" { #expect(h.handle(.keyDown(.character(ch), modifiers: []), scale: 1)) }
        #expect(popup.model.results.first?.title == "Gaussian Blur")
        #expect(h.handle(.keyDown(.enter, modifiers: []), scale: 1))
        #expect(h.quickApply == nil)
        #expect(h.session.activeTimeline!.tracks[0].clips[0].effects.contains { $0.kind == ClipEffect.gaussianBlurKind })
    }

    @Test func quickApplyClosesOnEscapeAndOnAPressOutsideAndTheCommandToggles() throws {
        let h = host()
        h.quickApplyItems = { [] }
        h.size = CGSize(width: 1280, height: 800)
        #expect(h.execute(.quickApply))
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(h.quickApply == nil)
        #expect(h.execute(.quickApply))
        #expect(h.handle(.mouseDown(x: 5, y: 790, modifiers: []), scale: 1))
        #expect(h.quickApply == nil)
        #expect(h.execute(.quickApply))
        #expect(h.execute(.quickApply))
        #expect(h.quickApply == nil)
    }

    @Test func aTransitionRowAsksStartOrEndWhenClipsAreSelected() throws {
        let h = host()
        h.quickApplyItems = {
            QuickApplyCatalog.items(effects: [(EffectDragPayload.transitionID(.crossDissolve), "Cross Dissolve")], builtInPresets: [], presets: [])
        }
        h.size = CGSize(width: 1280, height: 800)
        h.session.select(clips: [h.session.activeTimeline!.tracks[0].clips[0].id], captions: [])
        #expect(h.execute(.quickApply))
        let popup = try #require(h.quickApply)
        for ch in "cross" { _ = h.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        _ = h.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(popup.model.pendingTransition?.title == "Cross Dissolve")
        _ = h.handle(.keyDown(.left, modifiers: []), scale: 1)
        #expect(popup.model.transitionEnd == .start)
        _ = h.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(popup.model.pendingTransition == nil && h.quickApply != nil)
    }
}
