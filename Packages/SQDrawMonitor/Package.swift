// swift-tools-version: 6.2
import PackageDescription

// The monitors on the shared draw-list toolkit (the Windows port plan, "Panel status: monitors"): the Mac monitor's
// model (MonitorPanelModel), its menus and command routing moved here from SQMonitorUI, and the Program / Source
// monitor panel translated from MonitorPanelView onto the SQDrawKit Canvas. The Mac AppKit views keep using the model
// and menus through SQMonitorUI's re-export; Windows draws the panel.
let package = Package(
    name: "SQDrawMonitor",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQDrawMonitor", targets: ["SQDrawMonitor"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQUIKit"), .package(path: "../SQDrawKit"),
        .package(path: "../SQEditorSession"), .package(path: "../SQPlayback"), .package(path: "../SQMedia"),
        .package(path: "../SQGPU"), .package(path: "../SQAudioFX"),
    ],
    targets: [
        .target(name: "SQDrawMonitor", dependencies: [
            "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQPlayback",
            "SQMedia", .product(name: "SQGPUKernels", package: "SQGPU"), "SQAudioFX",
        ]),
        .testTarget(name: "SQDrawMonitorTests", dependencies: [
            "SQDrawMonitor", "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession",
            "SQPlayback", .product(name: "SQGPUKernels", package: "SQGPU"), "SQAudioFX",
        ]),
    ]
)
