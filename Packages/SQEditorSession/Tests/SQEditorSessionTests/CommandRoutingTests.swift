import Foundation
import Testing
import SQUIKit
@testable import SQEditorSession

/// One routing table (`CommandRouting`): every menu command has a handler stage or is listed as not wired, and the
/// panel-specific edit rules cover every focus target x verb. Guards against silent no-ops (FILMCRAFT-ISSUES #404 #1352).
@Suite struct CommandRoutingTests {
    private var menuCommands: [EditorCommand] { EditorMenus.all.flatMap(\.commands) }

    @Test func everyMenuCommandHasARouteOrIsListedAsNotWired() {
        for c in menuCommands {
            let routed = CommandRouting.route(for: c) != nil
            let listed = CommandRouting.notWired.contains(c)
            #expect(routed != listed, "\(c.title): routed=\(routed) listedNotWired=\(listed)")
        }
    }

    @Test func routeAgreesWithCommandSupport() {
        for c in CommandCatalog.audited(.premiereDefault) {
            #expect((CommandRouting.route(for: c) != nil) == CommandSupport.isSupported(c), "\(c.title)")
        }
    }

    @Test func notWiredCommandsAreReallyNotSupported() {
        #expect(CommandRouting.notWired.allSatisfy { !CommandSupport.isSupported($0) })
    }

    /// A routed command must be handled somewhere in the app target: its case name appears in a `case` line of App/Sources.
    @MainActor @Test func everyRoutedMenuCommandIsHandledInTheApp() throws {
        let lines = try Self.appSourceLines()
        for c in menuCommands + EditorMenus.windowPanels.map(EditorCommand.focusPanel) where CommandRouting.route(for: c) != nil {
            let name = String(String(describing: c).prefix { $0 != "(" })
            let found = EditorLookCommands.handles(c) || lines.contains { ($0.contains("case") || $0.contains("==")) && Self.mentions($0, ".\(name)") }
            #expect(found, "\(c.title) (.\(name)) is routed but no `case .\(name)` or `== .\(name)` exists in App/Sources")
        }
    }

    @Test func editRouteCoversEveryTargetAndVerbConsistentlyWithHandles() {
        let targets: [FocusedEditTarget] = [.timeline, .effectControls, .project, .graphics, .keystones, .captions, .none]
        for t in targets {
            for v in EditVerb.allCases {
                let r = CommandRouting.editRoute(target: t, verb: v)
                if t == .timeline { #expect(r.action == .fallThrough); continue }
                if !t.handles(v) {
                    #expect(r.action == .swallow && r.enabled == .never, "\(t) \(v)")
                } else {
                    #expect(r.action != .swallow && r.enabled != .never, "\(t) \(v)")
                }
            }
        }
    }

    @Test func editRoutesKeepTheirPanelActions() {
        #expect(CommandRouting.editRoute(target: .project, verb: .delete).action == .deleteProjectItems)
        #expect(CommandRouting.editRoute(target: .project, verb: .paste) == .init(action: .pasteMedia, enabled: .canPasteMedia))
        #expect(CommandRouting.editRoute(target: .graphics, verb: .delete).action == .deleteGraphicsLayers)
        #expect(CommandRouting.editRoute(target: .graphics, verb: .selectAll).action == .selectAllGraphicsLayers)
        #expect(CommandRouting.editRoute(target: .keystones, verb: .delete).action == .deleteKeystones)
        #expect(CommandRouting.editRoute(target: .captions, verb: .delete).action == .deleteCaptions)
        #expect(CommandRouting.editRoute(target: .effectControls, verb: .delete).action == .fallThrough)
        #expect(CommandRouting.editRoute(target: .effectControls, verb: .copy).action == .effectControls)
        #expect(CommandRouting.editRoute(target: .none, verb: .paste).action == .swallow)
    }

    @Test func deleteInTheProgramMonitorTakesSelectedLayers() {
        #expect(CommandRouting.deletesMonitorLayers(command: .delete, panel: .programMonitor, hasLayerSelection: true))
        #expect(!CommandRouting.deletesMonitorLayers(command: .delete, panel: .programMonitor, hasLayerSelection: false))
        #expect(!CommandRouting.deletesMonitorLayers(command: .delete, panel: .timeline, hasLayerSelection: true))
        #expect(!CommandRouting.deletesMonitorLayers(command: .rippleDelete, panel: .programMonitor, hasLayerSelection: true))
    }

    @Test func focusOverridesAreScopedToTheirPanels() {
        #expect(CommandRouting.focusOverride(.playPause, focus: .library) == .libraryPreviewPlay)
        #expect(CommandRouting.focusOverride(.playPause, focus: .timeline) == nil)
        for p in [PanelID.colorInspector, .colorClips, .steps] {
            #expect(CommandRouting.focusOverride(.copy, focus: p) == .copyGrade)
            #expect(CommandRouting.focusOverride(.paste, focus: p) == .pasteGrade)
            #expect(CommandRouting.focusOverride(.cut, focus: p) == nil)
        }
        #expect(CommandRouting.focusOverride(.copy, focus: .timeline) == nil)
    }

    // MARK: Helpers

    private static func mentions(_ line: String, _ token: String) -> Bool {
        var rest = line[...]
        while let r = rest.range(of: token) {
            let after = rest[r.upperBound...].first
            if after == nil || !(after!.isLetter || after!.isNumber) { return true }
            rest = rest[r.upperBound...]
        }
        return false
    }

    private static func appSourceLines() throws -> [String] {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Packages", url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        let dir = url.deletingLastPathComponent().appendingPathComponent("App/Sources")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        return try files.flatMap { try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n") }
    }
}

@Suite struct CommandRoutingFocusTests {
    @Test func zoomGoesToTheFocusedSurface() {
        #expect(CommandRouting.zoomTarget(focus: .programMonitor, effectControlsFocused: false) == .programMonitor)
        #expect(CommandRouting.zoomTarget(focus: .sourceMonitor, effectControlsFocused: false) == .sourceMonitor)
        #expect(CommandRouting.zoomTarget(focus: .timeline, effectControlsFocused: true) == .effectControls)
        #expect(CommandRouting.zoomTarget(focus: .timeline, effectControlsFocused: false) == .timeline)
        #expect(CommandRouting.zoomTarget(focus: nil, effectControlsFocused: false) == .timeline)
        // A focused monitor wins over a stale Effect Controls responder.
        #expect(CommandRouting.zoomTarget(focus: .programMonitor, effectControlsFocused: true) == .programMonitor)
    }

    @Test func exportFrameAndFindFollowFocus() {
        #expect(CommandRouting.exportFrameTarget(focus: .sourceMonitor) == .sourceMonitor)
        #expect(CommandRouting.exportFrameTarget(focus: .programMonitor) == .program)
        #expect(CommandRouting.exportFrameTarget(focus: nil) == .program)
        #expect(CommandRouting.findTarget(focus: .timeline) == .captionsThenProject)
        #expect(CommandRouting.findTarget(focus: .project) == .project)
        #expect(CommandRouting.findTarget(focus: nil) == .project)
    }

    @Test func sourceMonitorOffersCommandsOnlyWhenFocused() {
        #expect(CommandRouting.sourceMonitorOffered(focus: .sourceMonitor))
        #expect(!CommandRouting.sourceMonitorOffered(focus: .programMonitor))
        #expect(!CommandRouting.sourceMonitorOffered(focus: nil))
    }

    @Test func predicatesAgreeWithTheSupportTable() {
        for c in EditorMenus.all.flatMap(\.commands) {
            #expect(CommandRouting.isCore(c) == CommandSupport.isCore(c))
            #expect(CommandRouting.isTimelineOp(c) == CommandSupport.isTimelineOp(c))
            #expect(CommandRouting.isSupported(c) == CommandSupport.isSupported(c))
        }
    }

    @Test func handlerFollowsThePredicateOrder() {
        for c in CommandCatalog.audited(.premiereDefault) {
            let expected: CommandRouting.Handler?
            if CommandRouting.isShellCommand(c) { expected = .shell }
            else if CommandRouting.isTimelineOp(c) { expected = .timelineOp }
            else if CommandRouting.isEffectsLookOp(c) { expected = .effectsLook }
            else if CommandRouting.isCore(c) { expected = .core }
            else { expected = nil }
            #expect(CommandRouting.route(for: c)?.handler == expected, "\(c.title)")
        }
    }

    @Test func focusDependentCommandsAreFlagged() {
        for c in [EditorCommand.zoomIn, .zoomOut, .zoomFit, .find, .exportFrame, .playPause, .copy, .delete] {
            if let r = CommandRouting.route(for: c) { #expect(r.focusDependent, "\(c.title)") }
        }
    }
}
