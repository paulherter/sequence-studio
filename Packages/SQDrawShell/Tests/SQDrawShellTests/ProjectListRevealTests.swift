import Foundation
import Testing
import SQCore
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ProjectListRevealTests {
    @Test func revealOpensTheFoldersAboveTheItemAndSelectsIt() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let media = MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1))
        var p = m.project
        p.media.append(media)
        p.rootBin.children.append(.media(media.id))
        m.setProject(p)
        let outer = try #require(m.newBin(name: "Footage"))
        m.currentBin = outer
        let inner = try #require(m.newBin(name: "Day 1"))
        #expect(m.move([.media(media.id)], to: inner))
        #expect(!v.rows().contains { $0.ref == .media(media.id) })      // folders start closed
        v.reveal(media: media.id)
        #expect(v.expanded == [outer, inner])
        let row = try #require(v.rows().first { $0.ref == .media(media.id) })
        #expect(row.depth == 2)
        #expect(v.selection == [.media(media.id)])
    }

    @Test func itemCountCountsSequencesAndClipsButNoFolders() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let before = m.project.rootBin.allRefs.filter { if case .bin = $0 { false } else { true } }.count
        let media = MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1))
        var p = m.project
        p.media.append(media)
        p.rootBin.children.append(.media(media.id))
        m.setProject(p)
        _ = try #require(m.newBin(name: "Footage"))
        #expect(v.itemCountText == (before + 1 == 1 ? "1 item" : "\(before + 1) items"))
        #expect(before >= 1)       // the host's sequence counts too
    }
}
