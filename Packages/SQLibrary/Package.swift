// swift-tools-version: 6.2
import PackageDescription

#if os(Windows)
// Windows (the Windows port plan, seam 5): the portable part only: presets, packs, LUT and title libraries, folder scan,
// search, preview request queue and the `FolderWatching` / `PreviewProvider` seams. The AVFoundation preview players and
// thumbnail provider and the FSEvents watcher are Mac-only. A new source file that imports an Apple framework goes on
// this list.
let appleOnly = [
    "AudioPreviewPlayer.swift", "FSEventsFolderWatcher.swift", "LibraryPreviewPlayer.swift", "MediaPreviewProvider.swift",
]
let appleOnlyTests = ["FSEventsWatcherTests.swift", "LibraryPreviewPlayerTests.swift", "MediaPreviewProviderTests.swift"]
let package = Package(
    name: "SQLibrary",
    products: [.library(name: "SQLibrary", targets: ["SQLibrary"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQLibrary", dependencies: ["SQCore", .product(name: "SQMedia", package: "SQMedia")], exclude: appleOnly),
        .testTarget(name: "SQLibraryTests", dependencies: ["SQCore", "SQLibrary", .product(name: "SQMedia", package: "SQMedia")],
                    exclude: appleOnlyTests),
    ]
)
#else
let package = Package(
    name: "SQLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQLibrary", targets: ["SQLibrary"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQLibrary", dependencies: ["SQCore", .product(name: "SQMedia", package: "SQMedia")]),
        .testTarget(name: "SQLibraryTests", dependencies: ["SQCore", 
            "SQLibrary",
            .product(name: "SQMedia", package: "SQMedia"),
            .product(name: "SQMediaTestSupport", package: "SQMedia"),
        ]),
    ]
)
#endif
