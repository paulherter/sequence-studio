import Foundation
import SQCore
import SQDrawShell
import SQEditAPI
import SQEditorSession

/// The local Edit API on Windows (docs/EDIT-API.md), translated line for line from the Mac `EditAPIController`: off by
/// default (`sq.api.enabled`, Preferences > Advanced). When on, the winsock server (`EditAPIServer+Winsock`, 127.0.0.1
/// only) runs with a fresh per-launch token, and port + token go to the discovery file for local tools. Every agent
/// commit goes through `EditorSession.perform`: one undo step like any other edit.
/// shortcut: a twin of the Mac `EditAPIController` / `SessionAPIHost` (those sit in the Mac app beside SQEditorUI's
/// `EditAPIRunState`); move both into a portable package when the Mac app moves onto the shared shell for good.
@MainActor
final class WinEditAPI {
    static let enabledKey = "sq.api.enabled"
    static let portKey = "sq.api.port"
    static let defaultPort: UInt16 = 19790

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The run state, worded as the Mac `EditAPIRunState`.
    enum RunState: Equatable {
        case notRunning, starting, listening(port: Int), listeningNoFile(port: Int), portInUse(port: Int)

        var shell: ShellEditAPI.State {
            switch self {
            case .notRunning: ShellEditAPI.State(text: "Not running", tone: .idle)
            case .starting: ShellEditAPI.State(text: "Starting\u{2026}", tone: .idle)
            case .listening(let p): ShellEditAPI.State(text: "Listening on 127.0.0.1, port \(p)", tone: .ok, copyablePort: p)
            case .listeningNoFile(let p):
                ShellEditAPI.State(text: "Listening on 127.0.0.1, port \(p), but the connection file could not be written",
                                   tone: .warning, copyablePort: p)
            case .portInUse: ShellEditAPI.State(text: "Port in use, could not start", tone: .warning)
            }
        }
    }

    private let session: EditorSession
    private var server: EditAPIServer?
    private(set) var state = RunState.notRunning
    var onState: (@MainActor (RunState) -> Void)?
    private let isBusy: @MainActor () -> Bool

    init(session: EditorSession, isBusy: @escaping @MainActor () -> Bool) { self.session = session; self.isBusy = isBusy }

    /// Starts or stops the server to match the setting.
    func sync() {
        if Self.isEnabled { start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = (1024...65535).contains(stored) ? UInt16(stored) : Self.defaultPort
        let config = EditAPIConfig(token: EditAPIConfig.makeToken(), port: port)
        let s = EditAPIServer(router: EditAPIRouter(config: config, host: WinSessionAPIHost(session: session, isBusy: isBusy))) { [weak self] state in
            Task { @MainActor in self?.serverState(state, config: config) }
        }
        server = s
        s.start()
    }

    func stop() {
        guard let s = server else { return }
        server = nil
        s.stop()
        EditAPIDiscovery.remove()
        setState(.notRunning)
    }

    private func serverState(_ state: EditAPIServer.State, config: EditAPIConfig) {
        guard server?.router.config.token == config.token else { return }   // a stopped server reporting late
        switch state {
        case .starting: setState(.starting)
        case .ready(let port):
            do {
                try EditAPIDiscovery(port: port, token: config.token, pid: ProcessInfo.processInfo.processIdentifier).write()
                setState(.listening(port: Int(port)))
            } catch {
                setState(.listeningNoFile(port: Int(port)))
            }
        case .failed(let why):
            server = nil
            EditAPIDiscovery.remove()
            SQLog.info("edit API: could not start on port \(config.port): \(why)")
            setState(.portInUse(port: Int(config.port)))
        case .stopped: break
        }
    }

    private func setState(_ s: RunState) { state = s; onState?(s) }
}

/// `EditAPIHost` over the live session (the Mac `SessionAPIHost`): reads `session.project`, commits through
/// `session.perform`.
@MainActor
final class WinSessionAPIHost: EditAPIHost {
    private weak var session: EditorSession?
    /// True while a timeline gesture (drag, trim, scrub) runs: its commit would replace an agent edit.
    private let isBusy: @MainActor () -> Bool
    init(session: EditorSession, isBusy: @escaping @MainActor () -> Bool) { self.session = session; self.isBusy = isBusy }

    func project() async -> Project? { session?.project }
    func activeSequence() async -> Timeline.ID? { session?.activeTimelineID }

    func run(_ r: HostCommit) async throws -> (before: Project, after: Project) {
        guard let session else { throw TransactionError(.edit(.timelineNotFound)) }
        try r.admit(active: session.activeTimelineID, busy: isBusy())
        let before = session.project
        if r.dryRun {
            // Read-only: the operations run off the main actor on the snapshot (playback shares the main actor).
            let applied = try await EditTransaction.applyOffActor(r.operations, to: before, sequence: r.sequence)
            guard let session = self.session else { throw TransactionError(.cancelled) }
            return (before, try session.previewPerform { $0 = applied })
        }
        let edit: (inout Project) throws -> Void = { try EditTransaction.apply(r.operations, to: &$0, sequence: r.sequence) }
        try session.perform(r.name, edit)
        return (before, session.project)
    }

    func undo(ifTopStep accept: @Sendable (String) -> Bool) async -> Bool {
        guard let session, !isBusy(), let name = session.undoName, accept(name) else { return false }
        return session.undo()
    }
}

extension AppController {
    /// Preferences > Advanced: the switch and status line (the Mac `SharedUIController.wireEditAPI`). The server itself
    /// starts in `main.swift` only for the real window (headless runs must not bind the port or write the file).
    func wireEditAPI() {
        let api = WinEditAPI(session: session) { [weak self] in self?.timelinePanel.isDragging == true }
        editAPI = api
        shell.editAPI = ShellEditAPI(
            isEnabled: { WinEditAPI.isEnabled },
            setEnabled: { WinEditAPI.isEnabled = $0; api.sync() },
            state: { api.state.shell })
        api.onState = { [weak self] _ in self?.shell.editAPI?.stateChanged?() }
    }
}
