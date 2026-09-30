// swift-tools-version: 6.2
import PackageDescription

// Throwaway Phase 0 spike (decode + scrub measurements). Not product code: Swift 5 mode on purpose.
let package = Package(
    name: "DecodeSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "DecodeSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
