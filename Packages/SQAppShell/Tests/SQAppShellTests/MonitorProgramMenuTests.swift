import Foundation
import SQAppShell
import SQCore
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

/// Mac parity: the Program monitor's right-click menu is `EditorPanels.programMenuItems` row for row.
@MainActor
struct MonitorProgramMenuTests {
    @Test func programMenuIsTheMacRows() throws {
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(),
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost(), qualityDefaults: nil)
        let rows = host.monitor.model.contextMenuBuilder?() ?? []
        let titles = rows.map { $0.kind == .separator ? "-" : $0.title }
        #expect(titles == ["Mark In", "Mark Out", "Go to In", "Go to Out", "Remove In and Out", "-",
                           "Add Marker", "Clear Range", "Delete Range", "-",
                           "Show in Source", "Show in Timeline", "Export Frame…", "-",
                           "Add Rectangle Mask", "Add Ellipse Mask", "Add Picture Mask", "Add Color Range Mask",
                           "Add Subject Mask", "Delete Masks", "-",
                           "Safe Margins", "Mask Tint", "Subject Mask Edges", "Loop Playback", "-", "Zoom"])
        // No clip selected, nothing in Source: the mask rows and Show in Timeline are off, as on the Mac.
        let off = rows.filter { !$0.isEnabled && $0.kind == .action }.map(\.title)
        #expect(off.contains("Show in Timeline") && off.contains("Add Rectangle Mask") && off.contains("Delete Masks"))
        #expect(rows.last?.submenu?.first { $0.isChecked }?.title == "Fit")
    }
}
