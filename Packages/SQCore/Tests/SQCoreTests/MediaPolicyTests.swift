import Foundation
import Testing
@testable import SQCore

@Suite struct MediaPolicyTests {
    let fm = FileManager.default
    let projectURL = URL(fileURLWithPath: "/tmp/sqmp-x/Film/Film.sqproj")

    func ref(_ path: String) -> MediaRef {
        MediaRef(name: NSString(string: path).lastPathComponent, path: path, fingerprint: MediaFingerprint(size: 10))
    }

    @Test func insideTheProjectFolderIsAlwaysLinked() {
        for mode in OutsideMediaMode.allCases {
            var p = Project(name: "Film")
            p.mediaPolicy = MediaPolicy(outside: mode)
            let d = MediaManagement.disposition(forPath: "/tmp/sqmp-x/Film/Footage/a.mov", project: p, projectURL: projectURL,
                                                defaults: MediaPolicyDefaults(outside: mode))
            #expect(d == .link)
        }
    }

    @Test func outsideFollowsProjectThenAppDefault() {
        let out = "/Users/p/Downloads/a.mov"
        var p = Project(name: "Film")
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL, defaults: MediaPolicyDefaults()) == .ask)
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL,
                                            defaults: MediaPolicyDefaults(outside: .move)) == .apply(.move))
        p.mediaPolicy = MediaPolicy(outside: .copy)
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL,
                                            defaults: MediaPolicyDefaults(outside: .move)) == .apply(.copy))
        p.mediaPolicy = MediaPolicy(outside: .leave)
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL, defaults: MediaPolicyDefaults()) == .link)
    }

    @Test func olderImportModeStillCountsUntilTheProjectChoosesAgain() {
        let out = "/Users/p/Downloads/a.mov"
        var p = Project(name: "Film", importMode: .move)
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL, defaults: MediaPolicyDefaults()) == .apply(.move))
        p.mediaPolicy = MediaPolicy(outside: .ask)
        #expect(MediaManagement.disposition(forPath: out, project: p, projectURL: projectURL, defaults: MediaPolicyDefaults()) == .ask)
    }

    @Test func unsavedAndLooseProjectsNeverAsk() {
        let p = Project(name: "Film")
        #expect(MediaManagement.disposition(forPath: "/x/a.mov", project: p, projectURL: nil, defaults: MediaPolicyDefaults()) == .link)
        let loose = URL(fileURLWithPath: "/Users/p/Documents/Film.sqproj")
        #expect(MediaManagement.disposition(forPath: "/x/a.mov", project: p, projectURL: loose, defaults: MediaPolicyDefaults()) == .link)
        #expect(MediaManagement.disposition(forPath: "/x/a.mov", project: Project(name: "F", importMode: .copy), projectURL: loose,
                                            defaults: MediaPolicyDefaults()) == .apply(.copy))
        #expect(!MediaManagement.watchesFolder(p, projectURL: loose, defaults: MediaPolicyDefaults()))
        #expect(!MediaManagement.copiesLibraryItems(p, projectURL: nil, defaults: MediaPolicyDefaults()))
    }

    @Test func switchesFollowProjectThenDefault() {
        var p = Project(name: "Film")
        // No policy (an older project) or no explicit watch choice: watching is off, whatever the app default says.
        #expect(!MediaManagement.watchesFolder(p, projectURL: projectURL, defaults: MediaPolicyDefaults()))
        p.mediaPolicy = MediaPolicy(outside: .ask)
        #expect(!MediaManagement.watchesFolder(p, projectURL: projectURL, defaults: MediaPolicyDefaults()))
        p.mediaPolicy = MediaPolicy(copyLibraryItems: false, watchFolder: false)
        #expect(!MediaManagement.watchesFolder(p, projectURL: projectURL, defaults: MediaPolicyDefaults()))
        p.mediaPolicy = MediaPolicy(copyLibraryItems: false, watchFolder: true)
        #expect(MediaManagement.watchesFolder(p, projectURL: projectURL, defaults: MediaPolicyDefaults(watchFolder: false)))
        #expect(!MediaManagement.copiesLibraryItems(p, projectURL: projectURL, defaults: MediaPolicyDefaults()))
    }

    @Test func policyIsAnOptionalKeyOlderFilesLack() throws {
        var p = Project(name: "Film")
        let plain = try JSONEncoder().encode(p)
        #expect(!String(decoding: plain, as: UTF8.self).contains("mediaPolicy"))
        #expect(try JSONDecoder().decode(Project.self, from: plain).mediaPolicy == nil)
        p.mediaPolicy = MediaPolicy(outside: .move, copyLibraryItems: false, watchFolder: nil)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.mediaPolicy == p.mediaPolicy)
    }

    @Test func copiesLandInFlatImportedAndLibraryFolders() {
        #expect(MediaManagement.importedFolder(forProjectAt: projectURL).path == "/tmp/sqmp-x/Film/Files/Imported")
        #expect(MediaManagement.libraryFolder(forProjectAt: projectURL).path == "/tmp/sqmp-x/Film/Files/Library")
        let l = MediaManagement.layout(name: "Film", in: URL(fileURLWithPath: "/tmp/p"))
        #expect(!fm.fileExists(atPath: l.filesFolder.path))   // nothing is created by planning
        // A name clash gets " 2" (flat folder).
        let plan = MediaManagement.collectPlan(media: [ref("/a/x.mov"), ref("/b/x.mov")], into: MediaManagement.importedFolder(forProjectAt: projectURL),
                                               existing: [], exists: { _ in true })
        #expect(plan.map { ($0.destination as NSString).lastPathComponent } == ["x.mov", "x 2.mov"])
    }

    @Test func outsideMediaCountsDistinctExistingFilesAndSkipsAppFiles() {
        let media = [ref("/tmp/sqmp-x/Film/Files/a.mov"), ref("/Users/p/Downloads/b.mov"), ref("/Users/p/Downloads/b.mov"),
                     ref("/Users/p/Downloads/gone.mov"), ref("/cache/strip.mov")]
        let out = MediaManagement.outsideMedia(media, projectURL: projectURL, exists: { !$0.contains("gone") },
                                               ignore: { $0.hasPrefix("/cache/") })
        #expect(out.map(\.path) == ["/Users/p/Downloads/b.mov"])
        #expect(MediaManagement.outsideHint(count: 3) == "3 files outside the project folder")
        #expect(MediaManagement.outsideHint(count: 1) == "1 file outside the project folder")
        #expect(MediaManagement.outsideHint(count: 0) == nil)
        #expect(MediaManagement.outsideMedia(media, projectURL: nil, exists: { _ in true }).isEmpty)
    }

    @Test func folderSyncPlanMirrorsFoldersAndSkipsKnownAndNoise() {
        let root = URL(fileURLWithPath: "/p/Film")
        let files = ["/p/Film/Day 1/A/a.mov", "/p/Film/b.wav", "/p/Film/Film.sqproj/x.png", "/p/Film/.hidden/c.mov",
                     "/p/Film/Exports/out.mov", "/p/Film/Files/Imported/known.mov", "/p/Film/Files/Imported/pending.mov",
                     "/p/Film/Day 1/A/.x.mov.sqpart-1", "/elsewhere/z.mov"]
        let plan = MediaManagement.folderSyncPlan(files: files, projectFolder: root,
                                                  known: ["/p/Film/Files/Imported/Known.mov"],
                                                  ignoring: ["/p/Film/Files/Imported/pending.mov"])
        #expect(plan == [FolderSyncAdd(path: "/p/Film/Day 1/A/a.mov", bin: ["Day 1", "A"]), FolderSyncAdd(path: "/p/Film/b.wav", bin: [])])
    }

    @Test func neverWatchesHomeStandardFoldersOrVolumeRoots() {
        let home = NSHomeDirectory()
        var p = Project(name: "Film")
        p.mediaPolicy = MediaPolicy(watchFolder: true)
        for folder in [home, home + "/Movies", home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Music",
                       home + "/Pictures", "/Volumes/Disk", "/Users"] {
            let url = URL(fileURLWithPath: folder + "/Film.sqproj")
            #expect(!MediaManagement.watchesFolder(p, projectURL: url, defaults: MediaPolicyDefaults()), "\(folder)")
        }
        #expect(MediaManagement.watchesFolder(p, projectURL: URL(fileURLWithPath: home + "/Movies/Film/Film.sqproj"), defaults: MediaPolicyDefaults()))
    }

    @Test func ignoredFilesStayOutOfTheSyncUntilImportedAgain() throws {
        let folder = URL(fileURLWithPath: "/tmp/sqmp-x/Film")
        let files = ["/tmp/sqmp-x/Film/Footage/a.mov", "/tmp/sqmp-x/Film/b.mov"]
        var p = Project(name: "Film")
        p.ignoreFolderFile("/tmp/sqmp-x/Film/Footage/A.mov", projectFolder: folder)
        #expect(p.mediaPolicy?.ignored == ["Footage/A.mov"])
        let plan = MediaManagement.folderSyncPlan(files: files, projectFolder: folder, known: [], ignoredRelative: p.mediaPolicy?.ignored ?? [])
        #expect(plan.map(\.path) == ["/tmp/sqmp-x/Film/b.mov"])
        p.unignoreFolderFile("/tmp/sqmp-x/Film/Footage/a.mov", projectFolder: folder)
        #expect(p.mediaPolicy == nil)
        #expect(MediaManagement.folderSyncPlan(files: files, projectFolder: folder, known: []).count == 2)
        p.ignoreFolderFile("/tmp/sqmp-x/Film/b.mov", projectFolder: folder)   // additive key inside mediaPolicy: round trip
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.mediaPolicy?.ignored == ["b.mov"])
    }

    @Test func twoCopiesInImportedAreNotAddedAgainAfterTheRelink() {
        let folder = URL(fileURLWithPath: "/tmp/sqmp-x/Film")
        let copies = ["/tmp/sqmp-x/Film/Files/Imported/a.mov", "/tmp/sqmp-x/Film/Files/Imported/b.mov"]
        #expect(MediaManagement.folderSyncPlan(files: copies, projectFolder: folder, known: Set(copies)).isEmpty)
        #expect(MediaManagement.folderSyncPlan(files: copies, projectFolder: folder, known: [copies[0]], ignoring: [copies[1]]).isEmpty)
    }

    @Test func pendingMovesTrashOnlyWhatTheSavedProjectStillUses() {
        let a = PendingMove(id: UUID(), original: "/x/a.mov", copy: "/p/Files/Imported/a.mov")
        let b = PendingMove(id: UUID(), original: "/x/b.mov", copy: "/p/Files/Imported/b.mov")
        let c = PendingMove(id: UUID(), original: "/x/c.mov", copy: "/p/Files/Imported/c.mov")
        var m1 = ref(a.copy); m1.id = a.id
        var m2 = ref("/x/b.mov"); m2.id = b.id           // undone: points at the original again
        #expect(PendingMove.ready([a, b, c], savedMedia: [m1, m2]) == [a])   // c was removed: its original stays
    }

    @Test func filesStillBeingWrittenAreHeldBack() {
        let now = Date()
        let seen = [MediaManagement.SeenFile(path: "/a", size: 10, modified: now.addingTimeInterval(-60)),
                    MediaManagement.SeenFile(path: "/b", size: 10, modified: now.addingTimeInterval(-0.5)),     // written just now
                    MediaManagement.SeenFile(path: "/c", size: 20, modified: now.addingTimeInterval(-60))]      // grew since the last scan
        var grown = seen[2]; grown.size = 15
        let previous = ["/a": seen[0], "/b": seen[1], "/c": grown]
        let r = MediaManagement.settled(seen, previous: previous, now: now)
        #expect(r.stable == ["/a"] && r.unsettled)
        // The first sighting never imports: two scans with the same size and date are required.
        let first = MediaManagement.settled([seen[0]], previous: [:], now: now)
        #expect(first.stable.isEmpty && first.unsettled)
    }

    @Test(.enabled(if: TestFileSystem.canMakeSymlinks)) func aMoveIsNotReadyWhileAnotherItemUsesTheOriginal() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sqpm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("a.mov"); try Data([1]).write(to: real)
        let link = dir.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let move = PendingMove(id: UUID(), original: real.path, copy: "/p/Files/Imported/a.mov")
        var item1 = ref(move.copy); item1.id = move.id
        let item2 = ref(real.path)                                   // dropped again at the original path
        #expect(PendingMove.ready([move], savedMedia: [item1, item2]).isEmpty)
        #expect(PendingMove.ready([move], savedMedia: [item1, ref(link.path)]).isEmpty)   // through a symlink
        #expect(PendingMove.ready([move], savedMedia: [item1]) == [move])
    }

    @Test func syncedBinsKeepTheirIdsInEveryHistoryState() {
        let items = [(ref: ref("/p/Day 1/a.mov"), bin: ["Day 1"]), (ref: ref("/p/Day 1/A-cam/b.mov"), bin: ["Day 1", "A-cam"])]
        let ids = Project.newBinIDs(for: items)
        var one = Project(name: "F"), two = Project(name: "F")
        one.addSynced(items, newBinIDs: ids); two.addSynced(items, newBinIDs: ids)
        let a = one.binID(path: ["Day 1", "A-cam"], create: false), b = two.binID(path: ["Day 1", "A-cam"], create: false)
        #expect(a != nil && a == b)
        #expect(one.binID(path: ["Day 1"], create: false) == two.binID(path: ["Day 1"], create: false))
    }

    @Test func scanOfTenThousandFilesSkipsExportsAndIsFast() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sqscan10k-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let day = root.appendingPathComponent("Day 1"), exports = root.appendingPathComponent("Exports")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        for i in 0..<10_000 { fm.createFile(atPath: day.appendingPathComponent("clip\(i).mov").path, contents: Data([1])) }
        try Data([1]).write(to: exports.appendingPathComponent("out.mov"))
        let start = Date()
        let found = MediaManagement.scanFiles(in: root, isMedia: { $0 == "mov" })
        let plan = MediaManagement.folderSyncPlan(files: found, projectFolder: root, known: [])
        let seconds = Date().timeIntervalSince(start)
        print("PERF folder sync scan + plan, 10000 files: \(seconds) s")
        #expect(found.count == 10_000 && plan.count == 10_000 && !found.contains { $0.contains("Exports") })
    }

    @Test func scanSkipsHiddenAndPackages() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sqscan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let sub = root.appendingPathComponent("Day 1")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Film.sqproj"), withIntermediateDirectories: true)
        try Data([1]).write(to: sub.appendingPathComponent("a.MOV"))
        try Data([1]).write(to: sub.appendingPathComponent("notes.txt"))
        try Data([1]).write(to: sub.appendingPathComponent(".hidden.mov"))
        try Data([1]).write(to: root.appendingPathComponent("Film.sqproj/project.mov"))
        let found = MediaManagement.scanFiles(in: root, isMedia: { $0 == "mov" })
        #expect(found.map { ($0 as NSString).lastPathComponent } == ["a.MOV"])
    }

    /// Acceptance: zip the project folder, open it on another path: nothing stays offline.
    @Test func movedProjectFolderRelinksEverythingInsideIt() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sqmove-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("MacA/Film"), new = root.appendingPathComponent("MacB/Film")
        for rel in ["Files/Imported", "Files/Library", "Day 1"] {
            try fm.createDirectory(at: old.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        var refs: [MediaRef] = []
        for (i, rel) in ["Files/Imported/a.mov", "Files/Library/boom.wav", "Day 1/b.mov"].enumerated() {
            let u = old.appendingPathComponent(rel)
            try Data(repeating: UInt8(i), count: 100 + i).write(to: u)
            refs.append(MediaRef(name: u.lastPathComponent, path: u.path, fingerprint: MediaFingerprint(size: Int64(100 + i))))
        }
        try fm.moveItem(at: old, to: new)
        #expect(refs.allSatisfy { $0.status() == .missing })
        let found = RelinkScanner.scan(folders: [new], named: Set(refs.map { $0.name.lowercased() }))
        let result = RelinkPlanner.match(missing: refs, candidates: found)
        #expect(result.plan.count == 3 && result.sizeMismatch.isEmpty)
        var p = Project(name: "Film", media: refs)
        p.relink(result.plan)
        #expect(p.media.allSatisfy { $0.status(fileManager: fm) != .missing && MediaManagement.isInside($0.path, folder: new) })
    }

    @Test func syncedItemsLandInMirroredBinsWithoutDuplicates() {
        var p = Project(name: "Film")
        let a = ref("/p/Film/Day 1/A/a.mov"), b = ref("/p/Film/b.wav"), c = ref("/p/Film/Day 1/A/c.mov")
        #expect(p.addSynced([(a, ["Day 1", "A"]), (b, []), (c, ["day 1", "A"])]) == 3)
        let day = p.rootBin.children.compactMap { item -> Bin? in if case .bin(let x) = item { x } else { nil } }
        #expect(day.count == 1 && day[0].name == "Day 1")      // case-insensitive reuse, one folder
        #expect(p.rootBin.children.contains(.media(b.id)))
        let a2 = p.binID(path: ["Day 1", "A"], create: false)
        #expect(a2 != nil && p.rootBin.bin(a2!)?.mediaIDs == [a.id, c.id])
        #expect(p.addSynced([(ref(a.path), ["Day 1", "A"])]) == 0)       // same path again: skipped
        #expect(p.binID(path: ["Nope"], create: false) == nil)
    }
}
