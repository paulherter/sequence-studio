// swift-tools-version: 6.2
import PackageDescription

// ONNX Runtime behind a small Swift face (the Windows port plan, "Magic mask on Windows"). The C target loads
// onnxruntime.dll (MIT, Microsoft; ORT-LICENSE-MIT.txt) at run time and asks for the DirectML provider, so the app starts
// without the DLL. On the Mac the same API builds and reports "unavailable" (the Mac runs Core ML).
let package = Package(
    name: "SQOnnx",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQOnnx", targets: ["SQOnnx"])],
    targets: [
        .target(name: "CSQOnnx"),
        .target(name: "SQOnnx", dependencies: ["CSQOnnx"]),
        .testTarget(name: "SQOnnxTests", dependencies: ["SQOnnx"]),
    ]
)
