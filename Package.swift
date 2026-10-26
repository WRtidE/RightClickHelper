// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RightClickCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RightClickCore", targets: ["RightClickCore"])],
    targets: [
        .target(name: "RightClickCore", path: "Shared", resources: [.process("Resources")]),
        .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"])
    ]
)
