import Foundation
import Testing
import SQCore
@testable import SQAnalysis

/// Deleting tracked Magic mask frames from the lanes removes their mattes from the store.
struct MagicMatteStoreRemoveTests {
    private func matte() -> SubjectMatte { SubjectMatte(width: 2, height: 2, values: [0, 1, 1, 0]) }

    @Test func removeFramesDropsOnlyTheGivenTimes() {
        let store = MagicMatteStore(directory: nil)
        for i in 0 ..< 4 { store.put(matte(), key: "k", pts: Double(i) / 24) }
        store.put(matte(), key: "other", pts: 1.0 / 24)
        let n = store.removeFrames(key: "k", times: [1.0 / 24, 3.0 / 24 + 1e-9, 9])
        #expect(n == 2)
        #expect(store.times(key: "k") == [0, 2.0 / 24])
        #expect(store.times(key: "other") == [1.0 / 24])
    }

    @Test func aSnapshotBringsDeletedFramesBack() {
        let store = MagicMatteStore(directory: nil)
        for i in 0 ..< 4 { store.put(matte(), key: "k", pts: Double(i) / 24) }
        let snap = store.snapshotFrames(key: "k", times: [1.0 / 24, 2.0 / 24])
        #expect(snap.count == 2)
        store.removeFrames(key: "k", times: [1.0 / 24, 2.0 / 24])
        let left: [Double] = [0, 3.0 / 24]
        #expect(store.times(key: "k") == left)
        store.restore(snap)
        let all: [Double] = (0 ..< 4).map { Double($0) / 24 }
        #expect(store.times(key: "k") == all)
        #expect(store.matte(key: "k", pts: 1.0 / 24)?.values == [0, 1, 1, 0])
    }

    @Test func removedFramesStayGoneAfterSaveAndReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MagicMatteStore(directory: dir)
        for i in 0 ..< 3 { store.put(matte(), key: "k", pts: Double(i)) }
        store.removeFrames(key: "k", times: [1])
        store.save(key: "k")
        #expect(MagicMatteStore(directory: dir).times(key: "k") == [0, 2])
    }

    @Test func redoRemovesTheDeletedFramesNotOnesTrackedAgainSince() {
        let store = MagicMatteStore(directory: nil)
        for i in 0 ..< 3 { store.put(matte(), key: "k", pts: Double(i) / 24) }
        let snap = store.snapshotFrames(key: "k", times: [1.0 / 24, 2.0 / 24])
        store.removeFrames(key: "k", times: [1.0 / 24, 2.0 / 24])
        store.restore(snap)                                                       // undo
        store.put(SubjectMatte(width: 2, height: 2, values: [1, 1, 1, 1]), key: "k", pts: 1.0 / 24)   // tracked again
        let gone = store.removeFrames(matching: snap)                             // redo
        #expect(gone == [2.0 / 24])
        #expect(store.times(key: "k") == [0, 1.0 / 24])
        #expect(store.matte(key: "k", pts: 1.0 / 24)?.values == [1, 1, 1, 1])
    }

    @Test func redoOfAnUntouchedDeleteRemovesAllItsFrames() {
        let store = MagicMatteStore(directory: nil)
        for i in 0 ..< 3 { store.put(matte(), key: "k", pts: Double(i) / 24) }
        let snap = store.snapshotFrames(key: "k", times: [0, 1.0 / 24])
        #expect(store.removeFrames(matching: snap) == [0, 1.0 / 24])
        #expect(store.times(key: "k") == [2.0 / 24])
    }
}
