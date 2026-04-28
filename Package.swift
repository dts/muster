// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusterCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MusterCore",
            targets: ["MusterCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "MusterCore",
            dependencies: []
        ),
        .testTarget(
            name: "MusterCoreTests",
            dependencies: ["MusterCore"]
        ),
    ]
)
