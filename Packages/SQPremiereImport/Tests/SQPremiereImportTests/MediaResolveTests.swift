import Foundation
import Testing
import SQCore
@testable import SQPremiereImport

/// Media paths of a moved project (synthetic fixtures + temp folders; never a real .prproj).
@Suite struct MediaResolveTests {
    let S = PRFixture.second

    private func projectDir(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-prresolve-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func doc(_ build: (PRFixture) -> [String]) throws -> PRDocument {
        let f = PRFixture()
        let items = build(f).map { f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media($0)) }
        f.sequence("Main", video: [f.track(items)])
        return try PRReader.read(data: f.data)
    }

    @Test func clipsNextToTheProjectResolve() throws {
        let dir = try projectDir("S112 x2")
        for n in ["C2117.mp4", "C2116.mp4"] { try Data(count: 4).write(to: dir.appendingPathComponent(n)) }
        let d = try doc { f in [f.media(path: "/Volumes/Other Mac/S112 x2/C2117.mp4", title: "C2117.mp4"),
                                f.media(path: "/Volumes/Other Mac/S112 x2/C2116.mp4", title: "C2116.mp4")] }
        let hits = PRMapper.resolveMedia(d, projectFile: dir.appendingPathComponent("S112 x2.prproj"))
        #expect(hits["/Volumes/Other Mac/S112 x2/C2117.mp4"]?.path == dir.appendingPathComponent("C2117.mp4").path)
        #expect(hits["/Volumes/Other Mac/S112 x2/C2116.mp4"]?.path == dir.appendingPathComponent("C2116.mp4").path)
    }

    @Test func windowsPathsAreMediaNotGraphics() throws {
        let d = try doc { f in [f.media(path: "D:\\Footage\\C0001.MP4", title: "C0001.MP4")] }
        #expect(PRMapper.mediaPaths(d) == ["D:\\Footage\\C0001.MP4"])
        let dir = try projectDir("P")
        try Data(count: 4).write(to: dir.appendingPathComponent("C0001.MP4"))
        #expect(PRMapper.resolveMedia(d, projectFile: dir.appendingPathComponent("P.prproj"))["D:\\Footage\\C0001.MP4"]?.path
                == dir.appendingPathComponent("C0001.MP4").path)
    }

    @Test func relativePathIsRead() throws {
        let dir = try projectDir("P")
        let media = dir.deletingLastPathComponent().appendingPathComponent("Shoot/Day1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data(count: 4).write(to: media.appendingPathComponent("a.mov"))
        let d = try doc { f in [f.media(path: "/old/a.mov", title: "a.mov", relative: "../Shoot/Day1/a.mov")] }
        let hit = PRMapper.resolveMedia(d, projectFile: dir.appendingPathComponent("P.prproj"))["/old/a.mov"]
        #expect(hit == .init(path: media.appendingPathComponent("a.mov").path, method: .relativePath))
    }

    @Test func emptyActualPathFallsBackToFilePath() throws {
        let d = try doc { f in [f.media(path: "/f/a.mov", title: "a.mov", actual: "")] }
        #expect(PRMapper.mediaPaths(d) == ["/f/a.mov"])
    }

    @Test func locateFoldersAreUsed() throws {
        let dir = try projectDir("P")
        let card = try projectDir("Card")
        try Data(count: 4).write(to: card.appendingPathComponent("x.mov"))
        let d = try doc { f in [f.media(path: "/gone/x.mov", title: "x.mov")] }
        let hit = PRMapper.resolveMedia(d, projectFile: dir.appendingPathComponent("P.prproj"), searchFolders: [card])["/gone/x.mov"]
        #expect(hit?.method == .searchFolder)
    }

    @Test func offlinePlaceholderKeepsTheStoredPath() throws {
        // Missing media keeps its stored path (Locate matches on its file name) and Windows paths included.
        let f = PRFixture()
        let m = f.media(path: "D:\\Footage\\C0001.MP4", title: "Interview")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m))])])
        let r = PRMapper.map(try PRReader.read(data: f.data), name: "P")
        #expect(r.project.media.count == 1 && r.project.media[0].path == "D:\\Footage\\C0001.MP4")
    }
}
