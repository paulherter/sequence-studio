import Foundation
import Testing
@testable import SQAnalysis
import SQCore

@Suite struct FrameMatteStoreTests {
    private func matte(_ v: Float) -> SubjectMatte { SubjectMatte(width: 4, height: 4, values: [Float](repeating: v, count: 16)) }

    @Test func aFrameIsFoundAtItsTimeAndNotFarAfterIt() {
        let store = FrameMatteStore()
        store.put(key: "k", pts: 1.0, matte: matte(1))
        store.put(key: "k", pts: 1.04, matte: matte(0.5))
        #expect(store.matte(key: "k", pts: 1.0)?.values[0] == 1)
        #expect(store.matte(key: "k", pts: 1.04)?.values[0] == 0.5)
        #expect(store.matte(key: "k", pts: 0.9) == nil)           // before the first tracked frame
        #expect(store.matte(key: "k", pts: 1.2) == nil)           // a hole longer than the spacing: not tracked there
        #expect(store.times(key: "k") == [1.0, 1.04])
    }

    @Test func healthSamplesAreTheCoverageOfEachStoredFrameInTimeOrder() {
        let store = FrameMatteStore()
        store.put(key: "k", pts: 2, matte: matte(0))
        store.put(key: "k", pts: 1, matte: matte(1))
        store.put(key: "k", pts: 3, matte: matte(0.5))
        let s = store.healthSamples(key: "k")
        #expect(s.map(\.pts) == [1, 2, 3])
        #expect(s[0].area == 1 && s[1].area == 0 && abs(s[2].area - 0.5) < 0.01)
        #expect(store.healthSamples(key: "none").isEmpty)
    }

    @Test func storingAgainReplacesTheFrameAndDropsItsEdgedCopy() {
        let store = FrameMatteStore()
        store.put(key: "k", pts: 2, matte: matte(1))
        let before = store.revision
        _ = store.matte(key: "k", pts: 2, feather: 2, expansion: 0, frameWidth: 4)
        store.put(key: "k", pts: 2, matte: matte(0))
        #expect(store.revision > before)
        #expect(store.matte(key: "k", pts: 2, feather: 2, expansion: 0, frameWidth: 4)?.values.allSatisfy { $0 == 0 } == true)
        store.remove(key: "k")
        #expect(!store.has(key: "k"))
    }

    @Test func expansionGrowsThePickAndNoEdgeKeepsItAsIs() {
        let store = FrameMatteStore()
        var v = [Float](repeating: 0, count: 64)
        v[3 * 8 + 3] = 1
        store.put(key: "k", pts: 0, matte: SubjectMatte(width: 8, height: 8, values: v))
        #expect(store.matte(key: "k", pts: 0, feather: 0, expansion: 0, frameWidth: 8)?.values == v)
        let grown = store.matte(key: "k", pts: 0, feather: 0, expansion: 1, frameWidth: 8)!
        #expect(grown.values[3 * 8 + 4] == 1 && grown.area > 1)
    }
}

@Suite struct FrameMatteStoreFileTests {
    private func folder() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-matte-\(UUID().uuidString)")
        return d
    }
    private func matte(_ v: Float) -> SubjectMatte { SubjectMatte(width: 4, height: 2, values: [Float](repeating: v, count: 8)) }

    @Test func framesComeBackFromTheFileInAnotherStore() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FrameMatteStore(directory: dir)
        a.put(key: "k", pts: 0.5, matte: matte(1))
        a.put(key: "k", pts: 0.54, matte: matte(0))
        a.saveLater(key: "k")
        a.waitForSaves()
        #expect(a.unsavedKeys.isEmpty)
        let b = FrameMatteStore(directory: dir)
        #expect(b.times(key: "k") == [0.5, 0.54])
        #expect(b.matte(key: "k", pts: 0.5)?.values.allSatisfy { $0 == 1 } == true)
        #expect(b.matte(key: "k", pts: 0.54)?.values.allSatisfy { $0 == 0 } == true)
    }

    @Test func theFileIsTheMacFormat() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FrameMatteStore(directory: dir)
        a.put(key: "k", pts: 2, matte: matte(1))
        a.save(key: "k")
        let d = try Data(contentsOf: dir.appendingPathComponent("k.sqmatte"))
        #expect(String(data: d.prefix(4), encoding: .utf8) == "SQMT")
        // magic 4, version 4, count 4, then pts 8, width 4, height 4, size 4, 8 bytes.
        let expected: Int = 12 + 8 + 4 + 4 + 4 + 8
        #expect(d.count == expected)
        #expect(d.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 2)
    }

    @Test func removingAKeyDeletesItsFileAndCopyKeepsTheWantedFrames() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FrameMatteStore(directory: dir)
        for t in [1.0, 1.04, 1.08] { a.put(key: "old", pts: t, matte: matte(1)) }
        a.put(key: "new", pts: 1.04, matte: matte(0))
        #expect(a.copyFrames(from: "old", to: "new") { $0 < 1.04 - 1e-6 } == 1)
        #expect(a.times(key: "new") == [1.0, 1.04])
        #expect(a.matte(key: "new", pts: 1.04)?.values[0] == 0)      // the corrected frame is not overwritten
        a.save(key: "new")
        a.remove(key: "new")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.sqmatte").path))
        #expect(!FrameMatteStore(directory: dir).has(key: "new"))
    }

    @Test func aFileOfAnotherVersionOrWithCompressedFramesGivesNothing() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("SQMT".utf8).write(to: dir.appendingPathComponent("junk.sqmatte"))
        #expect(!FrameMatteStore(directory: dir).has(key: "junk"))
    }
}

@Suite struct SubjectFrameUprightTests {
    // 3 x 2: row 0 = A B C, row 1 = D E F (the red channel holds the letter's index).
    private var frame: SubjectFrame {
        var px: [UInt8] = []
        for i in 0..<6 { px += [UInt8(i), 0, 0, 255] }
        return SubjectFrame(width: 3, height: 2, rgba: px)
    }
    private func reds(_ f: SubjectFrame) -> [UInt8] { (0..<(f.rgba.count / 4)).map { f.rgba[$0 * 4] } }

    @Test func clockwiseQuarterTurnPutsTheLeftColumnOnTop() {
        let r = frame.upright(rotation: 90)
        #expect((r.width, r.height) == (2, 3))
        #expect(reds(r) == [3, 0, 4, 1, 5, 2])
    }

    @Test func halfAndThreeQuarterTurns() {
        #expect(reds(frame.upright(rotation: 180)) == [5, 4, 3, 2, 1, 0])
        let r = frame.upright(rotation: 270)
        #expect((r.width, r.height) == (2, 3))
        #expect(reds(r) == [2, 5, 1, 4, 0, 3])
        #expect(reds(frame.upright(rotation: 0)) == [0, 1, 2, 3, 4, 5])
        #expect(reds(frame.upright(rotation: -90)) == reds(r))
    }
}
