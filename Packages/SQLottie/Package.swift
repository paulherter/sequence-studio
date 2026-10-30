// swift-tools-version: 6.2
import PackageDescription

// ThorVG v1.1.2 (MIT), vendored in Sources/CThorVG (software renderer + Lottie/PNG/JPG loaders; see docs/THIRD_PARTY.md).
// Windows (the Windows port plan): the documents and `portableFrame` build everywhere; LottieRenderer.swift (CoreVideo
// buffers) compiles out, and the CoreVideo tests stay on the Mac.
#if os(Windows)
let tests = Target.testTarget(name: "SQLottieTests", dependencies: ["SQCore", "SQRender", "SQLottie"],
                              exclude: ["LottieRendererTests.swift"])
#else
let tests = Target.testTarget(name: "SQLottieTests", dependencies: ["SQCore", "SQRender", "SQLottie",
                                                                    .product(name: "SQFrameCoreVideo", package: "SQFrame")])
#endif

let package = Package(
    name: "SQLottie",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQLottie", targets: ["SQLottie"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQFrame")],
    targets: [
        .target(
            name: "CThorVG",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."), .headerSearchPath("inc"), .headerSearchPath("src/common"),
                .headerSearchPath("src/renderer"), .headerSearchPath("src/renderer/cpu_engine"),
                .headerSearchPath("src/loaders/lottie"), .headerSearchPath("src/loaders/raw"),
                .headerSearchPath("src/loaders/png"), .headerSearchPath("src/loaders/jpg"),
                .define("TVG_STATIC"),
                // windows.h (pulled in by tvgCommon.h) would turn min/max into macros.
                .define("NOMINMAX", .when(platforms: [.windows])), .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows])),
                .define("_USE_MATH_DEFINES", .when(platforms: [.windows])),
            ]),
        .target(name: "SQLottie", dependencies: ["SQCore", "SQRender", "CThorVG"]),
        tests,
    ],
    cxxLanguageStandard: .cxx17
)
