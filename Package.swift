// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LarkPeek",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LarkPeek", targets: ["LarkPeek"]),
        .library(name: "LarkPeekCore", targets: ["LarkPeekCore"])
    ],
    targets: [
        .target(name: "LarkPeekCore"),
        .executableTarget(
            name: "LarkPeek",
            dependencies: ["LarkPeekCore"]
        ),
        .testTarget(
            name: "LarkPeekCoreTests",
            dependencies: ["LarkPeekCore"]
        )
    ]
)
