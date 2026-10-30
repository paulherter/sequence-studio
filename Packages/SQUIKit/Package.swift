// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the lowest UI module. Theme and tokens, SQ controls, menus, dialogs, popovers, command and
// key vocabulary, keyframe graph math. Knows no session, timeline, monitor or inspector code. SQEditorUI re-exports it.
#if os(Windows)
// Windows (the Windows port plan, seam 5): the portable vocabulary only (commands, keys, settings, localization, panel
// ids, keyframe math) so the session layer builds. The AppKit/SwiftUI controls stay Mac-only until the shared toolkit
// (phase 3). A new source file that imports an Apple framework goes on this list.
let appleOnly = [
    "ControlShape.swift", "DisclosureGlyph.swift", "EmptyStateView.swift",
    "FlatSelectionRowView.swift", "IconButton.swift", "IconScrubField.swift",
    "InspectorSection.swift", "KeyframeControls.swift",
    "KeyframeToggleView.swift",
    "KeyframeZoomBar.swift", "MakeLabel.swift", "Mascot/SQMascotArt.swift",
    "Mascot/SQMascotPlace.swift", "Mascot/SQMascotSwiftUI.swift", "Mascot/SQMascotView.swift",
    "NSView+LayoutSize.swift", "NumericSlider.swift", "OverlayCursors.swift", "OverlayTokens.swift",
    "QuietList.swift", "SQAfterEvent.swift", "SQButton.swift", "SQCheckbox.swift", "SQColorPicker.swift",
    "SQDialog.swift", "SQDialogForm.swift", "SQDivider.swift", "SQEditorWindow.swift", "SQFlatButtonStyle.swift",
    "SQFloatingPanel.swift", "SQFlyToIndicator.swift", "SQFontField.swift", "SQIcon+Render.swift", "SQLoupe.swift",
    "SQMenuController.swift", "SQMenuListView.swift", "SQMenuModel+AppKit.swift", "SQMenuPopup.swift",
    "SQMenuTableView.swift", "SQModal.swift", "SQModalSheet.swift", "SQPopover.swift", "SQPopup.swift",
    "SQRadio.swift", "SQRenderSupport.swift", "SQScroller.swift", "SQSearchField.swift", "SQSegmented.swift",
    "SQSlider.swift", "SQSwiftUIChrome.swift", "SQTextField.swift", "SQTextFieldMenu.swift", "SQToast.swift",
    "SQTooltip.swift", "SQUnitLabel.swift", "SQWindowLights.swift", "SQWindowTitleStrip.swift",
    "ScrollHoverSync.swift", "ScrubField.swift", "ShellMetrics.swift", "Theme.swift", "ThemeAppearance.swift",
    "ThemePlayhead.swift", "ThemeTimelineSkin.swift", "ThemeTokens.swift",
    "Tooltip.swift", "UIScale.swift", "UIScaleRelayout.swift", "ZoomScrollBar.swift",
]
let portableTests = [
    "AngleKeyBindingTests.swift", "AppMenuLiteralTests.swift", "AppVersionTests.swift",
    "AppearancePaletteTests.swift", "AutosaveVersionLabelTests.swift", "CloseProjectCommandTests.swift",
    "ImportedCommandSupportTests.swift", "KeyframeNudgeKeyTests.swift", "KeymapTemplateTests.swift",
    "LocalizationTests.swift", "MarkerListCommandTests.swift", "MenuCatalogParityTests.swift",
    "MenuLimitsTests.swift", "MenuPathTextTests.swift", "MonitorViewCommandTests.swift", "PanelCycleTests.swift",
    "PremiereResolveImportTests.swift", "ReplaceModeMenuTests.swift", "SQAccessibilityTextTests.swift",
    "SQByteSizeTests.swift", "SQColorRecentsTests.swift", "SQColorValueTests.swift", "SQFontFieldModelTests.swift",
    "SQMascotReactorTests.swift", "ScrubMathTests.swift", "ShortcutAuditTests.swift", "ShortcutGapsTests.swift",
    "ShortcutTableTests.swift", "ShortformCommandsVisibleTests.swift", "TimecodeStartEntryTests.swift",
    "TrimModeShiftTTests.swift",
]
let package = Package(
    name: "SQUIKit",
    products: [.library(name: "SQUIKit", targets: ["SQUIKit"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQText"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQUIKit", dependencies: ["SQCore", "SQText", "SQMedia"], exclude: appleOnly,
                resources: [.copy("Resources/Icons"), .copy("Resources/Localization"), .copy("Resources/Mascot")]),
        .testTarget(name: "SQUIKitTests", dependencies: ["SQCore", "SQMedia", "SQUIKit"], sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQUIKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQUIKit", targets: ["SQUIKit"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQText"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQUIKit", dependencies: ["SQCore", "SQText", "SQMedia"], resources: [.copy("Resources/Icons"), .copy("Resources/Localization"), .copy("Resources/Mascot")]),
        .testTarget(name: "SQUIKitTests", dependencies: ["SQCore", "SQMedia", "SQUIKit"]),
    ]
)
#endif
