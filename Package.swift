// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "desktop-ops",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "desktop-ops", targets: ["desktop-ops"])
    ],
    targets: [
        .executableTarget(
            name: "desktop-ops",
            path: "Sources/desktop-ops"
        )
    ]
)
