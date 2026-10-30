import Testing
import Foundation
import SQCore
@testable import SQPremiereImport

@Suite struct ImportChecklistTests {
    let S = PRFixture.second

    func map(_ f: PRFixture) throws -> PRImportResult { PRMapper.map(try PRReader.read(data: f.data), name: "Test", media: [:]) }

    @Test func collectTiesApproximatedNotesToTheClip() {
        var r = PRImportReport()
        let loc = PRImportReport.Location(timeline: UUID(), clip: UUID())
        r.beginCollect()
        r.note("Text", .approximated, "n")
        r.note("Video clip", .mapped)
        r.endCollect(attachingTo: loc)
        #expect(r.entries.first { $0.feature == "Text" }?.locations == [loc])
        #expect(r.entries.first { $0.feature == "Video clip" }?.locations == [])
    }

    @Test func locationsAreNotEncoded() throws {
        var r = PRImportReport()
        r.beginCollect(); r.note("Text", .dropped); r.endCollect(attachingTo: .init(timeline: UUID(), clip: UUID()))
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("locations") && !json.contains("collecting"))
    }

    @Test func offlineMediaListsEveryClipThatUsesIt() throws {
        let f = PRFixture()
        let m = f.media(path: "/gone/a.mov", title: "a.mov")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m)),
                                            f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .media(m))])])
        let r = try map(f)
        let list = PRImportChecklist(report: r.report, project: r.project)
        let missing = try #require(list.items.first { $0.kind == .missingFiles })
        #expect(missing.count == 1)
        #expect(missing.locations.count == 2)
        let ids = Set(r.project.timelines.flatMap(\.tracks).flatMap(\.clips).map(\.id))
        #expect(missing.locations.allSatisfy { ids.contains($0.clip) })
        #expect(list.needsAttention)
    }

    @Test func cameOverCountsClipsAndSequences() throws {
        let f = PRFixture()
        let m = f.media(path: "/gone/a.mov", title: "a.mov")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m))])])
        let r = try map(f)
        let list = PRImportChecklist(report: r.report, project: r.project)
        let first = try #require(list.items.first)
        #expect(first.kind == .cameOver)
        #expect(first.title == "1 clip, 1 sequence")
    }

    @Test func orderAndOfflineSplitFromApproximated() {
        var r = PRImportReport()
        r.note("Offline media", .approximated, "x")
        r.note("Offline media", .approximated, "x")
        r.note("AE.ADBE Lumetri", .dropped, "no counterpart")
        r.note("Text", .approximated, "close")
        let list = PRImportChecklist(report: r, project: Project(name: "p"))
        #expect(list.items.map(\.kind) == [.cameOver, .approximated, .leftOut, .missingFiles])
        #expect(list.items.first { $0.kind == .leftOut }?.title == "Lumetri")
        #expect(list.items.first { $0.kind == .missingFiles }?.title == "2 files missing")
    }

    @Test func nothingToCheckWhenAllMapped() {
        var r = PRImportReport()
        r.note("Video clip", .mapped)
        #expect(!PRImportChecklist(report: r, project: Project(name: "p")).needsAttention)
    }
}
