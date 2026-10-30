import Foundation

/// The host's local Edit API (the Mac `EditAPIController`) as Preferences > Advanced shows it: the switch, the run state
/// and the address to copy. The host sets `ShellHost.editAPI`; without one the Advanced page is left out.
@MainActor
public final class ShellEditAPI {
    /// `EditAPIRunState.text` / `tone` / `copyablePort`.
    public struct State: Equatable, Sendable {
        public var text: String
        public var tone: ShellForm.Status.Tone
        public var copyablePort: Int?
        public init(text: String, tone: ShellForm.Status.Tone, copyablePort: Int? = nil) {
            self.text = text; self.tone = tone; self.copyablePort = copyablePort
        }
    }

    public let isEnabled: @MainActor () -> Bool
    /// Stores the switch and starts or stops the server (`EditAPIController.isEnabled` + `sync()`).
    public let setEnabled: @MainActor (Bool) -> Void
    public let state: @MainActor () -> State
    /// Set while Preferences is open; the host calls it when the run state changes.
    public var stateChanged: (@MainActor () -> Void)?

    public init(isEnabled: @escaping @MainActor () -> Bool, setEnabled: @escaping @MainActor (Bool) -> Void,
                state: @escaping @MainActor () -> State) {
        self.isEnabled = isEnabled; self.setEnabled = setEnabled; self.state = state
    }
}
