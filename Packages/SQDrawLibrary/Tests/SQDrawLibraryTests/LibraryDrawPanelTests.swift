import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary
import SQInspectorUI
@testable import SQDrawLibrary

private struct NoPreviews: PreviewProvider {
    func generate(_ request: PreviewRequest, to destination: URL) async throws { try Data("png".utf8).write(to: destination) }
}

@MainActor
private struct Env {
    let root: URL
    let media: URL
    let model: LibraryPanelModel
    let panel: LibraryDrawPanel
    var requests: [LibraryRequest] { box.requests }
    var drags: [(LibraryDragPayload, LibraryDrawPanel.DragPhase)] { box.drags }
    final class Box { var requests: [LibraryRequest] = []; var drags: [(LibraryDragPayload, LibraryDrawPanel.DragPhase)] = [] }
    let box = Box()

    init(files: [String] = ["b_clip.mp4", "a_song.wav", "c_still.png"]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libdraw-\(UUID().uuidString)")
        media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: media.appendingPathComponent(f)) }
        let store = try PresetStore(applicationSupport: root.appendingPathComponent("support"))
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("caches"), disk: .unchecked),
                                             provider: NoPreviews())
        model = LibraryPanelModel(index: LibraryIndex(watcher: FakeFolderWatcher()), presetStore: store, coordinator: coordinator,
                                  favoritesURL: root.appendingPathComponent("favorites.json"))
        await model.start()
        let defaults = UserDefaults(suiteName: "libdraw-\(UUID().uuidString)")!
        panel = LibraryDrawPanel(model: model, defaults: defaults)
        panel.size = CGSize(width: 600, height: 400)
        let box = box
        panel.onRequest = { box.requests.append($0) }
        panel.onDrag = { p, phase, _ in box.drags.append((p, phase)) }
        panel.now = { 0 }
    }

    /// The panel-local center of the cell with `key`.
    func center(_ index: Int) -> CGPoint {
        panel.refresh()
        let pl = panel.placed().first { $0.index == index }!
        let r = panel.cellRect(pl)
        return CGPoint(x: r.midX, y: r.midY)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite struct LibraryDrawPanelTests {
    @Test func sidebarRowsFollowTheBoardOrder() {
        let rows = LibrarySidebarRow.rows(folders: [], packNames: ["Pack A"])
        #expect(rows.first?.section == .all && rows.first?.isGroup == true)
        #expect(rows[1].section == .favorites)
        let presets = rows.firstIndex { $0.title == "Presets" }!
        #expect(rows[presets].section == nil)
        #expect(rows[presets + 1].section == .presets(nil))
        #expect(!rows.contains { $0.section == .presets(.titleBlock) })
        #expect(rows.last?.section == .pack("Pack A"))
        #expect(!LibrarySidebarRow.rows(folders: [], packNames: []).contains { $0.title == "Packs" })
    }

    @Test func emptyTextsAndTileLayout() {
        #expect(LibraryLabels.emptyText(offline: false, presetMode: false, favorites: false, hasFolders: false).title == "No library folders")
        #expect(LibraryLabels.emptyText(offline: true, presetMode: false, favorites: false, hasFolders: true).title == "Folder is offline")
        #expect(LibraryLabels.emptyText(offline: false, presetMode: false, favorites: false, hasFolders: true, query: " x ").title == "No results")
        #expect(LibraryTileGeometry.thumbWidth(forFraction: 0.4) == 96)
        let g = LibraryTileGeometry.layout(width: 400, fraction: 0.4)
        #expect(g.columns == 3)
        #expect(g.tile.width == 128)
        #expect(abs(g.tile.height - 98) < 0.001, "\(g.tile.height)")
    }

    @Test func emptyPanelOffersAddFolder() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        #expect(!env.panel.offersAddFolder)       // Favorites says how to add favorites
        env.model.selection = .all
        env.panel.refresh()
        #expect(env.panel.offersAddFolder)
        let b = env.panel.addFolderButtonRect
        env.panel.mouseDown(at: CGPoint(x: b.midX, y: b.midY), modifiers: [])
        #expect(env.requests == [.addFolder])
    }

    @Test func listSelectsWithShiftAndDragsTheFiles() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        env.panel.setViewMode(.list)
        env.panel.refresh()
        #expect(env.panel.contentCount == 3)
        env.panel.mouseDown(at: env.center(0), modifiers: [])
        env.panel.mouseUp(at: env.center(0))
        env.panel.mouseDown(at: env.center(2), modifiers: [.shift])
        #expect(env.panel.selectedItems.count == 3)
        // Dragging out of the panel carries every selected file; release outside ends the drag.
        env.panel.mouseDragged(to: CGPoint(x: 300, y: 500))
        env.panel.mouseUp(at: CGPoint(x: 300, y: 500))
        guard case .files(let urls)? = env.drags.first?.0 else { Issue.record("no files drag"); return }
        #expect(urls.count == 3)
        #expect(env.drags.last?.1 == .ended)
    }

    @Test func dropBackOnThePanelCancels() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        env.panel.setViewMode(.list)
        env.panel.mouseDown(at: env.center(1), modifiers: [])
        env.panel.mouseDragged(to: CGPoint(x: 300, y: 300))
        env.panel.mouseUp(at: CGPoint(x: 300, y: 300))
        #expect(env.drags.last?.1 == .canceled)
    }

    @Test func gridHasSectionsAndSearchFilters() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let sub = env.media.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("d_deep.wav"))
        let f = await env.model.addFolder(url: env.media)
        await env.model.rescan(f.id)
        env.panel.setViewMode(.grid)
        env.panel.refresh()
        #expect(env.panel.cells.contains { if case .header = $0 { true } else { false } })
        env.panel.setSearchText("song")
        env.panel.refresh()
        #expect(env.panel.cells.compactMap { if case .item(let it) = $0 { it.entry.name } else { nil } } == ["a_song.wav"])
        env.panel.setSearchText("zzz")
        env.panel.refresh()
        #expect(env.panel.isNoHits)
        #expect(env.panel.emptyText.title == "No results")
    }

    @Test func optionsMenuSwitchesViewAndFlipsSort() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let menu = env.panel.optionsMenu()
        menu.first { $0.title == "as List" }?.action?()
        #expect(env.model.viewMode == .list)
        let byName = { env.panel.optionsMenu().first { $0.title == "Sort by Name" } }
        #expect(byName()?.isChecked == true)
        let before = env.model.ascending
        byName()?.action?()
        #expect(env.model.ascending != before)
        env.panel.optionsMenu().first { $0.title == "Add Folder\u{2026}" }?.action?()
        #expect(env.requests == [.addFolder])
    }

    @Test func presetsShowTemplatesAndDoubleClickPlacesOne() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.model.selection = .presets(.textTemplate)
        env.panel.setViewMode(.list)
        env.panel.refresh()
        guard let i = env.panel.cells.firstIndex(where: { if case .preset(.template) = $0 { true } else { false } }),
              case .preset(.template(let t)) = env.panel.cells[i] else { Issue.record("no template cell"); return }
        env.panel.mouseDown(at: env.center(i), modifiers: [])
        env.panel.mouseUp(at: env.center(i))
        env.panel.mouseDown(at: env.center(i), modifiers: [])
        #expect(env.requests.contains(.applyTextTemplate(t.id)))
        // A template drags as a text template payload.
        env.panel.mouseUp(at: env.center(i))
        env.panel.now = { 10 }
        env.panel.mouseDown(at: env.center(i), modifiers: [])
        env.panel.mouseDragged(to: CGPoint(x: env.center(i).x, y: 600))
        #expect(env.drags.first?.0 == .textTemplate(t.id))
    }

    @Test func savedPresetMenuOffersExportAndDelete() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let item = PresetItem(kind: .effect, name: "Warm", payload: Data(), payloadVersion: 1)
        try await env.model.savePreset(item)
        env.model.selection = .presets(.effect)
        env.panel.setViewMode(.list)
        env.panel.refresh()
        guard let i = env.panel.cells.firstIndex(where: { $0 == .preset(.user(item)) || $0.key == PresetKey.user(item.id) }) else {
            Issue.record("no preset cell"); return
        }
        env.panel.mouseDown(at: env.center(i), modifiers: [.secondary])
        let menu = env.panel.itemMenu(at: i)
        func find(_ prefix: String, in items: [SQMenuItem]) -> SQMenuItem? {
            for m in items {
                if m.title.hasPrefix(prefix) { return m }
                if let s = m.submenu, let hit = find(prefix, in: s) { return hit }
            }
            return nil
        }
        find("Delete", in: menu)?.action?()
        find("Export", in: menu)?.action?()
        #expect(env.requests.contains { if case .deletePreset(let p) = $0 { p.id == item.id } else { false } })
        #expect(env.requests.contains { if case .exportPreset(let p) = $0 { p.id == item.id } else { false } })
        // Effect presets drag as effect presets (applied to the clip under the drop).
        env.panel.mouseUp(at: env.center(i))
        env.panel.mouseDown(at: env.center(i), modifiers: [])
        env.panel.mouseDragged(to: CGPoint(x: 10, y: 700))
        #expect(env.drags.first?.0 == .effectPreset(item.id))
    }

    @Test func emptyAreaOfTheFilesShowsTheFullFileMenuLikeTheMac() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let menu = env.panel.itemMenu(at: nil)
        #expect(menu.map(\.title) == ["Toggle Favorite", "Whoosh at Selected Cuts", "Add to SFX Folder", "Reveal in Finder"])
        #expect(menu.filter(\.isEnabled).map(\.title) == ["Toggle Favorite", "Reveal in Finder"])
    }

    @Test func drawsWithoutAnAtlas() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        for mode in [LibraryViewMode.grid, .list] {
            env.panel.setViewMode(mode)
            var c = Canvas(width: 600, height: 400, atlas: nil, scale: 1)
            env.panel.draw(&c)
            #expect(c.list.quads.count > 10)
        }
    }

    @Test func chipsWrapOntoMoreRowsInANarrowPanelAndTheListStartsBelowThem() async throws {
        let env = try await Env()
        let p = env.panel
        p.size = CGSize(width: 900, height: 400)
        #expect(p.chipRows == 1)
        let wideTop = p.listRect.minY
        p.size = CGSize(width: p.contentX + 150, height: 400)
        let frames = p.chipFrames()
        #expect(p.chipRows > 1)
        #expect(p.listRect.minY == wideTop + LibraryDrawPanel.chipRowHeight * CGFloat(p.chipRows - 1))
        // Every chip stays inside the panel (unless one chip alone is wider) and no two overlap.
        for f in frames where f.frame.width < 150 - 2 * LibraryDrawPanel.pad { #expect(f.frame.maxX <= p.size.width - LibraryDrawPanel.pad) }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(!a.frame.intersects(b.frame)) }
        #expect(frames.allSatisfy { $0.frame.maxY <= p.listRect.minY })
    }

    @Test func searchRowSpansThePanelWithSwitchAndSliderAtTheRight() async throws {
        let env = try await Env()
        let p = env.panel
        p.size = CGSize(width: 341, height: 500)
        p.model.viewMode = .grid
        #expect(p.searchFieldRect.minX == LibraryDrawPanel.pad - 2)   // measured against the AppKit crop
        let slider = try #require(p.sliderRect)
        #expect(slider.maxX == p.size.width - LibraryDrawPanel.pad)
        #expect(p.viewButtonRect.maxX + LibraryDrawPanel.pad + 5 == slider.minX)
        #expect(p.searchFieldRect.maxX + 11 == p.viewButtonRect.minX)
        #expect(p.sidebarRect.minY == LibraryDrawPanel.searchRowHeight)
        p.model.viewMode = .list
        #expect(p.sliderRect == nil)
        #expect(p.viewButtonRect.maxX == p.size.width - LibraryDrawPanel.pad)
    }
}

@MainActor
@Suite struct OpenFieldKeysTests {
    @Test func librarySearchKeepsUndoAndPaste() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.panel.focusSearch()
        for ch in "ab" { #expect(env.panel.key(.character(ch), modifiers: [])) }
        #expect(env.panel.searchText == "ab")
        #expect(env.panel.key(.character("z"), modifiers: .command))
        #expect(env.panel.searchText == "")
        TextClipboard.shared.write("song")
        #expect(env.panel.key(.character("v"), modifiers: .command))
        #expect(env.panel.searchText == "song")
        #expect(env.panel.key(.character("c"), modifiers: .command))
    }

    @Test func effectsSearchKeepsUndoAndPaste() {
        let panel = EffectsDrawPanel(defaults: UserDefaults(suiteName: "OpenFieldKeys.\(UUID().uuidString)")!)
        panel.focusSearch()
        for ch in "ab" { #expect(panel.key(.character(ch), modifiers: [])) }
        #expect(panel.key(.character("z"), modifiers: .command))
        #expect(panel.searchText == "")
        TextClipboard.shared.write("blur")
        #expect(panel.key(.character("v"), modifiers: .command))
        #expect(panel.searchText == "blur")
    }
}

@MainActor
@Suite struct LibraryMarqueeTests {
    @Test func dragFromEmptySpaceSelectsTheTilesTheBandCrosses() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let f = await env.model.addFolder(url: env.media)
        await env.model.rescan(f.id)
        env.panel.setViewMode(.grid)
        env.panel.refresh()
        let panel = env.panel
        let tiles = panel.placed().filter { !panel.cells[$0.index].isHeader }
        #expect(tiles.count >= 2)
        let first = panel.cellRect(tiles[0])
        // Start in the list's empty bottom right corner, drag over the first and last tile.
        let empty = CGPoint(x: panel.size.width - 2, y: panel.size.height - 2)
        #expect(panel.cellIndex(at: empty) == nil)
        panel.mouseDown(at: empty, modifiers: [])
        panel.mouseDragged(to: CGPoint(x: first.minX + 1, y: first.minY + 1))
        #expect(panel.selected == Set(tiles.map { panel.cells[$0.index].key }))
        panel.mouseUp(at: CGPoint(x: first.minX + 1, y: first.minY + 1))
        #expect(panel.marquee == nil && !panel.selected.isEmpty)
        // A plain press on empty space starts over; Cmd keeps the earlier selection.
        let kept = panel.selected
        panel.mouseDown(at: empty, modifiers: .command)
        panel.mouseDragged(to: CGPoint(x: empty.x - 1, y: empty.y - 1))
        #expect(panel.selected == kept)
        panel.mouseUp(at: empty)
        panel.mouseDown(at: empty, modifiers: [])
        #expect(panel.selected.isEmpty)
    }

    @Test func theListHasNoBand() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        env.panel.setViewMode(.list)
        env.panel.refresh()
        env.panel.mouseDown(at: CGPoint(x: env.panel.size.width - 2, y: env.panel.size.height - 2), modifiers: [])
        #expect(env.panel.marquee == nil)
    }
}
