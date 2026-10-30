import Foundation
import SQCore
import SQEditorSession

extension MonitorPanelModel {
    /// Program monitor format switcher follows the session (cheap; writes only what changed).
    public func syncFormats(from session: EditorSession) {
        let t = session.activeTimeline
        let base = t.map { SequenceConform.aspectLabel(width: $0.format.displayWidth, height: $0.format.height) } ?? ""
        let items = t?.variants.map { FormatItem(id: $0.id, name: $0.name) } ?? []
        let current = session.activeVariantID
        // Title popup: the open sequences (tabs), the shown one checked. Picking one makes it the active sequence.
        let open = session.sequenceTabs.tabs.compactMap { tab -> SequenceItem? in
            session.project.timeline(tab.root).map { SequenceItem(id: tab.root, name: $0.name) }
        }
        let shown = session.sequenceTabs.tabs.first(where: { $0.shown == session.activeTimelineID })?.root ?? session.activeTimelineID
        if sequenceItems != open { sequenceItems = open }
        if sequenceCurrent != shown { sequenceCurrent = shown }
        if onPickSequence == nil { onPickSequence = { [weak session] id in session?.selectSequenceTab(root: id) } }
        if formatBaseName != base { formatBaseName = base }
        let name = t?.name ?? ""
        if sequenceName != name { sequenceName = name }
        if formatItems != items { formatItems = items }
        if formatCurrent != current { formatCurrent = current }
    }
}
