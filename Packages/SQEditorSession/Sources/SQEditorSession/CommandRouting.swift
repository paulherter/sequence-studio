import Foundation
import SQUIKit

/// The one command-routing table. It answers, without any AppKit state:
/// - which handler stage owns a command (`route(for:)`; nil = not wired, then the app flashes "not available yet"),
/// - what Cmd+A/C/X/V and Delete do per focused panel (`editRoute`),
/// - which panel-specific shortcuts take a command before the generic path (`focusOverride`).
/// `AppController.execute` and the menu enablement read these; tests walk them against `EditorMenus`.
public enum CommandRouting {
    /// The stage of `AppController.execute` that performs the command.
    public enum Handler: Sendable, Equatable {
        case core, timelineOp, shell, effectsLook
    }

    /// Where a command goes. `focusDependent` = the result depends on the focused panel (edit verbs, panel overrides,
    /// zoom, delete); everything else is global and ignores focus.
    public struct Route: Sendable, Equatable {
        public var handler: Handler
        public var focusDependent: Bool
    }

    /// Commands that are listed in a menu but have no handler yet. Must stay empty; a new menu item without a handler
    /// fails `CommandRoutingTests` instead of becoming a silent no-op.
    public static let notWired: Set<EditorCommand> = []

    public static func route(for c: EditorCommand) -> Route? {
        let handler: Handler
        if CommandSupport.isShellCommand(c) { handler = .shell }
        else if CommandSupport.isTimelineOp(c) { handler = .timelineOp }
        else if CommandSupport.isEffectsLookOp(c) { handler = .effectsLook }
        else if CommandSupport.isCore(c) { handler = .core }
        else { return nil }
        return Route(handler: handler, focusDependent: isFocusDependent(c))
    }

    private static func isFocusDependent(_ c: EditorCommand) -> Bool {
        if EditVerb(command: c) != nil || c.keyframeNudgeFrames != nil { return true }
        switch c {
        case .playPause, .zoomIn, .zoomOut, .zoomFit, .exportFrame, .find, .playInToOutRoll, .playAround, .maximizeActivePanel, .selectNextPanel, .selectPreviousPanel,
             .maximizePanel, .deleteProjectItems, .nextKeyframe, .previousKeyframe, .addKeyframe, .insert, .overwrite: return true
        default: return false
        }
    }

    // MARK: Edit verbs by focused panel

    /// What an edit verb does for a focus target.
    public enum EditAction: Sendable, Hashable {
        /// The timeline's own path continues (also Effect Controls' Delete, which has its own order of targets).
        case fallThrough
        /// The panel has no such command: the key does nothing and the item is disabled. Never the timeline's clips.
        case swallow
        case effectControls
        case deleteProjectItems, pasteMedia, deleteGraphicsLayers, selectAllGraphicsLayers, deleteKeystones, deleteCaptions
    }

    /// Menu enablement of an edit verb.
    public enum EditEnabled: Sendable, Equatable {
        /// The timeline's own rules decide.
        case timelineRules
        case always, never
        case canPasteMedia, graphicsHasSelection, graphicsHasLayers
    }

    public struct EditRoute: Sendable, Equatable {
        public var action: EditAction
        public var enabled: EditEnabled
        public init(action: EditAction, enabled: EditEnabled) { self.action = action; self.enabled = enabled }
    }

    public static func editRoute(target: FocusedEditTarget, verb: EditVerb) -> EditRoute {
        switch (target, verb) {
        case (.timeline, _): return .init(action: .fallThrough, enabled: .timelineRules)
        case (.effectControls, .delete): return .init(action: .fallThrough, enabled: .timelineRules)
        case (.effectControls, .selectAll): return swallowed        // keyframe select-all: not built yet
        case (.effectControls, _): return .init(action: .effectControls, enabled: .timelineRules)
        case (.project, .delete): return .init(action: .deleteProjectItems, enabled: .always)
        case (.project, .paste): return .init(action: .pasteMedia, enabled: .canPasteMedia)
        case (.graphics, .delete): return .init(action: .deleteGraphicsLayers, enabled: .graphicsHasSelection)
        case (.graphics, .selectAll): return .init(action: .selectAllGraphicsLayers, enabled: .graphicsHasLayers)
        case (.keystones, .delete): return .init(action: .deleteKeystones, enabled: .always)
        case (.captions, .delete): return .init(action: .deleteCaptions, enabled: .always)
        default: return swallowed
        }
    }

    private static let swallowed = EditRoute(action: .swallow, enabled: .never)

    /// Delete in the Program monitor with graphics layers selected removes those layers (undo "Delete Layers"), never the
    /// whole graphics clip. Ripple delete and every other panel keep their own rules.
    public static func deletesMonitorLayers(command: EditorCommand, panel: PanelID?, hasLayerSelection: Bool) -> Bool {
        command == .delete && panel == .programMonitor && hasLayerSelection
    }

    // MARK: Panel-specific overrides

    public enum FocusOverride: Sendable, Equatable {
        /// Space plays the previewed Library item.
        case libraryPreviewPlay
        /// Cmd-C / Cmd-V copy and paste the whole grade.
        case copyGrade, pasteGrade
    }

    /// A command a focused panel takes before the generic path; nil = no override.
    public static func focusOverride(_ c: EditorCommand, focus: PanelID?) -> FocusOverride? {
        switch (focus, c) {
        case (.library, .playPause): return .libraryPreviewPlay
        case (.colorInspector, .copy), (.colorClips, .copy), (.steps, .copy): return .copyGrade
        case (.colorInspector, .paste), (.colorClips, .paste), (.steps, .paste): return .pasteGrade
        default: return nil
        }
    }

    // MARK: Predicates (the app asks here, never CommandSupport directly)

    // shortcut: the member lists still live in SQUIKit.CommandSupport (menus and key tests read them there);
    // upgrade by moving the lists here once those packages depend on SQEditorSession.
    public static func isCore(_ c: EditorCommand) -> Bool { CommandSupport.isCore(c) }
    public static func isTimelineOp(_ c: EditorCommand) -> Bool { CommandSupport.isTimelineOp(c) }
    public static func isShellCommand(_ c: EditorCommand) -> Bool { CommandSupport.isShellCommand(c) }
    public static func isEffectsLookOp(_ c: EditorCommand) -> Bool { CommandSupport.isEffectsLookOp(c) }
    public static func isSupported(_ c: EditorCommand) -> Bool { CommandSupport.isSupported(c) }

    // MARK: Focus-dependent targets of single commands

    public enum ZoomTarget: Sendable, Equatable { case programMonitor, sourceMonitor, effectControls, timeline }

    /// A focused monitor zooms its picture; Effect Controls and the timeline keep their own zoom.
    public static func zoomTarget(focus: PanelID?, effectControlsFocused: Bool) -> ZoomTarget {
        switch focus {
        case .programMonitor: return .programMonitor
        case .sourceMonitor: return .sourceMonitor
        default: return effectControlsFocused ? .effectControls : .timeline
        }
    }

    public enum ExportFrameTarget: Sendable, Equatable { case sourceMonitor, program }
    public static func exportFrameTarget(focus: PanelID?) -> ExportFrameTarget { focus == .sourceMonitor ? .sourceMonitor : .program }

    public enum FindTarget: Sendable, Equatable {
        /// Caption find and replace if the timeline has captions to search, else the Project panel.
        case captionsThenProject, project
    }
    public static func findTarget(focus: PanelID?) -> FindTarget { focus == .timeline ? .captionsThenProject : .project }

    /// The Source monitor gets the first look at every command while it has focus.
    public static func sourceMonitorOffered(focus: PanelID?) -> Bool { focus == .sourceMonitor }
}
