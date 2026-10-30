// swift-tools-version: 6.2
import PackageDescription

// The Library and Effects panels on the shared draw-list toolkit (the Windows port plan, "Panel status: Library and
// Effects"): the panel models (LibraryPanelModel, the Effects catalog, folders, search terms, grid layout, menus)
// moved here from SQEditorUI, and both panels drawn on the SQDrawKit Canvas. The Mac AppKit views keep using the models
// through SQEditorUI's re-export; Windows and the Mac shared UI draw the panels. Portable: no AppKit, AVFoundation or
// CoreText imports (the pack font registration sits behind `canImport(CoreText)`).
let package = Package(
    name: "SQDrawLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQDrawLibrary", targets: ["SQDrawLibrary"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQUIKit"), .package(path: "../SQDrawKit"),
        .package(path: "../SQEditorSession"), .package(path: "../SQLibrary"), .package(path: "../SQText"),
        .package(path: "../SQInspectorUI"),
    ],
    targets: [
        .target(name: "SQDrawLibrary", dependencies: [
            "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQLibrary",
            "SQText", "SQInspectorUI",
        ]),
        .testTarget(name: "SQDrawLibraryTests", dependencies: [
            "SQDrawLibrary", "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession",
            "SQLibrary", "SQText", "SQInspectorUI",
        ]),
    ]
)
