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
        .undo, .redo, nil, .cut, .copy, .paste, .pasteAttributes, nil,
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
        .addMarker, .matchFrame, .reverseMatchFrame,
    ]))
    public static let view = MenuSpec(title: "View", items: cmds([
        .playPause, .shuttleReverse, .shuttleStop, .shuttleForward, nil,
        .stepBackward, .stepForward, .stepBackward5, .stepForward5, nil,
        .zoomIn, .zoomOut, .zoomFit, nil,
        .tool(.selection), .tool(.trackForward), .tool(.trackBackward), .tool(.ripple), .tool(.rolling),
        .tool(.slip), .tool(.slide), .tool(.razor), .tool(.hand), .tool(.zoom), .tool(.type),
    ]))
    public static let window: MenuSpec = {
        let panels: [PanelID] = [.project, .sourceMonitor, .timeline, .programMonitor, .effectControls, .library, .effects]
        let items: [EditorCommand?] = panels.map { EditorCommand.focusPanel($0) } + [nil, .maximizePanel]
        return MenuSpec(title: "Window", items: cmds(items))
    }()
}
