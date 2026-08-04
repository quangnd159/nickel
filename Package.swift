// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nickel",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "NickelObjCShims",
            path: "Sources/NickelObjCShims"
        ),
        .executableTarget(
            name: "Nickel",
            dependencies: ["NickelObjCShims"],
            path: "Sources/Nickel"
        ),
        .testTarget(
            name: "NickelTests",
            dependencies: ["Nickel"],
            path: "Tests/NickelTests"
        )
    ]
)
