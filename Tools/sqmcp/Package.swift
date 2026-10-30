// swift-tools-version: 6.2
import PackageDescription

// MCP stdio shim for the local edit API (docs/EDIT-API.md). Foundation only; talks to the running app over 127.0.0.1.
// Build: `cd Tools/sqmcp && /usr/bin/swift build -c release` -> .build/release/sqmcp
let package = Package(
    name: "sqmcp",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "sqmcp")]
)
