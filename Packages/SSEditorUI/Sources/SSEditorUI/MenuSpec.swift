import Foundation

/// Menu structure for U-04 (real NSMenus). Key equivalents come from `CommandMap.binding(for:)`.
public struct MenuSpec: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        case command(EditorCommand)
        case separator
    }
    public var title: String
    public var items: [Item]
}

public enum EditorMenus {
    public static let all: [MenuSpec] = [file, edit, clip, sequence, view, window]

    private static func cmds(_ c: [EditorCommand?]) -> [MenuSpec.Item] {
        c.map { $0.map(MenuSpec.Item.command) ?? .separator }
    }

    public static let file = MenuSpec(title: "File", items: cmds([
        .newSequence, .importMedia, nil, .save, nil, .export,
    ]))
    public static let edit = MenuSpec(title: "Edit", items: cmds([
        .undo, .redo, nil, .cut, .copy, .paste, .pasteInsert, .pasteAttributes, nil, .selectAll, nil,
        .delete, .rippleDelete, nil, .toggleSnapping,
    ]))
    public static let clip = MenuSpec(title: "Clip", items: cmds([
        .insert, .overwrite, nil, .link, .group, nil,
        .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation, .addKeyframe, .toggleSpeedGraph,
    ]))
    public static let sequence = MenuSpec(title: "Sequence", items: cmds([
        .markIn, .markOut, .goToIn, .goToOut, .clearInOut, .markClip, nil,
        .lift, .extract, nil,
        .addEdit, .addEditAllTracks, .rippleTrimPrevious, .rippleTrimNext, .extendEdit, nil,
        .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd, nil,
        .toggleLinkedSelection, .markSelection, nil,
        .addMarker, .nextMarker, .previousMarker, .matchFrame, .reverseMatchFrame,
    ]))
    public static let view = MenuSpec(title: "View", items: cmds([
        .playPause, .shuttleReverse, .shuttleStop, .shuttleForward, nil,
        .stepBackward, .stepForward, .stepBackward5, .stepForward5, nil,
        .zoomIn, .zoomOut, .zoomFit, nil,
        .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter,
        .minimizeAllTracks, .expandAllTracks, nil,
        .tool(.selection), .tool(.trackForward), .tool(.trackBackward), .tool(.ripple), .tool(.rolling),
        .tool(.slip), .tool(.slide), .tool(.razor), .tool(.hand), .tool(.zoom), .tool(.type),
    ]))
    /// Panels in the Window menu, in menu order: one checkable item each (check = visible in the workspace).
    public static let windowPanels: [PanelID] = [
        .effectControls, .text, .programMonitor, .sourceMonitor, .library, .effects, .project, .timeline, .audioMeter,
        .colorInspector, .scopes,
    ]

    /// The panel items and the workspace list are added by the app (they carry state); the spec keeps the plain commands.
    public static let window = MenuSpec(title: "Window", items: cmds([.maximizePanel]))
}
