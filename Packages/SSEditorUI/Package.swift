// swift-tools-version: 6.2
import PackageDescription

// DECISIONS: SSEditorUI will depend on SSCore, SSMedia, SSRender, SSPlayback.
// So far SSCore, SSRender (scopes), SSExport, SSText, SSAudioFX, SSTranscribe, SSLibrary; add the others when a slice needs them.
let package = Package(
    name: "SSEditorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSEditorUI", targets: ["SSEditorUI"])],
    dependencies: [
        .package(path: "../SSCore"), .package(path: "../SSRender"), .package(path: "../SSExport"),
        .package(path: "../SSText"), .package(path: "../SSAudioFX"), .package(path: "../SSTranscribe"),
        .package(path: "../SSLibrary"), .package(path: "../SSMedia"),
    ],
    targets: [
        .target(name: "SSEditorUI", dependencies: [
            "SSCore", "SSExport", "SSText", "SSAudioFX", "SSTranscribe", "SSLibrary", "SSMedia",
            .product(name: "SSRender", package: "SSRender"),
        ]),
        .testTarget(name: "SSEditorUITests", dependencies: ["SSEditorUI", .product(name: "SSRender", package: "SSRender")]),
    ]
)
