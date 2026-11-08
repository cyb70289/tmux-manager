// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TmuxManager",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TmuxManagerCore"),
        .executableTarget(name: "TmuxManager", dependencies: ["TmuxManagerCore"]),
        .testTarget(name: "TmuxManagerCoreTests", dependencies: ["TmuxManagerCore"]),
    ]
)
