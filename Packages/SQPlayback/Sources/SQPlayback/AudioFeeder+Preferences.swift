import Foundation
import SQAudioFX
import SQCore

extension AudioFeeder {
    /// Preferences > Audio De-Click and Live Ducking as playback reads them: the Mac `AudioEngine` keeps observers for
    /// both, a host without them (the Windows WASAPI engine) calls this at start and after Preferences change.
    public func applyAudioPreferences(_ defaults: UserDefaults = .standard) {
        declickFrames = AudioDeClick.currentFadeFrames(sampleRate: sampleRate, defaults: defaults)
        liveDucking = LiveDucking.current(defaults)
    }
}
