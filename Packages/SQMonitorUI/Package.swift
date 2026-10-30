// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the monitor view layer above SQEditorSession. Viewer, monitor panel, overlays, scopes,
// meters, trim monitor. Knows no timeline or inspector view code. SQEditorUI re-exports it.
let package = Package(
    name: "SQMonitorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQMonitorUI", targets: ["SQMonitorUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQCore"),
        .package(path: "../SQRender"), .package(path: "../SQText"), .package(path: "../SQAudioFX"),
        .package(path: "../SQMedia"), .package(path: "../SQPlayback"), .package(path: "../SQDrawKit"),
        .package(path: "../SQDrawMonitor"),
    ],
    targets: [
        .target(name: "SQMonitorUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQCore", "SQText", "SQAudioFX", "SQMedia", "SQPlayback",
            .product(name: "SQRender", package: "SQRender"), .product(name: "SQDrawKit", package: "SQDrawKit"), "SQDrawMonitor",
        ]),
        .testTarget(name: "SQMonitorUITests", dependencies: [
            "SQCore", "SQAudioFX", "SQMedia", "SQPlayback", "SQText", "SQMonitorUI", "SQEditorSession", "SQUIKit",
            .product(name: "SQRender", package: "SQRender"),
        ]),
    ]
)
