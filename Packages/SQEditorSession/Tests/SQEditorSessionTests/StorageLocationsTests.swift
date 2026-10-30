import Foundation
import Testing
import SQMedia
@testable import SQEditorSession

@Suite struct StorageLocationsTests {
    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "sq-storage-\(UUID().uuidString)")! }

    @Test func defaultsResolveToTheUsualPlaces() {
        let l = StorageLocations()
        #expect(l.proxyDirectory.path.hasSuffix("Library/Caches/SequenceStudio/Proxies"))
        #expect(l.cacheRoot == AppSettings.defaultCacheFolder)
        #expect(l.scratchRoot.lastPathComponent == "Scratch")
        #expect(l.projectsRoot.lastPathComponent == "Sequence Studio")
    }

    @Test func pickedCacheRootDecidesProxiesAndWaveforms() {
        let l = StorageLocations(cacheFolder: URL(fileURLWithPath: "/Volumes/Fast/C", isDirectory: true))
        #expect(l.proxyDirectory.path == "/Volumes/Fast/C/Proxies")
        #expect(l.waveformDirectory.path == "/Volumes/Fast/C/Waveforms")
        #expect(l.scratchRoot.path == "/Volumes/Fast/C/Scratch")
    }

    @Test func exportFallbackIsTheProjectsRoot() {
        let projects = tmp().appendingPathComponent("P", isDirectory: true)
        let l = StorageLocations(projectsFolder: projects)
        #expect(l.exportFallbackDirectory?.path == projects.path)
        #expect(FileManager.default.fileExists(atPath: projects.path))
    }

    @Test func scratchAndProjectsOverridesWin() {
        let l = StorageLocations(cacheFolder: URL(fileURLWithPath: "/a"), scratchFolder: URL(fileURLWithPath: "/s"),
                                 projectsFolder: URL(fileURLWithPath: "/p"))
        #expect(l.scratchRoot.path == "/s" && l.projectsRoot.path == "/p")
    }

    @Test func roundTripsThroughDefaultsAndReadsTheLegacyCacheKey() {
        let d = defaults()
        d.set("/old/cache", forKey: AppSettings.Key.cache)
        #expect(StorageLocations.load(from: d).cacheFolder?.path == "/old/cache")
        var l = StorageLocations(cacheFolder: URL(fileURLWithPath: "/n/c", isDirectory: true),
                                 scratchFolder: URL(fileURLWithPath: "/n/s", isDirectory: true), projectsFolder: nil)
        l.save(to: d)
        #expect(StorageLocations.load(from: d) == l)
        l.cacheFolder = nil; l.scratchFolder = nil; l.save(to: d)
        #expect(StorageLocations.load(from: d) == StorageLocations())
        #expect(d.string(forKey: StorageLocations.Key.cache) == nil)
    }

    @Test func relativeStoredPathsAreIgnored() {
        let d = defaults()
        d.set("relative", forKey: StorageLocations.Key.scratch)
        #expect(StorageLocations.load(from: d).scratchFolder == nil)
    }

    @Test func windowsDrivePathsCountAsAbsolute() {
        for p in ["/Users/a", "C:/Users/a", "c:\\cache", "\\\\server\\share"] { #expect(StorageLocations.isAbsolutePath(p), "\(p)") }
        for p in ["", "rel", "C:", "C:rel", "1:/x"] { #expect(!StorageLocations.isAbsolutePath(p), "\(p)") }
    }

    @Test func validationAcceptsWritableFolderWithSpace() {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StorageLocations.validate(dir, requiredBytes: 10, freeBytes: { _ in 1000 }) == nil)
    }

    @Test func validationRejectsEachProblem() {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt"); try? Data("x".utf8).write(to: file)
        #expect(StorageLocations.validate(URL(string: "rel")!, freeBytes: { _ in 1 << 40 }) == .notAbsolute)
        #expect(StorageLocations.validate(file, freeBytes: { _ in 1 << 40 }) == .notAFolder)
        #expect(StorageLocations.validate(dir, requiredBytes: 500, freeBytes: { _ in 100 }) == .notEnoughSpace(free: 100, needed: 500))
        let ro = dir.appendingPathComponent("ro", isDirectory: true)
        try? FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        if getuid() != 0 { #expect(StorageLocations.validate(ro, freeBytes: { _ in 1 << 40 }) == .notWritable) }
    }

    @Test func validationCreatesAMissingFolderUnderAWritableParent() {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("new/inner", isDirectory: true)
        #expect(StorageLocations.validate(sub, freeBytes: { _ in 1 << 40 }) == nil)
    }

    @Test func migrationCopiesAndNeverDeletesOrOverwrites() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        let fm = FileManager.default
        try fm.createDirectory(at: old.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: old.appendingPathComponent("a.mov"))
        try Data("b".utf8).write(to: old.appendingPathComponent("sub/b.mov"))
        try Data("keep".utf8).write(to: old.appendingPathComponent("clash.mov"))
        try Data("mine".utf8).write(to: new.appendingPathComponent("clash.mov"))
        let r = StorageLocations.migrate(from: old, to: new)
        #expect(r.copied == 2 && r.skipped == 1 && r.failed == 0)
        #expect(fm.fileExists(atPath: new.appendingPathComponent("sub/b.mov").path))
        #expect(try Data(contentsOf: new.appendingPathComponent("clash.mov")) == Data("mine".utf8))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("a.mov").path), "old data stays")
    }

    @Test func migrationRefusesNestedOrIdenticalFolders() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("a.mov"))
        #expect(StorageLocations.migrate(from: root, to: root).copied == 0)
        #expect(StorageLocations.migrate(from: root, to: inner).copied == 0)
        #expect(StorageLocations.migrate(from: inner, to: root).copied == 0)
    }

    @Test func appSettingsProxyDirectoryFollowsTheResolver() {
        var s = AppSettings.standard
        s.cacheFolder = URL(fileURLWithPath: "/x/y", isDirectory: true)
        #expect(s.proxyCacheDirectory.path == "/x/y/Proxies")
    }

    @Test func settingsLocationsReadScratchAndProjectsPicks() {
        let d = defaults()
        StorageLocations(scratchFolder: URL(fileURLWithPath: "/s"), projectsFolder: URL(fileURLWithPath: "/p")).save(to: d)
        var s = AppSettings.standard
        s.cacheFolder = URL(fileURLWithPath: "/c")
        let l = s.locations(from: d)
        #expect(l.cacheFolder?.path == "/c")
        #expect(l.scratchRoot.path == "/s")
        #expect(l.projectsRoot.path == "/p")
    }

    @Test func scratchDirectoryIsCreatedUnderTheRoot() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let l = StorageLocations(scratchFolder: root)
        let u = try #require(l.scratchDirectory("Pasted"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(u.path == root.appendingPathComponent("Pasted").path)
    }

    @Test func waveformCacheFollowsTheCacheFolder() {
        defer { WaveformDiskCache.configureShared(directory: nil) }
        StorageLocations(cacheFolder: URL(fileURLWithPath: "/Volumes/Fast/C")).applyWaveformDirectory()
        #expect(WaveformDiskCache.shared?.directory.path == "/Volumes/Fast/C/Waveforms")
    }
}
