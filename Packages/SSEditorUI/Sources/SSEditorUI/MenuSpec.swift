import Foundation

/// Menu structure (real NSMenus). Key equivalents come from `CommandMap.binding(for:)`.
/// Names and order follow Premiere Pro: File, Edit, Clip, Sequence, Markers, View, Window (Help and the app menu are
/// built by the app). Only commands that exist are listed; the app hides the ones that are not wired yet.
public struct MenuSpec: Sendable, Equatable {
    public indirect enum Item: Sendable, Equatable {
        case command(EditorCommand)
        case separator
        case submenu(String, [Item])
    }
    public var title: String
    public var items: [Item]

    /// Every command in the menu, submenus included.
    public var commands: [EditorCommand] { Self.flatten(items) }

    static func flatten(_ items: [Item]) -> [EditorCommand] {
        items.flatMap { item -> [EditorCommand] in
            switch item {
            case .command(let c): [c]
            case .separator: []
            case .submenu(_, let sub): flatten(sub)
            }
        }
    }
}

public enum EditorMenus {
    public static let all: [MenuSpec] = [file, edit, clip, sequence, markers, view, window]

    private static func cmds(_ c: [EditorCommand?]) -> [MenuSpec.Item] {
        c.map { $0.map(MenuSpec.Item.command) ?? .separator }
    }

    /// File. The app inserts "Open Recent" after Open Project.
    public static let file = MenuSpec(title: "File", items: cmds([
        .newProject, .newSequence, .newBin, nil, .openProject, nil, .save, .saveAs, .revert, nil, .importMedia, nil, .export, .exportFrame,
    ]))
    public static let edit = MenuSpec(title: "Edit", items: cmds([
        .undo, .redo, nil, .cut, .copy, .paste, .pasteInsert, .pasteAttributes, nil,
        .selectAll, .deselectAll, nil,
        .delete, .rippleDelete,
    ]))
    public static let clip = MenuSpec(title: "Clip", items: cmds([
        .insert, .overwrite, nil, .speedDuration, nil, .link, nil,
        .setToFrameSize, nil,
        .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation, .addKeyframe, .toggleSpeedGraph,
    ]))
    public static let sequence = MenuSpec(title: "Sequence", items: cmds([
        .sequenceSettings, nil,
        .lift, .extract, nil,
        .addEdit, .addEditAllTracks, .rippleTrimPrevious, .rippleTrimNext, .extendEdit, nil,
        .toggleSnapping, .toggleLinkedSelection, nil,
        .matchFrame, .reverseMatchFrame, nil,
        .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd,
    ]))
    /// Premiere's Markers menu: In/Out marking and sequence markers.
    public static let markers = MenuSpec(title: "Markers", items: cmds([
        .markIn, .markOut, .markClip, nil,
        .goToIn, .goToOut, nil,
        .clearIn, .clearOut, .clearInOut, nil,
        .addMarker, .nextMarker, .previousMarker, nil,
        .markSelection,
    ]))
    public static let view = MenuSpec(title: "View", items: [
        .submenu("Playback", cmds([
            .playPause, .playInToOut, .toggleLoop, nil, .shuttleReverse, .shuttleStop, .shuttleForward, nil,
            .stepBackward, .stepForward, .stepBackward5, .stepForward5,
        ])),
        .separator,
        .command(.zoomIn), .command(.zoomOut), .command(.zoomFit),
        .separator,
        .submenu("Track Height", cmds([
            .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, nil,
            .minimizeAllTracks, .expandAllTracks,
        ])),
        .separator,
        .submenu("Tools", cmds([
            .tool(.selection), .tool(.trackForward), .tool(.trackBackward), .tool(.ripple), .tool(.rolling),
            .tool(.slip), .tool(.slide), .tool(.rateStretch), .tool(.razor), .tool(.hand), .tool(.zoom), .tool(.type),
        ])),
    ])
    /// Panels in the Window menu, in menu order: one checkable item each (check = visible in the workspace).
    public static let windowPanels: [PanelID] = [
        .effectControls, .text, .programMonitor, .sourceMonitor, .library, .effects, .project, .timeline, .audioMeter,
        .colorInspector, .scopes,
    ]

    /// The panel items and the workspace list are added by the app (they carry state); the spec keeps the plain commands.
    public static let window = MenuSpec(title: "Window", items: cmds([.maximizePanel, .maximizeActivePanel]))

    /// Commands that stay visible in their menu even when not wired (the standard text editing commands: a text field
    /// handles them) and commands that are menu-only (no default key in Premiere).
    public static let alwaysShown: Set<EditorCommand> = [.undo, .redo, .cut, .copy, .paste, .delete]
    public static let menuOnly: Set<EditorCommand> = [.revert, .sequenceSettings, .setToFrameSize, .toggleLinkedSelection]
}
