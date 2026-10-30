import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
final class FilePicker: ShellFilePicker {
    var file: URL?
    var asked: [URL?] = []
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { nil }
    func chooseMedia() async -> [URL] { [] }
    func chooseFile(prompt: String, directory: URL?) async -> URL? { asked.append(directory); return file }
}

@MainActor
@Suite(.serialized) struct ShellLocateTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-locate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Two offline items (a.wav, b.wav, 3 bytes recorded) whose files now sit in `dir`.
    func host() throws -> (ShellHost, FilePicker, [MediaRef]) {
        let gone = "/sq-gone-\(UUID().uuidString)"
        let media = ["a.wav", "b.wav"].map {
            MediaRef(name: $0, path: gone + "/" + $0, fingerprint: MediaFingerprint(size: 3), duration: Time(2, 1),
                     info: MediaInfo(duration: Time(2, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        }
        for m in media { try Data([0, 1, 2]).write(to: dir.appendingPathComponent(m.name)) }
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = ShellRecoveryTests.session(Project(name: "P", media: media, timelines: [tl]))
        let h = ShellHost(session: s, map: .premiereDefault)
        h.projectModel = ProjectPanelModel(project: s.project, probe: ShellImportTests.fakeProbe,
                                           onEdit: { [weak s] p, name in s?.perform(name) { $0 = p } })
        h.probe = ShellImportTests.fakeProbe
        let picker = FilePicker()
        h.files = picker
        return (h, picker, media)
    }

    func waitForDialog(_ h: ShellHost) async -> ShellDialog? {
        for _ in 0..<400 {
            if let d = h.dialog { return d }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func locateRelinksTheItemAndOffersTheSiblingsInTheFolder() async throws {
        let (h, picker, media) = try host()
        var status: [String] = []
        h.onStatus = { status.append($0) }
        picker.file = dir.appendingPathComponent("a.wav")
        let flow = Task { await h.locateOffline(media[0].id) }
        let d = try #require(await waitForDialog(h))
        #expect(h.session.project.media(media[0].id)?.path == picker.file?.path)
        #expect(h.session.missingMedia.map(\.name) == ["b.wav"])
        #expect(d.messageText == "Reconnect 1 more file in this folder?")
        d.press(.first)
        await flow.value
        #expect(h.session.missingMedia.isEmpty)
        #expect(picker.asked == [nil])     // the old folder is gone: the chooser opens where it likes
        #expect(status == ["Located a.wav.", "Reconnected 1 more file."])
    }

    @Test func notNowLeavesTheSiblingsOffline() async throws {
        let (h, picker, media) = try host()
        picker.file = dir.appendingPathComponent("b.wav")
        let flow = Task { await h.locateOffline(media[1].id) }
        let d = try #require(await waitForDialog(h))
        d.press(.second)
        await flow.value
        #expect(h.session.missingMedia.map(\.name) == ["a.wav"])
    }

    @Test func replaceMediaProbesTheFileAndTakesOverTheItem() async throws {
        let (h, picker, media) = try host()
        let url = dir.appendingPathComponent("c.wav")
        try Data([0, 1, 2]).write(to: url)
        picker.file = url
        await h.replaceMedia(media[0].id)
        #expect(h.session.project.media(media[0].id)?.path == url.path)
        #expect(h.session.canUndo)
    }

    @Test func projectMenuOffersLocateOnlyForOneOfflineItem() throws {
        let (h, _, media) = try host()
        let list = ProjectListView(host: h)
        list.selection = [.media(media[0].id)]
        // The menu reads the model's offline set (as the Mac `ProjectPanelView`); the tests refresh it synchronously.
        h.projectModel?.refreshOffline()
        let titles = list.menu().map(\.title)
        #expect(titles.contains("Locate…") && titles.contains("Reconnect Media…"))
        h.session.relinkMedia([media[0].id: dir.appendingPathComponent("a.wav").path])
        h.projectModel?.setProject(h.session.project)
        h.projectModel?.refreshOffline()
        let online = list.menu().map(\.title)
        #expect(!online.contains("Locate…") && online.contains("Replace Media…"))
    }
}
