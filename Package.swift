// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iMemory",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "imemory-scan", targets: ["imemory-scan"]),
        .executable(name: "iMemoryApp", targets: ["iMemoryApp"]),
    ],
    targets: [
        .target(name: "ScanKit"),
        .target(
            name: "RulesKit",
            dependencies: ["ScanKit"],
            resources: [.embedInCode("catalog.json")]
        ),
        .target(name: "AppsKit", dependencies: ["ScanKit"]),
        .target(name: "DuplicateKit", dependencies: ["ScanKit"]),
        // The only target allowed to change the disk.
        .target(name: "CleanKit", dependencies: ["RulesKit", "ScanKit"]),
        .executableTarget(name: "imemory-scan", dependencies: ["ScanKit"]),
        .executableTarget(
            name: "iMemoryApp",
            dependencies: ["ScanKit", "RulesKit", "CleanKit", "AppsKit", "DuplicateKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit", "RulesKit", "ScanKit", "AppsKit", "DuplicateKit"]),
    ]
)
