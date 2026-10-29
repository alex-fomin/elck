// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "elck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElckCore", targets: ["ElckCore"]),
    ],
    targets: [
        .target(name: "ElckCore"),
        .testTarget(name: "ElckCoreTests", dependencies: ["ElckCore"]),
    ]
)
