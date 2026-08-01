// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nickel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nickel",
            path: "Sources/Nickel"
        ),
        .testTarget(
            name: "NickelTests",
            dependencies: ["Nickel"],
            path: "Tests/NickelTests"
        )
    ]
)
