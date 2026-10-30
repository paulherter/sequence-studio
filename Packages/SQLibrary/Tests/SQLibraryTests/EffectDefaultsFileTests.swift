import Foundation
import Testing
import SQCore
@testable import SQLibrary

@Suite struct EffectDefaultsFileTests {
    private func sample() -> EffectDefaults {
        var e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(12)
        return EffectDefaults(effects: [e.kind: e],
                              transitions: [TransitionKind.push.rawValue: TransitionPreset(kind: .push, duration: Time(1, 2))])
    }

    @Test func livesNextToThePresetsInTheUserLibrary() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = EffectDefaultsFile.fileURL(applicationSupport: dir.url)
        #expect(url.deletingLastPathComponent() == PresetStore.fileURL(applicationSupport: dir.url).deletingLastPathComponent())
        #expect(url.lastPathComponent == "defaults.json")
    }

    @Test func missingFileIsEmptyAndSaveRoundTrips() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = EffectDefaultsFile.fileURL(applicationSupport: dir.url)
        #expect(try EffectDefaultsFile.load(url).isEmpty)
        let d = sample()
        try EffectDefaultsFile.save(d, to: url)
        #expect(try EffectDefaultsFile.load(url) == d)
    }

    @Test func newerFormatThrowsAndLeavesTheFile() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = EffectDefaultsFile.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"formatVersion": 99, "payloadVersion": 1, "defaults": {}}"#.utf8).write(to: url)
        #expect(throws: LibraryStoreError.newerFormat(found: 99, supported: EffectDefaultsFile.formatVersion)) {
            _ = try EffectDefaultsFile.load(url)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptFileIsMovedAsideAndStartsEmpty() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = EffectDefaultsFile.fileURL(applicationSupport: dir.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(try EffectDefaultsFile.load(url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
