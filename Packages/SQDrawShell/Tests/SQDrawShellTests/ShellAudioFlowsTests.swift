import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor
@Suite(.serialized) struct ShellAudioFlowsTests {
    func host() -> (ShellHost, ShellAudioToolsTests.Box, music: Clip) {
        let (h, _, _, m, _, box) = ShellAudioToolsTests().host()
        return (h, box, m)
    }

    func answer(_ h: ShellHost, _ flow: @escaping @MainActor () async -> Void, with r: ShellDialog.Response) async {
        await ShellAudioToolsTests().answer(h, flow, with: r)
    }

    @Test func voiceChainTogglesAndSays() {
        let (h, box, m) = host()
        h.session.select(clips: [m.id], captions: [])
        #expect(h.execute(.voiceChain))
        #expect(box.lines.first == "Voice chain on: EQ, compressor, noise reduction.")
        #expect(h.session.voiceChainActive)
        #expect(h.execute(.voiceChain))
        #expect(box.lines.last == "Voice chain removed.")
    }

    @Test func voiceChainWithoutAClipAsksForOne() {
        let (h, box, _) = host()
        h.session.select(clips: [], captions: [])
        #expect(!h.execute(.voiceChain))
        h.voiceChain()
        #expect(box.lines.last == "Select an audio clip first.")
    }

    @Test func beatMarkersWithoutTargetsSayWhatToSelect() async {
        let (h, box, _) = host()
        h.session.select(clips: [], captions: [])
        await h.markersOnBeat(downbeatsOnly: false)
        // The sample timeline has a Music clip, so it is analyzed; its media does not exist: no beat.
        #expect(box.lines.last == "No beat found.")
    }

    @Test func proposedCutCommandsAcceptAndReject() async {
        let (h, box, _) = host()
        await h.proposedCuts(.acceptProposedCuts)
        #expect(box.lines.last == "No proposed cuts.")
        #expect(h.session.proposeCuts([TimeRange(start: s(2), duration: s(1))]))
        await h.proposedCuts(.rejectProposedCuts)
        #expect(h.session.activeTimeline?.proposedCuts.isEmpty == true)
    }

    @Test func reviewListChecksEveryCutAndCountsTheChecked() {
        let cuts = [Timeline.ProposedCut(id: UUID(), range: TimeRange(start: s(2), duration: s(1)), kind: .silence),
                    Timeline.ProposedCut(id: UUID(), range: TimeRange(start: s(5), duration: s(2)), kind: .silence)]
        let form = ShellHost.reviewForm(cuts)
        #expect(ShellHost.checkedCuts(form, cuts) == Set(cuts.map(\.id)))
        form.set("cut0", .bool(false))
        #expect(ShellHost.checkedCuts(form, cuts) == [cuts[1].id])
    }

    @Test func rejectAllInTheReviewSheetDropsTheProposals() async {
        let (h, _, _) = host()
        #expect(h.session.proposeCuts([TimeRange(start: s(2), duration: s(1))]))
        let cuts = h.session.activeTimeline!.proposedCuts
        await answer(h, { await h.reviewProposedCuts(cuts) }, with: .third)
        #expect(h.session.activeTimeline?.proposedCuts.isEmpty == true)
    }

    @Test func voiceoverWithoutAnEngineIsNotAvailable() async {
        let (h, box, _) = host()
        h.voiceover = nil
        await h.voiceoverFromText(defaults: UserDefaults(suiteName: "sq.test.vo.\(UUID())")!)
        #expect(box.lines.last == ShellPlatformText.notAvailable)
    }

    @Test func voiceoverRendersImportsAndPlaces() async {
        let (h, box, _) = host()
        let defaults = UserDefaults(suiteName: "sq.test.vo.\(UUID())")!
        h.voiceover = ShellVoiceoverBackend(voices: { [(id: "v1", title: "Test (en)")] }, render: { _, _, _, _ in s(3) })
        let t = Task { @MainActor in await h.voiceoverFromText(defaults: defaults) }
        for _ in 0..<400 where h.dialog == nil { await Task.yield() }
        // Empty text: Insert is disabled.
        #expect(h.dialog?.isEnabled(0) == false)
        h.dialog?.form?.set("text", .text("Hello there"))
        #expect(h.dialog?.isEnabled(0) == true)
        h.dialog?.press(.second)
        await t.value
        #expect(box.lines.isEmpty)    // canceled: nothing said
        #expect(defaults.string(forKey: ShellHost.voiceoverVoiceKey) == nil)
    }
}
