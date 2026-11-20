// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PillChat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PillChat",
            path: "Sources/PillChat",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
