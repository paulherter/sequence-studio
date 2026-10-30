import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// When the Magic mattes reach their files: saves queued off the main thread, frames that were never written, and
/// keys that were removed.
@Suite struct MagicMatteSaveTests {
    static let matte = SubjectMatte(width: 4, height: 2, values: [1, 1, 0, 0, 1, 1, 0, 0])

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-save-\(UUID().uuidString)")
    }

    static func exists(_ key: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(key).sqmatte").path)
    }

    /// A stopped run's save is queued (`saveLater`), the caller does not wait for the write. The queue writes in the
    /// order asked, each write reads the frames when it runs, and `waitForSaves` (project close, quit) returns only
    /// when everything queued is in its file.
    @Test func queuedSavesRunInOrderOffTheCallingThreadAndCloseWaitsForThem() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MagicMatteStore(directory: dir)
        // The queue is held: nothing is written while the caller goes on.
        let gate = DispatchSemaphore(value: 0)
        s.holdSaves(until: gate)
        s.put(Self.matte, key: "run", pts: 0)
        s.saveLater(key: "run")
        for i in 0..<12 {
            s.put(Self.matte, key: "k\(i)", pts: 0)
            s.saveLater(key: "k\(i)")
        }
        #expect(!Self.exists("run", in: dir) && s.unsavedKeys.count == 13)
        // The run's own save at its end comes first here (on its own thread), with one more frame; the queued save
        // of the stop then writes what the store holds at that time: never an older state over a newer one.
        s.put(Self.matte, key: "run", pts: 1)
        s.save(key: "run")
        #expect(MagicMatteStore(directory: dir).times(key: "run") == [0, 1])
        s.put(Self.matte, key: "run", pts: 2)
        gate.signal()
        s.waitForSaves()
        #expect(s.unsavedKeys.isEmpty)
        #expect(s.savedOrder.suffix(13) == ["run"] + (0..<12).map { "k\($0)" })
        let read = MagicMatteStore(directory: dir)
        #expect(read.times(key: "run") == [0, 1, 2])
        #expect((0..<12).allSatisfy { read.times(key: "k\($0)") == [0] })
    }

    /// A save that runs after its key was removed (a stopped run's save behind the sweep at project close) writes
    /// nothing: no empty file comes back for a key no mask has.
    @Test func aRemovedKeyRefusesLaterSaves() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MagicMatteStore(directory: dir)
        for key in ["gone", "swept", "kept"] {
            s.put(Self.matte, key: key, pts: 0)
            s.save(key: key)
        }
        let gate = DispatchSemaphore(value: 0)
        s.holdSaves(until: gate)
        for key in ["gone", "swept", "kept"] { s.saveLater(key: key) }
        s.remove(key: "gone")
        #expect(s.sweep(keeping: ["kept"]).contains("swept"))
        gate.signal()
        s.waitForSaves()
        s.save(key: "gone")
        #expect(!Self.exists("gone", in: dir) && !Self.exists("swept", in: dir) && Self.exists("kept", in: dir))
        #expect(s.times(key: "gone").isEmpty)
        // The key is used again (the same pick is made again): it is saved like any other.
        s.put(Self.matte, key: "gone", pts: 3)
        s.save(key: "gone")
        #expect(MagicMatteStore(directory: dir).times(key: "gone") == [3])
    }

    /// Removing a key (Delete Mask, a correction, the sweep at project close: all on the main thread) never waits for
    /// a write: the frames are gone at once, the file goes on the save queue behind the write, and the key still
    /// refuses the saves that come later.
    @Test func removingAKeyNeverWaitsForAWriteAndItsFileGoesBehindIt() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MagicMatteStore(directory: dir)
        for key in ["gone", "swept", "again"] {
            s.put(Self.matte, key: key, pts: 0)
            s.save(key: key)
        }
        // A slow write holds the lock.
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        s.holdWrite(started: started, until: gate)
        started.wait()
        s.saveLater(key: "gone")
        s.remove(key: "gone")
        s.remove(key: "again")
        #expect(s.sweep(keeping: ["again"]) == ["gone", "swept"])
        // Back at once: nothing is drawn from the keys any more, their files are still there.
        #expect(s.times(key: "gone").isEmpty && s.times(key: "swept").isEmpty)
        #expect(Self.exists("gone", in: dir) && Self.exists("swept", in: dir))
        // The same pick made again before the queue got to its file: the file holds the new frames only.
        s.put(Self.matte, key: "again", pts: 7)
        gate.signal()
        s.waitForSaves()
        #expect(!Self.exists("gone", in: dir) && !Self.exists("swept", in: dir))
        #expect(MagicMatteStore(directory: dir).times(key: "again") == [7])
        s.save(key: "gone")
        s.saveLater(key: "swept")
        s.waitForSaves()
        #expect(!Self.exists("gone", in: dir) && !Self.exists("swept", in: dir))
    }

    /// Two writers of one key: a save that waits behind a slow write reads the frames when it gets the lock, so the file
    /// ends with the frames put while it waited, and an older save never lands over a newer one.
    @Test func aSaveBehindASlowWriteWritesTheNewestFrames() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MagicMatteStore(directory: dir)
        s.put(Self.matte, key: "k", pts: 0)
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        s.holdWrite(started: started, until: gate)
        started.wait()
        s.saveLater(key: "k")                         // queued behind the write that holds the lock
        s.put(Self.matte, key: "k", pts: 1)           // a run stores another frame meanwhile
        s.saveLater(key: "k")
        s.put(Self.matte, key: "k", pts: 2)
        gate.signal()
        s.waitForSaves()
        #expect(MagicMatteStore(directory: dir).times(key: "k") == [0, 1, 2])
        #expect(s.unsavedKeys.isEmpty)
    }

    /// A run whose mask was removed is stopped without saving, its frames stay in memory. When the mask returns
    /// (undo), they are written, so the mask still has them after a relaunch.
    @Test func framesOfAMaskThatReturnsAreSaved() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MagicMatteStore(directory: dir)
        s.put(Self.matte, key: "mask", pts: 0)
        s.save(key: "mask")
        // The run goes on for two frames, its mask is removed: nothing more is written.
        s.put(Self.matte, key: "mask", pts: 1)
        s.put(Self.matte, key: "mask", pts: 2)
        s.put(Self.matte, key: "other", pts: 0)
        #expect(s.unsavedKeys == ["mask", "other"])
        #expect(MagicMatteStore(directory: dir).times(key: "mask") == [0])
        // The project without the mask asks for nothing ...
        #expect(s.saveUnsaved(among: []).isEmpty)
        s.waitForSaves()
        #expect(MagicMatteStore(directory: dir).times(key: "mask") == [0])
        // ... the project that has it again (undo) gets its frames written, and only those.
        #expect(s.saveUnsaved(among: ["mask", "never-tracked"]) == ["mask"])
        s.waitForSaves()
        #expect(MagicMatteStore(directory: dir).times(key: "mask") == [0, 1, 2])
        #expect(s.unsavedKeys == ["other"] && !Self.exists("other", in: dir) && !Self.exists("never-tracked", in: dir))
        // Nothing changed since: nothing is written a second time.
        #expect(s.saveUnsaved(among: ["mask"]).isEmpty)
        // Deleted frames count as a change too.
        s.removeFrames(key: "mask", times: [1])
        #expect(s.saveUnsaved(among: ["mask"]) == ["mask"])
        s.waitForSaves()
        #expect(MagicMatteStore(directory: dir).times(key: "mask") == [0, 2])
    }
}
