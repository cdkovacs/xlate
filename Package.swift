// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Xlate",
    platforms: [.macOS(.v26)],
    dependencies: [
        // argmax-oss-swift 1.1.1 (released 2026-10-08), formerly WhisperKit.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "XlateCore", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ]),
        .executableTarget(name: "Xlate", dependencies: ["XlateCore"]),
        .testTarget(name: "XlateCoreTests", dependencies: ["XlateCore"]),
    ]
)
