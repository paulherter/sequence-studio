import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor
@Suite struct SessionAutosaveRootTests {
    /// A session only ever writes its crash marker into the autosave store it was given (render mode passes a temp one).
    @Test func markerStaysInInjectedRoot() throws {
        let fm = FileManager.default
        let given = fm.temporaryDirectory.appendingPathComponent("sq-given-\(UUID().uuidString)")
        let untouched = fm.temporaryDirectory.appendingPathComponent("sq-untouched-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: given) }
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: given))
        #expect(fm.fileExists(atPath: given.path))
        #expect(!fm.fileExists(atPath: untouched.path))
        session.close()
    }
}
