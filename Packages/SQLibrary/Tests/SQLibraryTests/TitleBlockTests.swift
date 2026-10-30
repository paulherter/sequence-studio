import Foundation
import SQCore
import Testing
@testable import SQLibrary

@Suite struct TitleBlockTests {
    private let fd = Time(1, 30)

    private func text(_ start: Time) -> Clip {
        let id = UUID()
        return Clip(id: id, name: "Line", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: start,
                    generator: GeneratorRef(kind: GeneratorRef.text, payload: Data("{\"t\":1}".utf8)))
    }

    /// Two text clips on V2 / V3, the first with a Move head transition.
    private func selectionBlock() throws -> TimelineClipboard {
        var t = Timeline(name: "src", frameDuration: fd, tracks: Timeline.defaultTracks(video: 3, audio: 1))
        let a = text(Time(4, 1)), b = text(Time(4, 1) + Time(1, 2))
        try t.tracks[1].overwrite(a)
        try t.tracks[2].overwrite(b)
        _ = try t.addElementTransitions(kind: .move, track: t.tracks[1].id, clip: a.id, edges: [.head], duration: Time(6, 30))
        return try #require(t.clipboard(copying: [a.id, b.id]))
    }

    @Test func saveStoreReopenInsertRoundTrip() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let block = try #require(TitleBlock(block: try selectionBlock()))
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(try block.presetItem(name: "My Title"))

        let reopened = try PresetStore(applicationSupport: dir.url)
        let item = try #require(await reopened.presets(kind: .titleBlock).first)
        #expect(item.payloadVersion == TitleBlock.payloadVersion)
        let loaded = try TitleBlock(preset: item)
        #expect(loaded == block)

        var dst = Timeline(name: "dst", frameDuration: fd, tracks: Timeline.defaultTracks(video: 3, audio: 1))
        let ids = try dst.placeBlock(loaded.block, at: Time(2, 1))
        #expect(ids.count == 2)
        let v = dst.tracks.filter { $0.kind == .video }
        // An empty sequence: the free tracks from the bottom, offsets kept, the transition travels along.
        #expect(v[0].clips.first?.start == Time(2, 1))
        #expect(v[1].clips.first?.start == Time(2, 1) + Time(1, 2))
        #expect(v[0].transitions.count == 1)
    }

    @Test func refusesMediaClipsAndEmptyBlocks() {
        #expect(TitleBlock(block: TimelineClipboard(entries: [])) == nil)
        let media = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        #expect(TitleBlock(block: TimelineClipboard(entries: [.init(clip: media, offset: .zero, lane: 0)])) == nil)
    }

    @Test func newerPayloadVersionAndDamagedPayloadAreRejected() throws {
        let good = try #require(TitleBlock(block: try selectionBlock())).payload()
        #expect(throws: TitleBlock.PayloadError.newerVersion(found: 2, supported: 1)) { try TitleBlock(payload: good, version: 2) }
        #expect(throws: TitleBlock.PayloadError.damaged) { try TitleBlock(payload: Data("{}".utf8), version: 1) }
    }

    @Test func exportImportKeepsThePayloadReadable() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let block = try #require(TitleBlock(block: try selectionBlock()))
        let file = try PresetFile.encode(try block.presetItem(name: "T"))
        let imported = try PresetFile.decode(file)
        #expect(imported.kind == .titleBlock)
        #expect(try TitleBlock(preset: imported).clipCount == 2)
    }
}
