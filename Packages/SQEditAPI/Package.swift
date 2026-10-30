// swift-tools-version: 6.2
import PackageDescription

// Local edit API (docs/EDIT-API.md): operation schema, transaction, diff, read model, HTTP routing (pure, tested) and a
// loopback-only server (Network.framework). Depends on SQCore only; the app wires it to EditorSession.
let package = Package(
    name: "SQEditAPI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQEditAPI", targets: ["SQEditAPI"])],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQEditAPI", dependencies: ["SQCore"]),
        .testTarget(name: "SQEditAPITests", dependencies: ["SQEditAPI", "SQCore"]),
    ]
)
