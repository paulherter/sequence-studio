// swift-tools-version: 6.2
import PackageDescription

// DECISIONS: SSEditorUI will depend on SSCore, SSMedia, SSRender, SSPlayback.
// For now only SSCore; add the others when a slice needs them (viewer/monitor panels).
let package = Package(
    name: "SSEditorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSEditorUI", targets: ["SSEditorUI"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSEditorUI", dependencies: ["SSCore"]),
        .testTarget(name: "SSEditorUITests", dependencies: ["SSEditorUI"]),
    ]
)
