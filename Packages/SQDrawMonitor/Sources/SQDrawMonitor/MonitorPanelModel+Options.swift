import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQPlayback
import SQUIKit

extension MonitorPanelModel {
    /// The monitor menu ("..." of the header): SQ rows built when it opens (moved from MonitorPanelView). `viewItems`:
    /// the View Gamma / Display View rows of the Mac renderer, appended to the playback group (none on Windows).
    public func optionItems(viewItems: [SQMenuItem] = []) -> [SQMenuItem] {
        let model = self
        let base = MonitorMenus.optionItems(
            mode: model.mode, available: model.availableActions, isLooping: model.isLooping, safeMargins: model.safeMargins,
            zoom: model.zoom, quality: model.quality, autoLevel: model.effectiveQuality,
            title: { MonitorFooter.symbols[$0]?.1 ?? $0.menuTitle ?? "" },
            perform: { [weak self] in self?.perform($0) },
            setZoom: { [weak self] in self?.setZoom($0) },
            setQuality: { [weak self] in self?.setQuality($0) })
        let program = model.mode == .program
        // Overlays: what is drawn over the picture.
        var overlays: [SQMenuItem] = []
        if program {
            overlays.append(SQMenuItem(title: "Show Overlays", isChecked: !model.overlaysHidden,
                                       action: { [weak self] in self?.toggleOverlays() }))
            overlays.append(SQMenuItem(title: "Platform Safe Zone", submenu: model.safeZoneMenu()))
            overlays.append(SQMenuItem(title: "Safe Margin Sizes", submenu: [
                SQMenuItem(title: "Action Safe", submenu: SafeMarginSizes.actionPresets.map { v in
                    SQMenuItem(title: "\(v)%", isChecked: v == model.safeMarginSizes.action, action: { [weak self] in
                        guard let m = self else { return }; m.safeMarginSizes = m.safeMarginSizes.settingAction(v) })
                }),
                SQMenuItem(title: "Title Safe", submenu: SafeMarginSizes.titlePresets.map { v in
                    SQMenuItem(title: "\(v)%", isChecked: v == model.safeMarginSizes.title, action: { [weak self] in
                        guard let m = self else { return }; m.safeMarginSizes = m.safeMarginSizes.settingTitle(v) })
                }),
            ]))
            overlays.append(SQMenuItem(title: "Transparency Grid", isChecked: model.showsTransparencyGrid,
                                       action: { [weak self] in guard let m = self else { return }; m.setShowsTransparencyGrid(!m.showsTransparencyGrid) }))
            overlays.append(SQMenuItem(title: "Rulers", isChecked: model.showsRulers,
                                       action: { [weak self] in guard let m = self else { return }; m.showsRulers.toggle() }))
            if !model.guides.isEmpty {
                overlays.append(SQMenuItem(title: "Clear Guides", action: { [weak self] in self?.guides.clear() }))
            }
        }
        overlays.append(SQMenuItem(title: "Resolution Badge", isChecked: model.showsResolutionBadge,
                                   action: { [weak self] in guard let m = self else { return }; m.setShowsResolutionBadge(!m.showsResolutionBadge) }))
        // Playback: how the picture is played and looked at.
        var playback: [SQMenuItem] = []
        if model.onPreviewRateChange != nil {      // the host plays at the chosen speed (Program monitor)
            playback.append(SQMenuItem(title: "Preview Speed", submenu: PreviewRate.presets.map { r in
                SQMenuItem(title: r.title, isChecked: r == model.previewRate, action: { [weak self] in self?.setPreviewRate(r) })
            }))
        }
        playback += viewItems
        // Compare: other frames and formats of the same picture.
        var compare: [SQMenuItem] = []
        if program {
            compare.append(SQMenuItem(title: "Frame Format", submenu: MonitorMenus.formatItems(
                base: model.formatBaseName, model.formatItems, current: model.formatCurrent,
                pick: { [weak self] id in self?.onPickFormat?(id) },
                add: { [weak self] p in self?.onAddFormat?(p) },
                remove: { [weak self] id in self?.onRemoveFormat?(id) })))
            compare.append(SQMenuItem(title: "Aspect Frame", submenu: AspectFrame.allCases.map { f in
                SQMenuItem(title: f.title, isChecked: f == model.aspectFrame, action: { [weak self] in self?.aspectFrame = f })
            }))
        }
        var tail: [SQMenuItem] = []
        if program, model.onShowScopes != nil {
            tail.append(SQMenuItem(title: "Scopes", action: { [weak self] in self?.onShowScopes?() }))
        }
        if program, model.onFullScreen != nil {
            tail.append(SQMenuItem(title: "Full Screen", action: { [weak self] in self?.onFullScreen?() }))
        }
        return MonitorMenus.grouped(base: base, overlays: overlays, playback: playback, compare: compare, tail: tail)
    }
}

extension ProgramEmptyKind {
    /// The Program monitor's empty-state line (ProgramEmptyView).
    public var hint: String {
        self == .emptyTimeline ? "Nothing on the timeline yet. Drop a clip here" : "Create a sequence or drop a clip here"
    }
}
