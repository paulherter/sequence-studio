import Foundation
import Testing
@testable import SQCore

/// Premiere-import placeholders (offline at import: no probe info, size 0) become normal media once relinked and probed.
@Suite struct RelinkProbeTests {
    private let fd = Time(1, 30)

    private func project(_ ref: MediaRef, clip: Clip) -> Project {
        Project(name: "t", media: [ref], timelines: [Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                                                               tracks: [Track(kind: .video, clips: [clip])])])
    }

    @Test func everyRelinkedUnprobedMediaAwaitsAProbe() {
        let placeholder = MediaRef(name: "a.png", path: "/gone/a.png", fingerprint: MediaFingerprint(size: 0))
        let probed = MediaRef(name: "b.mov", path: "/gone/b.mov", fingerprint: MediaFingerprint(size: 9), info: MediaInfo(duration: Time(2, 1)))
        let p = Project(name: "t", media: [placeholder, probed])
        let ids = p.mediaAwaitingProbe([placeholder.id: "/new/a.png", probed.id: "/new/b.mov"])
        #expect(ids == [placeholder.id])
        #expect(p.mediaAwaitingProbe([:]).isEmpty)
    }

    @Test func probedStillFixesTheImportedClip() throws {
        let ref = MediaRef(name: "a.png", path: "/new/a.png", fingerprint: MediaFingerprint(size: 0))
        // As mapped from Premiere without probe info: a huge in point (Premiere's still convention), not a still.
        let clip = Clip(name: "a.png", media: ref.id, kind: .video, source: TimeRange(start: Time(3600, 1), duration: Time(5, 1)), start: .zero)
        var p = project(ref, clip: clip)
        let info = MediaInfo(duration: Time(5, 1), isStill: true)
        let changed = p.adoptProbedInfo([ref.id: info], fingerprints: [ref.id: MediaFingerprint(size: 1234)])
        #expect(changed)
        let m = try #require(p.media.first)
        #expect(m.info == info && m.duration == Time(5, 1) && m.fingerprint.size == 1234)
        let c = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(c.isStill && c.source.start == .zero && c.source.duration == Time(5, 1) && c.mediaDuration == Time(5, 1))
    }

    @Test func probedVideoKeepsTheSourceRangeAndLearnsItsLength() throws {
        let ref = MediaRef(name: "a.mov", path: "/new/a.mov", fingerprint: MediaFingerprint(size: 0))
        let clip = Clip(name: "a.mov", media: ref.id, kind: .video, source: TimeRange(start: Time(3, 1), duration: Time(2, 1)), start: .zero)
        var p = project(ref, clip: clip)
        let changed = p.adoptProbedInfo([ref.id: MediaInfo(duration: Time(10, 1))])
        #expect(changed)
        let c = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(!c.isStill && c.source.start == Time(3, 1) && c.mediaDuration == Time(10, 1))
        #expect(p.media.first?.fingerprint.size == 0)   // no fingerprint passed: unchanged
    }

    @Test func mediaWithInfoIsLeftAlone() {
        let info = MediaInfo(duration: Time(4, 1))
        let ref = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 5), duration: Time(4, 1), info: info)
        let clip = Clip(name: "a", media: ref.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        var p = project(ref, clip: clip)
        let before = p
        let changed = p.adoptProbedInfo([ref.id: MediaInfo(duration: Time(9, 1), isStill: true)])
        #expect(!changed)
        #expect(p == before)
    }
}
