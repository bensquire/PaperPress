// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperPress",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PressKit", path: "Sources/PressKit"),
        // App layer as a library so the model is testable; the executable
        // is just the @main scene declaration.
        .target(
            name: "PressApp", dependencies: ["PressKit"],
            path: "Sources/PressApp"
        ),
        .executableTarget(
            name: "PaperPress", dependencies: ["PressApp"],
            path: "Sources/PaperPress"
        ),
        .testTarget(
            name: "PaperPressTests", dependencies: ["PressKit", "PressApp"],
            path: "Tests/PaperPressTests"
        ),
    ]
)
