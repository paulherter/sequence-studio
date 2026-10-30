import Foundation
import Testing
import SQCore
@testable import SQTranscribe

private let fd = Time(1, 30)

private func aclip(media: UUID, source: (Int64, Int64), start: Int64, speed: ClipSpeed = .normal,
                   enabled: Bool = true) -> Clip {
    var c = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: t(source.0), end: t(source.1)),
                 start: t(start), mediaDuration: t(60_000), speed: speed)
    c.isEnabled = enabled
    return c
}

private func timeline(_ tracks: [Track]) -> Timeline {
    Timeline(name: "S", format: SequenceFormat(frameDuration: fd), tracks: tracks)
}

@Suite("Timeline transcription: word to sequence time")
struct TimelineTranscriptionTests {
    @Test func shiftsWordsByClipPosition() {
        let clip = aclip(media: UUID(), source: (2000, 6000), start: 10_000)
        let out = TimelineTranscription.mapWords([w("hallo", 2500, 3000), w("welt", 3000, 3500)], from: clip, frameDuration: fd)
        #expect(out.map(\.text) == ["hallo", "welt"])
        #expect(out[0].range.start == t(10_500) && out[0].range.end == t(11_000))
        #expect(out[1].range.start == t(11_000))
    }

    @Test func dropsWordsOutsideTheUsedSourceRange() {
        let clip = aclip(media: UUID(), source: (2000, 4000), start: 0)
        let out = TimelineTranscription.mapWords([w("vor", 500, 1500), w("drin", 2500, 3000), w("nach", 4500, 5000)],
                                                 from: clip, frameDuration: fd)
        #expect(out.map(\.text) == ["drin"])
    }

    @Test func wordCutByClipEdgeIsClampedOrDroppedByMidpoint() {
        let clip = aclip(media: UUID(), source: (2000, 4000), start: 1000)
        // 1800..2400: midpoint 2100 inside -> kept, start clamped to the clip start.
        // 3800..4800: midpoint 4300 outside -> dropped.
        let out = TimelineTranscription.mapWords([w("a", 1800, 2400), w("b", 3800, 4800)], from: clip, frameDuration: fd)
        #expect(out.map(\.text) == ["a"])
        #expect(out[0].range.start == t(1000) && out[0].range.end == t(1400))
    }

    @Test func doubleSpeedHalvesDurations() {
        let clip = aclip(media: UUID(), source: (0, 4000), start: 5000, speed: ClipSpeed(num: 2, den: 1))
        let out = TimelineTranscription.mapWords([w("schnell", 1000, 2000)], from: clip, frameDuration: fd)
        #expect(out[0].range.start == t(5500) && out[0].range.end == t(6000))
    }

    @Test func halfSpeedDoublesDurations() {
        let clip = aclip(media: UUID(), source: (1000, 3000), start: 0, speed: ClipSpeed(num: 1, den: 2))
        let out = TimelineTranscription.mapWords([w("langsam", 1000, 1500)], from: clip, frameDuration: fd)
        #expect(out[0].range.start == t(0) && out[0].range.end == t(1000))
    }

    @Test func reversedClipYieldsNoWords() {
        var clip = aclip(media: UUID(), source: (0, 4000), start: 0)
        clip.reversed = true
        #expect(TimelineTranscription.mapWords([w("x", 1000, 2000)], from: clip, frameDuration: fd).isEmpty)
    }

    @Test func audibleClipsHonourMuteSoloEnabledAndKind() {
        let m = UUID()
        let a1 = Track(kind: .audio, clips: [aclip(media: m, source: (0, 1000), start: 0)])
        let a2 = Track(kind: .audio, clips: [aclip(media: m, source: (0, 1000), start: 2000)], isMuted: true)
        let a3 = Track(kind: .audio, clips: [aclip(media: m, source: (0, 1000), start: 4000, enabled: false)])
        let v = Track(kind: .video, clips: [Clip(name: "v", media: m, kind: .video, source: TimeRange(start: t(0), end: t(1000)), start: t(0))])
        #expect(TimelineTranscription.audibleClips(in: timeline([v, a1, a2, a3])).count == 1)
        var solo = a2
        solo.isMuted = false; solo.isSolo = true
        let clips = TimelineTranscription.audibleClips(in: timeline([a1, solo]))
        #expect(clips.count == 1 && clips[0].start == t(2000))
    }

    @Test func threeClipsWithGapsGiveOneSortedTranscript() async throws {
        let m1 = UUID(), m2 = UUID()
        let c1 = aclip(media: m1, source: (0, 2000), start: 0)
        let c2 = aclip(media: m2, source: (1000, 3000), start: 5000)        // gap 2..5 s
        let c3 = aclip(media: m1, source: (4000, 6000), start: 8000)        // same media, later part
        let tl = timeline([Track(kind: .audio, clips: [c1, c2, c3])])
        let a = URL(fileURLWithPath: "/a.wav"), b = URL(fileURLWithPath: "/b.wav")
        let service = FakeService(words: [
            a.path: [w("eins", 500, 900), w("weg", 2500, 3000), w("drei", 4500, 5000)],
            b.path: [w("zwei", 1200, 1800)],
        ])
        let tr = try await TimelineTranscription.transcribe(timeline: tl, urls: [m1: a, m2: b], service: service,
                                                            locale: Locale(identifier: "de-DE"), progress: { _ in })
        #expect(tr.words.map(\.text) == ["eins", "zwei", "drei"])
        #expect(tr.words[1].range.start == t(5200))
        #expect(tr.words[2].range.start == t(8500))
        #expect(service.calls == 2)                      // each source file once
        #expect(tr.language == "de-DE")
    }

    @Test func overlappingClipsOfSameMediaGiveNoDuplicateWords() async throws {
        let m = UUID()
        let a = URL(fileURLWithPath: "/a.wav")
        // A1 and A2 play the same recording at the same time (and a third clip overlaps the first half).
        let c1 = aclip(media: m, source: (0, 4000), start: 0)
        let c2 = aclip(media: m, source: (0, 4000), start: 0)
        let tl = timeline([Track(kind: .audio, clips: [c1]), Track(kind: .audio, clips: [c2])])
        let service = FakeService(words: [a.path: [w("eins", 500, 900), w("zwei", 1000, 1500)]])
        let tr = try await TimelineTranscription.transcribe(timeline: tl, urls: [m: a], service: service,
                                                            locale: Locale(identifier: "de-DE"), progress: { _ in })
        #expect(tr.words.map(\.text) == ["eins", "zwei"])
    }

    @Test func clipsWithSpeedKeysAreNotAudible() {
        var c = aclip(media: UUID(), source: (0, 4000), start: 0)
        c.speedKeys = SpeedKeys(constant: ClipSpeed(num: 2, den: 1), reversed: false, duration: c.source.duration, origin: c.source.start)
        #expect(TimelineTranscription.audibleClips(in: timeline([Track(kind: .audio, clips: [c])])).isEmpty)
    }

    @Test func layoutChangesWhenAClipIsTrimmedMovedOrRetimed() {
        let m = UUID()
        let base = aclip(media: m, source: (0, 4000), start: 0)
        let l0 = TimelineTranscription.layout(of: timeline([Track(kind: .audio, clips: [base])]))
        var moved = base; moved.start = t(1000)
        var trimmed = base; trimmed.source = TimeRange(start: t(0), end: t(3000))
        var fast = base; fast.speed = ClipSpeed(num: 2, den: 1)
        for c in [moved, trimmed, fast] {
            #expect(TimelineTranscription.layout(of: timeline([Track(kind: .audio, clips: [c])])) != l0)
        }
        #expect(TimelineTranscription.layout(of: timeline([Track(kind: .audio, clips: [base])])) == l0)
    }

    @Test func noAudibleClipsThrowsNoAudio() async {
        let tl = timeline([Track(kind: .audio)])
        await #expect(throws: TranscriptionError.noAudio) {
            _ = try await TimelineTranscription.transcribe(timeline: tl, urls: [:], service: FakeService(words: [:]),
                                                           locale: Locale(identifier: "de-DE"), progress: { _ in })
        }
    }
}

private final class FakeService: TranscriptionService, @unchecked Sendable {
    let words: [String: [TranscriptWord]]
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    init(words: [String: [TranscriptWord]]) { self.words = words }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        lock.withLock { _calls += 1 }
        progress(1)
        return Transcript(language: locale.identifier(.bcp47), words: words[url.path] ?? [])
    }
}
