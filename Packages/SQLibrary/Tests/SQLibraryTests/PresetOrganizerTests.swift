import Foundation
import Testing
@testable import SQLibrary

@Suite struct PresetOrganizerTests {
    func entry(_ name: String, builtIn: Bool = false, created: Double = 0, cat: PresetCategory = .titles, meta: PresetMeta = PresetMeta()) -> PresetListEntry {
        PresetListEntry(key: builtIn ? PresetKey.builtIn(name) : "user:\(name)", name: name, isBuiltIn: builtIn,
                        createdAt: Date(timeIntervalSince1970: created), defaultCategory: cat, meta: meta)
    }

    @Test func defaultCategoriesFollowKind() {
        #expect(PresetCategory.defaultCategory(for: .titleBlock) == .titles)
        #expect(PresetCategory.defaultCategory(for: .caption) == .captions)
        #expect(PresetCategory.defaultCategory(for: .keystone) == .motion)
        #expect(PresetCategory.inferred(fromName: "Lower Third Bar") == .lowerThirds)
        #expect(PresetCategory.inferred(fromName: "CTA End Card") == .social)
        #expect(PresetCategory.inferred(fromName: "Bold Box") == .titles)
    }

    @Test func tagsAreNormalisedDedupedAndCapped() {
        var t = PresetMetaTable()
        t.addTag("k", "  Bold ")
        t.addTag("k", "bold")
        t.addTag("k", "  ")
        #expect(t["k"].tags == ["bold"])
        for i in 0..<20 { t.addTag("k", "tag\(i)") }
        #expect(t["k"].tags.count == PresetMetaTable.maxTags)
        t.addTag("long", String(repeating: "x", count: 60))
        #expect(t["long"].tags[0].count == PresetMetaTable.maxTagLength)
        t.toggleTag("k", "BOLD")
        #expect(!t["k"].tags.contains("bold"))
    }

    @Test func defaultMetaIsNotStored() {
        var t = PresetMetaTable()
        t.toggleFavorite("a")
        #expect(t.entries.count == 1)
        t.toggleFavorite("a")
        #expect(t.entries.isEmpty)
    }

    @Test func recordUseCountsAndStamps() {
        var t = PresetMetaTable()
        let d = Date(timeIntervalSince1970: 500)
        t.recordUse("a", at: d)
        t.recordUse("a", at: d.addingTimeInterval(10))
        #expect(t["a"].useCount == 2)
        #expect(t["a"].lastUsed == d.addingTimeInterval(10))
    }

    @Test func pruneKeepsBuiltInsAndLiveUserKeys() {
        var t = PresetMetaTable()
        t.toggleFavorite("builtin:x"); t.toggleFavorite("user:gone"); t.toggleFavorite("user:live")
        t.prune(keepingUserKeys: ["user:live"])
        #expect(Set(t.entries.keys) == ["builtin:x", "user:live"])
    }

    @Test func sortKeys() {
        let a = entry("Alpha", created: 10, meta: PresetMeta(lastUsed: Date(timeIntervalSince1970: 5), useCount: 1))
        let b = entry("Beta", created: 30, meta: PresetMeta(lastUsed: Date(timeIntervalSince1970: 9), useCount: 7))
        let c = entry("Gamma", created: 20)
        let all = [c, a, b]
        func names(_ s: PresetSortKey, _ asc: Bool = true) -> [String] {
            PresetOrganizer.visible(all, filter: PresetFilter(), sort: s, ascending: asc).map(\.name)
        }
        #expect(names(.name) == ["Alpha", "Beta", "Gamma"])
        #expect(names(.name, false) == ["Gamma", "Beta", "Alpha"])
        #expect(names(.newest) == ["Beta", "Gamma", "Alpha"])
        #expect(names(.mostUsed) == ["Beta", "Alpha", "Gamma"])
        #expect(names(.recentlyUsed) == ["Beta", "Alpha", "Gamma"])
    }

    @Test func filtersByScopeCategoryTagAndQuery() {
        let fav = entry("Pop", meta: PresetMeta(tags: ["bold"], isFavorite: true))
        let built = entry("Classic", builtIn: true, cat: .captions)
        let used = entry("Slide", meta: PresetMeta(tags: ["clean"], lastUsed: Date(timeIntervalSince1970: 1), useCount: 1))
        let all = [fav, built, used]
        func names(_ f: PresetFilter) -> [String] { PresetOrganizer.visible(all, filter: f, sort: .name).map(\.name) }
        #expect(names(PresetFilter(scope: .favorites)) == ["Pop"])
        #expect(names(PresetFilter(scope: .recent)) == ["Slide"])
        #expect(names(PresetFilter(scope: .builtIn)) == ["Classic"])
        #expect(names(PresetFilter(scope: .yours)) == ["Pop", "Slide"])
        #expect(names(PresetFilter(category: .captions)) == ["Classic"])
        #expect(names(PresetFilter(tag: " Bold ")) == ["Pop"])
        #expect(names(PresetFilter(query: "clean")) == ["Slide"])           // tag match
        #expect(names(PresetFilter(query: "captions")) == ["Classic"])      // category title match
        #expect(names(PresetFilter(query: "pop bold")) == ["Pop"])
        #expect(names(PresetFilter(query: "pop clean")).isEmpty)
    }

    @Test func recentScopeIsCappedNewestFirst() {
        let list = (0..<20).map { entry("P\($0)", meta: PresetMeta(lastUsed: Date(timeIntervalSince1970: Double($0)), useCount: 1)) }
        let r = PresetOrganizer.visible(list, filter: PresetFilter(scope: .recent), sort: .name)
        #expect(r.count == PresetOrganizer.recentLimit)
        #expect(r.first?.name == "P19")
    }

    @Test func metaOverridesCategory() {
        let e = entry("X", cat: .titles, meta: PresetMeta(category: .social))
        #expect(e.category == .social)
    }

    @Test func countsAndHoverLines() {
        let a = entry("A", meta: PresetMeta(tags: ["x", "y"], useCount: 2))
        let b = entry("B", cat: .effects, meta: PresetMeta(tags: ["x"]))
        #expect(PresetOrganizer.tagCounts([a, b]).first?.tag == "x")
        #expect(PresetOrganizer.categoryCounts([a, b])[.effects] == 1)
        #expect(PresetHoverInfo.lines(for: a) == ["Yours · Titles", "#x #y", "Used 2 times"])
    }

    @Test func storeRoundTripsAndRejectsNewerVersion() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = PresetMetaStore.fileURL(applicationSupport: dir.url)
        var t = PresetMetaTable()
        t.toggleFavorite("user:1"); t.addTag("user:1", "bold"); t.setCategory("builtin:z", .social)
        t.recordUse("user:1", at: Date(timeIntervalSince1970: 100))
        try PresetMetaStore.save(t, to: url)
        #expect(try PresetMetaStore.load(from: url) == t)
        try Data(#"{"formatVersion":99,"entries":{}}"#.utf8).write(to: url)
        #expect(throws: LibraryStoreError.self) { try PresetMetaStore.load(from: url) }
    }

    @Test func corruptFileStartsEmptyAndIsMovedAside() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = PresetMetaStore.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nonsense".utf8).write(to: url)
        #expect(try PresetMetaStore.load(from: url) == PresetMetaTable())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
