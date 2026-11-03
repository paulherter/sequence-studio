// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the lowest UI module. Theme and tokens, SQ controls, menus, dialogs, popovers, command and
// key vocabulary, keyframe graph math. Knows no session, timeline, monitor or inspector code.

#if os(Windows)
// Windows runs only the tests of portable logic (the rest import Apple frameworks).
let testSources: [String]? = [
    "AngleKeyBindingTests.swift",
    "AppMenuLiteralTests.swift",
    "AppVersionTests.swift",
    "AppearancePaletteTests.swift",
    "AutosaveVersionLabelTests.swift",
    "CloseProjectCommandTests.swift",
    "ImportedCommandSupportTests.swift",
    "KeyframeNudgeKeyTests.swift",
    "KeymapTemplateTests.swift",
    "LocalizationTests.swift",
    "MarkerListCommandTests.swift",
    "MenuCatalogParityTests.swift",
    "MenuLimitsTests.swift",
    "MenuPathTextTests.swift",
    "MonitorViewCommandTests.swift",
    "PanelCycleTests.swift",
    "PremiereResolveImportTests.swift",
    "ReplaceModeMenuTests.swift",
    "SQAccessibilityTextTests.swift",
    "SQByteSizeTests.swift",
    "SQColorRecentsTests.swift",
    "SQColorValueTests.swift",
    "SQFontFieldModelTests.swift",
    "SQMascotReactorTests.swift",
    "ScrubMathTests.swift",
    "ShortcutAuditTests.swift",
    "ShortcutGapsTests.swift",
    "ShortcutTableTests.swift",
    "ShortformCommandsVisibleTests.swift",
    "TimecodeStartEntryTests.swift",
    "TrimModeShiftTTests.swift",
]
#else
let testSources: [String]? = nil
#endif
let package = Package(
    name: "SQUIKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQUIKit", targets: ["SQUIKit"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQText"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQUIKit", dependencies: ["SQCore", "SQText", "SQMedia"], resources: [.copy("Resources/Icons"), .copy("Resources/Localization"), .copy("Resources/Mascot")]),
        .testTarget(name: "SQUIKitTests", dependencies: ["SQCore", "SQMedia", "SQUIKit"], sources: testSources),
    ]
)
