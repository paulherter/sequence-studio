import Foundation
import Testing
@testable import SQLibrary

@Suite struct PresetStoreTests {
    func item(_ name: String, _ kind: PresetKind = .textTemplate, payload: String = "{}") -> PresetItem {
        PresetItem(kind: kind, name: name, createdAt: Date(timeIntervalSince1970: 1_000), payload: Data(payload.utf8), payloadVersion: 3)
    }

    @Test func fileLivesUnderInjectedApplicationSupport() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        #expect(store.fileURL.path == dir.url.path + "/Sequence Studio/Library/presets.json"
                || store.fileURL.path.hasSuffix("/Sequence Studio/Library/presets.json"))
        #expect(store.fileURL.path.hasPrefix(dir.url.resolvingSymlinksInPath().path)
                || store.fileURL.path.hasPrefix(dir.url.path))
    }

    @Test func crudPersistsAcrossReopen() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        let a = item("Lower Third", .textTemplate, payload: #"{"x":1}"#)
        try await store.add(a)
        try await store.add(item("Ease Out", .easing))
        try await store.rename(a.id, to: "  Title  ")
        var changed = a; changed.payload = Data("[1]".utf8); changed.payloadVersion = 4
        changed.name = "ignored"
        try await store.updatePayload(a.id, payload: changed.payload, version: 4)

        let reopened = try PresetStore(applicationSupport: dir.url)
        let all = await reopened.all()
        #expect(all.count == 2)
        let got = await reopened.preset(a.id)
        #expect(got?.name == "Title")
        #expect(got?.payload == Data("[1]".utf8))
        #expect(got?.payloadVersion == 4)
        #expect(got?.kind == .textTemplate)

        try await reopened.delete(a.id)
        #expect(await reopened.all().count == 1)
        #expect(await reopened.preset(a.id) == nil)
    }

    @Test func searchByKindAndName() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(item("Crème Schrift", .textTemplate))
        try await store.add(item("Creme Fade", .animatedTextTemplate))
        try await store.add(item("Bounce", .easing))
        #expect(await store.presets(kind: .easing).map(\.name) == ["Bounce"])
        #expect(await store.presets(kind: nil, query: "FADE creme").map(\.name) == ["Creme Fade"])
        #expect(await store.presets(kind: .textTemplate, query: "creme").map(\.name) == ["Crème Schrift"])
        #expect(await store.presets(kind: nil).map(\.name) == ["Bounce", "Creme Fade", "Crème Schrift"])
        #expect(await store.presets(kind: .caption).isEmpty)
    }

    @Test func validationErrors() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        let a = item("A")
        try await store.add(a)
        await #expect(throws: LibraryStoreError.duplicateID) { try await store.add(a) }
        await #expect(throws: LibraryStoreError.emptyName) { try await store.add(item("   ")) }
        await #expect(throws: LibraryStoreError.emptyName) { try await store.rename(a.id, to: "") }
        let missing = UUID()
        await #expect(throws: LibraryStoreError.notFound) { try await store.rename(missing, to: "x") }
        await #expect(throws: LibraryStoreError.notFound) { try await store.delete(missing) }
        #expect(await store.all().count == 1)
    }

    @Test func fileFormatIsVersionedSortedAndDeterministic() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(item("A"))
        let first = try Data(contentsOf: store.fileURL)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\"formatVersion\" : 1"))
        // sorted keys: createdAt < id < kind < name < payload
        let order = ["createdAt", "\"id\"", "\"kind\"", "\"name\"", "\"payload\"", "payloadVersion"]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        let again = try PresetStore(applicationSupport: dir.url)
        try await again.rename(await again.all()[0].id, to: "A")
        #expect(try Data(contentsOf: store.fileURL) == first)
    }

    @Test func newerFormatThrowsAndLeavesFileUntouched() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = PresetStore.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = Data(#"{"formatVersion":2,"presets":[]}"#.utf8)
        try body.write(to: url)
        #expect(throws: LibraryStoreError.newerFormat(found: 2, supported: 1)) { try PresetStore(applicationSupport: dir.url) }
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func corruptFileIsBackedUpAndStoreStartsEmpty() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = PresetStore.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        let store = try PresetStore(applicationSupport: dir.url)
        #expect(await store.all().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("presets.json.corrupt-") })
        try await store.add(item("Fresh"))
        #expect(try PresetStore(applicationSupport: dir.url).fileURL == store.fileURL)
    }

    @Test func missingFileStartsEmptyWithoutCreatingIt() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
