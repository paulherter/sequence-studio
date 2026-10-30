// swift-tools-version: 6.2
import PackageDescription

// The Timeline panel on the shared draw-list toolkit (the Windows port plan, "Panel status: Timeline"): the Mac
// TimelineView's models, layout math, hit-testing and tool logic (SQTimelineUI's portable part) drawn through the
// CGContext-shaped SQDrawKit Canvas. Windows uses it today; the Mac AppKit panel stays until a CoreGraphics canvas backend.
let package = Package(
    name: "SQDrawTimeline",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQDrawTimeline", targets: ["SQDrawTimeline"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQUIKit"), .package(path: "../SQDrawKit"),
        .package(path: "../SQEditorSession"), .package(path: "../SQTimelineUI"), .package(path: "../SQMedia"),
    ],
    targets: [
        .target(name: "SQDrawTimeline", dependencies: [
            "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQTimelineUI", "SQMedia",
        ]),
        .testTarget(name: "SQDrawTimelineTests", dependencies: [
            "SQDrawTimeline", "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQTimelineUI",
            "SQMedia",
        ]),
    ]
)
