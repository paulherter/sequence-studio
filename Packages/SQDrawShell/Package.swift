// swift-tools-version: 6.2
import PackageDescription

// SQDrawShell: the app shell of the shared toolkit (the Windows port plan, "Panel status: App shell"): menu bar and menus,
// dialogs, the shortcut route, window title, recents. It is the Mac shell code (App/Sources MenuBuilder, SQUIKit SQMenuListView,
// SQDialog) translated onto the SQDrawKit Canvas: the menu and dialog models stay the SQUIKit ones, only drawing and event glue
// are new. Own package because it needs SQEditorSession, which SQDrawKit's other users must not pull in.
let package = Package(
    name: "SQDrawShell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQDrawShell", targets: ["SQDrawShell"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQUIKit"), .package(path: "../SQDrawKit"),
        .package(path: "../SQEditorSession"), .package(path: "../SQPremiereImport"),
        .package(path: "../SQExport"), .package(path: "../SQMedia"), .package(path: "../SQLibrary"),
    ],
    targets: [
        .target(name: "SQDrawShell", dependencies: [
            "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQPremiereImport", "SQExport",
            .product(name: "SQMedia", package: "SQMedia"), "SQLibrary",
        ]),
        .testTarget(name: "SQDrawShellTests", dependencies: [
            "SQDrawShell", "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession",
            "SQPremiereImport", "SQExport", .product(name: "SQMedia", package: "SQMedia"), "SQLibrary",
        ]),
    ]
)
