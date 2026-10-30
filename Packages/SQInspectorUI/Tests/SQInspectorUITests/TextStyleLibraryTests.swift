import AppKit
import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

@MainActor @Suite struct TextStyleLibraryTests {
    static let red = TextStyle(fontName: "Menlo", size: 50, weight: .bold, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))


    @Test func builtInsAreUniqueReadOnlyAndCoverTheLooks() {
        let b = TextStyleLibrary.builtIns
        #expect(b.count >= 8 && b.count <= 10)
        let ids = Set(b.map { $0.id }), names = Set(b.map { $0.name })
        let allBuiltIn = b.allSatisfy { $0.isBuiltIn }
        #expect(ids.count == b.count)
        #expect(allBuiltIn)
        #expect(names.count == b.count)
    }

    @Test func addNamesAndUniqueIDs() {
        var l = TextStyleLibrary()
        let a = l.add(name: "  My Look ", style: Self.red)
        let b = l.add(name: "My Look", style: Self.red)
        #expect(a != nil && b != nil && a != b)
        #expect(l.entry(a!)?.name == "My Look")
        #expect(l.user.count == 2)
        let none = l.add(name: "   ", style: Self.red)
        #expect(none == nil)
    }

    @Test func renameDeleteUpdateOnlyForUserStyles() {
        var l = TextStyleLibrary()
        let id = l.add(name: "A", style: Self.red)!
        let renamed = l.rename(id, to: "B")
        #expect(renamed)
        #expect(l.entry(id)?.name == "B")
        let blank = l.rename(id, to: " ")
        #expect(!blank)
        let updated = l.update(id, style: TextStyle())
        #expect(updated)
        #expect(l.entry(id)?.style == TextStyle())
        let builtIn = TextStyleLibrary.builtIns[0].id
        let r1 = l.rename(builtIn, to: "X"), r2 = l.delete(builtIn), r3 = l.update(builtIn, style: Self.red)
        #expect(!r1 && !r2 && !r3)
        #expect(l.entry(builtIn)?.name == TextStyleLibrary.builtIns[0].name)
        let d1 = l.delete(id)
        #expect(d1)
        #expect(l.entry(id) == nil)
        let d2 = l.delete(id)
        #expect(!d2)
    }

    @Test func duplicateMakesAnEditableCopy() {
        var l = TextStyleLibrary()
        let builtIn = TextStyleLibrary.builtIns[0]
        let copy = l.duplicate(builtIn.id)!
        #expect(l.entry(copy)?.isBuiltIn == false)
        #expect(l.entry(copy)?.style == builtIn.style)
        #expect(l.entry(copy)?.name == "\(builtIn.name) Copy")
        let again = l.duplicate(copy)!
        #expect(l.entry(again)?.name == "\(builtIn.name) Copy 2")
        let nope = l.duplicate("nope")
        #expect(nope == nil)
    }

    @Test func matchFindsEqualStyle() {
        var l = TextStyleLibrary()
        let id = l.add(name: "A", style: Self.red)!
        #expect(l.match(Self.red) == id)
        #expect(l.match(TextStyleLibrary.builtIns[2].style) == TextStyleLibrary.builtIns[2].id)
        var changed = Self.red; changed.size = 51
        #expect(l.match(changed) == nil)
    }


    @Test func userStylesSurviveSaveAndLoad() throws {
        var l = TextStyleLibrary()
        _ = l.add(name: "A", style: Self.red)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-textstyles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("text-styles.json")
        try TextStyleStore.save(l, to: url)
        let loaded = TextStyleStore.load(from: url)
        #expect(loaded == l)
        let missing = TextStyleStore.load(from: dir.appendingPathComponent("missing.json"))
        #expect(missing.user.isEmpty)
        try Data("junk".utf8).write(to: url)
        let junk = TextStyleStore.load(from: url)
        #expect(junk.user.isEmpty)
    }

    // MARK: Thumbnails

    @Test func thumbnailTextUsesShortClipTextElseSample() {
        #expect(TextStyleThumbnails.sample(forClipText: "Hello") == "Hello")
        #expect(TextStyleThumbnails.sample(forClipText: " Hello ") == "Hello")
        #expect(TextStyleThumbnails.sample(forClipText: "123456789012345678") == "123456789012345678")
        #expect(TextStyleThumbnails.sample(forClipText: "1234567890123456789") == "Aa")
        #expect(TextStyleThumbnails.sample(forClipText: "two\nlines") == "Aa")
        #expect(TextStyleThumbnails.sample(forClipText: "   ") == "Aa")
    }

    @Test func cacheKeyChangesWithLookOrTextOnly() {
        let a = TextStyleThumbnails.key(style: Self.red, text: "Aa")
        #expect(a == TextStyleThumbnails.key(style: Self.red, text: "Aa"))
        #expect(a != TextStyleThumbnails.key(style: Self.red, text: "Hi"))
        var other = Self.red; other.color = .white
        #expect(a != TextStyleThumbnails.key(style: other, text: "Aa"))
    }

    @Test func thumbnailRendersAndIsCached() {
        let cache = TextStyleThumbnails()
        let img = cache.image(style: TextStyleLibrary.builtIns[0].style, text: "Aa")
        #expect(img != nil)
        #expect(cache.renderCount == 1)
        _ = cache.image(style: TextStyleLibrary.builtIns[0].style, text: "Aa")
        #expect(cache.renderCount == 1)
        _ = cache.image(style: TextStyleLibrary.builtIns[1].style, text: "Aa")
        #expect(cache.renderCount == 2)
    }

    // MARK: Model

    func model(_ style: TextStyle = TextStyle(), styles: TextStyleLibrary = TextStyleLibrary()) -> TextInspectorModel {
        TextInspectorModel(style: style, animations: AnimationSet(in: nil, out: nil), library: .builtIn,
                           fontFamilies: { ["Helvetica"] }, styles: styles)
    }

    @Test func applyIsOneUndoStep() {
        let m = model()
        var events: [String] = []
        m.onBeginEditing = { events.append("begin") }
        m.onChange = { _, _ in events.append("change") }
        m.onEndEditing = { events.append("end") }
        let target = TextStyleLibrary.builtIns[3]
        m.applyStyle(target.id)
        #expect(m.style == target.style)
        #expect(events == ["begin", "change", "end"])
        #expect(m.selectedStyleID == target.id)
        #expect(!m.isStyleModified)
        m.setSize(m.style.size + 1)
        #expect(m.isStyleModified)
        #expect(m.selectedStyleID == nil)
    }

    @Test func applyLeavesAnimationsAlone() {
        let m = model()
        m.setInAnimation("fade")
        let before = m.animations
        m.applyStyle(TextStyleLibrary.builtIns[3].id)
        #expect(m.animations == before)
    }

    @Test func saveSelectsTheNewStyleAndReportsChange() {
        let m = model(Self.red)
        var saved: TextStyleLibrary?
        m.onStylesChanged = { saved = $0 }
        let id = m.saveCurrentAsStyle(named: "Red")
        #expect(id != nil)
        #expect(saved?.user.count == 1)
        #expect(m.selectedStyleID == id)
        #expect(m.saveCurrentAsStyle(named: " ") == nil)
    }

    @Test func updateRenameDeleteReport() {
        let m = model(Self.red)
        var count = 0
        m.onStylesChanged = { _ in count += 1 }
        let id = m.saveCurrentAsStyle(named: "Red")!
        m.setSize(80)
        #expect(m.isStyleModified)
        m.updateStyleFromCurrent(id)
        #expect(!m.isStyleModified)
        m.renameStyle(id, to: "Crimson")
        #expect(m.styles.entry(id)?.name == "Crimson")
        m.deleteStyle(id)
        #expect(m.styles.entry(id) == nil)
        #expect(count == 4)
        m.deleteStyle(TextStyleLibrary.builtIns[0].id)              // read-only: no callback
        #expect(count == 4)
    }

    @Test func loadingAClipFindsItsStyle() {
        let b = TextStyleLibrary.builtIns[1]
        let m = model()
        m.load(style: b.style, animations: AnimationSet(in: nil, out: nil))
        #expect(m.selectedStyleID == b.id)
    }

    @Test func deletingTheAppliedStyleClearsTheSelection() {
        let m = model(Self.red)
        let id = m.saveCurrentAsStyle(named: "Red")!
        m.deleteStyle(id)
        #expect(m.selectedStyleID == nil)
        #expect(!m.isStyleModified)
    }


    // MARK: Grid + view

    @Test func gridLayoutWrapsAndStripStaysOneRow() {
        let cell = NSSize(width: 96, height: 48)
        let strip = TextStyleGridLayout.size(count: 10, cell: cell, gap: 6, columns: nil)
        #expect(strip.height == 48 && strip.width == 10 * 96 + 9 * 6)
        let grid = TextStyleGridLayout.size(count: 10, cell: cell, gap: 6, columns: 3)
        #expect(grid.width == 3 * 96 + 12 && grid.height == 4 * 48 + 3 * 6)
        let f = TextStyleGridLayout.frames(count: 4, cell: cell, gap: 6, columns: 3)
        #expect(f[3].minX == 0 && f[3].minY == 54)
        #expect(TextStyleGridLayout.size(count: 0, cell: cell, gap: 6, columns: 3) == .zero)
    }

    @Test func inspectorLaysOutAtPanelWidth() {
        let v = TextInspectorView(model: model(Self.red))
        v.frame = NSRect(x: 0, y: 0, width: 280, height: 10)
        v.layoutSubtreeIfNeeded()
        let h = v.subviews.compactMap { $0 as? NSStackView }.first?.fittingSize.height ?? 0
        #expect(h > 150 && h < 1500)
    }
}
