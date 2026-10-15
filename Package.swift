// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkinTone",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SkinTone",
            path: "Sources/SkinTone"
        )
    ]
)
