import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// The Reverse checkbox of the Speed section: shows the clip's state and flips it through the session (one undo step).
@MainActor
@Suite struct ReverseControlTests {
    @Test func reverseCheckboxShowsAndTogglesThroughTheSession() throws {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero,
                     mediaDuration: Time(60, 1))
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [tr])]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] ch in model.sync(with: session, change: ch) }
        session.select(clips: [c.id])
        #expect(!model.isReversed)
        let depth = session.undoStepDepth
        model.setReversedClip(true)
        #expect(model.isReversed)
        #expect(session.undoStepDepth == depth + 1)
        model.setReversedClip(false)
        #expect(!model.isReversed)
        #expect(session.activeTimeline?.tracks[0].clips[0] == c)
    }
}
