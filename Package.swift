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
        ),
        // Optional privileged helper, installed setuid-root only when the user asks (Settings or Processes).
        .executableTarget(
            name: "tmhelper",
            path: "Sources/tmhelper"
        ),
    ]
)
