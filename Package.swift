// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperPress",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PressKit", path: "Sources/PressKit"),
        .executableTarget(
            name: "PaperPress", dependencies: ["PressKit"],
            path: "Sources/PaperPress"
        ),
        .testTarget(
            name: "PressKitTests", dependencies: ["PressKit"],
            path: "Tests/PressKitTests"
        ),
    ]
)
