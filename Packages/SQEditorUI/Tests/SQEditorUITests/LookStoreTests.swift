import Foundation
import Testing
import SQCore
import SQLibrary
import SQText
import SQTranscribe
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

private let red = TextStyle(fontName: "Menlo", size: 50, weight: .bold, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
private var big: TextStyle { var s = red; s.size = 90; return s }
private var huge: TextStyle { var s = red; s.size = 120; return s }

private struct OldTextStyles: Codable { var formatVersion = 1; var styles: [TextStyleEntry] }

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-looks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a `text-styles.json` as the Text panel wrote it before the Look store.
private func writeOldTextStyles(_ styles: [(String, TextStyle)], to url: URL) throws -> Data {
    let entries = styles.enumerated().map { TextStyleEntry(id: "user-0000000\($0.offset)", name: $0.element.0, style: $0.element.1) }
    let data = try JSONEncoder().encode(OldTextStyles(styles: entries))
    try data.write(to: url)
    return data
}

@MainActor @Suite struct LookStoreTests {
    @Test func oldTextStylesAreTakenInOnceAndTheOldFileStays() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("text-styles.json"), url = dir.appendingPathComponent("looks.json")
        let bytes = try writeOldTextStyles([("Red", red), ("Big", big)], to: old)
        let store = LookStore(url: url, legacyTextStyles: old)
        #expect(store.library.user.map(\.name) == ["Red", "Big"])
        #expect(store.library.user.map(\.style) == [red, big])
        #expect(store.library.user.allSatisfy { $0.animation == nil && UUID(uuidString: $0.id) != nil })
        #expect(try Data(contentsOf: old) == bytes)
        // A Look the user deletes does not come back from the old file.
        let gone = store.library.user[0].id
        let deleted = try store.edit { $0.delete(gone) }
        #expect(deleted)
        let again = LookStore(url: url, legacyTextStyles: old)
        #expect(again.library.user.map(\.name) == ["Big"])
        #expect(again.library == store.library)
    }

    @Test func aFileInTheOldFormatIsReadAsLooks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("text-styles.json")
        _ = try writeOldTextStyles([("Red", red)], to: url)
        #expect(TextStyleStore.load(from: url).user.map(\.name) == ["Red"])
    }

    @Test func captionPresetsMergeIntoTheSameLibrary() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("text-styles.json")
        _ = try writeOldTextStyles([("Red", red), ("Brand", big)], to: old)
        let presets = try PresetStore(applicationSupport: dir.appendingPathComponent("presets"))
        let same = UUID(), clash = UUID(), plain = UUID()
        func add(_ id: UUID, _ name: String, _ look: CaptionLook, _ segmentation: CaptionPreset?) async throws {
            let payload = try JSONEncoder().encode(CaptionLookPayload(look: look, segmentation: segmentation))
            try await presets.add(PresetItem(id: id, kind: .caption, name: name, payload: payload, payloadVersion: CaptionLookPayload.version))
        }
        try await add(same, "Same As Red", CaptionLook(style: red, animation: .none), nil)
        try await add(clash, "Brand", CaptionLook(style: huge, animation: .captionPop), .shortVideo)
        try await add(plain, "Pop", CaptionLook(style: red, animation: .captionPop), .standard)
        defer { for id in [same, clash, plain] { CaptionLookRegistry.shared.unregister(id: id.uuidString) } }

        let store = LookStore(url: dir.appendingPathComponent("looks.json"), legacyTextStyles: old, registry: .shared)
        let defaults = UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!
        defaults.set(same.uuidString, forKey: CaptionLookLibrary.defaultKey)
        let captions = CaptionLookLibrary(looks: store, legacy: presets, defaults: defaults)
        await captions.reload()

        // Equal values merge (the old id still resolves), a taken name gets a number, the rest keeps id and name.
        let lib = store.library
        #expect(Set(lib.user.map(\.name)) == ["Red", "Brand", "Brand 2", "Pop"])
        let redID = try #require(lib.user.first { $0.name == "Red" }?.id)
        #expect(lib.look(same.uuidString)?.id == redID)
        #expect(lib.look(clash.uuidString)?.name == "Brand 2" && lib.look(clash.uuidString)?.style == huge)
        #expect(lib.look(plain.uuidString)?.animation == .captionPop)
        #expect(LookStore.segmentation(of: lib.look(clash.uuidString)!) == .shortVideo)
        // Captions that carry an old ref still draw, also the merged one; the default follows the merge.
        let drawn = CaptionLookRegistry.shared.library(for: nil as StyleKit?)
        #expect(drawn.style(for: CaptionLook.styleID(for: same.uuidString)) == red)
        #expect(drawn.style(for: CaptionLook.styleID(for: clash.uuidString)) == huge)
        #expect(captions.defaultLookID?.uuidString == redID)
        #expect(captions.looks.count == 4)
        #expect(captions.looks.first { $0.id == clash }?.segmentation == .shortVideo)
        // The presets stay where they were; a second run changes nothing.
        #expect(await presets.presets(kind: .caption).count == 3)
        await captions.reload()
        let reopened = LookStore(url: dir.appendingPathComponent("looks.json"), legacyTextStyles: old)
        await reopened.importCaptionPresets(from: presets)
        #expect(reopened.library == lib)
    }

    @Test func handingBackACopyKeepsWhatChangedElsewhere() throws {
        let store = LookStore(url: nil)
        let keptID = try store.edit { $0.add(name: "Kept", style: red) }
        let kept = try #require(keptID)
        let base = store.library
        var copy = base
        let otherID = try store.edit { $0.add(name: "Other", style: big) }
        let other = try #require(otherID)
        let mineID = copy.add(name: "Mine", style: huge)
        let mine = try #require(mineID)
        try store.replace(with: copy, base: base)
        #expect(Set(store.library.user.map(\.id)) == [kept, other, mine])

        let secondBase = store.library
        var second = secondBase
        let d = second.delete(mine)
        #expect(d)
        _ = try store.edit { $0.rename(other, to: "Renamed") }
        _ = try store.edit { $0.delete(kept) }
        try store.replace(with: second, base: secondBase)
        #expect(store.library.user.map(\.name) == ["Renamed"])
    }

    /// The Text panel's case: ONE copy, loaded once, saved again and again while Looks are saved elsewhere. Whatever
    /// the copy never saw stays, on the first save and on every later one.
    @Test func oneOldCopySavedTwiceNeverDeletesALookItHasNotSeen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("looks.json")
        let store = LookStore(url: url)
        let keptID = try store.edit { $0.add(name: "Kept", style: red) }
        let kept = try #require(keptID)
        var panel = TextStyleLibrary(looks: store.library, base: store.library)

        let captionID = try store.edit { $0.add(name: "Caption Look", style: big, animation: .captionPop) }
        let caption = try #require(captionID)
        let firstID = panel.add(name: "First", style: huge)
        let first = try #require(firstID)
        try store.replace(with: panel.looks, base: panel.base)
        #expect(Set(store.library.user.map(\.id)) == [kept, caption, first])

        // The same copy again, still without the caption Look.
        var other = huge
        other.size = 130
        let secondID = panel.add(name: "Second", style: other)
        let second = try #require(secondID)
        try store.replace(with: panel.looks, base: panel.base)
        #expect(Set(store.library.user.map(\.id)) == [kept, caption, first, second])
        #expect(store.library.look(caption)?.animation == .captionPop)

        // And a third time, now deleting what it did see.
        let d = panel.delete(kept)
        #expect(d)
        try store.replace(with: panel.looks, base: panel.base)
        #expect(Set(store.library.user.map(\.id)) == [caption, first, second])
        #expect(LookStore(url: url).library == store.library)
    }

    @Test func aChangeIsAnnouncedSoCopiesCanReload() throws {
        let store = LookStore(url: nil)
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: LookStore.didChange, object: store, queue: nil) { _ in count.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let id = try store.edit { $0.add(name: "A", style: red) }
        #expect(count.n == 1)
        _ = try store.edit { $0.rename(id ?? "", to: "A") }
        #expect(count.n == 1)
        // The panel model takes the reloaded copy, with the store's Looks as its new base.
        let model = TextInspectorModel(styles: TextStyleLibrary())
        let now = store.library
        model.reloadStyles(TextStyleLibrary(looks: now, base: now))
        #expect(model.styles.user.map(\.name) == ["A"] && model.styles.base == now)
    }

    /// A damaged Look file is moved aside, never written over: not by the import of the old Text panel styles that
    /// follows, not by a later save.
    @Test func aDamagedFileIsMovedAsideNotWrittenOver() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("text-styles.json"), url = dir.appendingPathComponent("looks.json")
        _ = try writeOldTextStyles([("Red", red)], to: old)
        let good = LookStore(url: url, legacyTextStyles: old)
        _ = try good.edit { $0.add(name: "Mine", style: big, animation: .captionPop) }
        let whole = try Data(contentsOf: url)
        let truncated = whole.prefix(whole.count / 2)
        try truncated.write(to: url)

        let store = LookStore(url: url, legacyTextStyles: old)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("looks.json.corrupt-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(try #require(aside.first))) == truncated)
        // The store starts again from the old Text panel file and stays usable.
        #expect(store.library.user.map(\.name) == ["Red"])
        _ = try store.edit { $0.add(name: "New", style: huge) }
        #expect(LookStore(url: url).library.user.map(\.name) == ["Red", "New"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("looks.json.corrupt-") } == aside)

        // Not JSON at all, and JSON of another shape: the same.
        for junk in ["nope", "[1, 2]", "{\"formatVersion\": 1}"] {
            let d = try tempDir()
            defer { try? FileManager.default.removeItem(at: d) }
            let u = d.appendingPathComponent("looks.json")
            try Data(junk.utf8).write(to: u)
            let s = LookStore(url: u)
            #expect(s.library.user.isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: d.path)
            #expect(names.count == 1 && names[0].hasPrefix("looks.json.corrupt-"))
            #expect(try Data(contentsOf: d.appendingPathComponent(names[0])) == Data(junk.utf8))
        }
    }

    /// One Look this build cannot read does not empty the library: the others load, and it is written back as it was.
    @Test func oneUnreadableLookKeepsTheOthersAndStaysInTheFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("looks.json")
        let first = LookStore(url: url)
        _ = try first.edit { $0.add(name: "A", style: red) }
        _ = try first.edit { $0.add(name: "B", style: big, animation: .captionPop) }
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var looks = try #require(obj["looks"] as? [[String: Any]])
        let broken: [String: Any] = ["id": "broken-1", "name": "Broken", "style": "not a style", "future": 7]
        looks.insert(broken, at: 1)
        obj["looks"] = looks
        obj["aliases"] = ["old-broken": "broken-1"]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)

        let store = LookStore(url: url)
        #expect(store.library.user.map(\.name) == ["A", "B"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["looks.json"])
        _ = try store.edit { $0.add(name: "C", style: huge) }
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let kept = try #require(written["looks"] as? [[String: Any]])
        // In its old place, and the alias that points at it is still there.
        #expect(kept.map { $0["name"] as? String } == ["A", "Broken", "B", "C"])
        #expect((written["aliases"] as? [String: String])?["old-broken"] == "broken-1")
        let back = try #require(kept.first { $0["id"] as? String == "broken-1" })
        #expect(back["name"] as? String == "Broken" && back["style"] as? String == "not a style" && back["future"] as? Int == 7)
        #expect(LookStore(url: url).library.user.map(\.name) == ["A", "B", "C"])
    }

    /// A stored `text-styles.json` as the Text panel wrote it before the Look store (`Tests/Fixtures`), opened through
    /// the Text panel's store at a URL of its own: a delete persists, also when the same loaded copy is saved again.
    @Test func aStoredOldTextStylesFileIsReadAndADeletePersists() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/text-styles-v1.json")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("styles.json")
        try FileManager.default.copyItem(at: fixture, to: url)

        var lib = TextStyleStore.load(from: url)
        #expect(lib.user.map(\.name) == ["Red", "Big"])
        #expect(lib.user.map(\.style) == [red, big])
        // The same ids on every read of the old file.
        #expect(TextStyleStore.load(from: url).user.map(\.id) == lib.user.map(\.id))
        let d = lib.delete(lib.user[0].id)
        #expect(d)
        try TextStyleStore.save(lib, to: url)
        #expect(TextStyleStore.load(from: url).user.map(\.name) == ["Big"])
        try TextStyleStore.save(lib, to: url)
        #expect(TextStyleStore.load(from: url).user.map(\.name) == ["Big"])

        // As the app's old file next to the Look file: taken in once.
        let store = LookStore(url: dir.appendingPathComponent("looks.json"), legacyTextStyles: fixture)
        #expect(store.library.user.map(\.name) == ["Red", "Big"])
    }

    /// After the first import the Look store follows the `.caption` presets: added, changed, renamed and deleted ones.
    @Test func captionPresetsAreFollowedAfterTheFirstImport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = try PresetStore(applicationSupport: dir)
        func item(_ id: UUID, _ name: String, _ style: TextStyle) throws -> PresetItem {
            let payload = try JSONEncoder().encode(CaptionLookPayload(look: CaptionLook(style: style, animation: .captionPop), segmentation: .shortVideo))
            return PresetItem(id: id, kind: .caption, name: name, payload: payload, payloadVersion: CaptionLookPayload.version)
        }
        let a = UUID(), b = UUID()
        try await presets.add(item(a, "A", red))
        let url = dir.appendingPathComponent("looks.json")
        let store = LookStore(url: url)
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.map(\.name) == ["A"])

        // A Look renamed or changed here stays as it is while its preset does not change.
        _ = try store.edit { $0.rename(a.uuidString, to: "Mine") }
        try await presets.add(item(b, "B", big))
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.map(\.name) == ["Mine", "B"])

        try await presets.updatePayload(b, payload: item(b, "B", huge).payload, version: CaptionLookPayload.version)
        await store.importCaptionPresets(from: presets)
        #expect(store.library.look(b.uuidString)?.style == huge && store.library.look(b.uuidString)?.name == "B")
        try await presets.rename(b, to: "B2")
        await store.importCaptionPresets(from: presets)
        #expect(store.library.look(b.uuidString)?.name == "B2" && store.library.look(b.uuidString)?.style == huge)

        // A deleted preset takes its Look along unless the Look was edited here ("Mine").
        let c = UUID()
        try await presets.add(item(c, "C", red))
        await store.importCaptionPresets(from: presets)
        try await presets.delete(a)
        try await presets.delete(c)
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.map(\.name) == ["Mine", "B2"])
        _ = try store.edit { $0.delete(a.uuidString) }
        // A Look the user deleted does not come back while its preset stays the same; a reopened store agrees.
        _ = try store.edit { $0.delete(b.uuidString) }
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.isEmpty)
        let reopened = LookStore(url: url)
        await reopened.importCaptionPresets(from: presets)
        #expect(reopened.library.user.isEmpty)
    }

    /// A Look saved from the caption panels writes its preset too. The follow does not take that preset for a new or
    /// changed one: an edit or delete of the Look in the Text panel survives a restart. Deleting the Look deletes the
    /// preset, and the caption panels list what the store holds at once.
    @Test func aLookSavedInTheCaptionPanelsKeepsALaterEditAndDelete() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = try PresetStore(applicationSupport: dir)
        let url = dir.appendingPathComponent("looks.json")
        let store = LookStore(url: url, presets: presets)
        let captions = CaptionLookLibrary(looks: store, legacy: presets, defaults: UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!)
        await captions.reload()
        let a = try await captions.save(name: "A", look: CaptionLook(style: red, animation: .none), segmentation: .standard)
        let b = try await captions.save(name: "B", look: CaptionLook(style: big, animation: .none), segmentation: .standard)
        func restarted() async -> LookLibrary {
            let s = LookStore(url: url, presets: presets)
            await s.importCaptionPresets(from: presets)
            return s.library
        }

        _ = try store.edit { $0.update(a.uuidString, style: huge) }
        #expect(captions.looks.first { $0.id == a }?.look.style == huge)
        #expect(await restarted().look(a.uuidString)?.style == huge)

        try await captions.update(b, look: CaptionLook(style: huge, animation: .captionPop), segmentation: nil)
        _ = try store.edit { $0.rename(b.uuidString, to: "Mine") }
        let after = await restarted().look(b.uuidString)
        #expect(after?.name == "Mine" && after?.style == huge && after?.animation == .captionPop)

        _ = try store.edit { $0.delete(a.uuidString) }
        #expect(captions.looks.map(\.id) == [b])
        await store.mirrored()
        #expect(await presets.presets(kind: .caption).map(\.id) == [b])
        #expect(await restarted().user.map(\.name) == ["Mine"])

        // Without a preset store to delete from, the preset stays; renaming it later does not bring the Look back.
        let dir2 = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let presets2 = try PresetStore(applicationSupport: dir2)
        let plain = LookStore(url: nil)
        let captions2 = CaptionLookLibrary(looks: plain, legacy: presets2, defaults: UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!)
        await captions2.reload()
        let c = try await captions2.save(name: "C", look: CaptionLook(style: red, animation: .none), segmentation: .standard)
        _ = try plain.edit { $0.delete(c.uuidString) }
        try await presets2.rename(c, to: "C2")
        await captions2.reload()
        #expect(plain.library.user.isEmpty && captions2.looks.isEmpty)
    }

    /// The follow deletes a Look only for a preset that is gone from a preset store that was read as it is. A preset
    /// this build cannot read, a stand-in store and a store that started empty after a damaged file delete nothing.
    @Test func anUnreadablePresetOrPresetStoreDeletesNoLook() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = try PresetStore(applicationSupport: dir)
        #expect(presets.origin == .file)
        func item(_ id: UUID, _ name: String, _ style: TextStyle) throws -> PresetItem {
            let payload = try JSONEncoder().encode(CaptionLookPayload(look: CaptionLook(style: style, animation: .none), segmentation: nil))
            return PresetItem(id: id, kind: .caption, name: name, payload: payload, payloadVersion: CaptionLookPayload.version)
        }
        let a = UUID(), b = UUID(), c = UUID()
        try await presets.add(item(a, "A", red))
        try await presets.add(item(b, "B", big))
        try await presets.add(item(c, "C", huge))
        let url = dir.appendingPathComponent("looks.json")
        let store = LookStore(url: url)
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.map(\.name) == ["A", "B", "C"])

        // A preset from a newer build: its Look stays, here and after a restart.
        try await presets.updatePayload(c, payload: Data("{\"future\":1}".utf8), version: CaptionLookPayload.version + 1)
        await store.importCaptionPresets(from: presets)
        #expect(store.library.user.map(\.name) == ["A", "B", "C"])
        let again = LookStore(url: url)
        await again.importCaptionPresets(from: presets)
        #expect(again.library.user.map(\.name) == ["A", "B", "C"])

        // The stand-in for a `presets.json` of a newer build is empty: nothing is known, nothing changes, and the Looks
        // are still followed afterwards (B's preset is deleted for real below).
        let other = try tempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        let standIn = try PresetStore(applicationSupport: other, standIn: true)
        #expect(standIn.origin == .standIn)
        let before = try Data(contentsOf: url)
        let third = LookStore(url: url)
        await third.importCaptionPresets(from: standIn)
        #expect(third.library.user.map(\.name) == ["A", "B", "C"])
        #expect(try Data(contentsOf: url) == before)
        try await presets.delete(b)
        let fourth = LookStore(url: url)
        await fourth.importCaptionPresets(from: presets)
        #expect(fourth.library.user.map(\.name) == ["A", "C"])

        // A damaged `presets.json`: the store starts empty, the Looks stay; a later clean start agrees.
        try Data("nope".utf8).write(to: presets.fileURL)
        let recovered = try PresetStore(applicationSupport: dir)
        #expect(recovered.origin == .recovered)
        let fifth = LookStore(url: url)
        await fifth.importCaptionPresets(from: recovered)
        #expect(fifth.library.user.map(\.name) == ["A", "C"])
        let clean = try PresetStore(applicationSupport: dir)
        #expect(clean.origin == .file)
        let sixth = LookStore(url: url)
        await sixth.importCaptionPresets(from: clean)
        #expect(sixth.library.user.map(\.name) == ["A", "C"])
    }

    /// A Look file from a newer build is read only: a save says so instead of being lost without a word on quit.
    @Test func aSaveToANewerLookFileThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("looks.json")
        let newer = Data("{\"formatVersion\": \(LookLibrary.formatVersion + 1), \"looks\": [], \"later\": true}".utf8)
        try newer.write(to: url)
        let store = LookStore(url: url)
        #expect(throws: LookStore.StoreError.readOnly) { _ = try store.edit { $0.add(name: "A", style: red) } }
        #expect(try Data(contentsOf: url) == newer)
    }

    /// Handing back a copy applies what it did to the aliases too: one it removed stays removed, one removed elsewhere
    /// is not brought back.
    @Test func handingBackACopyKeepsAliasRemovals() {
        let a = Look(id: "a", name: "A", style: red), b = Look(id: "b", name: "B", style: big)
        let base = LookLibrary(user: [a, b], aliases: ["old-a": "a", "old-b": "b", "both": "a"])
        var mine = base, theirs = base
        let d1 = mine.delete("old-a"), d2 = theirs.delete("old-b")
        #expect(d1 && d2)
        let out = LookStore.threeWay(base: base, mine: mine, theirs: theirs)
        #expect(out.aliases == ["both": "a"] && out.user == [a, b])
    }

    /// The caption panels' view: a blank name saves nothing and leaves the default; an id that was merged into another
    /// Look changes that Look and, deleted, only stops resolving.
    @Test func captionLooksRejectABlankNameAndResolveMergedIds() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = try PresetStore(applicationSupport: dir)
        let same = UUID()
        let payload = try JSONEncoder().encode(CaptionLookPayload(look: CaptionLook(style: red, animation: .none), segmentation: nil))
        try await presets.add(PresetItem(id: same, kind: .caption, name: "Same As Red", payload: payload, payloadVersion: CaptionLookPayload.version))
        let store = LookStore(url: nil)
        let keptID = try store.edit { $0.add(name: "Red", style: red) }
        let kept = try #require(keptID)
        let defaults = UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!
        let captions = CaptionLookLibrary(looks: store, legacy: presets, defaults: defaults)
        await captions.reload()
        #expect(store.library.user.count == 1 && store.library.look(same.uuidString)?.id == kept)
        captions.defaultLookID = UUID(uuidString: kept)

        await #expect(throws: CaptionLookLibrary.SaveError.emptyName) {
            try await captions.save(name: "  ", look: CaptionLook(style: big, animation: .none), segmentation: .standard, makeDefault: true)
        }
        #expect(store.library.user.count == 1 && captions.defaultLookID?.uuidString == kept)
        #expect(await presets.presets(kind: .caption).count == 1)

        try await captions.update(same, look: CaptionLook(style: huge, animation: .captionPop), segmentation: nil)
        #expect(store.library.look(kept)?.style == huge && store.library.look(kept)?.animation == .captionPop)
        await captions.reload()
        #expect(store.library.look(kept)?.name == "Red" && store.library.user.count == 1)

        try await captions.delete(same)
        await captions.reload()
        #expect(store.library.look(kept)?.style == huge && store.library.look(same.uuidString) == nil)
        #expect(captions.defaultLookID?.uuidString == kept)
    }
}

// MARK: - The session's Look API

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

@MainActor private func template(_ session: EditorSession, _ id: Clip.ID) throws -> (TextTemplate, AnimationSet?) {
    let clip = try #require(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
    return try TextGenerator.decode(try #require(clip.generator))
}

@MainActor @Suite struct LookSessionTests {
    @Test func textClipApplyEditUpdateSaveRenameDelete() throws {
        let session = makeSession(), store = LookStore(url: nil)
        let id = try #require(session.addTextClip(template: TextTemplate(name: "t", text: "Hi", style: red)))
        session.select(clips: [id])
        #expect(session.lookTarget == .textClip(id))
        #expect(session.lookState(store: store) == .none)
        #expect(session.looks(store: store).map(\.ref.scope) == Array(repeating: .builtIn, count: LookLibrary.builtIns.count))

        // Apply: one undo step, the clip remembers the Look.
        let title = LookRef(scope: .builtIn, id: "title")
        let depth = session.undoDepth
        #expect(session.applyLook(title, store: store))
        #expect(session.undoDepth == depth + 1)
        #expect(try template(session, id).0.style == LookLibrary.builtIns[0].style)
        #expect(session.lookState(store: store) == .applied("title"))

        // Edited: the style no longer equals the Look. A built-in Look cannot take the change.
        var (t, anims) = try template(session, id)
        t.style.size = 33
        session.updateTextClip(id, template: t, animations: anims, continuesGesture: false)
        #expect(session.lookState(store: store) == .edited("title"))
        let builtInUpdate = try session.updateLook(title, store: store)
        #expect(!builtInUpdate)

        // Save as new: the clip carries the new Look, which has no animation.
        let saved = try session.saveLookAsNew(name: " Mine ", store: store)
        let mine = try #require(saved)
        #expect(mine.scope == .user && store.library.look(mine.id)?.name == "Mine")
        #expect(store.library.look(mine.id)?.animation == nil)
        #expect(session.lookState(store: store) == .applied(mine.id))

        // Update from current.
        (t, anims) = try template(session, id)
        t.style.size = 44
        session.updateTextClip(id, template: t, animations: anims, continuesGesture: false)
        #expect(session.lookState(store: store).isEdited)
        let updated = try session.updateLook(mine, store: store)
        #expect(updated && store.library.look(mine.id)?.style.size == 44)
        #expect(session.lookState(store: store) == .applied(mine.id))

        let renamed = try session.renameLook(mine, to: "Yours", store: store)
        #expect(renamed && session.looks(store: store).last?.look.name == "Yours")
        let deleted = try session.deleteLook(mine, store: store)
        #expect(deleted && session.lookState(store: store) == .none)
    }

    @Test func aLookWithAnAnimationAnimatesTheTextClip() throws {
        let session = makeSession(), store = LookStore(url: nil)
        let id = try #require(session.addTextClip(template: TextTemplate(name: "t", text: "Hi", style: red)))
        session.select(clips: [id])
        let lookID = try store.edit { $0.add(name: "Pop", style: big, animation: .captionPop) }
        let look = try #require(lookID)
        #expect(session.applyLook(LookRef(scope: .user, id: look), store: store))
        #expect(try template(session, id).1?.animationIn == .captionPop)
        #expect(session.lookState(store: store) == .applied(look))
        session.updateTextClip(id, template: try template(session, id).0, animations: nil, continuesGesture: false)
        #expect(session.lookState(store: store) == .edited(look))
    }

    @Test func captionsCarryBuiltInAndProjectLooks() throws {
        let session = makeSession(), store = LookStore(url: nil)
        func item(_ text: String, _ a: Int64) -> CaptionItem {
            CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(a + 1, 1)), styleRef: "default")
        }
        session.replaceCaptions([item("a", 0), item("b", 2)])
        #expect(session.lookTarget == .captions)
        #expect(session.lookState(store: store) == .none)
        func drawn() -> CaptionPresetLibrary { CaptionLookRegistry.shared.library(for: session.project) }
        let animation = drawn().animation(for: session.captionItems[0].animationRef)

        // A built-in Look is copied into the project (so the file is v72) and keeps the captions' animation.
        let depth = session.undoDepth
        #expect(session.applyLook(LookRef(scope: .builtIn, id: "title"), store: store))
        #expect(session.undoDepth == depth + 1)
        for c in session.captionItems {
            #expect(drawn().style(for: c.styleRef) == LookLibrary.builtIns[0].style)
            #expect(drawn().animation(for: c.animationRef) == animation)
        }
        #expect(session.lookState(store: store) == .applied("title"))
        #expect(session.project.styleKit?.looks["builtin-title"] != nil)
        #expect(session.project.containsV72Content)
        #expect(!session.looks(store: store).contains { $0.ref.scope == .project })

        // Save as a project Look (one undo step): listed, applied, the built-in copy is no longer needed.
        let beforeSave = session.undoDepth
        let savedRef = try session.saveLookAsNew(name: "Brand", scope: .project, store: store)
        let ref = try #require(savedRef)
        #expect(session.undoDepth == beforeSave + 1)
        #expect(session.looks(store: store).last?.ref == ref)
        #expect(session.lookState(store: store) == .applied(ref.token))
        #expect(session.project.styleKit?.looks["builtin-title"] == nil)
        let inUse = try session.deleteLook(ref, store: store)
        #expect(!inUse)

        // A Style tab edit moves the captions off the Look; Update Look takes the change and gives it back.
        // The captions still know which Look they came from: the state reads "edited", not "none".
        #expect(session.editCaptionStyle(.size(61), scope: .all))
        #expect(session.lookState(store: store) == .edited(ref.token))
        #expect(session.appliedLook(store: store) == ref)
        let beforeUpdate = session.undoDepth
        let updated = try session.updateLook(ref, store: store)
        #expect(updated && session.look(ref, store: store)?.style.size == 61)
        #expect(session.undoDepth == beforeUpdate + 1)
        #expect(session.lookState(store: store) == .applied(ref.token))
        // One undo takes the whole update back: the Look and the captions.
        _ = session.undo()
        #expect(session.look(ref, store: store)?.style.size != 61)
        #expect(session.lookState(store: store) == .edited(ref.token))
        _ = session.redo()
        #expect(session.lookState(store: store) == .applied(ref.token))
        let renamed = try session.renameLook(ref, to: "Brand X", store: store)
        #expect(renamed && session.look(ref, store: store)?.name == "Brand X")

        // Choosing another caption style forgets the Look.
        let track = try #require(session.activeTimeline?.captionTracks.first)
        try session.perform("Other Style") { p in
            try p.edit(try #require(session.activeTimelineID)) { try $0.setCaptionStyle(styleRef: "default", track: track.id) }
        }
        #expect(session.lookState(store: store) == .none)
    }

    /// A Look is in use while captions carry its style or only its animation: it is then neither deleted nor pruned.
    @Test func aLookCarriedOnlyAsAnAnimationIsKept() throws {
        let session = makeSession(), store = LookStore(url: nil)
        let c = CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: "default")
        session.replaceCaptions([c])
        let savedRef = try session.saveLookAsNew(name: "Brand", scope: .project, store: store)
        let ref = try #require(savedRef)
        let track = try #require(session.activeTimeline?.captionTracks.first)
        let tl = try #require(session.activeTimelineID)
        try session.perform("Style Only") { p in
            try p.edit(tl) { try $0.setCaptionStyle(styleRef: "default", animationRef: CaptionLook.animationID(for: ref.token), track: track.id) }
        }
        #expect(session.activeTimeline?.captionTracks.first?.styleRef == "default")
        let inUse = try session.deleteLook(ref, store: store)
        #expect(!inUse && session.look(ref, store: store) != nil)
        try session.perform("No Animation") { p in
            try p.edit(tl) { try $0.setCaptionStyle(styleRef: "default", animationRef: "none", track: track.id) }
        }
        let free = try session.deleteLook(ref, store: store)
        #expect(free && session.look(ref, store: store) == nil)

        // The same for the hidden kit looks (a caption's own look, the copy of a built-in Look).
        let payload = try JSONEncoder().encode(CaptionLook(style: red, animation: .captionPop))
        let look = StyleKitLook(name: "x", payload: payload, payloadVersion: 1)
        var p = session.project
        p.styleKit = StyleKit(looks: ["own-1": look, "own-2": look, "builtin-title": look, "builtin-old": look])
        try p.edit(tl) { t in
            try t.setCaptionStyle(styleRef: CaptionLook.styleID(for: StyleKit.lookID("own-2")),
                                  animationRef: CaptionLook.animationID(for: StyleKit.lookID("own-1")), track: track.id)
        }
        CaptionStyleEdit.pruneOwnLooks(&p)
        CaptionStyleEdit.pruneKitLooks(&p, prefix: EditorSession.builtInLookPrefix)
        #expect(Set(p.styleKit?.looks.keys.map { $0 } ?? []) == ["own-1", "own-2"])
        try p.edit(tl) { t in
            try t.setCaptionStyle(styleRef: "default", animationRef: CaptionLook.animationID(for: StyleKit.lookID("builtin-title")), track: track.id)
        }
        p.styleKit?.looks["builtin-title"] = look
        CaptionStyleEdit.pruneOwnLooks(&p)
        CaptionStyleEdit.pruneKitLooks(&p, prefix: EditorSession.builtInLookPrefix)
        #expect(Set(p.styleKit?.looks.keys.map { $0 } ?? []) == ["builtin-title"])
    }

    /// A Look animated from the end sits in the clip's out-animation: that is the slot the state compares and the
    /// one Update Look reads, whatever the clip's in-animation is.
    @Test func aLookAnimatedFromTheEndComparesTheOutAnimation() throws {
        let session = makeSession(), store = LookStore(url: nil)
        let id = try #require(session.addTextClip(template: TextTemplate(name: "t", text: "Hi", style: red)))
        session.select(clips: [id])
        session.updateTextClip(id, template: try template(session, id).0, animations: AnimationSet(in: .captionPop, out: nil), continuesGesture: false)
        var out = KeyframeTemplate.captionPop
        out.anchor = .end
        out.duration = Time(3, 4)
        let lookID = try store.edit { $0.add(name: "Leave", style: big, animation: out) }
        let ref = LookRef(scope: .user, id: try #require(lookID))
        #expect(session.applyLook(ref, store: store))
        #expect(try template(session, id).1?.animationIn?.duration == KeyframeTemplate.captionPop.duration)
        #expect(try template(session, id).1?.animationOut == out)
        #expect(session.lookState(store: store) == .applied(ref.id))

        // Changing the in-animation does not touch the Look; changing the out-animation does.
        var (t, anims) = try template(session, id)
        session.updateTextClip(id, template: t, animations: AnimationSet(in: nil, out: anims?.animationOut), continuesGesture: false)
        #expect(session.lookState(store: store) == .applied(ref.id))
        var longer = out
        longer.duration = Time(1, 1)
        (t, anims) = try template(session, id)
        session.updateTextClip(id, template: t, animations: AnimationSet(in: anims?.animationIn, out: longer), continuesGesture: false)
        #expect(session.lookState(store: store) == .edited(ref.id))
        let updated = try session.updateLook(ref, store: store)
        #expect(updated && store.library.look(ref.id)?.animation == longer)
        #expect(session.lookState(store: store) == .applied(ref.id))
    }
}
