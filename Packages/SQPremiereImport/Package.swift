// swift-tools-version: 6.2
import PackageDescription

// Reads Adobe Premiere Pro projects (.prproj) into the SQCore model (docs/PRPROJ-IMPORT.md). Foundation + Compression only:
// no AVFoundation/AppKit; the app probes the media after import.
let package = Package(
    name: "SQPremiereImport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQPremiereImport", targets: ["SQPremiereImport"])],
    // SQAudioFX only for the tests: imported voice presets run through the real clip chain (peak / clipping checks).
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQText"), .package(path: "../SQAudioFX")],
    targets: [
        .target(name: "SQPremiereImport", dependencies: ["SQCore", "SQText"]),
        .testTarget(name: "SQPremiereImportTests", dependencies: ["SQCore", "SQText", "SQPremiereImport",
                                 .product(name: "SQAudioFX", package: "SQAudioFX", condition: .when(platforms: [.macOS]))],
                    resources: [.copy("Fixtures")]),
    ]
)
