import Foundation
import Testing
@testable import SQCore

@Suite struct TransitionShapeTests {
    @Test func exponentialFadeIsAnAudioKind() {
        #expect(TransitionKind.exponentialFade.trackKind == .audio)
        #expect(TransitionKind.kinds(for: .audio).contains(.exponentialFade))
        #expect(!TransitionKind.kinds(for: .video).contains(.exponentialFade))
    }

    @Test func exponentialFadeGains() {
        let g0 = TransitionMix.audioGains(.exponentialFade, progress: 0)
        let g1 = TransitionMix.audioGains(.exponentialFade, progress: 1)
        #expect(g0.outgoing == 1 && g0.incoming == 0 && g1.outgoing == 0 && g1.incoming == 1)
        let mid = TransitionMix.audioGains(.exponentialFade, progress: 0.5)
        #expect(mid.outgoing < 0.5 && mid.incoming < 0.5)
    }
}
