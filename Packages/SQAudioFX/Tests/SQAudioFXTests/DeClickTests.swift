import Testing
import Foundation
import Synchronization
@testable import SQAudioFX

@Suite struct DeClickTests {
    @Test func fadeLengthIsAboutThreeMilliseconds() {
        #expect(AudioDeClick.fadeFrames(sampleRate: 48_000) == 144)
    }

    @Test func settingToggleControlsFrames() {
        let key = AudioDeClick.defaultsKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AudioDeClick.currentFadeFrames() == 144)       // default on
        AudioDeClick.isEnabled = false
        #expect(AudioDeClick.currentFadeFrames() == 0)
        AudioDeClick.isEnabled = true
        #expect(AudioDeClick.currentFadeFrames() == 144)
    }

    @Test func observerReportsLiveChangesOnlyWhenValueChanges() {
        let name = "sq.test.declick.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let seen = Mutex<[Int]>([])
        let obs = AudioDeClickObserver(defaults: d) { n in seen.withLock { $0.append(n) } }
        d.set(false, forKey: AudioDeClick.defaultsKey)
        d.set(false, forKey: AudioDeClick.defaultsKey)      // no change, no callback
        d.set(true, forKey: AudioDeClick.defaultsKey)
        obs.refresh()
        #expect(seen.withLock { $0 } == [0, 144])
        #expect(AudioDeClick.currentFadeFrames(defaults: d) == 144)
    }

    @Test func edgesRampFromAndToSilenceInteriorUntouched() {
        let g = (0..<1000).map { AudioDeClick.edgeGain(frame: Int64(500 + $0), start: 500, end: 1500, fade: 100) }
        #expect(g[0] == 0 && g[999] == 0)
        #expect(g[100] == 1 && g[899] == 1 && g[500] == 1)
        #expect(g[50] == 0.5)
        for i in 0..<99 { #expect(g[i + 1] > g[i]) }
    }

    @Test func shortSegmentsFadeInsideThemselves() {
        let g = (0..<10).map { AudioDeClick.edgeGain(frame: Int64($0), start: 0, end: 10, fade: 144) }
        #expect(g[0] == 0 && g[9] == 0)
        #expect(g.max()! <= 1)
    }

    @Test func zeroFadeIsIdentityAndApplyMatchesGain() {
        #expect(AudioDeClick.edgeGain(frame: 0, start: 0, end: 10, fade: 0) == 1)
        var a = [Float](repeating: 1, count: 600)
        a.withUnsafeMutableBufferPointer { AudioDeClick.apply($0.baseAddress!, count: 300, firstFrame: 650, start: 600, end: 1200, fade: 144) }
        for i in 0..<300 { #expect(a[i] == AudioDeClick.edgeGain(frame: Int64(650 + i), start: 600, end: 1200, fade: 144)) }
        #expect(a[300] == 1)
    }

    @Test func blockSplitGivesIdenticalSamples() {
        var whole = [Float](repeating: 1, count: 1000)
        whole.withUnsafeMutableBufferPointer { AudioDeClick.apply($0.baseAddress!, count: 1000, firstFrame: 0, start: 0, end: 1000, fade: 144) }
        var parts = [Float](repeating: 1, count: 1000)
        parts.withUnsafeMutableBufferPointer { p in
            for s in stride(from: 0, to: 1000, by: 77) {
                AudioDeClick.apply(p.baseAddress! + s, count: min(77, 1000 - s), firstFrame: Int64(s), start: 0, end: 1000, fade: 144)
            }
        }
        #expect(whole == parts)
        #expect(whole[0] == 0 && whole[999] == 0 && whole[500] == 1)
    }
}
