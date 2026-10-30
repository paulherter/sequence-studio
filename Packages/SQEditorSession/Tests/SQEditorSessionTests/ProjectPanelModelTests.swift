import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func ref(_ name: String, path: String? = nil, w: Int = 3840, dur: Time = Time(10, 1)) -> MediaRef {
    let v = VideoTrackInfo(width: w, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                           nominalFrameDuration: Time(1001, 30000), isVariableFrameRate: false)
    return MediaRef(name: name, path: path ?? "/nonexistent/\(name)", fingerprint: MediaFingerprint(size: 1),
                    duration: dur, info: MediaInfo(duration: dur, video: v))
}

/// Lets a probe return only after a number of progressive commits landed.
private final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(need: Int, cont: CheckedContinuation<Void, Never>)] = []
    func committed(_ n: Int) {
        lock.lock()
        count = n
        let ready = waiters.filter { $0.need <= n }
        waiters.removeAll { $0.need <= n }
        lock.unlock()
        for w in ready { w.cont.resume() }
    }
    func wait(untilCommits need: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if count >= need { lock.unlock(); c.resume() } else { waiters.append((need, c)); lock.unlock() }
        }
    }
}

private final class ProbeGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0, top = 0
    func enter() { lock.lock(); now += 1; top = max(top, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return top }
}

@MainActor final class Recorder { var edits: [(Project, String)] = [] }

@MainActor private func makeModel(_ p: Project = Project(name: "P"),
                                  probe: @escaping ProjectPanelModel.Probe = { url in ref(url.lastPathComponent, path: url.path) })
    -> (ProjectPanelModel, Recorder) {
    let rec = Recorder()
    let m = ProjectPanelModel(project: p, probe: probe, onEdit: { rec.edits.append(($0, $1)) })
    return (m, rec)
}

@MainActor @Suite struct ProjectPanelModelTests {
    @Test func formatString() {
        #expect(ProjectPanelModel.formatString(ref("a")) == "3840×2160 29.97 H.264 4:2:2 10-bit")
        var r = ref("b"); r.info = nil
        #expect(ProjectPanelModel.formatString(r) == "")
    }

    /// Board `.tr` Format column: a short label (log profile, size, sample rate, sequence aspect); the full line is the tooltip.
    @Test func formatLabelIsShort() {
        #expect(ProjectPanelModel.formatLabel(ref("a")) == "3840×2160")
        var log = ref("l"); log.info?.detectedColorSpace = .sLog3SGamut3Cine
        #expect(ProjectPanelModel.formatLabel(log) == "S-Log3")
        var rec = ref("r"); rec.info?.detectedColorSpace = .rec709
        #expect(ProjectPanelModel.formatLabel(rec) == "3840×2160")
        let au = MediaRef(name: "m", path: "/x/m.mp3", fingerprint: MediaFingerprint(size: 1), duration: Time(1, 1),
                          info: MediaInfo(duration: Time(1, 1), audio: AudioTrackInfo(sampleRate: 44_100, channels: 2, codec: "mp3")))
        #expect(ProjectPanelModel.formatLabel(au) == "44.1 kHz")
        var none = ref("n"); none.info = nil
        #expect(ProjectPanelModel.formatLabel(none) == "")
        #expect(ProjectPanelModel.aspectLabel(width: 1080, height: 1920) == "9:16")
        #expect(ProjectPanelModel.aspectLabel(width: 3840, height: 2160) == "16:9")
        #expect(ProjectPanelModel.aspectLabel(width: 0, height: 0) == "")
    }

    @Test func formatColumnUsesTheShortLabel() {
        var p = Project(name: "p")
        let m = ref("a")
        p.add(m)
        let t = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: [])
        p.timelines.append(t)
        let (model, _) = makeModel(p)
        #expect(model.cellText(.format, .media(m.id)) == "3840×2160")
        #expect(model.cellText(.format, .sequence(t.id)) == "9:16")
        #expect(model.cellTooltip(.format, .media(m.id)) == "3840×2160 29.97 H.264 4:2:2 10-bit")
        #expect(model.cellTooltip(.duration, .media(m.id)) == nil)
    }

    @Test func variableFrameRateClipCarriesAConformNote() {
        var p = Project(name: "p")
        var vfr = ref("phone")
        vfr.info?.video?.isVariableFrameRate = true
        let cfr = ref("cam")
        p.add(vfr); p.add(cfr)
        let (model, _) = makeModel(p)
        let note = ProjectPanelModel.variableFrameRateNote(vfr)
        #expect(note?.hasPrefix("Variable frame rate") == true)
        #expect(note?.contains("Conform") == true)
        #expect(ProjectPanelModel.variableFrameRateNote(cfr) == nil)
        #expect(model.cellTooltip(.frameRate, .media(vfr.id)) == note)
        #expect(model.cellTooltip(.frameRate, .media(cfr.id)) == nil)
        #expect(model.cellTooltip(.format, .media(vfr.id))?.hasSuffix(note ?? "?") == true)
        #expect(model.cellTooltip(.format, .media(cfr.id)) == "3840×2160 29.97 H.264 4:2:2 10-bit")
    }

    @Test func durationTimecode() {
        #expect(ProjectPanelModel.durationString(ref("a", dur: Time(1001, 30000) * (30 * 3725))) == "01:02:05:00")
        // 301 frames at 29.97 -> 00:00:10:01 (rounded fps 30)
        let d = Time(1001, 30000) * 301
        #expect(ProjectPanelModel.durationString(ref("a", dur: d)) == "00:00:10:01")
    }

    /// Weak-Mac part 2: an import of many files probes (and copies) at most `probeLimit` at once, in the files' order.
    @Test func importProbesAreBounded() async {
        let gauge = ProbeGauge()
        let m = ProjectPanelModel(project: Project(name: "P"), probe: { url in
            gauge.enter()
            try? await Task.sleep(for: .milliseconds(3))
            gauge.leave()
            return ref(url.lastPathComponent, path: url.path)
        }, probeLimit: 3, onEdit: { _, _ in })
        let urls = (0..<30).map { URL(fileURLWithPath: "/x/clip\($0).mov") }
        await m.importFiles(urls)
        #expect(gauge.peak == 3)
        #expect(m.project.media.map(\.path) == urls.map(\.path))
        #expect(m.pendingImports == 0)
    }

    /// Large folders: with a coalescing edit handler the bin fills while the import probes (in input order, failures
    /// skipped), every step under one key so it stays one undo step named after the whole import.
    /// Deterministic: a probe only returns after the commits of every successful file before it landed, so the batches
    /// do not depend on how the probes are scheduled (the old 2 ms sleeps raced with other main-actor tests).
    @Test func largeImportFillsTheBinProgressivelyAsOneUndoStep() async {
        var steps: [(count: Int, name: String, key: String)] = []
        var plainEdits = 0
        let gate = CommitGate()
        let m = ProjectPanelModel(project: Project(name: "P"), probe: { url in
            let n = Int(url.lastPathComponent.dropFirst(4).prefix(while: \.isNumber))!
            await gate.wait(untilCommits: n < 4 ? n : n - 1)          // clip3 fails: it is not a commit
            if n == 3 { throw URLError(.cannotOpenFile) }
            return ref(url.lastPathComponent, path: url.path)
        }, probeLimit: 8, onEdit: { _, _ in plainEdits += 1 })
        let bin = m.newBin()!
        m.currentBin = bin
        m.importCommitInterval = .zero
        m.onCoalescingEdit = { p, name, key in steps.append((p.media.count, name, key)); gate.committed(steps.count) }
        let urls = (0..<8).map { URL(fileURLWithPath: "/x/clip\($0).mov") }
        await m.importFiles(urls)
        #expect(plainEdits == 1)                                            // the new bin only
        #expect(steps.count > 1)
        #expect(steps.first?.count == 1)                                    // the first file shows at once
        #expect(Set(steps.map(\.key)).count == 1)
        #expect(steps.last?.name == "Import 7 Media Items")
        #expect(m.project.media.map(\.path) == urls.map(\.path).filter { !$0.hasSuffix("clip3.mov") })
        #expect(m.project.bin(bin)!.mediaIDs.count == 7)
        #expect(m.importFailures == ["clip3.mov"])
        #expect(m.pendingImports == 0)
    }

    /// Cancel: the file being probed finishes and stays, the queued ones are never probed, the summary says how many landed.
    @Test func cancelImportKeepsFinishedFilesAndSkipsTheRest() async {
        let started = ProbeStartGate()
        let m = ProjectPanelModel(project: Project(name: "P"), probe: { url in
            await started.enter(url.lastPathComponent)
            return ref(url.lastPathComponent, path: url.path)
        }, probeLimit: 1, onEdit: { _, _ in })
        let urls = (0..<10).map { URL(fileURLWithPath: "/x/clip\($0).mov") }
        let run = Task { @MainActor in await m.importFiles(urls) }
        await started.waitUntilEntered()
        #expect(m.pendingImports == 10 && m.importTotal == 10)
        m.cancelImport()
        await started.release()
        await run.value
        #expect(m.project.media.map(\.name) == ["clip0.mov"])
        #expect(m.importCanceled?.imported == 1 && m.importCanceled?.total == 10)
        #expect(m.pendingImports == 0 && m.importTotal == 0 && m.importFailures.isEmpty)
        #expect(ProjectPanelModel.canceledText(imported: 1, total: 10) == "Import canceled: 1 of 10 files imported.")
        await m.importFiles([URL(fileURLWithPath: "/x/other.mov")])        // a later import is not canceled
        #expect(m.project.media.count == 2 && m.importCanceled == nil)
    }

    @Test func importAddsToCurrentBinInOneUndoStep() async {
        let (m, rec) = makeModel()
        let bin = m.newBin()!
        rec.edits.removeAll()
        m.currentBin = bin
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov"), URL(fileURLWithPath: "/x/b.mov")])
        #expect(rec.edits.count == 1)
        #expect(m.project.media.count == 2)
        #expect(m.project.bin(bin)!.mediaIDs.count == 2)
        #expect(m.project.rootBin.children.count == 1)
    }

    @Test func importedFilesLandAtTheOriginalPlaceThenAreReportedOnce() async {
        let (m, _) = makeModel(probe: { url in ref(url.lastPathComponent, path: url.path) })
        var reports: [[ProjectPanelModel.ImportedFile]] = []
        m.onImported = { files, _ in reports.append(files) }
        await m.importFiles([URL(fileURLWithPath: "/Downloads/a.mov"), URL(fileURLWithPath: "/Downloads/b.mov")])
        #expect(m.project.media.map(\.path) == ["/Downloads/a.mov", "/Downloads/b.mov"])
        #expect(reports.count == 1 && reports[0].map(\.url.path) == ["/Downloads/a.mov", "/Downloads/b.mov"])   // one prompt
        #expect(reports[0].map(\.id) == m.project.media.map(\.id))
        await m.importFiles([URL(fileURLWithPath: "/Downloads/a.mov")])      // already in the project: nothing to decide again
        #expect(reports.count == 1)
    }

    @Test func folderSyncFilesLinkedInMirroredBinsInOneUndoStep() async {
        let (m, rec) = makeModel(probe: { url in ref(url.lastPathComponent, path: url.path) })
        let n = await m.importSynced([FolderSyncAdd(path: "/p/Film/Day 1/a.mov", bin: ["Day 1"]),
                                      FolderSyncAdd(path: "/p/Film/b.wav", bin: [])])
        #expect(n == 2 && rec.edits.count == 1)
        #expect(m.project.media.map(\.path).sorted() == ["/p/Film/Day 1/a.mov", "/p/Film/b.wav"])
        var copy = m.project
        #expect(copy.binID(path: ["Day 1"], create: false) != nil)
        #expect(await m.importSynced([FolderSyncAdd(path: "/p/Film/b.wav", bin: [])]) == 0 && rec.edits.count == 1)
    }

    @Test func unreadableFilesAreNeverReportedForPlacement() async {
        struct Boom: Error {}
        let (m, _) = makeModel(probe: { _ in throw Boom() })
        var reports = 0
        m.onImported = { _, _ in reports += 1 }
        await m.importFiles([URL(fileURLWithPath: "/Desktop/notes.txt")])
        #expect(reports == 0 && m.importFailures == ["notes.txt"])
    }

    @Test func folderSyncWithAnAmendHookIsNoUndoStep() async {
        let (m, rec) = makeModel(probe: { url in ref(url.lastPathComponent, path: url.path) })
        var applied = 0
        m.amend = { change in applied += 1; var p = m.project; change(&p); m.setProject(p) }
        let n = await m.importSynced([FolderSyncAdd(path: "/p/Film/a.mov", bin: [])])
        #expect(n == 1 && applied == 1 && rec.edits.isEmpty)
        #expect(m.project.media.map(\.path) == ["/p/Film/a.mov"])
    }

    @Test func unreadableFilesAreProbedAgainOnlyWhenTheyChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqfail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("broken.mov")
        try Data([1, 2, 3]).write(to: file)
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let (m, _) = makeModel(probe: { _ in calls.n += 1; throw CocoaError(.fileReadCorruptFile) })
        let add = [FolderSyncAdd(path: file.path, bin: [])]
        _ = await m.importSynced(add); _ = await m.importSynced(add); _ = await m.importSynced(add)
        #expect(calls.n == 1 && m.rememberedFailureCount == 1)
        try Data([1, 2, 3, 4, 5]).write(to: file)                  // changed: worth another try
        _ = await m.importSynced(add)
        #expect(calls.n == 2)
    }

    @Test func aCanceledProbeIsNotRememberedAsABrokenFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqcancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("slow.mov")
        try Data([1, 2, 3]).write(to: file)
        let (m, _) = makeModel(probe: { _ in try await Task.sleep(for: .seconds(30)); throw CocoaError(.fileReadCorruptFile) })
        let add = [FolderSyncAdd(path: file.path, bin: [])]
        let run = Task { @MainActor in await m.importSynced(add) }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        _ = await run.value
        #expect(m.rememberedFailureCount == 0)
    }

    @Test func aSyncResultIsDroppedWhenTheProjectChangedDuringTheProbes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqstale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.mov")
        try Data([1, 2, 3]).write(to: file)
        let (m, _) = makeModel()
        let add = [FolderSyncAdd(path: file.path, bin: [])]
        let added = await m.importSynced(add, stillValid: { false })
        #expect(added == 0 && m.rememberedFailureCount == 0 && m.project.media.isEmpty)
    }

    @Test func removingAnItemInTheProjectFolderIsRemembered() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqpm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Footage/a.mov")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([1]).write(to: file)
        var p = Project(name: "P")
        let inside = ref("a.mov", path: file.path), gone = ref("b.mov", path: root.appendingPathComponent("b.mov").path)
        p.add(inside); p.add(gone)
        let (m, _) = makeModel(p)
        m.projectFolder = { root }
        m.delete([.media(inside.id), .media(gone.id)])
        // Only the file that stays in the folder is remembered: a missing one cannot come back by itself.
        #expect(m.project.mediaPolicy?.ignored == ["Footage/a.mov"])
    }

    @Test func clearMakesUsedMediaOfflineAndKeepsItsClips() {
        var p = Project(name: "P")
        let used = ref("u.mov", path: "/x/u.mov"), free = ref("f.mov", path: "/x/f.mov")
        p.add(used); p.add(free)
        var tracks = Timeline.defaultTracks(video: 1, audio: 0)
        try! tracks[0].overwrite(Clip(name: "u", media: used.id, kind: .video,
                                      source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero))
        p.timelines = [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: tracks)]
        let (m, rec) = makeModel(p)
        #expect(m.delete([.media(used.id)]).blockedItems == 1)   // delete still refuses
        let r = m.clear([.media(used.id), .media(free.id)])
        #expect(r.changed && r.offlined == 1 && r.blockedItems == 0)
        #expect(m.project.media.map(\.id) == [used.id])             // unused one is gone, used one stays
        #expect(m.project.media[0].status() == .missing)
        #expect(m.project.timelines[0].tracks[0].clips.count == 1 && m.project.timelines[0].tracks[0].clips[0].media == used.id)
        #expect(rec.edits.last?.1 == "Clear Items")
    }

    @Test func unusedMediaFilterShowsOnlyMediaNoSequenceUses() {
        var p = Project(name: "P")
        let used = ref("used.mov", path: "/x/used.mov"), free = ref("free.mov", path: "/x/free.mov")
        p.add(used); p.add(free)
        var tracks = Timeline.defaultTracks(video: 1, audio: 0)
        try! tracks[0].overwrite(Clip(name: "u", media: used.id, kind: .video,
                                      source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero))
        p.timelines = [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: tracks)]
        let (m, _) = makeModel(p)
        #expect(!m.isFiltering && m.children(of: m.project.rootBin).contains { $0.ref == .media(used.id) })
        m.mediaFilter = .unused
        #expect(m.isFiltering)
        #expect(m.children(of: m.project.rootBin).map(\.ref) == [.media(free.id)])
        m.refreshOffline()   // both paths do not exist
        m.mediaFilter = .offline
        #expect(m.children(of: m.project.rootBin).map(\.ref).count == 2)
    }

    // Review finding 37: the same file dropped twice while the first probe still ran was added twice.
    @Test func overlappingImportsOfOneFileAddItOnce() async {
        let (m, _) = makeModel(probe: { url in
            try await Task.sleep(for: .milliseconds(60))
            return ref(url.lastPathComponent, path: url.path)
        })
        let url = URL(fileURLWithPath: "/x/a.mov")
        async let first: Void = m.importFiles([url])
        async let second: Void = m.importFiles([url])
        _ = await (first, second)
        #expect(m.project.media.count == 1)
    }

    #if os(macOS)   // the failure reason and dropped-audio note come from the Mac importer (SQMedia)
    @Test func failedImportCarriesReasonAndDroppedAudioIsReported() async {
        struct Boom: Error {}
        let (m, _) = makeModel(probe: { url in
            if url.lastPathComponent == "gone.mov" { throw Boom() }
            if url.lastPathComponent == "talk.webm" { ImportNotes.noteAudioDropped(url, codec: "ac-3") }
            return ref(url.lastPathComponent, path: url.path)
        })
        var dropped: [(file: String, codec: String)] = []
        m.onAudioDropped = { dropped = $0 }
        await m.importFiles([URL(fileURLWithPath: "/nowhere/gone.mov"), URL(fileURLWithPath: "/nowhere/talk.webm")])
        #expect(m.importFailures == ["gone.mov"])
        #expect(m.importFailureReasons.count == 1)
        #expect(m.importFailureReasons[0].file == "gone.mov")
        #expect(m.importFailureReasons[0].reason.contains("no longer there"))
        #expect(ProjectPanelModel.failureStatus(m.importFailureReasons, names: m.importFailures).hasPrefix("gone.mov: "))
        #expect(dropped.map(\.file) == ["talk.webm"] && dropped.map(\.codec) == ["ac-3"])
        #expect(m.audioDroppedImports.count == 1)
    }
    #endif

    @Test func importSkipsDuplicatesAndReportsFailures() async {
        struct Boom: Error {}
        let (m, rec) = makeModel(probe: { url in
            if url.lastPathComponent == "bad.txt" { throw Boom() }
            return ref(url.lastPathComponent, path: url.path)
        })
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov")])
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov"), URL(fileURLWithPath: "/x/bad.txt")])
        #expect(m.project.media.count == 1)
        #expect(m.importFailures == ["bad.txt"])
        #expect(rec.edits.count == 1)            // second call changed nothing
        #expect(m.pendingImports == 0)
    }

    @Test func binOperations() {
        let (m, rec) = makeModel()
        let a = m.newBin(name: "A")!
        let b = m.newBin(name: "B")!
        #expect(rec.edits.count == 2)
        #expect(m.rename(.bin(a), to: "Alpha"))
        #expect(!m.rename(.bin(a), to: "  "))
        #expect(m.project.bin(a)?.name == "Alpha")
        #expect(m.move([.bin(b)], to: a))
        #expect(!m.move([.bin(a)], to: b))        // cycle refused
        #expect(m.project.bin(a)?.children.count == 1)
        #expect(m.delete([.bin(a)]).changed)
        #expect(m.project.rootBin.children.map(\.ref) == [.bin(b)])
        #expect(!m.delete([.bin(m.project.rootBin.id)]).changed)
    }

    @Test func mediaDelete() {
        let r1 = ref("a"), r2 = ref("b")
        var p = Project(name: "P"); p.add(r1); p.add(r2)
        let (m, _) = makeModel(p)
        #expect(m.delete([.media(r1.id)]).changed)
        #expect(m.project.media.map(\.id) == [r2.id])
        #expect(m.project.rootBin.mediaIDs == [r2.id])
    }

    @Test func offlineFlagged() {
        let here = URL(fileURLWithPath: #filePath).path
        var p = Project(name: "P")
        let ok = MediaRef(name: "ok", path: here, fingerprint: MediaFingerprint(size: -1))   // size mismatch: changed, not offline
        let gone = ref("gone")
        p.add(ok); p.add(gone)
        let (m, _) = makeModel(p)
        m.refreshOffline()
        #expect(m.isOffline(gone.id))
        #expect(!m.isOffline(ok.id))
    }

    @Test func sortAndSearch() {
        var p = Project(name: "P")
        let b = ref("b.mov", w: 1920), a = ref("a.mov", w: 3840, dur: Time(20, 1)), c = ref("c.mov", w: 1280, dur: Time(5, 1))
        p.add(b); p.add(a); p.add(c)
        let (m, _) = makeModel(p)
        func names() -> [String] { m.children(of: m.project.rootBin).map { m.project.displayName(of: $0.ref) } }
        #expect(names() == ["b.mov", "a.mov", "c.mov"])
        m.setSort(.name, ascending: true);      #expect(names() == ["a.mov", "b.mov", "c.mov"])
        m.setSort(.duration, ascending: false); #expect(names() == ["a.mov", "b.mov", "c.mov"])
        m.setSort(.duration, ascending: true);  #expect(names() == ["c.mov", "b.mov", "a.mov"])
        m.setSort(nil, ascending: true);        #expect(names() == ["b.mov", "a.mov", "c.mov"])
        m.searchText = "A.M"
        #expect(names() == ["a.mov"])
        #expect(m.project.rootBin.children.count == 3)   // filter is display-only
    }

    @Test func searchKeepsBinsWithMatches() {
        var p = Project(name: "P"); let r = ref("needle.mov"); p.add(r); p.add(ref("hay.mov"))
        let bin = p.newBin(name: "Sub")!; _ = p.newBin(name: "Empty")!
        p.move([.media(r.id)], to: bin)
        let (m, _) = makeModel(p)
        m.searchText = "needle"
        #expect(m.children(of: m.project.rootBin).map(\.ref) == [.bin(bin)])
        #expect(m.children(of: m.project.bin(bin)!).count == 1)
    }

    @Test func pasteboardIDsRoundTrip() {
        let refs: [BinItemRef] = [.media(UUID()), .bin(UUID()), .sequence(UUID())]
        #expect(ProjectPanelModel.decodeItems(ProjectPanelModel.encodeItems(refs)) == refs)
        #expect(ProjectPanelModel.decodeItems("garbage") == [])
    }
}

/// Holds the first probe until released (later probes pass at once).
private actor ProbeStartGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    func enter(_ name: String) async {
        if !entered {
            entered = true
            for w in enterWaiters { w.resume() }
            enterWaiters = []
            if !released { await withCheckedContinuation { waiters.append($0) } }
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }
    func release() {
        released = true
        for w in waiters { w.resume() }
        waiters = []
    }
}
