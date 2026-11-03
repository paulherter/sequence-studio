import Foundation
import Testing
@testable import SQDrawKit
import SQUIKit

/// `SQTokens` (SQUIKit/DesignTokens.swift) is the only home of the shared design values: DrawTheme, TimelineSkin and the
/// AppKit Theme read it. These tests fail when a copy differs or when a literal creeps back into the readers.
@Suite struct DesignTokensTests {
    @Test func drawThemeReadsTheTokens() {
        typealias M = DrawTheme.Metrics
        typealias T = SQTokens.Metrics
        let pairs: [(Float, Float)] = [
            (M.topBar, T.topBar), (M.statusBar, T.statusBar), (M.panelHeader, T.panelHeader), (M.trackV1, T.trackV1),
            (M.trackA1, T.trackA1), (M.trackOther, T.trackOther), (M.trackHeader, T.trackHeader), (M.capsule, T.capsule),
            (M.monitorHeader, T.monitorHeader), (M.monitorFooter, T.monitorFooter), (M.monitorStrip, T.monitorStrip),
            (M.monitorSliderMaxWidth, T.monitorSliderMaxWidth), (M.monitorSliderHeight, T.monitorSliderHeight),
            (M.monitorDimWidth, T.monitorDimWidth), (M.monitorDimHeight, T.monitorDimHeight), (M.scrubBar, T.scrubBar),
            (M.sequenceTabs, T.sequenceTabs), (M.ruler, T.ruler), (M.clipNameBand, T.clipNameBand), (M.paneDivider, T.paneDivider),
            (DrawTheme.Spacing.xxs, SQTokens.Spacing.xxs), (DrawTheme.Spacing.xs, SQTokens.Spacing.xs), (DrawTheme.Spacing.sm, SQTokens.Spacing.sm),
            (DrawTheme.Spacing.md, SQTokens.Spacing.md), (DrawTheme.Spacing.lg, SQTokens.Spacing.lg), (DrawTheme.Spacing.xl, SQTokens.Spacing.xl),
            (DrawTheme.Radius.panel, SQTokens.Radius.panel), (DrawTheme.Radius.small, SQTokens.Radius.small), (DrawTheme.Radius.control, SQTokens.Radius.control),
            (DrawTheme.TypeSize.caption, SQTokens.TypeSize.caption), (DrawTheme.TypeSize.body, SQTokens.TypeSize.body),
            (DrawTheme.TypeSize.clipName, SQTokens.TypeSize.clipName), (DrawTheme.TypeSize.title, SQTokens.TypeSize.title),
            (DrawTheme.TypeSize.display, SQTokens.TypeSize.display), (DrawTheme.TypeSize.list, SQTokens.TypeSize.list),
            (DrawTheme.TypeSize.heading, SQTokens.TypeSize.heading),
            (DrawTheme.Spacing.snug, SQTokens.Spacing.snug), (DrawTheme.Spacing.wide, SQTokens.Spacing.wide), (DrawTheme.Spacing.xxl, SQTokens.Spacing.xxl),
            (DrawTheme.Radius.none, SQTokens.Radius.none), (DrawTheme.Radius.overlay, SQTokens.Radius.overlay),
            (DrawTheme.Radius.menu, SQTokens.Radius.menu), (DrawTheme.Radius.card, SQTokens.Radius.card),
            (DrawTheme.Height.compact, SQTokens.Height.compact), (DrawTheme.Height.normal, SQTokens.Height.normal),
            (DrawTheme.Height.large, SQTokens.Height.large), (DrawTheme.Height.panelList, SQTokens.Height.panelList),
        ]
        for (i, p) in pairs.enumerated() { #expect(p.0 == p.1, "pair \(i)") }
    }

    @Test func drawThemeAlphasAreTheTokens() {
        let t = DrawTheme()
        #expect(t.fill == t.inkFill(SQTokens.Alpha.fill))
        #expect(t.fillHover == t.inkFill(SQTokens.Alpha.fillHover))
        #expect(t.fillPressed == t.inkFill(SQTokens.Alpha.fillPressed))
        #expect(t.separator == t.inkLine(SQTokens.Alpha.separator))
        #expect(t.rulerLine == t.inkLine(SQTokens.Alpha.rulerLine))
        #expect(t.monitorBackdrop == DrawColor(hex: SQTokens.Hex.monitorBackdrop))
        #expect(t.viewer == DrawColor(hex: SQTokens.Hex.viewer))
        #expect(t.yellow == DrawColor(hex: SQTokens.Hex.yellow))
    }

    /// No second copy: the readers hold no numeric literal for a token (hex, ink alpha, metric, radius, size).
    @Test func readersHoldNoLiteralCopy() throws {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = ["SQDrawKit/Sources/SQDrawKit/DrawTheme.swift", "SQDrawTimeline/Sources/SQDrawTimeline/TimelineSkin.swift",
                     "SQUIKit/Sources/SQUIKit/Theme.swift", "SQUIKit/Sources/SQUIKit/ThemeTimelineSkin.swift"]
        let forbidden = [#"0x[0-9A-Fa-f]{6}"#, #"(inkFill|inkLine|\.alpha|withAlpha|withAlphaComponent)\(0?\.[0-9]"#,
                         #"static let \w+: (Float|CGFloat) = (UIScale\.scaled\()?[0-9]"#, #"UIScale\.scaled\([0-9]"#]
        for f in files {
            let text = try String(contentsOf: packages.appendingPathComponent(f), encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for pat in forbidden where l.range(of: pat, options: .regularExpression) != nil && !Self.knownOpen.contains(where: { l.contains($0) }) {
                    Issue.record("\(f):\(n + 1) holds a token literal: \(l)")
                }
            }
        }
    }

    /// Mac-only values that have no portable twin yet (Theme-only metrics, palette inputs): listed so a new copy still fails.
    static let knownOpen = [
        "treeIndent", "iconToLabel", "inset: CGFloat", "toolColumn", "checkbox", "sliderKnob", "sliderTrack", "statusLine",
        "tabUnderline", "focusRingWidth", "barIconWidth", "workspacePopupWidth", "none: CGFloat", "inner:", "overlay: CGFloat",
        "menu: CGFloat", "checkbox:", "well:", "UIScale.scaled(9)",
        // colors with no draw twin or a different light/dark rule
        "clipAudioWave", "clipCaptionWord", "skimmer", "support", "sliderKnob", "chevron", "pictureBadge", "viewerBadge", "meterTrack",
        "scopeBox", "tileBackground", "curveX", "curveY", "marker =", "field =", "selection =", "accentRing", "focusRing", "inOutWash",
        "range", "graph", "scrim", "overlayEdge", "overlayHover", "rowAlt", "onClip", "clipSelect", "waveform", "nameOnLight",
        "fxPill", "itemBar", "silence", "duckCurve", "static func white", "static func black", "hex(0xFFFFFF)", "lift", "tooltipEdge",
        "DrawColor(0.", "case .green: DrawColor(hex", "static func hex", "withAlpha(0.45)", "withAlpha(0.", "Theme.dynamic { PaletteColor.black",
        "func shade", "gray(", "hex(LabelColor", "fillAlpha", "UIScale.scaled(48)",
    ]
}

#if canImport(AppKit)
@Suite @MainActor struct ThemeTokensMirrorTests {
    @Test func themeReadsTheTokens() {
        func eq(_ a: CGFloat, _ b: Float, _ name: String) { #expect(Double(a) == Double(b), Comment(rawValue: name)) }
        eq(Theme.Metrics.topBar, SQTokens.Metrics.topBar, "topBar")
        eq(Theme.Metrics.statusBar, SQTokens.Metrics.statusBar, "statusBar")
        eq(Theme.Metrics.panelHeader, SQTokens.Metrics.panelHeader, "panelHeader")
        eq(Theme.Metrics.trackV1, SQTokens.Metrics.trackV1, "trackV1")
        eq(Theme.Metrics.trackA1, SQTokens.Metrics.trackA1, "trackA1")
        eq(Theme.Metrics.trackOther, SQTokens.Metrics.trackOther, "trackOther")
        eq(Theme.Metrics.trackHeader, SQTokens.Metrics.trackHeader, "trackHeader")
        eq(Theme.Metrics.capsule, SQTokens.Metrics.capsule, "capsule")
        eq(Theme.Metrics.pushButton, SQTokens.Metrics.pushButton, "pushButton")
        eq(Theme.Metrics.quietButton, SQTokens.Metrics.quietButton, "quietButton")
        eq(Theme.Metrics.quietField, SQTokens.Metrics.quietField, "quietField")
        eq(Theme.Metrics.barControl, SQTokens.Metrics.barControl, "barControl")
        eq(Theme.Metrics.monitorHeader, SQTokens.Metrics.monitorHeader, "monitorHeader")
        eq(Theme.Metrics.monitorFooter, SQTokens.Metrics.monitorFooter, "monitorFooter")
        eq(Theme.Metrics.monitorStrip, SQTokens.Metrics.monitorStrip, "monitorStrip")
        eq(Theme.Metrics.monitorSliderMaxWidth, SQTokens.Metrics.monitorSliderMaxWidth, "monitorSliderMaxWidth")
        eq(Theme.Metrics.monitorSliderHeight, SQTokens.Metrics.monitorSliderHeight, "monitorSliderHeight")
        eq(Theme.Metrics.monitorDimWidth, SQTokens.Metrics.monitorDimWidth, "monitorDimWidth")
        eq(Theme.Metrics.monitorDimHeight, SQTokens.Metrics.monitorDimHeight, "monitorDimHeight")
        eq(Theme.Metrics.scrubBar, SQTokens.Metrics.scrubBar, "scrubBar")
        eq(Theme.Metrics.sequenceTabs, SQTokens.Metrics.sequenceTabs, "sequenceTabs")
        eq(Theme.Spacing.paneDivider, SQTokens.Metrics.paneDivider, "paneDivider")
        eq(Theme.Spacing.xxs, SQTokens.Spacing.xxs, "xxs"); eq(Theme.Spacing.xs, SQTokens.Spacing.xs, "xs")
        eq(Theme.Spacing.sm, SQTokens.Spacing.sm, "sm"); eq(Theme.Spacing.md, SQTokens.Spacing.md, "md")
        eq(Theme.Spacing.lg, SQTokens.Spacing.lg, "lg"); eq(Theme.Spacing.xl, SQTokens.Spacing.xl, "xl")
        eq(Theme.Radius.panel, SQTokens.Radius.panel, "panel"); eq(Theme.Radius.small, SQTokens.Radius.small, "small")
        eq(Theme.Radius.control, SQTokens.Radius.control, "control")
        eq(Theme.Typography.captionSize, SQTokens.TypeSize.caption, "caption")
        eq(Theme.Typography.bodySize, SQTokens.TypeSize.body, "body")
        eq(Theme.Typography.titleSize, SQTokens.TypeSize.title, "title")
        eq(Theme.Typography.displaySize, SQTokens.TypeSize.display, "display")
        eq(Theme.Typography.clipName.pointSize, SQTokens.TypeSize.clipName, "clipName")
        eq(Theme.Selection.outlineWidth, Float(SQTokens.Timeline.selectionOutlineWidth), "outlineWidth")
    }

    @Test func themeAlphasAreTheTokens() {
        #expect(Theme.Colors.fill.alphaComponent > 0)
        #expect(Double(Theme.OnPicture.clipBadgeFill.alphaComponent) == SQTokens.Alpha.badgeFill)
        #expect(Double(Theme.OnPicture.clipBadgeEdge.alphaComponent) == SQTokens.Alpha.badgeEdge)
        #expect(Double(Theme.TimelineSkin.clipEdge.alphaComponent) == SQTokens.Alpha.clipEdge)
        #expect(Double(Theme.TimelineSkin.thumbRule.alphaComponent) == SQTokens.Alpha.thumbRule)
        #expect(Double(Theme.TimelineSkin.inOutBand.alphaComponent) == SQTokens.Alpha.inOutBand)
        #expect(Double(Theme.TimelineSkin.inOutBandEdge.alphaComponent) == SQTokens.Alpha.inOutBandEdge)
        #expect(Double(Theme.Colors.clipShade.alphaComponent) == SQTokens.Alpha.clipShade)
        #expect(Double(Theme.Colors.viewerHUD.alphaComponent) == SQTokens.Alpha.viewerHUD)
        #expect(Double(Theme.Colors.guide.alphaComponent) == SQTokens.Alpha.guide)
        #expect(Double(Theme.Colors.platformMock.alphaComponent) == SQTokens.Alpha.platformMock)
    }
}
#endif
