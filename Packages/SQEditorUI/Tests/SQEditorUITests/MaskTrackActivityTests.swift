import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

// The one mask track slot: before (2026-10-09) it stayed taken until the run's task had ended by itself, also when its
// mask was gone, so Track was off on every mask and corrections were refused.

@MainActor @Suite struct MaskTrackActivityTests {
    final class Owner {}

    /// A task that runs until it is canceled.
    private func endless(_ a: MaskTrackActivity, _ token: Int) -> Task<Void, Never> {
        let t = Task { @MainActor in
            defer { a.finish(token) }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        }
        a.attach(t, to: token)
        return t
    }

    @Test func stopFreesTheSlotAtOnceAndCancelsTheTask() async {
        let a = MaskTrackActivity()
        #expect(!a.stop(reason: "nothing runs"))
        let token = a.start(mask: UUID(), forward: true)
        let t = endless(a, token)
        #expect(a.isRunning && a.isCurrent(token))
        #expect(a.progress(10, token: token) && !a.progress(10, token: token))
        #expect(a.run?.percent == 10)
        #expect(a.stop(reason: "test"))
        // Free before the task has ended.
        #expect(!a.isRunning && t.isCancelled && !a.isCurrent(token))
        #expect(!a.progress(20, token: token))
        await t.value
        #expect(!a.isRunning)
    }

    @Test func aStoppedRunDoesNotClearTheNextOne() async {
        let a = MaskTrackActivity()
        let first = a.start(mask: UUID(), forward: true)
        let t1 = endless(a, first)
        let mask = UUID()
        let second = a.start(mask: mask, forward: false)       // stops the first
        let t2 = endless(a, second)
        #expect(t1.isCancelled && !t2.isCancelled)
        await t1.value                                          // its `finish(first)` must not free the second run's slot
        #expect(a.run?.mask == mask && a.isCurrent(second))
        #expect(!a.progress(5, token: first) && a.run?.percent == -1)
        a.stop(reason: "test")
        #expect(!a.isRunning)
        await t2.value
    }

    @Test func aTaskAttachedAfterItsRunWasStoppedIsCanceled() async {
        let a = MaskTrackActivity()
        let token = a.start(mask: UUID(), forward: true)
        a.stop(reason: "test")
        let t = Task { @MainActor in while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) } }
        a.attach(t, to: token)
        #expect(t.isCancelled)
        await t.value
    }

    @Test func aRunWhoseMaskIsGoneIsStoppedForItsOwnerOnly() async {
        let a = MaskTrackActivity()
        let owner = Owner(), stranger = Owner()
        let mask = UUID()
        let token = a.start(mask: mask, forward: true, owner: owner)
        let t = endless(a, token)
        #expect(!a.stopIfMaskGone(owner: owner) { _, m in m == mask })          // still there
        #expect(!a.stopIfMaskGone(owner: stranger) { _, _ in false })       // another window's project
        #expect(!a.stop(owner: stranger, reason: "closed"))
        #expect(a.isRunning && !t.isCancelled)
        #expect(a.stopIfMaskGone(owner: owner) { _, _ in false })
        #expect(!a.isRunning && t.isCancelled)
        await t.value
        let again = a.start(mask: mask, forward: true, owner: owner)
        let t2 = endless(a, again)
        #expect(a.stop(owner: owner, reason: "closed") && t2.isCancelled)
        await t2.value
    }

    /// Only the user's Stop lets a run write to the project; only a run whose mask is gone loses its frames. Every
    /// other stop (another run starts, the tool is switched, its project closes) saves the frames tracked so far, at
    /// once and by the run itself at its end (before, 2026-10-09: they stayed in memory only while the mask kept its key).
    @Test func onlyAUserStopWritesToTheProjectAndOnlyARemovedMaskLosesItsFrames() async {
        let a = MaskTrackActivity()
        let owner = Owner()
        var saved: [String] = []
        let first = a.start(mask: UUID(), forward: true, owner: owner, key: "1") { saved.append("1") }
        let keep1 = a.keepsFrames(first)
        #expect(a.mayWrite(first) && keep1())
        a.stop(reason: "Stop", keeps: true)
        #expect(a.mayWrite(first) && keep1() && !a.isCurrent(first) && saved == ["1"])
        // The next run takes the project away from the stopped one.
        let second = a.start(mask: UUID(), forward: true, owner: owner, key: "2") { saved.append("2") }
        let keep2 = a.keepsFrames(second)
        #expect(!a.mayWrite(first) && a.mayWrite(second) && keep2())
        #expect(a.keepsFrames(first)() == false)
        a.stopIfMaskGone(owner: owner) { _, _ in false }
        #expect(!a.mayWrite(second) && !keep2() && saved == ["1"])
        let third = a.start(mask: UUID(), forward: true, owner: owner, key: "3") { saved.append("3") }
        let keep3 = a.keepsFrames(third)
        let fourth = a.start(mask: UUID(), forward: true, owner: owner, key: "4") { saved.append("4") }     // another run starts
        #expect(!a.mayWrite(third) && keep3() && a.mayWrite(fourth) && saved == ["1", "3"])
        let keep4 = a.keepsFrames(fourth)
        a.stop(owner: owner, reason: "its project closes")
        #expect(!a.mayWrite(fourth) && keep4() && saved == ["1", "3", "4"])
        // A run that ended by itself is not saved a second time by a later stop.
        let fifth = a.start(mask: UUID(), forward: true, owner: owner, key: "5") { saved.append("5") }
        a.finish(fifth)
        #expect(!a.stop(reason: "nothing runs") && saved == ["1", "3", "4"])
    }

    /// A run stores frames under the key its mask had when it started. When the pick changes under it (a new click,
    /// undo or redo of a point), it is stopped: it never goes on for a pick the mask no longer has. Its frames are
    /// saved under its own key, where the pick finds them when it comes back.
    @Test func aRunWhosePickChangedIsStoppedAndItsFramesAreSaved() async {
        let a = MaskTrackActivity()
        let owner = Owner(), stranger = Owner()
        let mask = UUID()
        var saved = 0
        let token = a.start(mask: mask, forward: true, owner: owner, automatic: true, key: "old") { saved += 1 }
        let keep = a.keepsFrames(token)
        let t = endless(a, token)
        #expect(a.stopIfKeyChanged(owner: owner) { _, _ in "old" } == nil)
        #expect(a.stopIfKeyChanged(owner: stranger) { _, _ in "new" } == nil)
        #expect(a.isRunning && saved == 0)
        let stopped = a.stopIfKeyChanged(owner: owner) { _, m in m == mask ? "new" : nil }
        #expect(stopped?.mask == mask && stopped?.automatic == true)
        #expect(!a.isRunning && t.isCancelled && saved == 1 && keep() && !a.mayWrite(token))
        await t.value
        // A path track has no key: a changed pick elsewhere does not stop it.
        let path = a.start(mask: mask, forward: true, owner: owner)
        #expect(a.stopIfKeyChanged(owner: owner) { _, _ in "new" } == nil && a.isCurrent(path))
    }

    /// The track a pick starts by itself: one run for both directions, and the only kind a tool switch or a new click ends.
    @Test func anAutomaticRunTurnsAroundAndEndsWhereAUserRunStays() async {
        let a = MaskTrackActivity()
        let mask = UUID()
        let auto = a.start(mask: mask, forward: true, automatic: true)
        let keep = a.keepsFrames(auto)
        #expect(a.run?.automatic == true && a.progress(80, token: auto))
        #expect(a.turn(forward: false, token: auto))
        #expect(a.run == MaskTrackActivity.Run(mask: mask, forward: false, percent: -1, automatic: true))
        #expect(a.stopAutomatic(reason: "tool switched"))
        // Its frames stay (the mask still has that pick); the project is not written.
        #expect(!a.isRunning && !a.mayWrite(auto) && keep())
        #expect(!a.turn(forward: true, token: auto))
        // The user's Stop keeps an automatic run's frames like any other run's.
        let again = a.start(mask: mask, forward: true, automatic: true)
        #expect(a.stopAutomatic(reason: "Stop", keeps: true) && a.mayWrite(again))
        // A track the user started is not an automatic one.
        let user = a.start(mask: mask, forward: true)
        #expect(a.run?.automatic == false && !a.stopAutomatic(reason: "tool switched"))
        #expect(a.isCurrent(user))
    }
}
