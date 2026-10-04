// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PaperPress",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PressKit", path: "Sources/PressKit"),
        // The job vocabulary the app and its assistant helper share: a request,
        // its status, and the socket messages that carry them.
        .target(name: "PressJobs", dependencies: ["PressKit"], path: "Sources/PressJobs"),
        // The Model Context Protocol, written by hand (as in Prospect), and
        // PaperPress's tools over it. No AppKit: the app and its launcher are
        // protocols a test stands in for.
        .target(
            name: "PressMCP", dependencies: ["PressJobs", "PressKit"], path: "Sources/PressMCP"
        ),
        // The helper an assistant launches, shipped in PaperPress.app/Contents/MacOS:
        // stdio in, the app's socket out.
        .executableTarget(
            name: "paperpress-mcp", dependencies: ["PressMCP"], path: "Sources/paperpress-mcp"
        ),
        // App layer as a library so the model is testable; the executable
        // is just the @main scene declaration.
        .target(
            name: "PressApp", dependencies: ["PressKit", "PressJobs"],
            path: "Sources/PressApp"
        ),
        .executableTarget(
            name: "PaperPress", dependencies: ["PressApp"],
            path: "Sources/PaperPress"
        ),
        .testTarget(
            name: "PaperPressTests",
            dependencies: ["PressKit", "PressJobs", "PressMCP", "PressApp"],
            path: "Tests/PaperPressTests"
        ),
    ]
)
