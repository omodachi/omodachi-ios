// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteInputCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RemoteInputCore", targets: ["RemoteInputCore"])
    ],
    targets: [
        .target(name: "RemoteInputCore"),
        .testTarget(name: "RemoteInputCoreTests", dependencies: ["RemoteInputCore"])
    ]
)
