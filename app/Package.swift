// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JevFolderSort",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JevFolderSort", targets: ["JevFolderSort"]),
        .library(name: "JevFolderSortCore", targets: ["JevFolderSortCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "JevFolderSortCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(name: "JevFolderSort", dependencies: ["JevFolderSortCore"]),
        // Run with scripts/test.sh (handles machines with only the Command Line Tools).
        .testTarget(name: "JevFolderSortCoreTests", dependencies: ["JevFolderSortCore"]),
    ],
    swiftLanguageModes: [.v5]
)
