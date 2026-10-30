import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func ref(_ name: String, path: String) -> MediaRef {
    let v = VideoTrackInfo(width: 100, height: 100, codec: "ap4h", bitDepth: 8, chroma: "4:4:4",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    return MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(1, 1),
                    info: MediaInfo(duration: Time(1, 1), video: v))
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[String]] = [], singles: [String] = []
    func sequence(_ f: [String]) { lock.lock(); frames.append(f); lock.unlock() }
    func single(_ s: String) { lock.lock(); singles.append(s); lock.unlock() }
    var snapshot: (frames: [[String]], singles: [String]) { lock.lock(); defer { lock.unlock() }; return (frames, singles) }
}

@MainActor @Suite struct ImageSequenceImportTests {
    private func model(_ seen: Seen) -> ProjectPanelModel {
        let m = ProjectPanelModel(project: Project(name: "P"), probe: { url in
            seen.single(url.lastPathComponent)
            return ref(url.lastPathComponent, path: url.path)
        }, onEdit: { _, _ in })
        m.sequenceProbe = { frames in
            seen.sequence(frames.map(\.lastPathComponent))
            return ref("seq", path: "/cache/strip.mov")
        }
        return m
    }

    @Test func numberedPNGsImportAsOneClipAndOtherFilesStaySeparate() async {
        let seen = Seen(), m = model(seen)
        var urls = (1...5).map { URL(fileURLWithPath: "/x/fx_\($0).png") }
        urls.append(URL(fileURLWithPath: "/x/a.mov"))
        await m.importFiles(urls)
        let s = seen.snapshot
        #expect(s.frames == [["fx_1.png", "fx_2.png", "fx_3.png", "fx_4.png", "fx_5.png"]])
        #expect(s.singles == ["a.mov"])
        #expect(m.project.media.map(\.path).sorted() == ["/cache/strip.mov", "/x/a.mov"])
        #expect(m.mediaID(forImported: urls[0]) != nil)
    }

    @Test func aStripIsNeverCopiedAndShortRunsStayStills() async {
        let seen = Seen(), m = model(seen)
        var reported: [ProjectPanelModel.ImportedFile] = []
        m.onImported = { files, _ in reported += files }
        await m.importFiles((1...5).map { URL(fileURLWithPath: "/x/fx_\($0).png") })
        #expect(reported.isEmpty)              // the strip already lives in the app folder: nothing to copy or move
        let seen2 = Seen(), m2 = model(seen2)
        await m2.importFiles((1...3).map { URL(fileURLWithPath: "/x/s_\($0).png") })
        #expect(seen2.snapshot.frames.isEmpty && seen2.snapshot.singles.count == 3)   // 3 files: probably unrelated stills
    }

    @Test func cameraPhotosAreNotCollapsed() async {
        let seen = Seen(), m = model(seen)
        await m.importFiles((1...6).map { URL(fileURLWithPath: "/x/IMG_000\($0).jpg") })
        #expect(seen.snapshot.frames.isEmpty && seen.snapshot.singles.count == 6)
    }
}
