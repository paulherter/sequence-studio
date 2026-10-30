import Foundation
import Testing
@testable import SQLibrary

@Suite struct LibraryGroupingTests {
    let fid = UUID()
    func e(_ p: String) -> LibraryEntry {
        LibraryEntry(folderID: fid, relativePath: p, kind: .audio, size: 1, modified: .distantPast)
    }

    @Test func flatFolderHasNoGroups() {
        #expect(LibraryGrouping.groups([e("a.wav"), e("b.wav")]).isEmpty)
        #expect(LibraryGrouping.groups([]).isEmpty)
    }

    @Test func allSectionThenCategories() {
        let g = LibraryGrouping.groups([e("root.wav"), e("Calm/a.wav"), e("Calm/b.wav"), e("Epic/c.wav")])
        #expect(g.map(\.title) == ["All", "Calm", "Epic"])
        #expect(g[0].entries.count == 4 && g[0].totalCount == 4 && g[0].isAll)
        #expect(g[1].entries.map(\.name) == ["a.wav", "b.wav"] && g[1].totalCount == 2)
        #expect(g.map(\.depth) == [0, 0, 0])
    }

    @Test func nestedFoldersCountRecursivelyAndKeepOwnItems() {
        let g = LibraryGrouping.groups([e("Calm/a.wav"), e("Calm/Piano/p.wav"), e("Calm/Piano/Slow/s.wav"), e("Epic/c.wav")])
        #expect(g.map(\.id) == ["*", "Calm", "Calm/Piano", "Calm/Piano/Slow", "Epic"])
        #expect(g.map(\.depth) == [0, 0, 1, 2, 0])
        #expect(g[1].entries.count == 1 && g[1].totalCount == 3)
        #expect(g[2].entries.count == 1 && g[2].totalCount == 2)
        #expect(g[3].parentID == "Calm/Piano")
        #expect(g[1].parentID == nil)
    }

    @Test func directoryWithOnlySubfoldersStillGetsHeader() {
        let g = LibraryGrouping.groups([e("Cat/Sub/x.wav")])
        #expect(g.map(\.id) == ["*", "Cat", "Cat/Sub"])
        #expect(g[1].entries.isEmpty && g[1].totalCount == 1)
    }

    @Test func collapsedHidesDescendants() {
        let g = LibraryGrouping.groups([e("A/x.wav"), e("A/B/y.wav"), e("C/z.wav")])
        let vis = LibraryGrouping.visible(g, collapsed: ["A"])
        #expect(vis.map(\.id) == ["*", "A", "C"])
        #expect(vis.first { $0.id == "A" }?.isCollapsed == true)
        let allCollapsed = LibraryGrouping.visible(g, collapsed: ["*"])
        #expect(allCollapsed.map(\.id) == ["*", "A", "A/B", "C"])
        #expect(allCollapsed.first?.isCollapsed == true && allCollapsed.first?.entries.isEmpty == true)
    }

    @Test func manyFilesGroupCorrectly() {
        var entries: [LibraryEntry] = []
        for i in 0..<5000 { entries.append(e("cat\(i % 40)/sub\(i % 7)/f\(i).wav")) }
        let g = LibraryGrouping.groups(entries)
        #expect(g[0].entries.count == 5000)
        let pairs = Set((0..<5000).map { "\($0 % 40)/\($0 % 7)" }).count
        #expect(g.count == 1 + 40 + pairs)
    }
}
