import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct SyncAudioWarningTests {
    @Test func captureDateWarningOnlyWhenSomeClipsUsedIt() {
        #expect(EditorSession.captureDateWarning(count: 0) == nil)
        #expect(EditorSession.captureDateWarning(count: 1)?.hasPrefix("1 clip was") == true)
        #expect(EditorSession.captureDateWarning(count: 3)?.hasPrefix("3 clips were") == true)
    }

    @Test func actionNamesFollowTheMethod() {
        #expect(EditorSession.syncAudioActionName(for: .captureDate) == "Sync by Capture Date")
        #expect(EditorSession.syncAudioActionName(for: .sound) == "Sync Audio")
    }
}
