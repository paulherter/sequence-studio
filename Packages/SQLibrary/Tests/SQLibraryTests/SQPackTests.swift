import Foundation
import Testing
import SQCore
@testable import SQLibrary

@Suite struct SQPackTests {
    // MARK: Fixtures

    private func effectItem(_ name: String = "Pop In") throws -> PresetItem {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1, 2), value: 1.0)])
        let preset = EffectPreset.capture(from: c, anchor: .stretch)
        return PresetItem(kind: .effect, name: name, payload: try preset.payload(), payloadVersion: EffectPreset.payloadVersion)
    }

    private func cube(_ n: Int = 2) -> Data {
        var s = "TITLE \"t\"\nLUT_3D_SIZE \(n)\n"
        for _ in 0..<(n * n * n) { s += "0.0 0.0 0.0\n" }
        return Data(s.utf8)
    }

    private func font(_ extra: Int = 64) -> Data { Data([0, 1, 0, 0]) + Data(repeating: 7, count: extra) }

    private func pack(entries: [SQPackEntry]? = nil, assets: [SQPackAsset] = []) throws -> SQPack {
        let e = try entries ?? [SQPackEntry(item: effectItem())]
        return SQPack(manifest: SQPackManifest(name: "Pulse Presets Bundle 3.0", author: "Alex", version: "3.0",
                                               createdAt: Date(timeIntervalSince1970: 100)),
                      entries: e, assets: assets)
    }

    private func raw(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rewrite(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var o = try raw(data)
        change(&o)
        return try JSONSerialization.data(withJSONObject: o)
    }

    private func ofl(_ notice: String = "Copyright 2024 Test Authors") -> SQPackLicense { SQPackLicense(id: "OFL-1.1", notice: notice) }

    // MARK: Round trip

    @Test func roundTripKeepsEntriesAndAssets() throws {
        let lut = SQPackAsset(path: "luts/warm.cube", data: cube())
        let fnt = SQPackAsset(path: "fonts/Test-Regular.ttf", data: font(), license: ofl())
        let p = try pack(entries: [SQPackEntry(item: effectItem(), assets: ["luts/warm.cube"])], assets: [lut, fnt])
        let back = try SQPackFormat.decode(try SQPackFormat.encode(p))
        #expect(back.pack.manifest.name == "Pulse Presets Bundle 3.0" && back.pack.manifest.author == "Alex")
        #expect(back.pack.entries.count == 1 && back.pack.entries[0].name == "Pop In" && back.pack.entries[0].assets == ["luts/warm.cube"])
        #expect(back.pack.assets.map(\.path).sorted() == ["fonts/Test-Regular.ttf", "luts/warm.cube"])
        #expect(back.pack.assets.first { $0.path == "luts/warm.cube" }?.data == cube())
        #expect(back.skipped.isEmpty)
        #expect(back.pack.manifest.kinds == ["effect"])
    }

    @Test func fileIsVersionedJSON() throws {
        let o = try raw(try SQPackFormat.encode(try pack()))
        #expect(o["format"] as? String == SQPackFormat.formatName)
        #expect(o["formatVersion"] as? Int == SQPackFormat.formatVersion)
        #expect((o["manifest"] as? [String: Any])?["name"] as? String == "Pulse Presets Bundle 3.0")
    }

    // MARK: Validation

    @Test func rejectsNonPackAndNewerVersion() throws {
        #expect(throws: SQPackError.notAPack) { try SQPackFormat.decode(Data("nope".utf8)) }
        #expect(throws: SQPackError.notAPack) { try SQPackFormat.decode(try PresetFile.encode(try effectItem())) }
        let good = try SQPackFormat.encode(try pack())
        let newer = try rewrite(good) { $0["formatVersion"] = SQPackFormat.formatVersion + 1 }
        #expect(throws: SQPackError.newerFormat(found: SQPackFormat.formatVersion + 1, supported: SQPackFormat.formatVersion)) {
            try SQPackFormat.decode(newer)
        }
        let zero = try rewrite(good) { $0["formatVersion"] = 0 }
        #expect(throws: SQPackError.notAPack) { try SQPackFormat.decode(zero) }
    }

    @Test func rejectsMaliciousAssetPaths() throws {
        for path in ["../evil.cube", "luts/../../evil.cube", "/etc/x.cube", "luts/a/b.cube", "luts\\x.cube", "luts/.hidden.cube",
                     "luts/x.sh", "bin/x.cube", "luts/", "luts/x\u{0}.cube", "fonts/x.cube", "luts/x.ttf", "luts/..cube"] {
            let good = try SQPackFormat.encode(try pack(assets: [SQPackAsset(path: "luts/ok.cube", data: cube())]))
            let bad = try rewrite(good) {
                var a = $0["assets"] as! [[String: Any]]
                a[0]["path"] = path
                $0["assets"] = a
            }
            #expect(throws: SQPackError.self, "path \(path)") { try SQPackFormat.decode(bad) }
        }
    }

    @Test func encodeRejectsBadAssetPath() throws {
        let p = try pack(assets: [SQPackAsset(path: "../x.cube", data: cube())])
        #expect(throws: SQPackError.self) { try SQPackFormat.encode(p) }
    }

    @Test func rejectsChecksumMismatchAndWrongContent() throws {
        let good = try SQPackFormat.encode(try pack(assets: [SQPackAsset(path: "luts/ok.cube", data: cube())]))
        let tampered = try rewrite(good) {
            var a = $0["assets"] as! [[String: Any]]
            a[0]["data"] = Data("TITLE x\nLUT_3D_SIZE 2\n".utf8).base64EncodedString()
            $0["assets"] = a
        }
        #expect(throws: SQPackError.checksumMismatch("luts/ok.cube")) { try SQPackFormat.decode(tampered) }
        // A binary (executable-looking) blob named .cube, or a "font" that is not a font file.
        let elf = SQPackAsset(path: "luts/b.cube", data: Data([0x7f, 0x45, 0x4c, 0x46, 0, 0]))
        #expect(throws: SQPackError.self) { try SQPackFormat.encode(try pack(assets: [elf])) }
        let script = SQPackAsset(path: "fonts/f.ttf", data: Data("#!/bin/sh\n".utf8), license: ofl())
        #expect(throws: SQPackError.self) { try SQPackFormat.encode(try pack(assets: [script])) }
    }

    @Test func fontsNeedARecordedOFLLicence() throws {
        let none = SQPackAsset(path: "fonts/a.ttf", data: font())
        #expect(throws: SQPackError.missingLicense("fonts/a.ttf")) { try SQPackFormat.encode(try pack(assets: [none])) }
        let other = SQPackAsset(path: "fonts/a.ttf", data: font(), license: SQPackLicense(id: "Commercial", notice: "x"))
        #expect(throws: SQPackError.missingLicense("fonts/a.ttf")) { try SQPackFormat.encode(try pack(assets: [other])) }
        let noNotice = SQPackAsset(path: "fonts/a.ttf", data: font(), license: ofl(" "))
        #expect(throws: SQPackError.missingLicense("fonts/a.ttf")) { try SQPackFormat.encode(try pack(assets: [noNotice])) }
        // A hand-edited file that drops the license is rejected on import as well.
        let data = try SQPackFormat.encode(try pack(assets: [SQPackAsset(path: "fonts/a.ttf", data: font(), license: ofl())]))
        let stripped = try rewrite(data) {
            var a = $0["assets"] as! [[String: Any]]
            a[0]["license"] = nil
            $0["assets"] = a
        }
        #expect(throws: SQPackError.missingLicense("fonts/a.ttf")) { try SQPackFormat.decode(stripped) }
    }

    @Test func oversizedPackIsRejectedBeforeParsing() throws {
        var caps = SQPackCaps.standard
        caps.maxFileBytes = 100
        #expect(throws: SQPackError.tooLarge("file")) { try SQPackFormat.decode(try SQPackFormat.encode(try pack()), caps: caps) }
    }

    @Test func capsOnEntriesPayloadAndAssets() throws {
        let data = try SQPackFormat.encode(try pack(entries: [try SQPackEntry(item: effectItem("A")), try SQPackEntry(item: effectItem("B"))]))
        var caps = SQPackCaps.standard
        caps.maxEntries = 1
        #expect(throws: SQPackError.tooLarge("entries")) { try SQPackFormat.decode(data, caps: caps) }
        caps = .standard; caps.maxPayloadBytes = 10
        #expect(throws: SQPackError.tooLarge("payload")) { try SQPackFormat.decode(data, caps: caps) }
        let big = try SQPackFormat.encode(try pack(assets: [SQPackAsset(path: "luts/ok.cube", data: cube(8))]))
        caps = .standard; caps.maxAssetBytes = 100
        #expect(throws: SQPackError.tooLarge("asset")) { try SQPackFormat.decode(big, caps: caps) }
        caps = .standard; caps.maxTotalAssetBytes = 100
        #expect(throws: SQPackError.tooLarge("assets")) { try SQPackFormat.decode(big, caps: caps) }
        caps = .standard; caps.maxAssets = 0
        #expect(throws: SQPackError.tooLarge("assets")) { try SQPackFormat.decode(big, caps: caps) }
    }

    @Test func rejectsBadManifestAndDamagedPayload() throws {
        let good = try SQPackFormat.encode(try pack())
        for name in ["", "   ", "a/b", "..", String(repeating: "x", count: 500)] {
            let bad = try rewrite(good) { var m = $0["manifest"] as! [String: Any]; m["name"] = name; $0["manifest"] = m }
            #expect(throws: SQPackError.self, "name \(name.prefix(8))") { try SQPackFormat.decode(bad) }
        }
        let noManifest = try rewrite(good) { $0["manifest"] = nil }
        #expect(throws: SQPackError.self) { try SQPackFormat.decode(noManifest) }
        let damaged = try rewrite(good) {
            var e = $0["entries"] as! [[String: Any]]
            e[0]["payload"] = ["junk": 1]
            $0["entries"] = e
        }
        #expect(throws: SQPackError.damagedEntry("Pop In")) { try SQPackFormat.decode(damaged) }
        let empty = try rewrite(good) { $0["entries"] = [] }
        #expect(throws: SQPackError.emptyPack) { try SQPackFormat.decode(empty) }
    }

    @Test func entryReferencingMissingAssetIsRejected() throws {
        let p = try pack(entries: [SQPackEntry(item: effectItem(), assets: ["luts/none.cube"])])
        #expect(throws: SQPackError.self) { try SQPackFormat.encode(p) }
    }

    @Test func duplicateAssetPathsAreRejected() throws {
        let p = try pack(assets: [SQPackAsset(path: "luts/a.cube", data: cube()), SQPackAsset(path: "luts/A.cube", data: cube())])
        #expect(throws: SQPackError.self) { try SQPackFormat.encode(p) }
    }

    // MARK: Extensible kinds

    @Test func unknownKindsAreSkippedNotFatal() throws {
        let good = try SQPackFormat.encode(try pack())
        let future = try rewrite(good) {
            var e = $0["entries"] as! [[String: Any]]
            e.append(["kind": "multiLayerTemplate", "name": "Future", "payloadVersion": 1, "payload": ["layers": []], "assets": []])
            $0["entries"] = e
        }
        let r = try SQPackFormat.decode(future)
        #expect(r.pack.entries.map(\.name) == ["Pop In"])
        #expect(r.skipped == [SQPackSkipped(name: "Future", kind: "multiLayerTemplate")])
    }

    @Test func registeredKindPlugsInWithItsOwnValidator() throws {
        var registry = SQPackKindRegistry.standard
        registry.register("multiLayerTemplate") { payload, version in
            guard version == 1, (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { throw SQPackError.notAPack }
        }
        let entry = SQPackEntry(kind: "multiLayerTemplate", name: "Lower Third", payloadVersion: 1, payload: Data("{\"layers\":[]}".utf8))
        let data = try SQPackFormat.encode(try pack(entries: [entry]), registry: registry)
        let back = try SQPackFormat.decode(data, registry: registry)
        #expect(back.pack.entries.first?.kind == "multiLayerTemplate" && back.skipped.isEmpty)
        // The same file read by an app that does not know the kind: skipped, nothing left, so an empty pack.
        #expect(throws: SQPackError.emptyPack) { try SQPackFormat.decode(data) }
        // The plug-in validator still rejects bad payloads.
        let bad = SQPackEntry(kind: "multiLayerTemplate", name: "Bad", payloadVersion: 9, payload: Data("{}".utf8))
        #expect(throws: SQPackError.damagedEntry("Bad")) { try SQPackFormat.encode(try pack(entries: [bad]), registry: registry) }
    }

    // MARK: Store import / export

    private func makeStore() throws -> (PresetStore, TempDir) {
        let dir = try TempDir()
        return (try PresetStore(applicationSupport: dir.url), dir)
    }

    @Test func exportBundlesChosenPresets() async throws {
        let (store, dir) = try makeStore(); defer { dir.remove() }
        let a = try effectItem("A"), b = try effectItem("B")
        try await store.add(a); try await store.add(b)
        let p = try await store.makePack(ids: [a.id], manifest: SQPackManifest(name: "Mine", author: "", version: "1.0"))
        #expect(p.entries.map(\.name) == ["A"] && p.manifest.kinds == ["effect"])
        await #expect(throws: SQPackError.emptyPack) { try await store.makePack(ids: [], manifest: SQPackManifest(name: "Mine")) }
    }

    @Test func importLandsInPackFolderAndWorksImmediately() async throws {
        let (store, dir) = try makeStore(); defer { dir.remove() }
        let p = try pack(entries: [SQPackEntry(item: try effectItem("A")), SQPackEntry(item: try effectItem("B"))])
        let r = try await store.importPack(p, conflict: .rename)
        #expect(r.added.count == 2 && r.replaced == 0 && r.deferred.isEmpty)
        let all = await store.all()
        #expect(all.count == 2 && all.allSatisfy { $0.pack == "Pulse Presets Bundle 3.0" })
        let item = try #require(all.first)
        _ = try EffectPreset(payload: item.payload, version: item.payloadVersion)   // usable
        let reopened = try PresetStore(applicationSupport: dir.url)
        #expect(await reopened.all().allSatisfy { $0.pack == "Pulse Presets Bundle 3.0" })
    }

    @Test func duplicateConflictRenameReplaceSkip() async throws {
        let (store, dir) = try makeStore(); defer { dir.remove() }
        let p = try pack(entries: [SQPackEntry(item: try effectItem("A"))])
        _ = try await store.importPack(p, conflict: .rename)
        #expect(await store.conflicts(in: p) == ["A"])
        let renamed = try await store.importPack(p, conflict: .rename)
        #expect(renamed.added.map(\.name) == ["A 2"])
        let again = try await store.importPack(p, conflict: .rename)
        #expect(again.added.map(\.name) == ["A 3"])
        let skipped = try await store.importPack(p, conflict: .skip)
        #expect(skipped.added.isEmpty && skipped.skipped == 1)
        let replaced = try await store.importPack(p, conflict: .replace)
        #expect(replaced.replaced == 1 && replaced.added.isEmpty)
        #expect(await store.all().count == 3)
    }

    @Test func nonStoreKindsAreHandedBackDeferred() async throws {
        let (store, dir) = try makeStore(); defer { dir.remove() }
        var registry = SQPackKindRegistry.standard
        registry.register("workspace") { _, _ in }
        let ws = SQPackEntry(kind: "workspace", name: "Edit Wide", payloadVersion: 1, payload: Data("{}".utf8))
        let p = try pack(entries: [SQPackEntry(item: try effectItem()), ws])
        let r = try await store.importPack(p, conflict: .rename, registry: registry)
        #expect(r.added.count == 1 && r.deferred.map(\.name) == ["Edit Wide"])
    }

    @Test func assetsInstallToLUTAndFontDirectories() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let assets = [SQPackAsset(path: "luts/warm.cube", data: cube()),
                      SQPackAsset(path: "fonts/T.ttf", data: font(), license: ofl("c"))]
        let lutDir = dir.url.appendingPathComponent("LUTs"), fontDir = dir.url.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: lutDir, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: lutDir.appendingPathComponent("warm.cube"))
        let installed = try SQPackInstaller.install(assets, lutDirectory: lutDir, fontDirectory: fontDir)
        #expect(installed.luts.count == 1 && installed.luts[0].lastPathComponent == "warm 2.cube")   // existing file untouched
        #expect(try Data(contentsOf: lutDir.appendingPathComponent("warm.cube")) == Data("existing".utf8))
        #expect(installed.fonts.map(\.lastPathComponent) == ["T.ttf"])
        #expect(installed.fonts[0].path.hasPrefix(fontDir.path))
    }

    @Test func fileRoundTripAndSuggestedName() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = dir.url.appendingPathComponent("x.sqpack")
        try SQPackFormat.write(try pack(), to: url)
        #expect(try SQPackFormat.read(from: url).pack.entries.count == 1)
        #expect(SQPackFormat.suggestedFileName(for: "Pulse: Bundle/3") == "Pulse- Bundle-3.sqpack")
        #expect(SQPackFormat.suggestedFileName(for: "  ") == "Pack.sqpack")
    }

    @Test func scannerFindsLUTNamesInPayloads() {
        let payload = Data(#"{"a":{"lut":"/Users/x/LUTs/Warm Tone.cube"},"b":["Cool.3dl","notes.txt"],"c":"bad|name.cube"}"#.utf8)
        #expect(SQPackAssetScanner.lutFileNames(in: payload) == ["Cool.3dl", "Warm Tone.cube"])
        #expect(SQPackAssetScanner.lutFileNames(in: Data("nope".utf8)).isEmpty)
    }

    @Test func storeFileWithoutPackFieldStillLoads() async throws {
        let json = """
        {"formatVersion":1,"presets":[{"id":"\(UUID().uuidString)","kind":"effect","name":"Old","createdAt":"2026-01-01T00:00:00Z","payload":"e30=","payloadVersion":1}]}
        """
        let dir = try TempDir(); defer { dir.remove() }
        let url = PresetStore.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let s = try PresetStore(applicationSupport: dir.url)
        #expect(await s.all().first?.pack == nil)
    }
}
