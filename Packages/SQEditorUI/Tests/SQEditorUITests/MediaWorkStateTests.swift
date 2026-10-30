import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
struct MediaWorkStateTests {
    final class Count: @unchecked Sendable { var n = 0 }

    @Test func tokensReleaseOnceAndIdleFiresWhenTheLastGoes() {
        let s = MediaWorkState()
        var idle = 0
        s.onIdle = { idle += 1 }
        let a = s.hold(), b = s.hold()
        s.release(a); #expect(s.isBusy && idle == 0)
        s.release(a); #expect(s.holderCount == 1)                 // second release of the same token does nothing
        s.release(b); #expect(!s.isBusy && idle == 1)
        s.release(b); s.resume()                                   // extras are harmless
        #expect(idle == 1 && !s.isBusy)
        s.pause(); s.pause(); s.resume(); #expect(s.isBusy)
        s.resume(); #expect(!s.isBusy && idle == 2)
    }

    @Test func aRelinkWaitingForPlaybackReleasesItsTokenWhenTheProjectChanges() {
        let s = MediaWorkState()
        var idle = 0
        s.onIdle = { idle += 1 }
        let discards = Count()
        s.deferRelink(map: [UUID(): "/a"], projectID: UUID(), discard: { discards.n += 1 }, completion: { _ in Issue.record("must not apply") })
        #expect(s.isBusy)
        s.reset()                                                  // open, new, import, revert
        #expect(!s.isBusy && idle == 1 && discards.n == 1 && s.deferred.isEmpty)
    }

    @Test func aWaitingRelinkOfTheOpenProjectAppliesAndReleases() {
        let s = MediaWorkState()
        let project = UUID(), id = UUID()
        var applied: [MediaRef.ID: String] = [:]
        let discards = Count()
        s.deferRelink(map: [id: "/copy"], projectID: project, discard: { discards.n += 1 }, completion: { applied = $0 })
        s.flushDeferred(projectID: project) { $0 }
        #expect(applied == [id: "/copy"] && discards.n == 0 && !s.isBusy)
    }

    @Test func aWaitingRelinkOfAnotherProjectIsDroppedWithItsCopies() {
        let s = MediaWorkState()
        let discards = Count()
        s.deferRelink(map: [UUID(): "/copy"], projectID: UUID(), discard: { discards.n += 1 }, completion: { _ in Issue.record("must not apply") })
        s.flushDeferred(projectID: UUID()) { _ in Issue.record("must not apply"); return [:] }
        #expect(discards.n == 1 && !s.isBusy)
    }

    @Test func aSyncRequestedWhileOneRunsRunsAgain() {
        let s = MediaWorkState()
        #expect(s.beginSync())
        #expect(!s.beginSync() && !s.beginSync())                 // folded into one more run
        #expect(s.endSync())
        #expect(s.beginSync())
        #expect(!s.endSync())                                      // nothing asked meanwhile
    }

    @Test func resetForgetsEverythingOfTheOldProject() {
        let s = MediaWorkState()
        let g = s.generation, e = s.watchEpoch
        s.pendingAsk = [ProjectPanelModel.ImportedFile(id: UUID(), url: URL(fileURLWithPath: "/x.mov"))]
        s.lastSeen = ["/x.mov": MediaManagement.SeenFile(path: "/x.mov", size: 1, modified: Date())]
        s.sequenceFrames = ["/f1.png"]
        s.reset()
        #expect(s.pendingAsk.isEmpty && s.lastSeen.isEmpty && s.sequenceFrames.isEmpty)
        #expect(s.generation == g + 1 && s.watchEpoch > e)
    }

    @Test func aFailedSaveAsKeepsTheWatchSettingAndASuccessfulOneTurnsItOff() async throws {
        var p = EditorSession.makeUntitled()
        p.mediaPolicy = MediaPolicy(watchFolder: true)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqsa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        await #expect(throws: (any Error).self) {
            try await session.saveAsWithoutWatching(to: URL(fileURLWithPath: "/dev/null/nope/a.sqproj"))
        }
        #expect(session.project.mediaPolicy?.watchFolder == true)
        try await session.saveAsWithoutWatching(to: base.appendingPathComponent("a.sqproj"))
        #expect(session.project.mediaPolicy?.watchFolder == false)
    }

    @Test func aFileAnotherBatchReusedOrLinkedIsNeverDiscarded() {
        let s = MediaWorkState()
        #expect(s.discardable(["/p/a.mov", "/p/b.mov"], inUse: [], otherBatchesRunning: false) == ["/p/a.mov", "/p/b.mov"])
        s.claim(["/p/a.mov"])                                                        // reused or relinked by another batch
        #expect(s.discardable(["/p/a.mov", "/p/b.mov"], inUse: [], otherBatchesRunning: false) == ["/p/b.mov"])
        #expect(s.discardable(["/p/b.mov"], inUse: ["/p/b.mov"], otherBatchesRunning: false).isEmpty)   // a media item uses it
        #expect(s.discardable(["/p/b.mov"], inUse: [], otherBatchesRunning: true).isEmpty)              // a batch may reuse it now
        s.reset()
        #expect(s.claimed.contains("/p/a.mov"))                                       // a claim survives a project change
    }

    @Test func theWatchSettingIsFollowedWhenItChanges() {
        let s = MediaWorkState()
        #expect(s.watchSettingChanged(to: false))      // first look
        #expect(!s.watchSettingChanged(to: false))
        #expect(s.watchSettingChanged(to: true))       // menu or redo
        #expect(s.watchSettingChanged(to: false))      // undo
        s.reset()
        #expect(s.watchSettingChanged(to: false))      // a new project is looked at again
    }

    @Test func theSessionAnnouncesEveryProjectReplacement() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqrep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let session = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        var fired = 0
        session.onProjectReplaced = { fired += 1 }
        let file = base.appendingPathComponent("a.sqproj")
        try await session.saveAs(to: file)
        #expect(fired == 0)                                  // saving replaces nothing
        try await session.open(url: file); #expect(fired == 1)       // open, and Revert (same file, same project id)
        try await session.open(url: file); #expect(fired == 2)
        session.newProject(); #expect(fired == 3)                    // New Project, Premiere import
        session.closeProject(); #expect(fired == 4)
    }

    @Test func aPromptAnswerAfterARevertIsIgnored() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let session = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        let state = MediaWorkState()
        session.onProjectReplaced = { state.reset() }          // the app's wiring: cancelCopies() resets first
        let file = base.appendingPathComponent("a.sqproj")
        try await session.saveAs(to: file)
        let dropped = [ProjectPanelModel.ImportedFile(id: UUID(), url: URL(fileURLWithPath: "/out/a.mov"))]
        state.pendingAsk = dropped
        let shownFor = state.generation                         // the prompt is up
        try await session.open(url: file)                       // Revert
        #expect(state.takePendingAsk(promptGeneration: shownFor) == nil)   // the late answer does nothing
        #expect(state.pendingAsk.isEmpty)                       // and the queue went with the old project
    }

    // MARK: LUTs collected into the project at save

    private func gradedProject(lut: String) -> Project {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var e = ColorEffect(id: 1, inputLUT: .automatic)
        e.creative.look = .file(lut)
        c.effects = [ClipEffect.colorGrade(e)]
        var v = Track(kind: .video)
        try? v.overwrite(c)
        return Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])])
    }

    private func lutSession(_ base: URL, lut: URL) throws -> EditorSession {
        try Data("LUT_3D_SIZE 2\n".utf8).write(to: lut)
        return EditorSession(project: gradedProject(lut: lut.path), engine: StubProgramEngine(),
                             autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
    }

    private func projectFile(_ base: URL, _ folder: String, _ stem: String) throws -> URL {
        let dir = base.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(stem + ".sqproj")
    }

    private func tempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqlut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func savingCollectsTheLUTIntoTheProjectWithoutAnUndoStep() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let lut = base.appendingPathComponent("look.cube")
        let session = try lutSession(base, lut: lut)
        let folder = base.appendingPathComponent("Proj")
        let file = folder.appendingPathComponent("Proj.sqproj")
        try await session.saveAs(to: file)
        let copy = folder.appendingPathComponent("Files/Library/look.cube").path
        #expect(session.project.referencedLUTFiles == [copy])           // the absolute path of the copy
        #expect(FileManager.default.fileExists(atPath: copy))
        #expect(!session.canUndo && !session.isDirty)                  // history-neutral
        #expect(FileManager.default.fileExists(atPath: lut.path))      // the source is untouched
        try await session.save()
        #expect(session.project.referencedLUTFiles == [copy])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Files/Library").path).count == 1)
        let reopened = try ProjectFile.read(from: file)
        #expect(reopened.referencedLUTFiles == [copy])
    }

    @Test func savingKeepsTheLUTPathWhenTheSettingIsOffOrTheProjectIsLoose() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let lut = base.appendingPathComponent("look.cube")
        let session = try lutSession(base, lut: lut)
        session.mediaPolicyDefaults = { MediaPolicyDefaults(copyLibraryItems: false) }
        try await session.saveAs(to: try projectFile(base, "Off", "Off"))
        #expect(session.project.referencedLUTFiles == [lut.path])
        session.mediaPolicyDefaults = { MediaPolicyDefaults(copyLibraryItems: true) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Loose"), withIntermediateDirectories: true)
        try await session.saveAs(to: try projectFile(base, "Loose", "other"))     // not a project folder layout
        #expect(session.project.referencedLUTFiles == [lut.path])
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Loose/Files").path))
    }

    @Test func saveAsToAnotherFolderCollectsIntoTheNewFolder() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = try lutSession(base, lut: base.appendingPathComponent("look.cube"))
        try await session.saveAs(to: try projectFile(base, "One", "One"))
        try await session.saveAs(to: try projectFile(base, "Two", "Two"))
        let two = base.appendingPathComponent("Two/Files/Library/look.cube").path
        #expect(FileManager.default.fileExists(atPath: two))
        #expect(session.project.referencedLUTFiles == [two])
        // A loose Save As afterwards keeps the last good path; the file still resolves.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Loose"), withIntermediateDirectories: true)
        try await session.saveAs(to: try projectFile(base, "Loose", "x"))
        let kept = try #require(session.project.referencedLUTFiles.first)
        #expect(MediaManagement.resolveStoredPath(kept, projectFolder: nil).map { FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test func aRecoveredProjectKeepsItsLUT() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let lut = base.appendingPathComponent("look.cube")
        let session = try lutSession(base, lut: lut)
        session.amendProject { $0.name = "P2" }                                    // dirty, so an autosave is due
        #expect(await session.tickAutosave())
        let scanner = RecoveryScanner(store: AutosaveStore(base: base.appendingPathComponent("auto")), isProcessAlive: { _ in false })
        let found = EditorSession.recoveryCandidates(scanner: scanner)
        let recovered = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        try await recovered.recover(try #require(found.first), scanner: scanner)
        #expect(recovered.fileURL == nil)
        let path = try #require(recovered.project.referencedLUTFiles.first)
        #expect(MediaManagement.resolveStoredPath(path, projectFolder: nil) == lut.path)
        // And once it is saved into a project folder, the LUT is collected there.
        try await recovered.saveAs(to: try projectFile(base, "Rec", "Rec"))
        #expect(recovered.project.referencedLUTFiles == [base.appendingPathComponent("Rec/Files/Library/look.cube").path])
    }

    @Test func aProjectSwitchDuringTheLUTCopyWritesNothing() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = try lutSession(base, lut: base.appendingPathComponent("look.cube"))
        let file = try projectFile(base, "Proj", "Proj")
        let saving = Task { @MainActor in try await session.saveAs(to: file) }
        await Task.yield()                                                   // the save is waiting for the copy
        let other = gradedProject(lut: base.appendingPathComponent("look.cube").path)
        session.newProject(other)                                            // Open Recent, New or Revert
        await #expect(throws: EditorSession.SaveError.projectChanged) { try await saving.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.fileURL == nil && session.project.id == other.id)
        #expect(session.project.referencedLUTFiles == [base.appendingPathComponent("look.cube").path])   // nothing swapped
    }

    private func plainSession(_ base: URL, watch: Bool = false) -> EditorSession {
        var p = EditorSession.makeUntitled()
        if watch { p.mediaPolicy = MediaPolicy(watchFolder: true) }
        return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
    }

    @Test func aProjectSwitchDuringTheWriteNeverPointsTheNewProjectAtTheOldFile() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = plainSession(base)
        let file = try projectFile(base, "Proj", "Proj")
        let saving = Task { @MainActor in try await session.saveAs(to: file) }
        await Task.yield()                                                   // the write is running
        let other = EditorSession.makeUntitled()
        session.newProject(other)
        await #expect(throws: EditorSession.SaveError.projectChanged) { try await saving.value }
        #expect(session.fileURL == nil && session.project.id == other.id)
    }

    @Test func aProjectSwitchDuringSaveAsKeepsTheNewProjectsWatchSettingAndDirtyFlag() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = plainSession(base, watch: true)
        let file = try projectFile(base, "Proj", "Proj")
        let saving = Task { @MainActor in try await session.saveAsWithoutWatching(to: file) }
        await Task.yield()
        var other = EditorSession.makeUntitled()
        other.mediaPolicy = MediaPolicy(watchFolder: true)
        session.newProject(other)
        session.needsSaveFlag = true
        await #expect(throws: EditorSession.SaveError.projectChanged) { try await saving.value }
        #expect(session.project.id == other.id && session.project.mediaPolicy?.watchFolder == true)
        #expect(session.needsSaveFlag)
    }

    @Test func undoDuringTheWriteLeavesTheProjectDirty() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = plainSession(base)
        let file = try projectFile(base, "Proj", "Proj")
        session.perform("Rename") { $0.name = "Edited" }
        let saving = Task { @MainActor in try await session.saveAs(to: file) }
        await Task.yield()
        #expect(session.undo())                                              // back to the unedited state while writing
        try await saving.value
        #expect(session.isDirty)                                             // the file holds the edit, the project does not
    }

    @Test func returningToTheWrittenStateAfterALUTSwapReadsClean() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let lut = base.appendingPathComponent("look.cube")
        let session = try lutSession(base, lut: lut)
        let file = try projectFile(base, "Proj", "Proj")
        session.perform("Rename") { $0.name = "Edited" }
        let saving = Task { @MainActor in try await session.saveAs(to: file) }
        while !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(1)) }   // written, not yet finished
        #expect(session.undo())
        try await saving.value
        #expect(session.isDirty)
        #expect(session.redo())
        #expect(!session.isDirty)
    }

    @Test func aFailedSaveAsLeavesTheOpenProjectOnItsOldLUTPath() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("Bad").path)
                try? FileManager.default.removeItem(at: base) }
        let lut = base.appendingPathComponent("look.cube")
        let session = try lutSession(base, lut: lut)
        let file = try projectFile(base, "Bad", "Bad")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Bad/Files/Library"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base.appendingPathComponent("Bad").path)
        await #expect(throws: (any Error).self) { try await session.saveAs(to: file) }
        #expect(session.project.referencedLUTFiles == [lut.path])           // not pointed at Bad's Library
        #expect(session.fileURL == nil)
    }

    @Test func aMovedProjectFolderStillFindsTheCollectedLUT() async throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let session = try lutSession(base, lut: base.appendingPathComponent("look.cube"))
        try await session.saveAs(to: try projectFile(base, "Proj", "Proj"))
        let stored = try #require(session.project.referencedLUTFiles.first)
        let moved = base.appendingPathComponent("Elsewhere")
        try FileManager.default.moveItem(at: base.appendingPathComponent("Proj"), to: moved)
        #expect(!FileManager.default.fileExists(atPath: stored))
        let found = MediaManagement.resolveStoredPath(stored, projectFolder: moved)
        #expect(found == moved.appendingPathComponent("Files/Library/look.cube").path)
    }

    @Test func caseVariantsOfAFileAreTheSameFileForClaimsAndInUse() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let upper = base.appendingPathComponent("IMG.MOV")
        try Data("x".utf8).write(to: upper)
        let lower = base.appendingPathComponent("img.mov").path
        guard FileManager.default.fileExists(atPath: lower) else { return }          // case-sensitive volume
        let s = MediaWorkState()
        s.claim([lower])
        #expect(s.discardable([upper.path], inUse: [], otherBatchesRunning: false).isEmpty)
        let t = MediaWorkState()
        #expect(t.discardable([upper.path], inUse: [lower], otherBatchesRunning: false).isEmpty)
        #expect(t.discardable([upper.path], inUse: [], otherBatchesRunning: false) == [upper.path])
    }

    @Test func aPromptAnswerOfTheSameProjectTakesTheQueueOnce() {
        let state = MediaWorkState()
        let a = ProjectPanelModel.ImportedFile(id: UUID(), url: URL(fileURLWithPath: "/out/a.mov"))
        let b = ProjectPanelModel.ImportedFile(id: UUID(), url: URL(fileURLWithPath: "/out/b.mov"))
        state.pendingAsk = [a]
        let gen = state.generation
        state.pendingAsk += [b]                                 // a second drop while the prompt is up
        #expect(state.takePendingAsk(promptGeneration: gen) == [a, b])
        #expect(state.takePendingAsk(promptGeneration: gen) == [])      // answered twice: nothing left
    }

    @Test func revertDropsWaitingRelinksAndTheirCopiesButKeepsClaims() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqrev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let session = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        let state = MediaWorkState()
        session.onProjectReplaced = { state.reset() }
        let file = base.appendingPathComponent("a.sqproj")
        try await session.saveAs(to: file)
        let discarded = Count(), idle = Count()
        state.onIdle = { idle.n += 1 }
        state.deferRelink(map: [UUID(): "/p/Imported/a.mov"], projectID: session.project.id, discard: { discarded.n += 1 }, completion: nil)
        state.claim(["/p/Imported/b.mov"])
        #expect(state.isBusy)
        try await session.open(url: file)                       // Revert
        #expect(discarded.n == 1 && !state.isBusy && idle.n == 1)
        #expect(state.claimed.contains("/p/Imported/b.mov"))
    }

    @Test func aFailedSaveAsLeavesACleanProjectClean() async throws {
        var p = EditorSession.makeUntitled()
        p.mediaPolicy = MediaPolicy(watchFolder: true)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sqclean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: base.appendingPathComponent("auto")))
        let file = base.appendingPathComponent("a.sqproj")
        try await session.saveAs(to: file)
        #expect(!session.isDirty)
        await #expect(throws: (any Error).self) {
            try await session.saveAsWithoutWatching(to: URL(fileURLWithPath: "/dev/null/nope/a.sqproj"))
        }
        #expect(!session.isDirty && session.project.mediaPolicy?.watchFolder == true)
    }
}
