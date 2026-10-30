import Foundation
#if canImport(AppKit)
import AppKit

/// A control that keeps the arrow keys while it is the first responder (number fields, sliders, icon grids): the global
/// frame-step bindings must not run then.
@MainActor
public protocol KeyClaiming: AnyObject {
    var claimsArrowKeys: Bool { get }
}

public enum KeyClaims {
    /// True when the first responder owns Left/Right/Up/Down itself (see `KeyClaiming`; lists always do).
    @MainActor
    public static func claimsArrowKeys(responder: NSResponder?) -> Bool {
        if responder is NSTableView { return true }
        return (responder as? KeyClaiming)?.claimsArrowKeys == true
    }
}

/// The five edit verbs that follow the focused panel.
#endif

public enum EditVerb: CaseIterable, Sendable {
    case selectAll, copy, cut, paste, delete

    public init?(command: EditorCommand) {
        switch command {
        case .selectAll: self = .selectAll
        case .copy: self = .copy
        case .cut: self = .cut
        case .paste: self = .paste
        case .delete, .rippleDelete: self = .delete
        default: return nil
        }
    }
}

/// Which panel's selection Cmd+A/C/X/V and Delete act on. Never the timeline unless the timeline (or a monitor) is focused.
public enum FocusedEditTarget: Sendable {
    case timeline, effectControls, project, graphics, keystones, captions, none

    public init(panel: PanelID?) {
        switch panel {
        case nil, .timeline, .programMonitor, .sourceMonitor: self = .timeline
        case .effectControls: self = .effectControls
        case .project, .library: self = .project
        case .graphics: self = .graphics
        case .keystones: self = .keystones
        case .text: self = .captions
        default: self = .none
        }
    }

    /// False = the menu item is disabled and the key does nothing.
    public func handles(_ verb: EditVerb) -> Bool {
        switch self {
        case .timeline: true
        case .effectControls: verb != .selectAll      // Cmd+A on keyframes: not built yet, so disabled rather than the timeline
        case .project: verb == .delete || verb == .paste   // paste: media from the pasteboard (PasteMedia)
        case .graphics: verb == .delete || verb == .selectAll
        case .keystones, .captions: verb == .delete
        case .none: false
        }
    }
}

/// Where Insert / Overwrite (and Place on Top) take their clip from. One rule for the key and for the menu item, so the
/// item is never grayed out while the key works.
public enum PlaceSource: Sendable, Equatable {
    /// The clip loaded in the Source monitor, with its In / Out.
    case sourceMonitor
    /// The media selected in the Project panel.
    case projectMedia
    /// The sequences selected in the Project panel (nested as one clip).
    case projectSequences
    case nothing

    /// The Source monitor wins unless the Project panel has focus; then the Project selection, media before sequences.
    /// Without a Source clip the Project selection is used whatever has focus.
    public static func resolve(sourceLoaded: Bool, focus: PanelID?, selectedMedia: Int, selectedSequences: Int) -> PlaceSource {
        if sourceLoaded, focus != .project { return .sourceMonitor }
        if selectedMedia > 0 { return .projectMedia }
        if selectedSequences > 0 { return .projectSequences }
        return sourceLoaded ? .sourceMonitor : .nothing
    }
}
