import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQUIKit

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@MainActor @Suite struct RemoveSilencesTests {
    @Test func removeCutsMusicOnOtherTracksInOneUndoStep() {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(12)), start: .zero)
        var vt = Track(kind: .video), at = Track(kind: .audio), mt = Track(kind: .audio)
        try! vt.overwrite(v); try! at.overwrite(a); try! mt.overwrite(m)
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [vt, at, mt])]))
        let cuts = sess.silenceCuts(for: [a], silences: { _ in [TimeRange(start: s(2), duration: s(2)), TimeRange(start: s(6), duration: s(2))] },
                                    padding: Time(1, 10))
        #expect(cuts.count == 2)
        let removed = cuts.reduce(Time.zero) { $0 + $1.duration }
        let depth = sess.undoDepth
        #expect(sess.removeSilences(cuts: cuts, from: [a]))
        #expect(sess.undoDepth == depth + 1)
        let tl = sess.activeTimeline!
        #expect(tl.tracks[0].end == s(10) - removed && tl.tracks[1].end == s(10) - removed)
        #expect(tl.tracks[2].end == s(12) - removed)                      // music was cut with it, still under the same words
        #expect(tl.tracks[0].clips.map(\.start) == tl.tracks[1].clips.map(\.start))
        sess.undo()
        #expect(sess.activeTimeline!.tracks.map(\.end) == [s(10), s(10), s(12)])
    }

    @Test func slidersReportRoundedSettingsAndLivePreview() {
        var seen: [SilenceSettings] = []
        let ui = RemoveSilencesDialog.makeView(initial: SilenceSettings(thresholdDB: -35, minimumMs: 350, paddingMs: 100)) { s in
            seen.append(s)
            return (3, Time(21, 10))
        }
        let c = ui.controller
        #expect(c.settings == SilenceSettings(thresholdDB: -35, minimumMs: 350, paddingMs: 100))
        #expect(c.labels == ["-35", "350", "100","3 silences, 2.1 s will be removed."])
        c.minimum.value = 437; c.threshold.value = -41.6; c.padding.value = 237
        c.refresh()
        #expect(c.settings == SilenceSettings(thresholdDB: -42, minimumMs: 450, paddingMs: 240))
        #expect(seen.last == c.settings)
        #expect(c.labels.prefix(3) == ["-42", "450", "240"])      // fields show what is applied
        c.minimum.field.resetToDefault(); c.threshold.field.resetToDefault(); c.padding.slider.resetToDefault()
        #expect(c.settings == .standard)                                    // double-click: -35 dB, 350 ms, 70 ms
    }

    @Test func outOfRangeRememberedValuesAreClamped() {
        let ui = RemoveSilencesDialog.makeView(initial: SilenceSettings(thresholdDB: -90, minimumMs: 10, paddingMs: 0)) { _ in (0, .zero) }
        #expect(ui.controller.settings == SilenceSettings(thresholdDB: -60, minimumMs: 100, paddingMs: 0))
        #expect(ui.controller.labels.last == "No silences found.")
    }

    @Test func timelineHoldsThePreviewRanges() {
        let v = TimelineView()
        v.silencePreview = [TimeRange(start: s(1), duration: s(1))]
        #expect(v.silencePreview.count == 1)
        v.silencePreview = []
        #expect(v.silencePreview.isEmpty)
    }
}
