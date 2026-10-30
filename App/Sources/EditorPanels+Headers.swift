import AppKit
import SQCore
import SQEditorUI

/// Panel headers (Main and Color boards): the icon buttons of the Project and Library headers, the "2 uses" text of the
/// Color header, and the Color page's own chrome (viewer header above the Program monitor, the lower panel that holds
/// the timeline).
extension EditorPanels {
    func wireHeaders() {
        monitorModel.hasSequence = session.activeTimeline != nil
        monitorModel.timelineIsEmpty = session.activeTimeline.map { $0.tracks.allSatisfy { $0.clips.isEmpty } && $0.captionTracks.allSatisfy { $0.items.isEmpty } } ?? false
        monitorModel.onNewSequence = { [weak self] in self?.onCommand?(.newSequence) }
        colorView.onStepsDetailChange = { [weak self] text in self?.onHeaderDetailChange?(.steps, text) }
        colorView.onTimelineDetailChange = { [weak self] text in self?.onHeaderDetailChange?(.timeline, text) }
        colorView.onHeaderDetailChange = { [weak self] text in self?.onHeaderDetailChange?(.colorInspector, text) }
        colorView.onGradeOutlineChange = { [weak self] s in
            guard let self, colorPageActive else { return }
            timelineView.gradeOutline = s
        }
        colorView.onSplitShownChange = { [weak self] on in self?.surface.showsSplitDivider = on }
        colorView.viewerHeader.onMore = { [weak self] point in self?.showViewerMenu(at: point) }
    }

    // MARK: Color page

    /// Entering the Color page moves the timeline (with its tool strip, without the sequence tabs) into the page's
    /// lower panel; leaving hands it back to the Timeline panel.
    func setColorPage(_ on: Bool) {
        colorView.isActive = on      // hidden Color panels skip playhead ticks (Edit page)
        guard on != colorPageActive else { return }
        colorPageActive = on
        colorView.isOnColorPage = on      // Before / Split reach the Program monitor only on the page
        timelineView.gradeOutline = on ? colorView.gradeOutline : []
        scopesView.hint = on ? colorView.controller.onScreenHint : nil      // the Edit page grades nothing
        if !on { colorView.updateSolo() }
        updateOverlay()      // transform handles hide on the Color page
    }

    /// Every Color panel uses the normal dock tab strip (no custom header): they move like the Edit panels.
    func headerView(for selected: PanelID, panels: [PanelID]) -> NSView? { nil }

    private func showViewerMenu(at screenPoint: NSPoint) {
        let items = [
            SQMenuItem(title: "Copy Grade", isEnabled: colorView.canCopyGrade) { [weak self] in
                if self?.colorView.copyGrade() != true { NSSound.beep() }
            },
            SQMenuItem(title: "Paste Grade", isEnabled: colorView.canPasteGrade) { [weak self] in
                if self?.colorView.pasteGrade() != true { NSSound.beep() }
            },
        ]
        SQMenuController.shared.present(items: items, at: screenPoint)
    }

    // MARK: Header items

    func headerItems(for p: PanelID) -> PanelHeaderItems {
        switch p {
        case .project:
            projectCountLabel.stringValue = projectView.itemCountText
            projectView.onItemCountChange = { [weak self] text in
                guard let label = self?.projectCountLabel else { return }
                label.stringValue = text
                label.invalidateIntrinsicContentSize()
                label.superview?.needsLayout = true
            }
            // v9: "14 items", New Folder, then "..." (import, new items, as List / as Icons, Search). The icon view has
            // its own way back to the list next to the breadcrumb; Up One Level is in the context menu.
            return PanelHeaderItems(accessories: projectHeaderButtons, trailing: projectCountLabel,
                                    more: { [weak self] sender in self?.projectView.showOptions(from: sender) })
        case .library:
            // v9: only "..." (view mode, Add Folder…, presets); Grid / List also sits next to the search field.
            return PanelHeaderItems(more: { [weak self] sender in self?.libraryView.showOptions(from: sender) })
        case .keystones:
            // v9: no footer; "..." saves the selected clip's keyframes as a keystone.
            return PanelHeaderItems(more: { [weak self] sender in self?.keystonesView.showOptions(from: sender) })
        case .effects:
            // Board: the Effects tab has only the search field and the outline; List / Grid moved here from the panel body.
            return PanelHeaderItems(more: { [weak self] sender in self?.effectsView.showOptions(from: sender) })
        case .colorInspector:
            // Version 9: Simple | Pro and "..." (Layout, Copy grade, Paste grade, Reset, Send Simple grade into Pro).
            return PanelHeaderItems(detail: colorView.headerDetail, trailing: colorView.gradeSwitch, more: { [weak self] sender in
                guard let self, let w = sender.window else { return }
                colorView.showMoreMenu(at: w.convertPoint(toScreen: sender.convert(NSPoint(x: sender.bounds.minX, y: sender.bounds.minY), to: nil)))
            })
        case .steps:
            return PanelHeaderItems(accessories: colorView.stepsTools.views, detail: colorView.stepsDetail)
        case .colorClips:
            return PanelHeaderItems(accessories: colorView.sourcesTools.views, detail: ColorInspectorPanelView.sourcesHint)
        case .timeline where colorPageActive:
            return PanelHeaderItems(accessories: colorView.timelineTools.views, detail: colorView.timelineDetail)
        case .programMonitor, .sourceMonitor:
            // Board: the sequence / clip popup sits in the tab strip after the tabs, "..." opens the monitor menu (both pages).
            let view = p == .programMonitor ? monitorView : source.view
            view.hostsHeaderInStrip = true
            return PanelHeaderItems(leading: view.headerAccessory, trailing: view.headerBadge, more: { [weak view] sender in view?.showOptions(from: sender) })
        default:
            return PanelHeaderItems()
        }
    }

    func makeProjectHeaderButtons() -> [NSView] {
        [IconButton(symbol: .folderAdd, label: "New Folder", size: 12) { [weak self] in self?.projectView.newFolder() }]
    }

    /// v9 `.phead .meta`: "14 items" in 11 pt `label3`, right before the header icons.
    func makeProjectCountLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.Typography.body
        l.textColor = Theme.Colors.label3
        return l
    }
}
