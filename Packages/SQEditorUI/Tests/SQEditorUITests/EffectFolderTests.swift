import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@Suite struct EffectFolderTests {
    private typealias Entry = EffectsPanelView.Entry
    private let blur = Entry(id: "gaussianBlur", title: "Gaussian Blur", category: "Blur & Sharpen", symbol: .circleDot)
    private let sharpen = Entry(id: "sharpen", title: "Sharpen", category: "Blur & Sharpen", symbol: .triangle)
    private let glow = Entry(id: "glow", title: "Glow", category: "Stylize", symbol: .sunMedium)
    private let dissolve = Entry(id: "transition.crossDissolve", title: "Cross Dissolve", category: "Video Transitions", symbol: .unknown)
    private let audioFade = Entry(id: "transition.constantPower", title: "Constant Power", category: "Audio Transitions", symbol: .unknown)
    private let preset = Entry(id: "preset.11111111-1111-1111-1111-111111111111", title: "Soft Glow", category: "Presets", symbol: .unknown)
    private var entries: [Entry] { [blur, sharpen, glow, dissolve, audioFade, preset] }
    private func suite() -> UserDefaults { UserDefaults(suiteName: "sq.test.folders.\(UUID().uuidString)")! }

    private func titles(_ rows: [TemplateListPanelView.Row]) -> [String] { rows.map { String(repeating: ">", count: $0.depth) + $0.title } }

    // MARK: Folder drag

    @Test func folderDragCarriesItsApplicableEffects() {
        var store = EffectFolderStore()
        let f = store.createFolder(named: "Mine")
        for id in [glow.id, dissolve.id, preset.id, blur.id] { store.add(id, to: f) }
        // user folder: effects only, in folder order (transitions and presets are skipped)
        #expect(EffectFolderOutline.effectIDs(forFolder: EffectFolderOutline.userID(f), entries: entries, store: store) == ["glow", "gaussianBlur"])
        // built-in folders: the whole folder, or one category
        #expect(EffectFolderOutline.effectIDs(forFolder: EffectFolderOutline.builtinID("Video Effects"), entries: entries, store: store)
                == ["gaussianBlur", "sharpen", "glow"])
        #expect(EffectFolderOutline.effectIDs(forFolder: EffectFolderOutline.builtinID("Video Effects", "Blur & Sharpen"), entries: entries, store: store)
                == ["gaussianBlur", "sharpen"])
        // the Presets and transition folders carry nothing: no drag
        #expect(EffectFolderOutline.effectIDs(forFolder: EffectFolderOutline.builtinID("Presets"), entries: entries, store: store).isEmpty)
        #expect(EffectFolderOutline.effectIDs(forFolder: EffectFolderOutline.builtinID("Video Transitions"), entries: entries, store: store).isEmpty)
    }

    @Test func dragPayloadRoundTripsOneOrManyIDs() {
        #expect(EffectFolderOutline.decodeDrag(EffectFolderOutline.encodeDrag(["a", "b"])) == ["a", "b"])
        #expect(EffectFolderOutline.decodeDrag("sharpen") == ["sharpen"])
        #expect(EffectFolderOutline.decodeDrag("").isEmpty)
    }

    @Test func userFoldersReorder() {
        var store = EffectFolderStore()
        let a = store.createFolder(named: "A"), b = store.createFolder(named: "B"), c = store.createFolder(named: "C")
        store.move(c, before: a)
        #expect(store.folders.map(\.name) == ["C", "A", "B"])
        store.move(c, before: nil)                       // nil = to the end
        #expect(store.folders.map(\.name) == ["A", "B", "C"])
        store.move(a, before: b)                         // already there: unchanged
        #expect(store.folders.map(\.name) == ["A", "B", "C"])
        store.move(a, before: a)
        #expect(store.folders.map(\.name) == ["A", "B", "C"])
        store.move(a, before: c)
        #expect(store.folders.map(\.name) == ["B", "A", "C"])
        _ = b
    }

    // MARK: Outline

    @Test func topLevelFoldersInPremiereOrderAndCollapsedByDefault() {
        let rows = EffectFolderOutline.rows(entries: entries, store: EffectFolderStore(), expanded: [], query: "")
        #expect(titles(rows) == ["Presets", "Video", "Transitions", "Crossfades"])
        #expect(rows.allSatisfy { $0.isFolder })
    }

    @Test func expandingShowsCategoriesThenItems() {
        let open: Set<String> = [EffectFolderOutline.builtinID("Video Effects"), EffectFolderOutline.builtinID("Video Effects", "Blur & Sharpen"),
                                 EffectFolderOutline.builtinID("Video Transitions")]
        let rows = EffectFolderOutline.rows(entries: entries, store: EffectFolderStore(), expanded: open, query: "")
        #expect(titles(rows) == ["Presets", "Video", ">Blur & Sharpen", ">>Gaussian Blur", ">>Sharpen", ">Stylize",
                                 "Transitions", ">Cross Dissolve", "Crossfades"])
        #expect(rows.first { $0.title == "Sharpen" }?.payload == "sharpen")
        #expect(rows.first { $0.title == "Video" }?.isExpanded == true)
    }

    @Test func foldersOpenedBySearchCanBeClosedAgain() {
        let closed: Set<String> = [EffectFolderOutline.builtinID("Video Effects", "Stylize")]
        let rows = EffectFolderOutline.rows(entries: entries, store: EffectFolderStore(), expanded: [], query: "glow", collapsedInSearch: closed)
        #expect(titles(rows) == ["Presets", ">Soft Glow", "Video", ">Stylize"])
        #expect(rows.last?.isExpanded == false)
    }

    @Test func searchOpensMatchingFoldersAndHidesTheRest() {
        let rows = EffectFolderOutline.rows(entries: entries, store: EffectFolderStore(), expanded: [], query: "glow")
        #expect(titles(rows) == ["Presets", ">Soft Glow", "Video", ">Stylize", ">>Glow"])
    }

    @Test func searchMatchesCategoryNameToo() {
        let rows = EffectFolderOutline.rows(entries: entries, store: EffectFolderStore(), expanded: [], query: "blur")
        #expect(titles(rows) == ["Video", ">Blur & Sharpen", ">>Gaussian Blur", ">>Sharpen"])
    }

    // MARK: User folders

    @Test func userFoldersComeFirstAndListTheirItems() {
        var s = EffectFolderStore()
        let id = s.createFolder(named: "Look")
        s.add("glow", to: id); s.add(preset.id, to: id); s.add("gone-effect", to: id)
        let rows = EffectFolderOutline.rows(entries: entries, store: s, expanded: [EffectFolderOutline.userID(id)], query: "")
        #expect(Array(titles(rows).prefix(3)) == ["Look", ">Glow", ">Soft Glow"], "unknown ids are not shown")
        #expect(rows.first?.userFolder == id)
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count, "row ids stay unique when an item is in several places")
    }

    @Test func emptyUserFolderShowsOnlyWithoutSearch() {
        var s = EffectFolderStore()
        _ = s.createFolder(named: "Empty")
        #expect(titles(EffectFolderOutline.rows(entries: entries, store: s, expanded: [], query: "")).first == "Empty")
        #expect(!titles(EffectFolderOutline.rows(entries: entries, store: s, expanded: [], query: "glow")).contains("Empty"))
    }

    // MARK: Store

    @Test func createRenameDeleteAndDuplicateNames() {
        var s = EffectFolderStore()
        let a = s.createFolder(named: "  Look ")
        let b = s.createFolder(named: "Look")
        let c = s.createFolder(named: "  ")
        #expect(s.folders.map(\.name) == ["Look", "Look 2", "New Folder"])
        s.rename(b, to: "Look")
        #expect(s.folder(b)?.name == "Look 2", "rename to a taken name keeps unique")
        s.rename(c, to: "Cuts")
        #expect(s.folder(c)?.name == "Cuts")
        s.delete(a)
        #expect(s.folders.count == 2 && s.folder(a) == nil)
    }

    @Test func addIsIdempotentAndRemoveWorks() {
        var s = EffectFolderStore()
        let f = s.createFolder(named: "A")
        s.add("glow", to: f); s.add("glow", to: f); s.add("sharpen", to: f)
        #expect(s.folder(f)?.items == ["glow", "sharpen"])
        s.remove("glow", from: f)
        #expect(s.folder(f)?.items == ["sharpen"])
        s.add("glow", to: UUID())   // unknown folder: ignored
        #expect(s.folders.count == 1)
    }

    @Test func persistsInDefaultsAndSurvivesGarbage() {
        let d = suite()
        var s = EffectFolderStore()
        let f = s.createFolder(named: "Look"); s.add("glow", to: f)
        s.save(to: d)
        #expect(EffectFolderStore.load(from: d) == s)
        d.set(Data("nope".utf8), forKey: EffectFolderStore.key)
        #expect(EffectFolderStore.load(from: d).folders.isEmpty)
    }

    @Test func expandedStatePersists() {
        let d = suite()
        EffectFolderOutline.saveExpanded(["a", "b"], to: d)
        #expect(EffectFolderOutline.loadExpanded(from: d) == ["a", "b"])
    }
}

@Suite struct FolderKeyboardTests {
    private typealias Row = TemplateListPanelView.Row
    private func folder(_ id: String, depth: Int, open: Bool) -> Row {
        var r = Row(id: id, title: id, symbol: .folder); r.isFolder = true; r.depth = depth; r.isExpanded = open; return r
    }
    private func item(_ id: String, depth: Int) -> Row { var r = Row(id: id, title: id, symbol: .unknown); r.depth = depth; return r }
    private var rows: [Row] {
        [folder("A", depth: 0, open: true), folder("A/b", depth: 1, open: false), item("e1", depth: 2), folder("B", depth: 0, open: false)]
    }

    @Test func rightOpensClosedFolderThenEntersIt() {
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 1, key: .right) == .toggle("A/b"))
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 0, key: .right) == .select(1))
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 2, key: .right) == .none)
    }

    @Test func leftClosesOpenFolderThenJumpsToParent() {
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 0, key: .left) == .toggle("A"))
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 1, key: .left) == .select(0))
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 2, key: .left) == .select(1))
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: 3, key: .left) == .none)
    }

    @Test func noSelectionOrEmptyFolderDoesNothing() {
        #expect(EffectFolderOutline.keyNavigation(rows: rows, selected: -1, key: .left) == .none)
        var open = rows; open[3].isExpanded = true   // open but empty: right has nothing to enter
        #expect(EffectFolderOutline.keyNavigation(rows: open, selected: 3, key: .right) == .none)
    }

    @MainActor @Test func folderRowsAreNeverDraggableOrSelectableByMouse() {
        #expect(!TemplateListPanelView.isMouseSelectable(folder("A", depth: 0, open: true)))
        #expect(TemplateListPanelView.isMouseSelectable(item("e1", depth: 1)))
    }
}
