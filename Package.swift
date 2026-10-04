// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackHole",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BlackHole", targets: ["BlackHole"]),
    ],
    targets: [
        .executableTarget(
            name: "BlackHole",
            path: "Sources/BlackHole"
        ),
    ]
)
