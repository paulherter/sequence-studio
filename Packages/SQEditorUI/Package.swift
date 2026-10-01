// swift-tools-version: 6.2
import PackageDescription

// DECISIONS: SQEditorUI depends on SQCore, SQMedia, SQRender, SQPlayback.
// So far SQCore, SQRender (scopes), SQExport, SQText, SQAudioFX, SQTranscribe, SQLibrary; add the others when a slice needs them.
let package = Package(
    name: "SQEditorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQEditorUI", targets: ["SQEditorUI"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQExport"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
    ],
    targets: [
        .target(name: "SQEditorUI", dependencies: [
            "SQCore", "SQExport", "SQText", "SQAudioFX", "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback",
            .product(name: "SQRender", package: "SQRender"),
        ]),
        .testTarget(name: "SQEditorUITests", dependencies: ["SQEditorUI", .product(name: "SQRender", package: "SQRender")]),
    ]
)
