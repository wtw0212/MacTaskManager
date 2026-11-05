// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TaskManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TaskManager",
            path: "Sources/TaskManager",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
