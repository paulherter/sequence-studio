import Foundation
import SQAppShell
import SQCore
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQUIKit
import Testing

/// The timeline editor dialogs of the shared shells: the AppKit `EditorPanels` sheets (TrackMixDialog, PresetSaveSheet,
/// ColorMatteDialog) on the shared dialog.
@MainActor @Suite struct TimelineEditorDialogsTests {
    private static let fd = Time(1, 25)

    /// A session with one video clip (selected) on a video track and an audio track; spawned flows are collected so the
    /// test can answer their dialog.
    private func fixture() -> (EditorSession, ShellHost, TimelineEditorDialogs, Track.ID, Box) {
        var clip = Clip(name: "Shot", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Self.fd * 50), start: .zero)
        clip.animation.opacity = AnimatedProperty(0.5)
        let audio = Track(kind: .audio)
        let t = Timeline(name: "Main", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [clip]), audio])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        s.select(clips: [clip.id], captions: [])
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let box = Box()
        shell.spawn = { f in box.tasks.append(Task { @MainActor in await f() }) }
        return (s, shell, TimelineEditorDialogs(session: s, shell: shell), audio.id, box)
    }

    final class Box { var tasks: [Task<Void, Never>] = [] }

    /// Waits until a dialog shows, lets `fill` change it, presses `r` and waits for the flow.
    private func answer(_ shell: ShellHost, _ box: Box, with r: ShellDialog.Response,
                        _ fill: (ShellDialog) -> Void = { _ in }) async -> ShellDialog? {
        for _ in 0..<400 where shell.dialog == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let d = shell.dialog
        if let d { fill(d) }
        d?.press(r)
        for t in box.tasks { await t.value }
        return d
    }

    @Test func trackVolumeAndPanOKSetsTheTrackMix() async throws {
        let (s, shell, dialogs, audio, box) = fixture()
        #expect(dialogs.open(.trackMix(audio)) == true)
        let d = try #require(await answer(shell, box, with: .first) { d in
            d.form?.set("volume", .number(-6))
            d.form?.set("pan", .number(50))
        })
        #expect(d.messageText == "Track Volume and Pan")
        let track = try #require(s.activeTimeline?.tracks.first { $0.id == audio })
        #expect(track.volumeDB == -6)
        #expect(track.pan == 0.5)
    }

    @Test func cancelLeavesTheTrackMix() async throws {
        let (s, shell, dialogs, audio, box) = fixture()
        _ = dialogs.open(.trackMix(audio))
        _ = await answer(shell, box, with: .second) { $0.form?.set("volume", .number(-6)) }
        #expect(s.activeTimeline?.tracks.first { $0.id == audio }?.volumeDB == 0)
    }

    /// The Mac `PresetSaveSheet`: "Save as Preset", the informative line, unlabeled name field and anchor popup 400 wide.
    @Test func saveAsPresetIsTheMacSheet() async throws {
        let (s, shell, dialogs, _, box) = fixture()
        #expect(dialogs.open(.saveClipPreset) == true)
        let d = try #require(await answer(shell, box, with: .second))
        #expect(d.messageText == "Save as Preset")
        #expect(d.informativeText == "Saves Transform, Opacity and effects with their keyframes and easing.")
        let form = try #require(d.form)
        guard case .field(_, let label, let value, _) = form.rows[0], case .popup(_, let anchorLabel, _, _) = form.rows[1] else {
            Issue.record("unexpected rows"); return
        }
        #expect(label.isEmpty && anchorLabel.isEmpty && value == "Shot")
        #expect(form.controlWidths == ["name": 400, "anchor": 400])
    }

    /// The Mac `ColorMatteDialog`: XS card, informative line, Add puts the named matte on the timeline at the playhead.
    @Test func newColorMatteAddsTheNamedMatte() async throws {
        let (s, shell, dialogs, _, box) = fixture()
        #expect(dialogs.open(.newColorMatte) == true)
        let d = try #require(await answer(shell, box, with: .first) { $0.form?.set("name", .text("Black")) })
        #expect(d.width == 360)
        #expect(d.informativeText == "A flat color layer for when there is no video. It goes on the timeline at the playhead.")
        let names = s.activeTimeline?.tracks.flatMap(\.clips).map(\.name) ?? []
        #expect(names.contains("Black"))
    }

    @Test func otherRequestsAreNotTheirs() {
        let (_, _, dialogs, _, _) = fixture()
        #expect(dialogs.open(.revealInProject(media: UUID())) == nil)
    }

    /// The Mac `AnglesDialog` choices (Timeline Positions first, then In Points and Timecode) and the chosen sync is applied.
    @Test func anglesDialogOffersTheMacSyncChoices() async throws {
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Self.fd * 50), start: .zero)
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Self.fd * 50), start: .zero)
        let t = Timeline(name: "Main", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [a]), Track(kind: .video, clips: [b])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        s.select(clips: [a.id, b.id], captions: [])
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let box = Box()
        shell.spawn = { f in box.tasks.append(Task { @MainActor in await f() }) }
        let dialogs = TimelineEditorDialogs(session: s, shell: shell)
        dialogs.requestAnglesClip()
        let d = try #require(await answer(shell, box, with: .first) { $0.form?.set("sync", .index(1)) })
        guard case .popup(_, _, let options, _) = d.form?.rows[1] else { Issue.record("no sync popup"); return }
        #expect(options == ["Timeline Positions", "In Points", "Timecode"])
        #expect(s.project.timelines.contains { $0.name == "Angles 01" })
        withExtendedLifetime(dialogs) {}
    }

    @Test func anglesNameTakesTheFirstFreeNumber() {
        #expect(TimelineEditorDialogs.anglesName(existing: ["Angles 01", "Main"]) == "Angles 02")
    }
}
