import Foundation
import Testing
import Synchronization
@testable import SQCore

@Suite struct LiveDuckingTests {
    static func clip(_ start: Int64, _ len: Int64) -> Clip {
        Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(len, 1)), start: Time(start, 1))
    }
    static func timeline(dialogue: [(Int64, Int64)]) -> Timeline {
        var d = Track(kind: .audio, clips: dialogue.map { clip($0.0, $0.1) }); d.audioRole = .dialogue
        var m = Track(kind: .audio, clips: [clip(0, 100)]); m.audioRole = .music
        return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [d, m])
    }
    let live = LiveDucking(amountDB: 12, fade: Time(1, 2))

    @Test func dialogueRangesComeFromDialogueRoleTracksOnly() {
        let t = Self.timeline(dialogue: [(10, 5), (30, 5)])
        let r = LiveDucking.dialogueRanges(in: t)
        #expect(r == [TimeRange(start: Time(10, 1), duration: Time(5, 1)), TimeRange(start: Time(30, 1), duration: Time(5, 1))])
    }

    @Test func mutedTracksDoNotDuck() {
        var t = Self.timeline(dialogue: [(10, 5)])
        t.tracks[0].isMuted = true
        #expect(LiveDucking.dialogueRanges(in: t).isEmpty)
    }

    @Test func disabledClipsDoNotDuck() throws {
        var t = Self.timeline(dialogue: [(10, 5)])
        var c = t.tracks[0].clips[0]; c.isEnabled = false
        try t.replaceClip(c)
        #expect(LiveDucking.dialogueRanges(in: t).isEmpty)
    }

    @Test func gainIsFullOutsideRampsAndDuckedInside() {
        let r = [TimeRange(start: Time(10, 1), duration: Time(5, 1))]
        let f = Float(pow(10.0, -12.0 / 20))
        #expect(live.gain(at: Time(5, 1), ranges: r) == 1)
        #expect(abs(live.gain(at: Time(12, 1), ranges: r) - f) < 1e-6)
        let mid = (1 + f) / 2          // half way through the 0.5 s ramps
        #expect(abs(live.gain(at: Time(39, 4), ranges: r) - mid) < 1e-5)
        #expect(abs(live.gain(at: Time(61, 4), ranges: r) - mid) < 1e-5)
        #expect(live.gain(at: Time(16, 1), ranges: r) == 1)
    }

    @Test func closeRangesStayDuckedBetween() {
        let r = [TimeRange(start: Time(10, 1), duration: Time(2, 1)), TimeRange(start: Time(25, 2), duration: Time(2, 1))]
        let f = Float(pow(10.0, -12.0 / 20))
        #expect(abs(live.gain(at: Time(49, 4), ranges: r) - f) < 1e-6)
    }

    /// The point of N8: an edit to the dialogue track changes the envelope at once, no keys to refresh.
    @Test func movingADialogueClipMovesTheDuck() throws {
        var t = Self.timeline(dialogue: [(10, 5)])
        let probe = Time(40, 1)
        #expect(live.gain(at: probe, ranges: LiveDucking.dialogueRanges(in: t)) == 1)
        _ = try t.move(t.tracks[0].clips[0].id, to: Time(38, 1))
        #expect(live.gain(at: probe, ranges: LiveDucking.dialogueRanges(in: t)) < 0.3)
    }

    @Test func blockGainsMatchPointGains() {
        let r = [TimeRange(start: Time(1, 1), duration: Time(1, 1))]
        var out = [Float](repeating: 0, count: 480)
        out.withUnsafeMutableBufferPointer { live.fill($0.baseAddress!, startFrame: 24_000, count: 480, rate: 48_000, ranges: r) }
        for i in [0, 100, 479] {
            #expect(abs(out[i] - live.gain(at: Time(24_000 + Int64(i), 48_000), ranges: r)) < 1e-6)
        }
    }

    @Test func zeroAmountIsOff() {
        #expect(LiveDucking(amountDB: 0, fade: Time(1, 2)).isOff)
        #expect(LiveDucking(amountDB: 0, fade: Time(1, 2)).gain(at: .zero, ranges: [TimeRange(start: .zero, duration: Time(1, 1))]) == 1)
    }

    @Test func observerReportsASettingChange() {
        let d = UserDefaults(suiteName: "sq.test.liveduck.\(UUID())")!
        let seen = Mutex<[LiveDucking?]>([])
        let o = LiveDuckingObserver(defaults: d) { v in seen.withLock { $0.append(v) } }
        d.set(9.0, forKey: LiveDucking.defaultsKey)
        o.refresh()
        o.refresh()
        d.set(0.0, forKey: LiveDucking.defaultsKey)
        o.refresh()
        #expect(seen.withLock { $0 } == [LiveDucking(amountDB: 9), nil])
    }
}


@Suite struct LiveDuckingSettingTests {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "sq.test.ducking.\(UUID().uuidString)")!
        return d
    }
    @Test func setAmountWritesAndReadsBack() {
        let d = defaults()
        #expect(LiveDucking.current(d) == nil)
        LiveDucking.setAmount(9, defaults: d)
        #expect(LiveDucking.current(d)?.amountDB == 9)
        LiveDucking.setAmount(nil, defaults: d)
        #expect(LiveDucking.current(d) == nil)
        #expect(d.object(forKey: LiveDucking.defaultsKey) == nil)
    }
    @Test func amountIsClampedAndOffForNonsense() {
        let d = defaults()
        LiveDucking.setAmount(99, defaults: d)
        #expect(LiveDucking.current(d)?.amountDB == 40)
        LiveDucking.setAmount(-3, defaults: d)
        #expect(LiveDucking.current(d) == nil)
        LiveDucking.setAmount(.nan, defaults: d)
        #expect(LiveDucking.current(d) == nil)
    }
    @Test func choicesContainTheDefault() {
        #expect(LiveDucking.amountChoices.contains(Ducking.defaultAmountDB))
    }
}

/// N8b: per-track opt-out and the project's own stored setting (ProjectFile v43).
@Suite struct LiveDuckingSettingsTests {
    @Test func anExcludedDialogueTrackDoesNotDuck() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        #expect(!LiveDucking.dialogueRanges(in: t).isEmpty)
        t.tracks[0].isExcludedFromLiveDucking = true
        #expect(LiveDucking.dialogueRanges(in: t).isEmpty)
    }

    @Test func anExcludedMusicTrackIsNotDucked() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        #expect(LiveDucking.duckedClipIDs(in: t) == [t.tracks[1].clips[0].id])
        t.tracks[1].isExcludedFromLiveDucking = true
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty)
    }

    @Test func projectSettingOverridesPreferences() {
        let d = UserDefaults(suiteName: "sq.test.projduck.\(UUID())")!
        LiveDucking.setAmount(9, defaults: d)
        #expect(LiveDucking.resolved(project: nil, defaults: d)?.amountDB == 9)
        #expect(LiveDucking.resolved(project: ProjectLiveDucking(isOn: true, amountDB: 18), defaults: d)?.amountDB == 18)
        #expect(LiveDucking.resolved(project: ProjectLiveDucking(isOn: false, amountDB: 18), defaults: d) == nil)
        LiveDucking.setAmount(nil, defaults: d)
        #expect(LiveDucking.resolved(project: nil, defaults: d) == nil)
        #expect(LiveDucking.resolved(project: ProjectLiveDucking(isOn: true, amountDB: 99), defaults: d)?.amountDB == 40)
    }

    static func writtenVersion(_ p: Project) throws -> Int {
        let obj = try JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any]
        return obj?["formatVersion"] as? Int ?? -1
    }

    @Test func settingsAreWrittenAsV43AndRoundTrip() throws {
        var p = Project(name: "P", timelines: [LiveDuckingTests.timeline(dialogue: [(10, 5)])])
        #expect(try Self.writtenVersion(p) == 36)
        p.liveDucking = ProjectLiveDucking(isOn: true, amountDB: 15)
        #expect(try Self.writtenVersion(p) == 43)
        var back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        p.liveDucking = nil
        p.timelines[0].tracks[1].isExcludedFromLiveDucking = true
        #expect(try Self.writtenVersion(p) == 43)
        back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[1].isExcludedFromLiveDucking)
        #expect(!back.timelines[0].tracks[0].isExcludedFromLiveDucking)
    }

    @Test func trackOptOutIsOnlyStoredWhenSet() throws {
        let data = try JSONEncoder().encode(Track(kind: .audio))
        #expect(!String(decoding: data, as: UTF8.self).contains("liveDucking"))
    }
}
