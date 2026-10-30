import Foundation
import SQDrawKit
import SQUIKit

/// Tooltip text that carries the command's shortcut, taken from the key map so it can never go stale.
public extension KeyboardListing {
    /// "Mark In (I)"; the bare title when the command has no key.
    static func tip(_ title: String, _ command: EditorCommand, map: CommandMap = .current) -> String {
        #if canImport(AppKit)
        Tooltip.text(title, command: command, map: map)
        #else
        // Tooltip (SQUIKit) is AppKit-only; the same "Name (Key)" text from the portable key names.
        map.binding(for: command).map { "\(title) (\(KeyBindingText.text($0)))" } ?? title
        #endif
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
        case .clearIn: .clearIn
        case .clearOut: .clearOut
        case .clearInOut: .clearInOut
        case .toggleSafeMargins, .replace, .fitToFill: nil
        }
    }

    /// Tooltip of the transport button: title plus key.
    func tip(_ title: String, map: CommandMap = .current) -> String {
        command.map { KeyboardListing.tip(title, $0, map: map) } ?? title
    }

    /// The footer button's name (the Mac `MonitorPanelView.symbols` titles; Play reads Pause while playing).
    func buttonTitle(playing: Bool) -> String? {
        switch self {
        case .markIn: "Mark In"
        case .markOut: "Mark Out"
        case .goToIn: "Go to In"
        case .goToOut: "Go to Out"
        case .stepBack: "Step Back"
        case .stepForward: "Step Forward"
        case .playPause: playing ? "Pause" : "Play"
        case .addMarker: "Add Marker"
        case .insert: "Insert"
        case .overwrite: "Overwrite"
        case .lift: "Clear Range"
        case .extract: "Delete Range"
        case .exportFrame: "Export Frame"
        default: nil
        }
    }
}
