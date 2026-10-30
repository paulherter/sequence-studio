import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func dir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sqcfr-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func ref(_ name: String, path: String, vfr: Bool = true, still: Bool = false) -> MediaRef {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: vfr)
    var info = MediaInfo(duration: Time(4, 1), video: v, audio: nil)
    info.isStill = still
    return MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1), info: info)
}

@MainActor private func session(with m: MediaRef) -> EditorSession {
    var p = EditorSession.makeUntitled()
    p.add(m)
    return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir()))
}

@MainActor @Suite struct ConstantFrameRateConformTests {
    @Test func onlyVariableRateVideoIsEligible() {
        #expect(ConstantFrameRateConform.isEligible(ref("a.mov", path: "/x/a.mov")))
        #expect(!ConstantFrameRateConform.isEligible(ref("a.mov", path: "/x/a.mov", vfr: false)))
        #expect(!ConstantFrameRateConform.isEligible(ref("a.png", path: "/x/a.png", still: true)))
    }

    @Test func destinationNeverOverwrites() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let r = ref("Phone.MP4", path: "/x/Phone.MP4")
        let first = ConstantFrameRateConform.destination(for: r, in: d)
        #expect(first.lastPathComponent == "Phone (CFR).mov")
        try Data([1]).write(to: first)
        #expect(ConstantFrameRateConform.destination(for: r, in: d).lastPathComponent == "Phone (CFR 2).mov")
    }

    @Test func itemTakesOverTheConformedFileAndKeepsItsID() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("Phone.mp4")
        try Data([1]).write(to: src)
        let m = ref("Phone.mp4", path: src.path)
        let s = session(with: m)
        let runner = ConformRunner(convert: { _, dst, fd, progress in
            #expect(fd == Time(1, 30))
            progress(0.5)
            try Data([2, 2]).write(to: dst)
        }, probe: { url in
            var out = ref("Phone (CFR).mov", path: url.path, vfr: false)
            out.fingerprint = MediaFingerprint(size: 2)
            return out
        })
        let url = try await runner.conform(m.id, in: s, folder: d)
        #expect(url.lastPathComponent == "Phone (CFR).mov")
        let item = try #require(s.project.media(m.id))
        #expect(item.path == url.path)
        #expect(item.info?.video?.isVariableFrameRate == false)
        #expect(s.project.media.count == 1)
        #expect(FileManager.default.fileExists(atPath: src.path))   // the original stays
        #expect(!runner.isRunning(m.id) && runner.runs.isEmpty)
    }

    @Test func refusesConstantRateOfflineAndRunningItems() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let cfr = ref("c.mov", path: d.appendingPathComponent("c.mov").path, vfr: false)
        let off = ref("o.mov", path: d.appendingPathComponent("gone.mov").path)
        var p = EditorSession.makeUntitled(); p.add(cfr); p.add(off)
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir()))
        let runner = ConformRunner(convert: { _, _, _, _ in }, probe: { _ in cfr })
        await #expect(throws: ConstantFrameRateConform.Failure.notVariable) { try await runner.conform(cfr.id, in: s, folder: d) }
        await #expect(throws: ConstantFrameRateConform.Failure.offline) { try await runner.conform(off.id, in: s, folder: d) }
    }

    @Test func cancelRemovesThePartialFileAndLeavesTheItem() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("Phone.mp4")
        try Data([1]).write(to: src)
        let m = ref("Phone.mp4", path: src.path)
        let s = session(with: m)
        let runner = ConformRunner(convert: { _, dst, _, _ in
            try Data([2]).write(to: dst)
            try await Task.sleep(for: .seconds(30))
        }, probe: { _ in throw CancellationError() })
        let id = m.id
        let job = Task { try await runner.conform(id, in: s, folder: d) }
        while !runner.isRunning(id) { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        runner.cancel(id)
        await #expect(throws: (any Error).self) { try await job.value }
        #expect(s.project.media(id)?.path == src.path)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("Phone (CFR).mov").path))
    }
}
