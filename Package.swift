// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BibleLookup",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything the Python server did: reference parsing, the text sources, the /api answers.
        .target(name: "BibleLookupCore"),
        // The Mac app: window, web view, menus, Settings.
        .executableTarget(name: "BibleLookup", dependencies: ["BibleLookupCore"]),
        .testTarget(
            name: "BibleLookupCoreTests",
            dependencies: ["BibleLookupCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
