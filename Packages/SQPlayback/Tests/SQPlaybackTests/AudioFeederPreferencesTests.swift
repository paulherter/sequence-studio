import Testing
import Foundation
import SQCore
import SQAudioFX
@testable import SQPlayback

/// The feeder picks up Preferences > Audio De-Click and Live Ducking in one call (hosts without observers).
@Suite struct AudioFeederPreferencesTests {
    @Test func deClickAndLiveDuckingFollowTheStoredSettings() {
        let d = UserDefaults(suiteName: "sq.test.feeder.prefs.\(UUID().uuidString)")!
        let f = AudioFeeder(timeline: Timeline(name: "", frameDuration: Time(1, 30)), ring: RingBuffer(capacity: 1 << 12)) { _ in
            throw CancellationError()
        }
        f.applyAudioPreferences(d)
        #expect(f.declickFrames == AudioDeClick.fadeFrames(sampleRate: 48_000))   // absent = on
        #expect(f.liveDucking == nil)                                              // absent = off
        d.set(false, forKey: AudioDeClick.defaultsKey)
        LiveDucking.setAmount(12, defaults: d)
        f.applyAudioPreferences(d)
        #expect(f.declickFrames == 0)
        #expect(f.liveDucking?.amountDB == 12)
    }
}
