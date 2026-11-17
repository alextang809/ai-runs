// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIRuns",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIRuns", targets: ["AIRunsApp"]),
        .executable(name: "airuns-hook", targets: ["airuns-hook"]),
        .library(name: "AIRunsCore", targets: ["AIRunsCore"]),
    ],
    targets: [
        .target(name: "AIRunsCore"),
        .executableTarget(name: "airuns-hook", dependencies: ["AIRunsCore"]),
        .executableTarget(name: "AIRunsApp", dependencies: ["AIRunsCore"]),
        .testTarget(name: "AIRunsCoreTests", dependencies: ["AIRunsCore"]),
    ]
)
