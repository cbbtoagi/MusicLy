// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicLy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MusicLy", targets: ["MusicLy"])
    ],
    targets: [
        .executableTarget(
            name: "MusicLy",
            path: "Sources"
        )
    ]
)
