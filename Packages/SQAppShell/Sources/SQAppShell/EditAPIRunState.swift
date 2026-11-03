import Foundation

/// Run state of the Edit API server as the Settings page shows it (a dot and one line under the checkbox).
public enum EditAPIRunState: Sendable, Equatable {
    case notRunning
    case starting
    case listening(port: Int)
    /// Listening, but the connection file for local tools could not be written.
    case listeningNoFile(port: Int)
    case portInUse(port: Int)

    public var text: String {
        switch self {
        case .notRunning: "Not running"
        case .starting: "Starting…"
        case .listening(let p): "Listening on 127.0.0.1, port \(p)"
        case .listeningNoFile(let p): "Listening on 127.0.0.1, port \(p), but the connection file could not be written"
        case .portInUse: "Port in use, could not start"
        }
    }

    public enum Tone: Sendable, Equatable { case idle, ok, warning }
    public var tone: Tone {
        switch self {
        case .notRunning, .starting: .idle
        case .listening: .ok
        case .listeningNoFile, .portInUse: .warning
        }
    }

    /// Port to copy; nil unless the server listens.
    public var copyablePort: Int? {
        switch self {
        case .listening(let p), .listeningNoFile(let p): p
        default: nil
        }
    }
}
