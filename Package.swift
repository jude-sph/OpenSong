// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenSong",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "OpenSongCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "OpenSong",
            dependencies: ["OpenSongCore"]
        ),
        .executableTarget(
            name: "OpenSongTests",
            dependencies: ["OpenSongCore"],
            path: "Sources/OpenSongTests",
            resources: []
        ),
    ]
)
