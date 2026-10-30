import Foundation
import SQCore
import SQEditAPI
import SQEditorUI

/// Local edit API (docs/EDIT-API.md): off by default (`sq.api.enabled`, Settings > Advanced). When on, a loopback-only
/// server with a fresh per-launch token runs and its port + token are written to the discovery file for local tools.
/// Every agent commit goes through `EditorSession.perform`, so it is ONE undo step like any other edit.
@MainActor
final class EditAPIController {
    static let enabledKey = "sq.api.enabled"
    static let portKey = "sq.api.port"
    static let defaultPort: UInt16 = 19790

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let session: EditorSession
    private var server: EditAPIServer?
    private(set) var status = "Off"
    var onStatus: (@MainActor (String) -> Void)?
    /// Structured run state for the Settings page (dot, line, copy button).
    private(set) var state = EditAPIRunState.notRunning
    var onState: (@MainActor (EditAPIRunState) -> Void)?

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
        let s = EditAPIServer(router: EditAPIRouter(config: config, host: SessionAPIHost(session: session, isBusy: isBusy))) { [weak self] state in
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
        setStatus("Off", .notRunning)
    }

    private func serverState(_ state: EditAPIServer.State, config: EditAPIConfig) {
        guard server?.router.config.token == config.token else { return }   // a stopped server reporting late
        switch state {
        case .starting: setStatus(SQL10n.string("Starting…"), .starting)
        case .ready(let port):
            do {
                try EditAPIDiscovery(port: port, token: config.token, pid: ProcessInfo.processInfo.processIdentifier).write()
                setStatus(SQL10n.format("Running on 127.0.0.1:%@", String(port)), .listening(port: Int(port)))
            } catch {
                setStatus(SQL10n.format("Running on 127.0.0.1:%@, but the connection file could not be written", String(port)), .listeningNoFile(port: Int(port)))
            }
        case .failed(let why):
            server = nil
            EditAPIDiscovery.remove()
            setStatus(SQL10n.format("Could not start (port %@ busy?): %@", String(config.port), why), .portInUse(port: Int(config.port)))
        case .stopped: break
        }
    }

    private func setStatus(_ s: String, _ st: EditAPIRunState) { status = s; state = st; onStatus?(s); onState?(st) }
}

/// `EditAPIHost` over the live session: reads `session.project`, commits through `session.perform`.
@MainActor
final class SessionAPIHost: EditAPIHost {
    private weak var session: EditorSession?
    /// True while a timeline gesture (drag, trim, scrub, marker drag) runs: its commit would replace an agent edit.
    private let isBusy: @MainActor () -> Bool
    init(session: EditorSession, isBusy: @escaping @MainActor () -> Bool) { self.session = session; self.isBusy = isBusy }

    func project() async -> Project? { session?.project }
    func activeSequence() async -> Timeline.ID? { session?.activeTimelineID }

    func run(_ r: HostCommit) async throws -> (before: Project, after: Project) {
        guard let session else { throw TransactionError(.edit(.timelineNotFound)) }
        try r.admit(active: session.activeTimelineID, busy: isBusy())
        let before = session.project
        if r.dryRun {
            // Read-only: the operations run off the main actor on the snapshot (playback shares the main actor); only
            // the session's cheap extra steps run here, on that result. The preview describes the snapshot it started from.
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
