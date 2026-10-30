import AppKit
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

private func rgba(_ c: NSColor) -> [Int] {
    let s = c.usingColorSpace(.sRGB)!
    return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { Int(($0 * 255).rounded()) }
}

@Suite struct ThemeTests {
    @Test func hexValues() {
        #expect(rgba(Theme.Colors.accent) == [0xA5, 0x6B, 0xFF, 255])
        #expect(rgba(Theme.Colors.accentFill) == [0x7C, 0x3A, 0xED, 255])
        #expect(rgba(Theme.Colors.clipVideo) == [0x2F, 0x6F, 0xB0, 255])
        #expect(rgba(Theme.Colors.clipAudio) == [0x1E, 0x84, 0x49, 255])
        #expect(rgba(Theme.Colors.clipTitle) == [0x73, 0x50, 0xC0, 255])
        #expect(rgba(Theme.Colors.clipCaption) == [0xA8, 0x74, 0x1C, 255])
        #expect(rgba(Theme.Colors.clipNest) == [0x4F, 0x78, 0xA3, 255])
        #expect(rgba(Theme.Colors.clipAdjustment) == [0x4A, 0x4A, 0x4A, 255])
        #expect(rgba(Theme.Colors.clipAudioWave) == [0x9F, 0xD9, 0x8A, 255])
        #expect(rgba(Theme.Colors.meterTrack) == [0x0A, 0x0A, 0x0A, 255] && Theme.Colors.scopeBox == Theme.Colors.meterTrack)
        #expect(rgba(Theme.Colors.tileBackground) == [0x22, 0x22, 0x22, 255])
        #expect(rgba(Theme.Colors.viewerBadge) == [40, 40, 40, 217])
        #expect(rgba(Theme.Colors.tooltipEdge) == [255, 255, 255, 36])
        #expect(Theme.hex(LabelColor.videoDefault.rgb) == Theme.Colors.clipVideo && Theme.hex(LabelColor.audioDefault.rgb) == Theme.Colors.clipAudio)
        #expect(Theme.hex(LabelColor.textDefault.rgb) == Theme.Colors.clipTitle && Theme.hex(LabelColor.captionDefault.rgb) == Theme.Colors.clipCaption)
        #expect(Theme.hex(LabelColor.nestedDefault.rgb) == Theme.Colors.clipNest && Theme.hex(LabelColor.generatorDefault.rgb) == Theme.Colors.clipAdjustment)
        #expect(rgba(Theme.Colors.viewer) == [0x0C, 0x0C, 0x0C, 255])
        #expect(rgba(Theme.Colors.curveY) == [0x64, 0xD2, 0xFF, 255])
    }

    @Test func alphaTokens() {
        #expect(rgba(Theme.Colors.label) == [0xE6, 0xE6, 0xE8, 255])
        #expect(rgba(Theme.Colors.label3) == [0x9C, 0x9C, 0xA2, 255])
        #expect(rgba(Theme.Colors.accentTint)[3] == 56)                // 22 %
        #expect(rgba(Theme.Colors.overlay) == [0x2A, 0x2A, 0x2E, 255])
        #expect(rgba(Theme.Colors.divider) == [0x08, 0x08, 0x09, 255])
        #expect(rgba(Theme.Colors.selection)[3] == 36)                 // 14 %
        #expect(rgba(Theme.Colors.clipShade) == [0, 0, 0, 56])
    }

    /// Design artifact v11: neutral grays (r == g == b), the same luminance steps as the board's `--bar/--s1/--s0/--lane/--tl/--ov`.
    @Test func neutralSurfaces() {
        let surfaces = [Theme.Colors.titlebar, Theme.Colors.panel, Theme.Colors.content, Theme.Colors.lane, Theme.Colors.timeline, Theme.Colors.overlay]
        for c in surfaces.map(rgba) { #expect(c[2] >= c[0] && c[2] - c[0] <= 5) }   // slight blue lean, never a color cast
        #expect(surfaces.map { rgba($0)[1] } == [0x23, 0x1E, 0x19, 0x18, 0x15, 0x2A])
        #expect(rgba(Theme.Colors.viewer) == [0x0C, 0x0C, 0x0C, 255])
    }

    /// Feedback 2026-10-05: the area behind the Program/Source picture must be clearly lighter than the picture's black (>= 1.4:1,
    /// WCAG relative luminance), neutral, and the same color the Metal presenter clears to.
    @Test func monitorBackdropContrast() {
        func lum(_ c: NSColor) -> Double {
            let v = rgba(c).prefix(3).map { x -> Double in let s = Double(x) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
        }
        #expect(rgba(Theme.Colors.monitorBackdrop) == [0x2C, 0x2C, 0x2C, 255])
        #expect((lum(Theme.Colors.monitorBackdrop) + 0.05) / 0.05 >= 1.4)
        #expect(rgba(Theme.Colors.lane) == [0x18, 0x18, 0x1B, 255])          // timeline lanes are back at the board color
    }

    @Test func shapeAndBoardTokens() {
        #expect(Theme.Metrics.capsule == 22 && Theme.Metrics.quietButton == 22 && Theme.Metrics.quietField == 22)
        #expect(Theme.Radius.capsule() == 11 && Theme.Radius.checkbox == 4 && Theme.Radius.well == 8)
        #expect(Theme.Metrics.checkbox == 14 && Theme.Metrics.sliderKnob == 10 && Theme.Metrics.sliderTrack == 2)
        #expect(Theme.State.focusLineWidth == 1.5 && Theme.State.focusLine == Theme.Colors.accent)
        #expect(Theme.Colors.keyframeSelected == Theme.Colors.accent)
        #expect(rgba(Theme.Colors.playhead) == [255, 255, 255, 235])
        #expect(rgba(Theme.Colors.inOutWash)[3] == 15 && rgba(Theme.Colors.trackRowLine)[3] == 23)
    }

    @Test func scalesMatchDesign() {
        #expect(Theme.Spacing.scale == [2, 4, 8, 12, 16, 24])
        #expect(Theme.Spacing.iconToLabel == 6)
        #expect(Theme.Spacing.paneDivider == 2 && Theme.Radius.panel == 3)
        #expect(Theme.Radius.scale == [0, 4, 6, 8])
        #expect(Theme.Radius.none == 0 && Theme.Radius.small == 4 && Theme.Radius.control == 6 && Theme.Radius.overlay == 8)
    }

    @available(*, deprecated)
    @Test func radiusAliasesMatchNewTokens() {
        #expect(Theme.Radius.clip == Theme.Radius.small)
        #expect(Theme.Radius.row == Theme.Radius.small)
        #expect(Theme.Radius.check == Theme.Radius.small)
        #expect(Theme.Radius.field == Theme.Radius.control)
        #expect(Theme.Radius.card == Theme.Radius.overlay)
        #expect(Theme.Radius.window == Theme.Radius.none)
    }

    @Test func typeScale() {
        typealias T = Theme.Typography
        #expect(T.sizes == [10, 11, 13, 18])
        let fonts: [(NSFont, CGFloat)] = [(T.caption, 10), (T.captionStrong, 10), (T.body, 11), (T.bodyStrong, 11),
                                          (T.title, 13), (T.titleStrong, 13), (T.display, 18)]
        for (f, size) in fonts { #expect(f.pointSize == size) }
        func weight(_ f: NSFont) -> CGFloat {
            ((f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat) ?? -1
        }
        let regular = weight(NSFont.systemFont(ofSize: 11, weight: .regular))
        let medium = weight(NSFont.systemFont(ofSize: 11, weight: .medium))
        for f in [T.caption, T.body, T.title, T.display] { #expect(abs(weight(f) - regular) < 0.01) }
        for f in [T.captionStrong, T.bodyStrong, T.titleStrong] { #expect(abs(weight(f) - medium) < 0.01) }
        #expect([T.symbolSmall, T.symbolInline, T.symbolChrome] == [9, 11, 13])
    }

    @MainActor @Test func rowsStatesAndAliases() {
        #expect(Theme.Row.standard == 24 && Theme.Row.list == 24 && Theme.Row.menu == 24 && Theme.Row.property == 24)
        #expect(Theme.Row.thumb == 28 && Theme.Row.panelHeader == 30 && Theme.Row.panelHeader == Theme.Metrics.panelHeader)
        #expect(Theme.Row.menu == Theme.Overlay.rowHeight)
        #expect(Theme.Row.control == 22 && Theme.Row.controlLarge == 24 && Theme.Row.columnHeader == 22)
        #expect(Theme.Row.timelineHeader == 30 && Theme.Row.topBar == 44 && Theme.Metrics.scrubBar == 16)
        #expect(PanelID.headerHeight == Double(Theme.Row.panelHeader) && ShellMetrics.panelHeader == Theme.Row.panelHeader && ShellMetrics.topBar == Theme.Metrics.topBar)
        #expect(Theme.State.rowHover == Theme.Colors.overlayHover)
        #expect(Theme.State.selected == Theme.Colors.selection)
        #expect(Theme.State.controlHover == Theme.Colors.fillHover && Theme.State.pressed == Theme.Colors.fillPressed)
        #expect(Theme.State.selectedFocused == Theme.Colors.accentTint)
        #expect(Theme.State.focusRing == Theme.Colors.accentRing && Theme.State.panelFocusRing == Theme.Colors.focusRing)
        #expect(Theme.State.disabledText == Theme.Colors.label3 && Theme.State.disabledAlpha == 0.4)
        #expect(rgba(Theme.State.dropTargetFill)[3] == 26)
        #expect(Theme.Separator.hairline == Theme.Colors.separator && Theme.Separator.width == 1)
        #expect(rgba(Theme.OnPicture.guideSnap) == [0xFF, 0x40, 0x99, 255])
        #expect(rgba(Theme.OnPicture.offlineClip) == [0x5A, 0x1F, 0x1C, 255])
        #expect(Theme.Palette.graphCurve.count == 12)
        #expect(RulerView.color(of: .red) == Theme.Palette.marker(.red))
    }

    @Test func metricsAndFonts() {
        #expect(Theme.Metrics.topBar == 44 && Theme.Metrics.statusBar == 28 && Theme.Metrics.panelHeader == 30)
        #expect(Theme.Metrics.pushButton == 22)
        #expect(Theme.Metrics.trackV1 == 40 && Theme.Metrics.trackA1 == 32 && Theme.Metrics.trackOther == 20)
        #expect(Theme.Metrics.trackHeader == 156 && Theme.Metrics.toolColumn == 0)
        #expect(Theme.Radius.control == 6)
        #expect(Theme.Metrics.monitorHeader == 32 && Theme.Metrics.monitorFooter == 66)
        #expect(Theme.Typography.caption.pointSize == 10 && Theme.Typography.body.pointSize == 11)
        #expect(Theme.Typography.title.pointSize == 13 && Theme.Typography.display.pointSize == 18)
        #expect(Theme.Typography.clipName.pointSize == 10.5)
    }

    /// Design pass (DECISIONS 2026-10-03 "One design system"): one row pitch per family, read from `Theme.Row`.
    @MainActor @Test func panelFamiliesShareOneRowPitch() {
        #expect(Theme.Row.list == 24 && Theme.Row.property == 24 && Theme.Row.thumb == 28)
        // Lists: Library media list, Project list, Effects list (same as the Library sidebar and Keystones).
        #expect(LibraryPanelView.listRowHeight == Theme.Row.panelList)
        #expect(ProjectPanelView.listRowHeight == Theme.Row.panelList)
        #expect(TemplateListPanelView.itemRowHeight == Theme.Row.panelList)
        // Controls: every row has the grid's one pitch (v9 `--h-row`, the pitch of the right column lists), popup rows too.
        #expect(ControlsGrid.rowHeight == Theme.Row.panelList && ControlsGrid.rowHeight == Theme.Inspector.rowHeight)
        #expect(ControlsMetrics.parameter == ControlsGrid.rowHeight && ControlsMetrics.tallParameter == ControlsGrid.rowHeight)
        // Property rows: Color panel, Export settings.
        #expect(ColorGrid.row == Theme.Row.property && ColorGrid.controlRow == Theme.Metrics.quietButton + 2 * Theme.Spacing.xs)
        #expect(ExportSettingRow(title: "Codec", items: []).intrinsicContentSize.height == Theme.Row.property)
        // Floating layers: one hairline edge.
        #expect(Theme.Colors.tooltipEdge == Theme.Colors.overlayEdge && Theme.Overlay.edgeWidth == 0.5)
    }
}
