import Foundation
import Testing
import SQCore
import SQLibrary
import SQUIKit
import SQDrawKit
import SQEditorSession
import SQPremiereImport
import Synchronization
@testable import SQDrawShell

@MainActor
final class MediaPicker: ShellFilePicker {
    var media: [URL] = []
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { nil }
    func chooseMedia() async -> [URL] { media }
}

@MainActor
@Suite(.serialized) struct ShellImportTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    nonisolated static let probed = Mutex<[String]>([])
    nonisolated static let fakeProbe: ProjectPanelModel.Probe = { url in
        probed.withLock { $0.append(url.lastPathComponent) }
        return MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: MediaFingerprint(size: 1),
                 duration: Time(2, 1), info: MediaInfo(duration: Time(2, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
    }

    func host() -> (ShellHost, MediaPicker, [@MainActor () async -> Void]) {
        let s = ShellCommandsTests.session()
        let h = ShellHost(session: s, map: .premiereDefault)
        let model = ProjectPanelModel(project: s.project, probe: Self.fakeProbe, onEdit: { [weak s] p, name in s?.perform(name) { $0 = p } })
        h.projectModel = model
        h.probe = Self.fakeProbe
        let picker = MediaPicker()
        h.files = picker
        return (h, picker, [])
    }

    func file(_ name: String) throws -> URL {
        let url = Self.dir.appendingPathComponent(name)
        try Data([0, 1, 2]).write(to: url)
        return url
    }

    @Test func kindsFollowTheMacImportRouting() {
        #expect(ShellImportKind.of(URL(fileURLWithPath: "/a/b.prproj")) == .premiereProject)
        #expect(ShellImportKind.of(URL(fileURLWithPath: "/a/b.FCPXML")) == .timeline)
        #expect(ShellImportKind.of(URL(fileURLWithPath: "/a/b.mogrt")) == .motionGraphicsTemplate)
        #expect(ShellImportKind.of(URL(fileURLWithPath: "/a/b.mp4")) == .media)
    }

    @Test func ctrlIChoosesFilesAndTheyLandInTheProject() async throws {
        let (h, picker, _) = host()
        var flows: [@MainActor () async -> Void] = []
        h.spawn = { flows.append($0) }
        picker.media = [try file("voice.wav")]
        #expect(h.handle(.keyDown(.character("i"), modifiers: .command), scale: 1))
        while !flows.isEmpty { let f = flows.removeFirst(); await f() }
        #expect(h.session.project.media.map(\.name) == ["voice.wav"])
        #expect(h.session.isDirty)
    }

    @Test func mixedDropsSplitByKind() async throws {
        let (h, _, _) = host()
        h.spawn = { f in Task { @MainActor in await f() } }
        h.presetStore = try PresetStore(applicationSupport: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-mixed-presets-\(UUID().uuidString)"))
        // A timeline file now opens as its own project (it would ask about the dirty one). A preset file goes to the shared
        // preset flow: this one is no real preset file, so the flow says why instead of skipping it silently.
        h.importMixed([try file("a.wav"), try file("look.prfpset")])
        for _ in 0..<400 where h.dialog == nil || h.session.project.media.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.session.project.media.map(\.name) == ["a.wav"])
        #expect(h.dialog?.messageText == "Could not import “look.prfpset”")
    }

    @Test func premiereProjectReplacesTheWindowProject() async throws {
        let (h, _, _) = host()
        h.spawn = { f in Task { @MainActor in await f() } }
        let clip = try file("interview.mov")
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <PremiereData Version="3">
        <Media ObjectUID="00000000-0000-0000-0000-000000000101" Version="30"><ActualMediaFilePath>\(clip.path)</ActualMediaFilePath><FilePath>\(clip.path)</FilePath><Title>interview.mov</Title></Media>
        </PremiereData>
        """
        let pr = Self.dir.appendingPathComponent("Edit.prproj")
        try Data(xml.utf8).write(to: pr)
        await h.openProject(at: pr)
        // The fixture has no sequence, so nothing is probed (SQPremiereImport's PRFixture is test-target only);
        // the media path and probe order are the Mac's and covered by SQPremiereImport's MediaResolveTests.
        #expect(h.session.project.name == "Edit")
        #expect(h.session.fileURL == nil)
    }

    @Test func notAPremiereFileIsAnError() async {
        let (h, _, _) = host()
        h.spawn = { _ in }
        let t = Task { @MainActor in await h.importPremiereProject(at: URL(fileURLWithPath: "/x/y.txt")) }
        await t.value
        // presentError spawns the message; nothing replaced the project.
        #expect(h.session.project.name == "P")
    }
}
