import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct ExportPreflightTests {
    func job(_ name: String, dir: URL, replace: Bool = false) -> ExportJob {
        var j = ExportJob(name: name, settings: smallSettings(codec: .h264), outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30)), audio: nil)
        }
        j.replaceExisting = replace
        return j
    }

    @Test func findsExistingTargets() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = job("Clip", dir: dir)
        #expect(ExportPreflight.existingTargets(of: [j]).isEmpty)
        let file = dir.appendingPathComponent("Clip.\(j.settings.fileExtension)")
        try Data([1]).write(to: file)
        #expect(ExportPreflight.existingTargets(of: [j]).map(\.lastPathComponent) == [file.lastPathComponent])
    }

    @Test func keepBothSuffixesAndReplaceKeepsName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ext = job("Clip", dir: dir).settings.fileExtension
        try Data([1]).write(to: dir.appendingPathComponent("Clip.\(ext)"))
        let q = ExportQueue()
        let keep = await q.enqueue(job("Clip", dir: dir))
        let rep = await q.enqueue(job("Clip", dir: dir, replace: true))
        #expect(await q.status(keep)?.outputURL.lastPathComponent == "Clip 2.\(ext)")
        #expect(await q.status(rep)?.outputURL.lastPathComponent == "Clip.\(ext)")
    }

    @Test func offlineMediaIncludesNestedSequences() {
        let gone = MediaRef(name: "gone", path: "/nonexistent/gone.mov", fingerprint: MediaFingerprint(size: 1))
        let unused = MediaRef(name: "unused", path: "/nonexistent/unused.mov", fingerprint: MediaFingerprint(size: 1))
        let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let clip = Clip(name: "c", media: gone.id, kind: .video, source: TimeRange(start: .zero, duration: Time(30, 30)), start: .zero)
        let inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .video, clips: [clip])])
        let nest = Clip(name: "n", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(30, 30)),
                        start: .zero, sequence: inner.id)
        let outer = Timeline(name: "outer", format: fmt, tracks: [Track(kind: .video, clips: [nest])])
        let p = Project(name: "P", media: [gone, unused], timelines: [outer, inner])
        let offline = ExportPreflight.offlineMedia(in: outer.id, project: p)
        #expect(offline.map(\.id) == [gone.id])
    }

    @Test func hdrMediaListsOnlyUsedHDRSources() {
        var hdr = MediaRef(name: "hdr", path: "/x/hdr.mov", fingerprint: MediaFingerprint(size: 1))
        hdr.info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .hlgBT2020)
        var sdr = MediaRef(name: "sdr", path: "/x/sdr.mov", fingerprint: MediaFingerprint(size: 1))
        sdr.info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .rec709)
        let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        func clip(_ m: MediaRef) -> Clip { Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(30, 30)), start: .zero) }
        let tl = Timeline(name: "t", format: fmt, tracks: [Track(kind: .video, clips: [clip(hdr), clip(sdr)])])
        let p = Project(name: "P", media: [hdr, sdr], timelines: [tl])
        #expect(ExportPreflight.hdrMedia(in: tl.id, project: p).map(\.id) == [hdr.id])
    }

    @Test func diskFullMessage() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(ExportPreflight.failureMessage(full, freeBytes: nil).hasPrefix("The disk is full"))
        #expect(ExportPreflight.failureMessage(ExportError.writerFailed("x"), freeBytes: 1_000).hasPrefix("The disk is full"))
        #expect(!ExportPreflight.failureMessage(ExportError.writerFailed("x"), freeBytes: 50_000_000_000).hasPrefix("The disk is full"))
    }
}
