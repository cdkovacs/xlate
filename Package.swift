// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Xlate",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "XlateCore"),
        .executableTarget(name: "Xlate", dependencies: ["XlateCore"]),
        .testTarget(name: "XlateCoreTests", dependencies: ["XlateCore"]),
    ]
)
