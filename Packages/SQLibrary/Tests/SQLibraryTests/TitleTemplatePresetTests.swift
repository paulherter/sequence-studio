import Foundation
import SQCore
import Testing
@testable import SQLibrary

// A saved title template (TEMPLATE-ECOSYSTEM T3): a `.titleTemplate` preset whose payload is the SQCore `TitleTemplate`
// plus an optional thumbnail. Store, reopen, validation and `.sqpack` round trip.

@Suite struct TitleTemplatePresetTests {
    private func template(name: String = "Intro") -> TitleTemplate {
        let fd = Time(1, 30)
        let id = UUID()
        let clip = Clip(id: id, name: "Title", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero,
                        generator: GeneratorRef(kind: GeneratorRef.text, payload: Data("{\"template\":{\"text\":\"Hi\"}}".utf8)))
        var track = Track(kind: .video)
        try! track.overwrite(clip)
        let content = Timeline(name: name, frameDuration: fd, tracks: [track])
        let slot = TemplateSlot(name: "Text 1", kind: .text, layer: id, path: "template.text", value: .text("Hi"))
        return TitleTemplate(name: name, content: content, slots: [slot])
    }

    @Test func presetRoundTripKeepsTemplateAndThumbnail() throws {
        let t = template()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let item = try TitleTemplatePreset(template: t, thumbnail: png).presetItem(name: "My Intro")
        #expect(item.kind == .titleTemplate)
        #expect(item.payloadVersion == TitleTemplatePreset.payloadVersion)
        let back = try TitleTemplatePreset(preset: item)
        var renamed = t
        renamed.name = "My Intro"
        #expect(back.template == renamed)
        #expect(back.thumbnail == png)
        #expect(back.template.slots.count == 1)
    }

    /// An import skips a template whose name is taken by another title template, not by a preset of another kind.
    @Test func namesCountTitleTemplatesOnly() throws {
        let items = [try TitleTemplatePreset(template: template()).presetItem(name: "Lower Third"),
                     PresetItem(kind: .effect, name: "Glow", payload: Data(), payloadVersion: 1)]
        #expect(TitleTemplatePreset.names(in: items) == ["Lower Third"])
    }

    @Test func storeReopenAndSortUnderTitles() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(try TitleTemplatePreset(template: template()).presetItem(name: "Intro"))
        let reopened = try PresetStore(applicationSupport: dir.url)
        let item = try #require(await reopened.presets(kind: .titleTemplate).first)
        #expect(try TitleTemplatePreset(preset: item).template.name == "Intro")
        #expect(PresetCategory.defaultCategory(for: .titleTemplate) == .titles)
    }

    @Test func damagedAndNewerPayloadsAreRefused() throws {
        #expect(throws: TitleTemplatePreset.PayloadError.damaged) { try TitleTemplatePreset(payload: Data("{}".utf8), version: 1) }
        #expect(throws: TitleTemplatePreset.PayloadError.newerVersion(found: 9, supported: TitleTemplatePreset.payloadVersion)) {
            try TitleTemplatePreset(payload: Data("{}".utf8), version: 9)
        }
        #expect(throws: (any Error).self) { try PresetFile.validate(kind: .titleTemplate, payload: Data("[1]".utf8), version: 1) }
    }

    @Test func packExportImportRoundTrip() async throws {
        let src = try TempDir(), dst = try TempDir(); defer { src.remove(); dst.remove() }
        let t = template()
        let store = try PresetStore(applicationSupport: src.url)
        let item = try TitleTemplatePreset(template: t).presetItem(name: "Intro")
        try await store.add(item)
        let pack = try await store.makePack(ids: [item.id], manifest: SQPackManifest(name: "Titles"), assets: [], assetRefs: [:])
        let read = try SQPackFormat.decode(try SQPackFormat.encode(pack))
        #expect(read.skipped.isEmpty)
        let other = try PresetStore(applicationSupport: dst.url)
        _ = try await other.importPack(read.pack, conflict: .skip)
        let imported = try #require(await other.presets(kind: .titleTemplate).first)
        #expect(try TitleTemplatePreset(preset: imported).template == t)
    }
}
