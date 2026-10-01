import Foundation

/// Tooltip text that carries the command's shortcut, taken from the key map so it can never go stale.
public extension KeyboardListing {
    /// "Mark In (I)"; the bare title when the command has no key.
    static func tip(_ title: String, _ command: EditorCommand, map: CommandMap = .premiereDefault) -> String {
        guard let b = map.binding(for: command) else { return title }
        return "\(title) (\(text(for: b)))"
    }
}

public extension MonitorAction {
    /// The command a monitor button runs (nil for the ones without a command: Safe Margins).
    var command: EditorCommand? {
        switch self {
        case .markIn: .markIn
        case .markOut: .markOut
        case .goToIn: .goToIn
        case .goToOut: .goToOut
        case .stepBack: .stepBackward
        case .stepForward: .stepForward
        case .playPause: .playPause
        case .addMarker: .addMarker
        case .insert: .insert
        case .overwrite: .overwrite
        case .lift: .lift
        case .extract: .extract
        case .exportFrame: .exportFrame
        case .loop: .toggleLoop
        case .playInToOut: .playInToOut
        case .toggleSafeMargins: nil
        }
    }

    /// Tooltip of the transport button: title plus key.
    func tip(_ title: String, map: CommandMap = .premiereDefault) -> String {
        command.map { KeyboardListing.tip(title, $0, map: map) } ?? title
    }
}
